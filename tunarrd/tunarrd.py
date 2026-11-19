#!/opt/homebrew/bin/python3
"""Tunarr PiP's deliberately small, stdlib-only player daemon."""
import base64, fcntl, json, os, queue, random, secrets, signal, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen
from mpvctl import MPV

DEFAULT = {'baseUrl': None, 'user': None, 'streamViaTv': False, 'width':480, 'height':270,
           'margin':16, 'warmMinutes':15, 'volStep':5, 'mpv':'/opt/homebrew/bin/mpv'}

class Daemon:
 def __init__(self):
  self.dir=Path(os.environ.get('TUNARRD_DIR', Path.home()/'Library/Application Support/tunarr-pip')); self.dir.mkdir(parents=True,exist_ok=True); os.chmod(self.dir,0o700)
  self.config=DEFAULT.copy(); p=self.dir/'config.json'
  if p.exists(): self.config.update(json.loads(p.read_text()))
  self.sock=os.environ.get('TUNARRD_SOCK','/tmp/tunarr-pipd.sock'); self.port=int(os.environ.get('TUNARRD_PORT','7849'))
  self.config['mpv']=os.environ.get('TUNARRD_MPV',self.config['mpv']); self.token=self._token()
  # Test mode is hermetic: no Keychain, network, or real media device access.
  self.auth=os.environ.get('TUNARRD_AUTH') or (None if os.getenv('TUNARRD_TEST')=='1' else self._keychain()); self.scale=self._scale()
  self.q=queue.Queue(); self.stop_event=threading.Event(); self.warm=None; self.channels=None; self.channels_at=0; self.channel=None; self.last=None
  self.hidden=False; self.screen=None; self.fullscreen=False; self.frame=None; self.state_lock=threading.Lock(); self.last_write=0; self.write_timer=None
  self.events=0; self.events_lock=threading.Lock(); self.mpv=MPV(self.config['mpv'],self.sock,self._mpv_exit)
  self._write_state(True)
 def _token(self):
  p=self.dir/'token'
  if not p.exists(): p.write_text(secrets.token_hex(16)); os.chmod(p,0o600)
  return p.read_text().strip()
 def _keychain(self):
  if not self.config.get('user'): return None
  try:
   return 'Basic '+base64.b64encode((self.config['user']+':'+subprocess.check_output(['/usr/bin/security','find-generic-password','-s','tunarr-pip','-a',self.config['user'],'-w'],stderr=subprocess.DEVNULL).decode().strip()).encode()).decode()
  except (OSError,subprocess.CalledProcessError): print('tunarrd: no keychain password',file=sys.stderr); return None
 def _scale(self):
  if os.getenv('TUNARRD_TEST')=='1': return 2
  try: return float(subprocess.check_output(['/usr/bin/osascript','-l','JavaScript','-e','ObjC.import("AppKit");$.NSScreen.mainScreen.backingScaleFactor'],stderr=subprocess.DEVNULL).decode())
  except Exception: return 2
 def _state(self):
  return {'pid':self.mpv.pid,'frame':self.frame,'hidden':self.hidden,'screen':self.screen,'panel':{'frame':None,'visible':False,'tab':'tv'},'pickerVisible':False,'ts':time.time()}
 def _write_state(self, now=False):
  with self.state_lock:
   delay=.25-(time.monotonic()-self.last_write)
   if not now and delay>0:
    if not self.write_timer: self.write_timer=threading.Timer(delay,self._deferred_write); self.write_timer.daemon=True; self.write_timer.start()
    return
   self.write_timer=None; self.last_write=time.monotonic(); data=json.dumps(self._state(),separators=(',',':'))
   fd,tmp=tempfile.mkstemp(prefix='state.',dir=self.dir); os.write(fd,data.encode()); os.close(fd); os.replace(tmp,self.dir/'state.json')
 def _deferred_write(self): self._write_state(True)
 def _mpv_exit(self,p):
  self.channel=None; self.hidden=False; self.screen=None; self.fullscreen=False; self._write_state()
 def _heartbeat(self):
  # tunarr_keys.lua treats a state.json older than 15 s as a dead player: refresh it while mpv exists.
  every=float(os.environ.get('TUNARRD_HEARTBEAT','5'))
  while not self.stop_event.wait(every):
   if self.mpv.pid: self._write_state(True)
 def run(self):
  threading.Thread(target=self._consume,daemon=True).start(); threading.Thread(target=self._heartbeat,daemon=True).start()
  self.server=ThreadingHTTPServer(('127.0.0.1',self.port),Handler); self.server.daemon=self; self.server.serve_forever()
 def _consume(self):
  while not self.stop_event.is_set():
   try: cmd=self.q.get(.2); self.apply(cmd)
   except queue.Empty: pass
   except Exception as e: print('tunarrd command:',e,file=sys.stderr)
 def source(self,n):
  return f'av://lavfi:testsrc=size=640x360:rate=10' if os.getenv('TUNARRD_TEST')=='1' else f"{self.config['baseUrl'].rstrip('/')}/stream/channels/{n}.ts"
 def _args(self,n,screen=None):
  c=self.config; geom=f"--geometry={round(c['width']*self.scale)}x{round(c['height']*self.scale)}-{round(c['margin']*self.scale)}-{round(c['margin']*self.scale)}"
  a=['--no-config','--no-terminal',f'--title=Tunarr ch{n}','--force-window=immediate','--ontop','--no-border','--on-all-workspaces',geom,'--keepaspect-window=no','--native-fs=no','--hwdec=videotoolbox','--profile=low-latency','--cache=yes','--cache-pause=yes','--cache-pause-wait=3','--demuxer-readahead-secs=8','--demuxer-lavf-analyzeduration=0.5','--stream-lavf-o=reconnect=1,reconnect_streamed=1,reconnect_delay_max=5',f'--input-ipc-server={self.sock}',f'--script={Path(__file__).resolve().parent.parent}/static.lua',f'--http-header-fields=Authorization: {self.auth or ""}','--keep-open=no','--start=none']
  if os.getenv('TUNARRD_TEST')=='1': a.append('--no-audio')
  a += ['--fullscreen',f'--fs-screen-name={screen}'] if screen else ['--no-fullscreen']; return a+[self.source(n)]
 def _cancel_warm(self):
  if self.warm: self.warm.cancel(); self.warm=None
 def play(self,n):
  self.last=n
  if not self.mpv.pid: self.mpv.start(self._args(n,self.screen if self.fullscreen else None)); self.channel=n; self.hidden=False
  elif self.channel != n:
   self.show(); h=f'Authorization: {self.auth or ""}'; self.mpv.command(['change-list','http-header-fields','set',h]); self.mpv.command(['set_property','start','none']); self.mpv.command(['set_property','pause',False]); self.mpv.command(['loadfile',self.source(n),'replace']); self.mpv.command(['set_property','title',f'Tunarr ch{n}']); self.channel=n
  elif self.hidden: self.show()
  else: self.hide()
  self._write_state()
 def hide(self):
  self.mpv.command(['set_property','mute',True]); self.mpv.command(['set_property','window-minimized',True]); self.hidden=True; self._cancel_warm(); self.warm=threading.Timer(float(self.config['warmMinutes'])*60,self.stop); self.warm.daemon=True; self.warm.start(); self._write_state()
 def show(self):
  self._cancel_warm(); self.mpv.command(['set_property','window-minimized',False]); self.mpv.command(['set_property','mute',False]); self.hidden=False; self._write_state()
 def stop(self): self._cancel_warm(); self.mpv.stop(); self.channel=None; self.hidden=False; self.screen=None; self.fullscreen=False; self._write_state()
 def _channels(self):
  if self.channels is not None and time.monotonic()-self.channels_at<60:return self.channels
  if not self.auth and os.getenv('TUNARRD_TEST')!='1': raise RuntimeError('no keychain password')
  req=Request(self.config['baseUrl'].rstrip('/')+'/api/channels',headers={'Authorization':self.auth})
  try: data=json.load(urlopen(req,timeout=5))
  except OSError:
   if self.channels is not None: return self.channels # stale list beats no list
   raise
  data=data.get('data',data) if isinstance(data,dict) else data
  self.channels=sorted(int(x.get('number',x.get('id'))) for x in data); self.channels_at=time.monotonic(); return self.channels
 def apply(self,x):
  cmd=x.get('cmd')
  if cmd=='play': self.play(int(x['ch']))
  elif cmd=='stop': self.stop()
  elif cmd=='volume': self.mpv.command(['osd-msg-bar','add','volume',x.get('d',0)])
  elif cmd in ('step','random'):
   ns=self._channels()
   if cmd=='random': pool=[n for n in ns if n!=self.channel]; self.play(random.choice(pool)) if pool else None
   else:
    d=int(x.get('d',1)); old=self.channel if self.channel is not None else self.last
    if old is None: self.play(ns[0 if d>0 else -1])
    else:
     after=[n for n in ns if n>old] if d>0 else [n for n in ns if n<old]
     self.play((after[0] if d>0 else after[-1]) if after else (ns[0] if d>0 else ns[-1]))
  elif cmd=='pip':
   if self.fullscreen: self.mpv.command(['set_property','fullscreen',False]); self.fullscreen=False; self.screen=None; self._write_state()
  elif cmd=='playon':
   n=x.get('ch') or self.last or (self._channels()[0]); self.screen=x.get('screen'); self.fullscreen=True
   if not self.mpv.pid: self.play(n)
   else: self.play(n) if self.channel!=n else self.show(); self.mpv.command(['set_property','fullscreen',False]); self.mpv.command(['set_property','fs-screen-name',self.screen]); self.mpv.command(['set_property','fullscreen',True]); self._write_state()

