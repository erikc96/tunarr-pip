import json, os, socket, subprocess, sys, tempfile, threading, time, unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT=Path(__file__).parents[2]; PY=sys.executable
STUB='''#!/usr/bin/env python3
import os,sys,socket
s=[x.split('=',1)[1] for x in sys.argv if x.startswith('--input-ipc-server=')][0]
try: os.unlink(s)
except FileNotFoundError: pass
x=socket.socket(socket.AF_UNIX); x.bind(s); x.listen(5)
log=os.environ['MPV_LOG']
while True:
 c,_=x.accept()
 while True:
  z=c.recv(4096)
  if not z: break
  for line in z.splitlines():
   open(log,'ab').write(line+b'\\n')
   if b'"quit"' in line: c.close();x.close();sys.exit(0)
'''
class Channels(BaseHTTPRequestHandler):
 def do_GET(self): self.send_response(200);self.end_headers();self.wfile.write(b'[{"number":2},{"number":5},{"number":9}]')
 def log_message(self,*a):pass

class T(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(); self.d=Path(self.tmp.name); self.stub=self.d/'mpv.py'; self.stub.write_text(STUB);self.stub.chmod(0o755);self.log=self.d/'log'; self.sock=str(self.d/'mpv.sock')
  self.ch=ThreadingHTTPServer(('127.0.0.1',0),Channels);threading.Thread(target=self.ch.serve_forever,daemon=True).start()
  self.port=self._port(); env=os.environ.copy();env.update(TUNARRD_DIR=str(self.d/'cfg'),TUNARRD_PORT=str(self.port),TUNARRD_MPV=str(self.stub),TUNARRD_SOCK=self.sock,TUNARRD_AUTH='Basic test',TUNARRD_TEST='1',TUNARRD_HEARTBEAT='0.2',MPV_LOG=str(self.log))
  (self.d/'cfg').mkdir();(self.d/'cfg'/'config.json').write_text(json.dumps({'baseUrl':f'http://127.0.0.1:{self.ch.server_port}','warmMinutes':.02}))
  self.p=subprocess.Popen([PY,str(ROOT/'tunarrd/tunarrd.py')],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE);self.token=self._wait_token()
 def tearDown(self):
  self.p.terminate();self.p.wait(3);self.ch.shutdown();self.tmp.cleanup()
 def _port(self):
  s=socket.socket();s.bind(('127.0.0.1',0));p=s.getsockname()[1];s.close();return p
 def _wait_token(self):
  p=self.d/'cfg/token'
  for _ in range(200):
   if p.exists():
    try: socket.create_connection(('127.0.0.1',self.port),timeout=.2).close(); return p.read_text()
    except OSError: pass
   time.sleep(.03)
  raise AssertionError('daemon did not start')
 def req(self,path,body=None,token=True):
  import urllib.request, urllib.error
  r=urllib.request.Request(f'http://127.0.0.1:{self.port}{path}',data=None if body is None else json.dumps(body).encode(),method='GET' if body is None else 'POST')
  if token:r.add_header('X-Tunarr-Token',self.token)
  try:return urllib.request.urlopen(r,timeout=2)
  except urllib.error.HTTPError as e:return e
 def cmds(self):
  time.sleep(.2);return [json.loads(x)['command'] for x in self.log.read_text().splitlines()] if self.log.exists() else []
 def test_auth_queue_and_player_semantics(self):
  self.assertEqual(self.req('/state',token=False).status,403)
  self.assertEqual(self.req('/cmd',{'cmd':'play','ch':2}).status,202);self.assertEqual(self.req('/cmd',{'cmd':'play','ch':5}).status,202)
  for _ in range(30):
   if len(self.cmds())>=7:break
   time.sleep(.05)
  self.assertEqual([c for c in self.cmds() if c[0]!='script-message-to'][:7],[['set_property','window-minimized',False],['set_property','mute',False],['change-list','http-header-fields','set','Authorization: Basic test'],['set_property','start','none'],['set_property','pause',False],['loadfile','av://lavfi:testsrc=size=640x360:rate=10','replace'],['set_property','title','Tunarr ch5']])
  self.req('/cmd',{'cmd':'play','ch':5});self.req('/cmd',{'cmd':'play','ch':5});self.req('/cmd',{'cmd':'stop'});time.sleep(.3)
  c=self.cmds();self.assertIn(['set_property','mute',True],c);self.assertIn(['set_property','window-minimized',True],c);self.assertIn(['set_property','window-minimized',False],c);self.assertIn(['set_property','mute',False],c);self.assertEqual(c[-1],['quit'])
 def test_step_random_state_events_warm_and_singleton(self):
  self.req('/cmd',{'cmd':'play','ch':5});time.sleep(.15);self.req('/cmd',{'cmd':'step','d':1});time.sleep(.1);self.assertEqual(json.load(self.req('/state'))['channel'],9)
  self.req('/cmd',{'cmd':'step','d':1});time.sleep(.1);self.assertEqual(json.load(self.req('/state'))['channel'],2)
  self.req('/cmd',{'cmd':'step','d':-1});time.sleep(.1);self.assertEqual(json.load(self.req('/state'))['channel'],9)
  self.req('/cmd',{'cmd':'random'});time.sleep(.15);st=json.load(self.req('/state'));self.assertIn(st['channel'],[2,5])
  # Atomic replacement means a concurrent consumer never observes half JSON.
  bad=[]; done=threading.Event()
  def reader():
   while not done.is_set():
    try: json.loads((self.d/'cfg/state.json').read_text())
    except (OSError,json.JSONDecodeError) as e: bad.append(e)
  t=threading.Thread(target=reader);t.start()
  for x in range(8): self.req('/window',{'frame':{'x':x,'y':2,'w':3,'h':4},'onscreen':True})
  time.sleep(.35);done.set();t.join();self.assertFalse(bad);self.assertEqual(json.loads((self.d/'cfg/state.json').read_text())['frame']['x'],7)
  env=os.environ.copy();env['TUNARRD_DIR']=str(self.d/'other'); q=subprocess.run([PY,str(ROOT/'tunarrd/tunarrd.py')],env=env,capture_output=True,timeout=2);self.assertEqual(q.returncode,0)
  # Four clients reserve the SSE slots; the fifth is refused.
  import urllib.request
  a=urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{self.port}/events',headers={'X-Tunarr-Token':self.token}),timeout=2);b=urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{self.port}/events',headers={'X-Tunarr-Token':self.token}),timeout=2);c=urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{self.port}/events',headers={'X-Tunarr-Token':self.token}),timeout=2);e=urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{self.port}/events',headers={'X-Tunarr-Token':self.token}),timeout=2);self.assertEqual(self.req('/events').status,429);a.close();b.close();c.close();e.close()
  self.req('/cmd',{'cmd':'play','ch':st['channel']});time.sleep(1.5);self.assertIn(['quit'],self.cmds())

 def test_heartbeat_sigterm_and_dead_mpv(self):
  self.req('/cmd',{'cmd':'play','ch':5});time.sleep(.3)
  ts=lambda:json.loads((self.d/'cfg/state.json').read_text())
  a=ts()['ts'];time.sleep(.6);self.assertGreater(ts()['ts'],a);self.assertTrue(ts()['pid'])
  self.p.terminate();self.p.wait(3);self.assertIn(['quit'],self.cmds())  # SIGTERM stops mpv too
  self.p=subprocess.Popen([PY,'-c','pass'])  # tearDown needs a process
