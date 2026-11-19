#!/opt/homebrew/bin/python3
"""Tunarr PiP's deliberately small, stdlib-only player daemon."""
import base64, fcntl, json, os, queue, random, secrets, signal, subprocess, sys, tempfile, threading, time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from mpvctl import MPV
from store import PositionStore
from tvsite import TvSite
from bus import Bus

DEFAULT = {'baseUrl': None, 'user': None, 'streamViaTv': False, 'width':480, 'height':270,
           'margin':16, 'warmMinutes':15, 'volStep':5, 'mpv':'/opt/homebrew/bin/mpv',
           'fzf':'/opt/homebrew/bin/fzf', 'evalEnabled':False}

class Daemon:
 def __init__(self):
  self.dir=Path(os.environ.get('TUNARRD_DIR', Path.home()/'Library/Application Support/tunarr-pip')); self.dir.mkdir(parents=True,exist_ok=True); os.chmod(self.dir,0o700)
  self.config=DEFAULT.copy(); p=self.dir/'config.json'
  if p.exists(): self.config.update(json.loads(p.read_text()))
  self.sock=os.environ.get('TUNARRD_SOCK','/tmp/tunarr-pipd.sock'); self.port=int(os.environ.get('TUNARRD_PORT','7849'))
  self.config['mpv']=os.environ.get('TUNARRD_MPV',self.config['mpv']); self.token=self._token()
  # Test mode is hermetic: no Keychain, network, or real media device access.
  self.auth=os.environ.get('TUNARRD_AUTH') or (None if os.getenv('TUNARRD_TEST')=='1' else self._keychain()); self.scale=self._scale()
  self.tv_password=os.getenv('TUNARRD_TVPW') or self._tv_password()
  self.tv=TvSite(self.config['tvUrl'],self.config['tvUser'],self.tv_password) if self.config.get('tvUrl') and self.config.get('tvUser') and self.tv_password else None
  self.store=PositionStore(self.dir); self.tape=None; self.vibe=None; self.vibe_raw=None; self.receivers=[]; self.cast_to=None; self.cast_ch=None; self.active_rx=None; self.cast_topics={}; self.beating=False; self.last_beat=0; self.last_vibe=0; self.last_receivers=0; self.last_canary=0; self.pool=ThreadPoolExecutor(max_workers=3)
  self.q=queue.Queue(); self.stop_event=threading.Event(); self.warm=None; self.channels=None; self.channels_at=0; self.channel=None; self.last=None
  self.hidden=False; self.screen=None; self.fullscreen=False; self.frame=None; self.panel={'frame':None,'visible':False}; self.panelTab='tv'; self.state_lock=threading.Lock(); self.last_write=0; self.write_timer=None
  self.bus=Bus(); self.shelf_cache=None; self.shelf_at=0; self.by_key={}; self.cover_cache={}; self.surf_level=0; self.surf_timer=None; self.xray_cache=None; self.xray_loading=False
  self.events=0; self.events_lock=threading.Lock(); self.mpv=MPV(self.config['mpv'],self.sock,self._mpv_exit,self._mpv_event)
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
 def _tv_password(self):
  if not self.config.get('tvUser') or os.getenv('TUNARRD_TEST')=='1': return None
  try:return subprocess.check_output(['/usr/bin/security','find-generic-password','-s','craigo-tv','-a',self.config['tvUser'],'-w'],stderr=subprocess.DEVNULL).decode().strip()
  except (OSError,subprocess.CalledProcessError): return None
 def _scale(self):
  if os.getenv('TUNARRD_TEST')=='1': return 2
  try: return float(subprocess.check_output(['/usr/bin/osascript','-l','JavaScript','-e','ObjC.import("AppKit");$.NSScreen.mainScreen.backingScaleFactor'],stderr=subprocess.DEVNULL).decode())
  except Exception: return 2
 def _state(self):
  panel=getattr(self,'panel',{'frame':None,'visible':False}) | {'tab':getattr(self,'panelTab','tv')}
  return {'pid':self.mpv.pid,'frame':self.frame,'hidden':self.hidden,'screen':self.screen,'panel':panel,'pickerVisible':bool(panel.get('visible') and self.panelTab=='tv'),'ts':time.time(),'vibe':self.vibe,'receivers':self.receivers,'cast':self.cast_to,'trophy':getattr(self,'trophy',None)}
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
  self.end_tape(False)
  self.channel=None; self.hidden=False; self.screen=None; self.fullscreen=False; self._write_state()
 def _mpv_event(self,event):
  if event.get('event')=='end-file' and event.get('reason')=='eof': self.end_tape(True)
  if event.get('event')=='client-message': self._mpv_message(event.get('args') or [])
 def _heartbeat(self):
  # tunarr_keys.lua treats a state.json older than 15 s as a dead player: refresh it while mpv exists.
  every=float(os.environ.get('TUNARRD_HEARTBEAT','5'))
  while not self.stop_event.wait(every):
   if self.mpv.pid: self._write_state(True)
 def run(self):
  threading.Thread(target=self._consume,daemon=True).start(); threading.Thread(target=self._heartbeat,daemon=True).start(); threading.Thread(target=self._tick,daemon=True).start()
  self.server=ThreadingHTTPServer(('127.0.0.1',self.port),Handler); self.server.daemon=self; self.server.serve_forever()
 def _consume(self):
  while not self.stop_event.is_set():
   try: cmd=self.q.get(.2); self.apply(cmd)
   except queue.Empty: pass
   except Exception as e: print('tunarrd command:',e,file=sys.stderr)
 def source(self,n):
  return f'av://lavfi:testsrc=size=640x360:rate=10' if os.getenv('TUNARRD_TEST')=='1' else f"{self.config['baseUrl'].rstrip('/')}/stream/channels/{n}.ts"
 def _tick(self):
  every=float(os.getenv('TUNARRD_TICK','15'))
  while not self.stop_event.wait(every):
   if self.mpv.pid: self.pool.submit(self._watch)
   if self.tv and time.monotonic()-self.last_vibe>=120: self.last_vibe=time.monotonic(); self.pool.submit(self.load_vibe)
   if self.tv and time.monotonic()-self.last_receivers>=15: self.last_receivers=time.monotonic(); self.pool.submit(self.refresh_receivers)
   if self.config.get('canaryUrl') and time.monotonic()-self.last_canary>=3600: self.last_canary=time.monotonic(); self.pool.submit(self.canary)
 def _watch(self):
  idle=self.mpv.get_property('core-idle'); pos=self.mpv.get_property('time-pos'); duration=self.mpv.get_property('duration')
  if self.tape and pos is not None and int(pos)>10 and int(pos)%60<15: self.store.set('pos.'+self.tape['key'],int(pos))
  active=not idle and not self.hidden and (self.channel is not None or self.tape)
  if active and self.tv and time.monotonic()-self.last_beat>=58:
   self.last_beat=time.monotonic(); now=time.localtime(); status,data,_=self.tv.request('POST','/api/beat',{'channel':self.channel or 0,'day':time.strftime('%Y-%m-%d',now),'late':now.tm_hour<5}); self.beating=status==200
   if isinstance(data,dict) and data.get('trophies'): self.trophy=data['trophies']; self.mpv.command(['show-text',str(data['trophies'])]); self.load_vibe()
  elif not active and self.beating: self.unbeat()
 def unbeat(self):
  if self.tv and self.beating: self.tv.request('DELETE','/api/beat')
  self.beating=False
 def _args(self,n,screen=None):
  c=self.config; geom=f"--geometry={round(c['width']*self.scale)}x{round(c['height']*self.scale)}-{round(c['margin']*self.scale)}-{round(c['margin']*self.scale)}"
  a=['--no-config','--no-terminal',f'--title=Tunarr ch{n}','--force-window=immediate','--ontop','--no-border','--on-all-workspaces',geom,'--keepaspect-window=no','--native-fs=no','--hwdec=videotoolbox','--profile=low-latency','--cache=yes','--cache-pause=yes','--cache-pause-wait=3','--demuxer-readahead-secs=8','--demuxer-lavf-analyzeduration=0.5','--stream-lavf-o=reconnect=1,reconnect_streamed=1,reconnect_delay_max=5',f'--input-ipc-server={self.sock}',f'--script={Path(__file__).resolve().parent.parent}/static.lua',f'--http-header-fields=Authorization: {self.auth or ""}','--keep-open=no','--start=none']
  if os.getenv('TUNARRD_TEST')=='1': a.append('--no-audio')
  a += ['--fullscreen',f'--fs-screen-name={screen}'] if screen else ['--no-fullscreen']; return a+[self.source(n)]
 def _cancel_warm(self):
  if self.warm: self.warm.cancel(); self.warm=None
 def play(self,n):
  self.end_tape()
  self.last=n
  if not self.mpv.pid: self.mpv.start(self._args(n,self.screen if self.fullscreen else None)); self.channel=n; self.hidden=False
  elif self.channel != n:
   self.show(); h=f'Authorization: {self.auth or ""}'; self.mpv.command(['change-list','http-header-fields','set',h]); self.mpv.command(['set_property','start','none']); self.mpv.command(['set_property','pause',False]); self.mpv.command(['loadfile',self.source(n),'replace']); self.mpv.command(['set_property','title',f'Tunarr ch{n}']); self.channel=n
  elif self.hidden: self.show()
  else: self.hide()
  self.mpv.command(['script-message-to','xray','enable','0' if self.hidden else '1']); self._write_state()
 def hide(self):
  self.mpv.command(['set_property','pause',True] if self.tape else ['set_property','mute',True]); self.mpv.command(['set_property','window-minimized',True]); self.mpv.command(['script-message-to','xray','enable','0']); self.hidden=True; self._cancel_warm(); self.warm=threading.Timer(float(self.config['warmMinutes'])*60,self.stop); self.warm.daemon=True; self.warm.start(); self.pool.submit(self.unbeat); self._write_state()
 def show(self):
  self._cancel_warm(); self.mpv.command(['set_property','window-minimized',False]); self.mpv.command(['set_property','pause',False] if self.tape else ['set_property','mute',False]); self.mpv.command(['script-message-to','xray','enable','1']); self.hidden=False; self._write_state()
 def stop(self): self._cancel_warm(); self.end_tape(); self.pool.submit(self.unbeat); self.mpv.command(['script-message-to','xray','enable','0']); self.mpv.stop(); self.channel=None; self.hidden=False; self.screen=None; self.fullscreen=False; self._write_state()
 def play_tape(self,x):
  if not self.tv:return
  if self.tv.request('GET','/api/me')[0]!=200:return
  self.end_tape(); key=x['key']; sid=''.join(random.choice('abcdefghijklmnopqrstuvwxyz0123456789') for _ in range(8))+format(time.time_ns(),'x')
  self.tape={'key':key,'title':x.get('title',''),'show':x.get('show'),'duration':x.get('duration',0),'sid':sid}; self.channel=None
  url=self.config['tvUrl'].rstrip('/')+'/api/vhs/play/'+key+'.m3u8?s='+sid; start=self.store.get('pos.'+key,0); title='VHS · '+(' · '.join(z for z in (x.get('show'),x.get('title')) if z))
  cookie=self.tv.cookie_header()
  if not self.mpv.pid:
   args=self._args(0,self.screen if self.fullscreen else None); args[-1]=url; args.insert(-1,'--http-header-fields=Cookie: '+cookie); args.insert(-1,'--start='+str(start)); self.mpv.start(args)
  else:
   self.show(); self.mpv.command(['change-list','http-header-fields','set','Cookie: '+cookie]); self.mpv.command(['set_property','start',start]); self.mpv.command(['loadfile',url,'replace']); self.mpv.command(['set_property','title',title])
  self.hidden=False; self._write_state()
 def end_tape(self,ended=False):
  tape=self.tape
  if not tape:return
  pos=self.mpv.get_property('time-pos') or 0; duration=self.mpv.get_property('duration') or tape.get('duration',0)
  if self.tv:self.pool.submit(self.tv.request,'GET','/api/vhs/stop?s='+tape['sid'])
  if ended and duration and pos>=duration-180:
   self.store.set('done.'+tape['key'],True)
   if self.tv:
    self.pool.submit(self._rewind)
  elif pos>10:self.store.set('pos.'+tape['key'],int(pos))
  self.tape=None
 def _rewind(self):
  _,data,_=self.tv.request('POST','/api/vhs/rewind',{})
  if isinstance(data,dict) and data.get('trophies'): self.trophy=data['trophies']; self._write_state(); self.load_vibe()
 def load_vibe(self):
  if not self.tv:return
  status,data,raw=self.tv.request('GET','/api/vibe?day='+time.strftime('%Y-%m-%d'))
  if status==200 and isinstance(data,dict):
   self.vibe_raw=raw.decode('utf-8',errors='replace') if isinstance(raw,bytes) else str(raw or '')
   self.vibe=data
   self._write_state()
 def refresh_receivers(self):
  if not self.tv:return
  status,data,_=self.tv.request('GET','/api/cast/receivers')
  if status==200:
   self.receivers=data.get('data',data) if isinstance(data,dict) else data
   if not isinstance(self.receivers,list): self.receivers=[]
   found=None; open_here=False
   for receiver in self.receivers:
    if receiver.get('name')==self.cast_to:
     found=self.cast_to; open_here=True; self.cast_ch=receiver.get('ch'); break
    if found is None and isinstance(receiver.get('ch'),int): found=receiver.get('name')
   if self.cast_to and not open_here: self.cast_to=None
   self.active_rx=found; self._write_state()
 def _ntfy(self,topic,message,headers=None):
  if not topic:return
  base=self.config.get('ntfyUrl','https://ntfy.sh')
  if os.getenv('TUNARRD_TEST')=='1' and urlparse(base).hostname not in ('127.0.0.1','localhost','::1'):return
  req=Request(base.rstrip('/')+'/'+topic,data=message.encode(),method='POST',headers=headers or {})
  try:urlopen(req,timeout=5).read()
  except OSError:pass
 def cast(self,i):
  if not self.tv:return
  casts=self.config.get('cast') or []
  try: receiver=casts[int(i)-1]
  except (IndexError, TypeError, ValueError): return
  if not receiver:return
  rx=receiver.get('rx'); wake=receiver.get('wake')
  if not rx:return
  status,data,_=self.tv.request('GET','/api/cast/here?rx='+rx)
  if not (isinstance(data,dict) and data.get('here')):
   self._ntfy(wake,'Opening the receiver',{'Title':'tunarr cast','Click':self.config.get('tvUrl','').rstrip('/')+'/?cast='+rx,'Priority':'high'})
   # The first failed check is try one; Lua makes at most 20 checks total.
   for _ in range(19):
    if self.stop_event.wait(3): return
    _,data,_=self.tv.request('GET','/api/cast/here?rx='+rx)
    if isinstance(data,dict) and data.get('here'): break
   else:return
  n=self.channel if self.mpv.pid and self.channel is not None else (data.get('ch') if isinstance(data,dict) else None) or self.last or 1
  if self.mpv.pid: self.stop()
  if self.cast_to: self._cast_tune('off')
  self.cast_to=rx; self.cast_ch=n; self._write_state(); self._cast_tune('tune',n)
 def _cast_tune(self,cmd,ch=None):
  if not self.tv or not self.cast_to:return
  topic=self.cast_topics.get(self.cast_to)
  if not topic:
   status,data,_=self.tv.request('GET','/api/cast?rx='+self.cast_to)
   topic=data.get('topic') if isinstance(data,dict) else None
   if topic:self.cast_topics[self.cast_to]=topic
  if topic:
   body={'cmd':cmd}
   if cmd=='tune': body['ch']=ch
   self._ntfy(topic,json.dumps(body))
 def canary(self):
  try:status=urlopen(self.config['canaryUrl'],timeout=5).status
  except HTTPError as e:status=e.code # any answer means the port reopened, as hs.http status > 0
  except OSError:return
  if status>0:
   try: subprocess.call([os.getenv('TUNARRD_NOTIFY','/usr/bin/osascript'),'-e','display notification "Tunarr canary"'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   except OSError: pass
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
 def _cast_step_random(self,cmd,x):
  ns=self._channels()
  current=self.cast_ch if self.cast_ch is not None else self.last
  if cmd=='random':
   pool=[n for n in ns if n!=current]; n=random.choice(pool) if pool else None
  else:
   d=int(x.get('d',1)); after=[n for n in ns if n>current] if current is not None and d>0 else [n for n in ns if n<current] if current is not None else []
   n=(after[0] if d>0 else after[-1]) if after else ns[0 if d>0 else -1]
  if n is not None: self.last=n; self.cast_ch=n; self._cast_tune('tune',n); self._write_state()
 def _step_random(self,cmd,x):
  ns=self._channels()
  if cmd=='random': pool=[n for n in ns if n!=self.channel]; self.play(random.choice(pool)) if pool else None
  else:
   d=int(x.get('d',1)); old=self.channel if self.channel is not None else self.last
   if old is None: self.play(ns[0 if d>0 else -1])
   else:
    after=[n for n in ns if n>old] if d>0 else [n for n in ns if n<old]
    self.play((after[0] if d>0 else after[-1]) if after else (ns[0] if d>0 else ns[-1]))
 def _playon(self,x):
  n=x.get('ch') or self.last or self._channels()[0]; self.screen=x.get('screen'); self.fullscreen=True
  if not self.mpv.pid: self.play(n)
  else: self.play(n) if self.channel!=n else self.show(); self.mpv.command(['set_property','fullscreen',False]); self.mpv.command(['set_property','fs-screen-name',self.screen]); self.mpv.command(['set_property','fullscreen',True]); self._write_state()
 def emit(self, verb, *args): self.bus.emit(verb, *args)
 def _remote_sync(self):
  self.emit('now', self._now_text()); self.emit('current', self.channel or False, self.hidden); self._surf_sync()
 def _now_text(self):
  return ('CH %s' % self.channel) if self.channel is not None else ('VHS · '+self.tape.get('title','') if self.tape else '')
 def _surf_sync(self):
  labels=('SURF','30S','1M','3M','5M','15M','30M','60M'); self.emit('surf',labels[self.surf_level],self.surf_level>1)
 def _load_shelves(self):
  if not self.tv:return
  lists=[]
  for shelf in ('new','movies','tv'):
   status,data,_=self.tv.request('GET','/api/vhs/shelf?shelf='+shelf)
   lists.append(data if status==200 and isinstance(data,list) else [])
  all_,seen=[],set()
  for i,items in enumerate(lists):
   for item in items:
    if isinstance(item,dict) and item.get('key') not in seen:
     seen.add(item.get('key')); item=dict(item); item['isNew']=True if i==0 else None
     item['pos']=self.store.get('pos.'+item['key']); item['done']=self.store.get('done.'+item['key']) or None
     all_.append(item); self.by_key[item['key']]=item
  self.shelf_cache=all_; self.shelf_at=time.monotonic(); self.emit('shelves',all_)
 def shelves(self):
  if self.shelf_cache is not None and time.monotonic()-self.shelf_at<600:self.emit('shelves',self.shelf_cache)
  else:self._load_shelves()
 def cover(self, ident):
  if not isinstance(ident,str) or not __import__('re').match(r'^\d+/\d+$',ident):return
  if ident in self.cover_cache:self.emit('cover',ident,self.cover_cache[ident]); return
  if not self.tv:return
  status,_,raw=self.tv.request('GET','/api/vhs/cover/'+ident)
  if status==200 and raw:
   value='data:image/jpeg;base64,'+base64.b64encode(raw).decode(); self.cover_cache[ident]=value; self.emit('cover',ident,value)
 def open_show(self,key):
  if not self.tv:return
  status,data,_=self.tv.request('GET','/api/vhs/tape/'+str(key))
  if status==200 and isinstance(data,dict):
   for ep in data.get('episodes',[]):
    ep['show']=data.get('title'); self.by_key[ep.get('key')]=ep
   self.emit('show',data)
  else:self.emit('show',{'error':status})
 def xray(self):
  if not self.tv:return
  n=self.cast_ch if self.cast_to else self.channel
  if self.cast_to:
   st,data,_=self.tv.request('GET','/api/cast/here?rx='+self.cast_to)
   if st==200 and isinstance(data,dict) and isinstance(data.get('ch'),int): n=self.cast_ch=data['ch']
  if not n:self.emit('xray',None); return
  status,data,_=self.tv.request('GET','/api/xray/'+str(n)); self.emit('xray',data if status==200 and data else {'error':status})
 def person(self,name):
  if not self.tv:return
  name=str(name)[:80]; status,data,_=self.tv.request('GET','/api/xray/person?name='+quote(name)); self.emit('person',name,data if status==200 else None)
 def filter(self,x):
  seq,q,lines=x.get('seq'),x.get('q'),x.get('lines')
  fzf=self.config.get('fzf','/opt/homebrew/bin/fzf')
  if not isinstance(lines,list) or not fzf or not os.path.exists(fzf):self.emit('filtered',seq,None); return
  try:
   p=subprocess.run([fzf,'--filter='+str(q),'--delimiter=\t'],input='\n'.join(str(v).replace('\n',' ').replace('\r',' ') for v in lines),text=True,capture_output=True,timeout=5)
   nums=[int(line.split('\t',1)[0]) for line in p.stdout.splitlines() if line.split('\t',1)[0].isdigit()]
   self.emit('filtered',seq,nums)
  except (OSError,subprocess.SubprocessError):self.emit('filtered',seq,None)
 def push_channels(self):
  try:
   if not self.auth and os.getenv('TUNARRD_TEST')!='1':return
   req=Request(self.config['baseUrl'].rstrip('/')+'/api/channels',headers={'Authorization':self.auth or ''}); raw=json.load(urlopen(req,timeout=5)); channels=raw.get('data',raw) if isinstance(raw,dict) else raw
  except (OSError,URLError,ValueError):return
  channels=sorted(channels,key=lambda c:c.get('number',0)); self.emit('channels',[{'number':c.get('number'),'name':c.get('name')} for c in channels],self.channel or False)
  for c in channels:
   try:
    req=Request(self.config['baseUrl'].rstrip('/')+'/api/channels/'+str(c['id'])+'/now_playing',headers={'Authorization':self.auth or ''}); np=json.load(urlopen(req,timeout=5)); title=self.describe(np)
   except (OSError,URLError,ValueError,KeyError): title=''
   self.emit('np',c.get('number'),title or '')
 def describe(self,np):
  if not isinstance(np,dict) or not np.get('title'):return None
  if np.get('subtype')=='episode' and isinstance(np.get('grandparent'),dict) and np['grandparent'].get('title'):
   se=(' S%02dE%02d' % (np.get('parent',{}).get('index',0),np.get('episodeNumber',0))) if np.get('parent',{}).get('index') and np.get('episodeNumber') else ''
   return np['grandparent']['title']+se+' – '+np['title']
  return np['title']
 def vhs_now(self):
  if not self.channel or not self.tv:return
  status,x,_=self.tv.request('GET','/api/xray/'+str(self.channel))
  if status!=200 or not isinstance(x,dict) or not x.get('title'):return
  if self.shelf_cache is None:self._load_shelves()
  want=str(x.get('show') or x['title']).lower()
  for t in self.shelf_cache or []:
   if str(t.get('title','')).lower()==want and bool(x.get('show'))==(t.get('type')=='show'):
    if not x.get('show'): self.store.set('pos.'+t['key'],0); self.play_tape(t); return
    st,show,_=self.tv.request('GET','/api/vhs/tape/'+t['key'])
    for ep in show.get('episodes',[]) if st==200 and isinstance(show,dict) else []:
     if ep.get('season')==x.get('season') and ep.get('episode')==x.get('episode'):ep['show']=show.get('title');self.store.set('pos.'+ep['key'],0);self.play_tape(ep);return
 def _mpv_message(self,args):
  if not args:return
  if args[0]=='tunarr-xray-want':
   if self.xray_cache and self.xray_cache[0]>time.time()*1000:self.mpv.command(['script-message-to','xray','set',json.dumps(self.xray_cache[1])]);return
   self.mpv.command(['script-message-to','xray','set','null'])
   if not self.xray_loading:self.xray_loading=True; self.pool.submit(self._mpv_xray)
  elif args[0]=='tunarr-xray-click': self.emit('ui',{'open':True,'tab':'xray','find':False}); self.xray()
 def _mpv_xray(self):
  try:
   if not self.tv or not self.channel:return
   st,data,_=self.tv.request('GET','/api/xray/'+str(self.channel)); value=data if st==200 else {'error':st}; stop=value.get('stop',0) if isinstance(value,dict) else 0
   self.xray_cache=(stop,value); self.mpv.command(['script-message-to','xray','set',json.dumps(value)])
  finally:self.xray_loading=False
 def apply(self,x):
  cmd=x.get('cmd')
  if cmd=='play':
   if self.cast_to:
    n=int(x['ch']); self.last=n; self.cast_ch=n; self.pool.submit(self._cast_tune,'tune',n)
   else:self.play(int(x['ch']))
  elif cmd in ('step','random') and self.cast_to: self.pool.submit(self._cast_step_random,cmd,x)
  elif cmd=='tape': self.pool.submit(self.play_tape,x)
  elif cmd=='cast': self.pool.submit(self.cast,x.get('i',0))
  elif cmd=='stop': self.stop()
  elif cmd=='volume': self.mpv.command(['osd-msg-bar','add','volume',x.get('d',0)])
  elif cmd in ('step','random'): self.pool.submit(self._step_random,cmd,x)
  elif cmd=='pip':
   if self.fullscreen: self.mpv.command(['set_property','fullscreen',False]); self.fullscreen=False; self.screen=None; self._write_state()
  elif cmd=='playon': self.pool.submit(self._playon,x)
  elif cmd=='find': self.emit('find'); self.emit('ui',{'open':True,'tab':'tv','find':True})
  elif cmd=='panel':
   tab=x.get('tab') if x.get('tab') in ('tv','club','vhs','xray') else 'tv'; self.panelTab=tab; self.emit('ui',{'open':True,'tab':tab,'find':False}); self._write_state()
  elif cmd=='vhsnow': self.pool.submit(self.vhs_now)
  elif cmd=='surf':
   self.surf_level=(self.surf_level+1)%8
   if self.surf_timer:self.surf_timer.cancel();self.surf_timer=None
   periods=(0,30,60,180,300,900,1800,3600)
   if self.surf_level>1:
    def tick(): self.q.put({'cmd':'step','d':1}); self.surf_timer=threading.Timer(periods[self.surf_level],tick);self.surf_timer.daemon=True;self.surf_timer.start()
    self.surf_timer=threading.Timer(periods[self.surf_level],tick);self.surf_timer.daemon=True;self.surf_timer.start()
   self._surf_sync()

class Handler(BaseHTTPRequestHandler):
 def log_message(self,*x): pass
 def _ok(self):
  q=parse_qs(urlparse(self.path).query); return self.headers.get('X-Tunarr-Token')==self.server.daemon.token or q.get('t',[None])[0]==self.server.daemon.token
 def _json(self,status,obj): self.send_response(status); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(json.dumps(obj).encode())
 def do_GET(self):
  if not self._ok(): return self._json(403,{'error':'forbidden'})
  if urlparse(self.path).path=='/state': return self._json(200,self.server.daemon._state() | {'channel':self.server.daemon.channel,'tape':self.server.daemon.tape})
  if urlparse(self.path).path=='/panel':
   d=self.server.daemon
   if not hasattr(d,'_panel_html'):
    root=Path(d.config.get('panelDir') or Path(__file__).resolve().parent.parent)
    try:d._panel_html=(root/'panel.html').read_text().replace('{{FONT}}',base64.b64encode((root/'vt323.woff2').read_bytes()).decode())
    except OSError:return self._json(500,{'error':'panel unavailable'})
   self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.end_headers();self.wfile.write(d._panel_html.encode());return
  if urlparse(self.path).path=='/events':
   d=self.server.daemon
   with d.events_lock:
    if d.events>=4:return self._json(429,{'error':'too many event clients'})
    d.events+=1
   client=d.bus.connect()
   try:
    self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Cache-Control','no-cache');self.end_headers()
    while not d.stop_event.is_set():
     try: event=client.get(timeout=15)
     except queue.Empty:event='event: ping\ndata: {}\n\n'
     self.wfile.write(event.encode());self.wfile.flush()
   except (BrokenPipeError,ConnectionResetError): pass
   finally:
    d.bus.disconnect(client)
    with d.events_lock:d.events-=1
   return
  self._json(404,{'error':'not found'})
 def do_POST(self):
  if not self._ok():return self._json(403,{'error':'forbidden'})
  try: body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or b'{}')
  except json.JSONDecodeError:return self._json(400,{'error':'bad json'})
  d=self.server.daemon; path=urlparse(self.path).path
  if path=='/window':
   d.frame=body.get('frame') if body.get('onscreen',True) else None
   if isinstance(body.get('panel'),dict): d.panel={'frame':body['panel'].get('frame'),'visible':bool(body['panel'].get('visible'))}
   d._write_state(); return self._json(202,{'queued':True})
  if path=='/eval':
   if not (d.config.get('evalEnabled') or os.getenv('TUNARRD_EVAL_ENABLED')=='1'):return self._json(403,{'error':'disabled'})
   if not isinstance(body.get('js'),str):return self._json(400,{'error':'bad js'})
   d.emit('eval',body['js']);return self._json(202,{'queued':True})
  if path=='/act':
   act=body.get('act')
   if act=='ready':
    d.emit('tab',d.panelTab); d.emit('casts',[x.get('name') for x in d.config.get('cast',[]) if x.get('name')]);
    if d.vibe:d.emit('vibe',d.vibe,{},getattr(d,'trophy',None))
    if d.shelf_cache is not None:d.emit('shelves',d.shelf_cache)
   elif act=='tab' and body.get('tab') in ('tv','club','vhs','xray'):d.panelTab=body['tab'];d._write_state()
   elif act=='close':d.emit('ui',{'close':True})
   elif act=='shelves':d.pool.submit(d.shelves)
   elif act=='cover':d.pool.submit(d.cover,str(body.get('cover','')))
   elif act=='show':d.pool.submit(d.open_show,str(body.get('key','')))
   elif act=='tape':
    item=d.by_key.get(str(body.get('key','')))
    if item:d.q.put({'cmd':'tape',**item})
   elif act=='play':
    try:n=int(body.get('channel'))
    except (TypeError,ValueError):n=None
    if n is not None:
     # Selecting an already-visible channel must never use play's toggle/hide path.
     if n==d.channel and d.mpv.pid:
      if d.hidden:d.q.put({'cmd':'play','ch':n})
     else:d.q.put({'cmd':'play','ch':n})
     d.pool.submit(d._remote_sync)
   elif act=='cast':d.q.put({'cmd':'cast','i':body.get('i')})
   elif act=='xray':d.pool.submit(d.xray)
   elif act=='person':d.pool.submit(d.person,body.get('name',''))
   elif act=='open' and isinstance(body.get('url'),str) and body['url'].startswith('https://en.wikipedia.org/'):
    d.pool.submit(subprocess.call,['/usr/bin/open',body['url']],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   elif act=='filter':d.pool.submit(d.filter,body)
   elif act=='channels':d.pool.submit(d.push_channels);d.pool.submit(d._remote_sync)
   elif act=='remote' and body.get('cmd') in ('up','down','random','surf','volup','voldown','toggle','pip','max','stop','vhsnow'):
    m={'up':{'cmd':'step','d':1},'down':{'cmd':'step','d':-1},'random':{'cmd':'random'},'surf':{'cmd':'surf'},'volup':{'cmd':'volume','d':d.config['volStep']},'voldown':{'cmd':'volume','d':-d.config['volStep']},'toggle':{'cmd':'play','ch':d.channel or d.last},'pip':{'cmd':'pip'},'max':{'cmd':'playon','screen':d.screen},'stop':{'cmd':'stop'},'vhsnow':{'cmd':'vhsnow'}}[body['cmd']]
    if m.get('ch') is not None or m['cmd']!='play':d.q.put(m)
   return self._json(202,{'queued':True})
  if path=='/cmd':
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