class Handler(BaseHTTPRequestHandler):
 def log_message(self,*x): pass
 def _ok(self):
  q=parse_qs(urlparse(self.path).query); return self.headers.get('X-Tunarr-Token')==self.server.daemon.token or q.get('t',[None])[0]==self.server.daemon.token
 def _json(self,status,obj): self.send_response(status); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(json.dumps(obj).encode())
 def do_GET(self):
  if not self._ok(): return self._json(403,{'error':'forbidden'})
  if urlparse(self.path).path=='/state': return self._json(200,self.server.daemon._state() | {'channel':self.server.daemon.channel,'tape':None})
  if urlparse(self.path).path=='/events':
   d=self.server.daemon
   with d.events_lock:
    if d.events>=2:return self._json(429,{'error':'too many event clients'})
    d.events+=1
   try:
    self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Cache-Control','no-cache');self.end_headers()
    while not d.stop_event.wait(15): self.wfile.write(b'event: ping\ndata: {}\n\n');self.wfile.flush()
   except (BrokenPipeError,ConnectionResetError): pass
   finally:
    with d.events_lock:d.events-=1
   return
  self._json(404,{'error':'not found'})
 def do_POST(self):
  if not self._ok():return self._json(403,{'error':'forbidden'})
  try: body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or b'{}')
  except json.JSONDecodeError:return self._json(400,{'error':'bad json'})
  d=self.server.daemon; path=urlparse(self.path).path
  if path=='/window': d.frame=body.get('frame') if body.get('onscreen',True) else None; d._write_state(); return self._json(202,{'queued':True})
  if path=='/cmd':
   if body.get('cmd') in ('find','panel','vhsnow'): return self._json(501,{'error':'step 4'})
   if not d.auth and os.getenv('TUNARRD_TEST')!='1' and body.get('cmd') in ('play','step','random','playon'):return self._json(503,{'error':'no keychain password'})
   d.q.put(body); return self._json(202,{'queued':True})
  self._json(404,{'error':'not found'})

def main():
 lock=open('/tmp/tunarr-pipd.lock','w')
 try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 except BlockingIOError: print('tunarrd: already running',file=sys.stderr); return 0
 d=Daemon()
 signal.signal(signal.SIGTERM,lambda *a:(_ for _ in ()).throw(KeyboardInterrupt()))
 try:d.run()
 except KeyboardInterrupt:pass
 finally:d.stop(); d.stop_event.set()
 return 0
if __name__=='__main__': raise SystemExit(main())
