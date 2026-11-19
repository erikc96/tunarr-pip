"""B2 acceptance: the panel API against a real daemon with stub mpv, tv-site, Tunarr, fzf and open."""
import base64, http.client, json, os, socket, subprocess, sys, tempfile, threading, time, unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).parents[2]
PY = sys.executable
MPV_STUB = '''#!/usr/bin/env python3
import os, sys, socket, threading, time
s = [x.split('=', 1)[1] for x in sys.argv if x.startswith('--input-ipc-server=')][0]
try: os.unlink(s)
except FileNotFoundError: pass
x = socket.socket(socket.AF_UNIX); x.bind(s); x.listen(5)
log = os.environ['MPV_LOG']; emit = log + '.emit'
open(log + '.args', 'w').write(' '.join(sys.argv[1:]))
def pump(c):
  seen = 0
  while True:
    time.sleep(.05)
    try: data = open(emit, 'rb').read()
    except FileNotFoundError: continue
    if len(data) > seen:
      try: c.sendall(data[seen:])
      except OSError: return
      seen = len(data)
while True:
  c, _ = x.accept()
  threading.Thread(target=pump, args=(c,), daemon=True).start()
  while True:
    z = c.recv(4096)
    if not z: break
    for line in z.splitlines():
      open(log, 'ab').write(line + b'\\n')
      if b'"quit"' in line: sys.exit(0)
'''
FZF_STUB = '''#!/usr/bin/env python3
import sys
q = [a.split('=', 1)[1] for a in sys.argv if a.startswith('--filter=')][0]
for line in sys.stdin.read().splitlines():
  if q.lower() in line.lower(): print(line)
'''
OPEN_STUB = '''#!/bin/sh
echo "$@" >> "$OPEN_LOG"
'''


class Tunarr(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers()
        if self.path == '/api/channels':
            body = [{'id': 'idb', 'number': 5, 'name': 'Five'}, {'id': 'ida', 'number': 2, 'name': 'Two'}]
        elif self.path == '/api/channels/ida/now_playing':
            body = {'title': 'Pilot', 'subtype': 'episode', 'grandparent': {'title': 'Show'}, 'parent': {'index': 1}, 'episodeNumber': 2}
        else:
            body = {'title': 'A Movie'}
        self.wfile.write(json.dumps(body).encode())
    def log_message(self, *a): pass


class Site(BaseHTTPRequestHandler):
    log = []
    def _send(self, status, body=None, cookie=False):
        self.send_response(status)
        if cookie: self.send_header('Set-Cookie', 'tv_session=s; Path=/')
        self.end_headers()
        if body is not None: self.wfile.write(body if isinstance(body, bytes) else json.dumps(body).encode())
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0) or 0))
        self.log.append(('POST', self.path))
        self._send(200, {'ok': True}, cookie=self.path == '/api/login')
    def do_DELETE(self):
        self.log.append(('DELETE', self.path)); self._send(200, {})
    def do_GET(self):
        p = self.path; self.log.append(('GET', p))
        shelves = {'new': [{'key': 'k1', 'title': 'New One', 'type': 'movie'}],
                   'movies': [{'key': 'k1', 'title': 'New One', 'type': 'movie'}, {'key': 'k2', 'title': 'Old', 'type': 'movie'}],
                   'tv': [{'key': 'k3', 'title': 'Show', 'type': 'show'}]}
        if p.startswith('/api/vhs/shelf?shelf='): self._send(200, shelves[p.split('=')[1]])
        elif p == '/api/vhs/tape/k3': self._send(200, {'title': 'Show', 'episodes': [{'key': 'e1', 'season': 1, 'episode': 1, 'title': 'Pilot'}]})
        elif p == '/api/vhs/cover/1/2': self._send(200, b'JPG')
        elif p.startswith('/api/xray/person'): self._send(200, {'bio': 'x'})
        elif p.startswith('/api/xray/'): self._send(200, {'title': 'Now', 'stop': int((time.time() + 60) * 1000)})
        elif p.startswith('/api/cast/receivers'): self._send(200, [])
        elif p.startswith('/api/vibe'): self._send(200, {'mascot': {'mood': 'idle', 'idle': 1, 'fed': 0}, 'live': [], 'trophies': [], 'friends': []})
        else: self._send(200, {'ok': True})
    def log_message(self, *a): pass


class SSE:
    def __init__(self, port, token):
        self.conn = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
        self.conn.request('GET', '/events', headers={'X-Tunarr-Token': token})
        self.resp = self.conn.getresponse(); self.status = self.resp.status; self.events = []
        if self.status == 200: threading.Thread(target=self._read, daemon=True).start()
    def _read(self):
        verb = None
        try:
            for raw in self.resp:
                line = raw.decode().rstrip('\n')
                if line.startswith('event: '): verb = line[7:]
                elif line.startswith('data: ') and verb != 'ping': self.events.append((verb, json.loads(line[6:])))
        except (OSError, ValueError, http.client.HTTPException): pass
    def wait(self, verb, timeout=3):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            got = [a for v, a in list(self.events) if v == verb]
            if got: return got
            time.sleep(.03)
        raise AssertionError('no %s event; saw %s' % (verb, [v for v, _ in self.events]))
    def close(self):
        try: self.conn.close()
        except OSError: pass


class Panel(unittest.TestCase):
    config = {}
    env = {}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.d = Path(self.tmp.name)
        for name, text in (('mpv.py', MPV_STUB), ('fzf.py', FZF_STUB), ('open.sh', OPEN_STUB),
                           ('probe.sh', '#!/bin/sh\ncat "$(dirname "$0")/probe.out" 2>/dev/null\n'), ('connect.sh', OPEN_STUB.replace('$@', 'connect'))):
            (self.d / name).write_text(text); (self.d / name).chmod(0o755)
        self.log = self.d / 'log'; self.open_log = self.d / 'open.log'; Site.log = []
        self.tunarr = ThreadingHTTPServer(('127.0.0.1', 0), Tunarr); self.site = ThreadingHTTPServer(('127.0.0.1', 0), Site)
        for s in (self.tunarr, self.site): threading.Thread(target=s.serve_forever, daemon=True).start()
        s = socket.socket(); s.bind(('127.0.0.1', 0)); self.port = s.getsockname()[1]; s.close()
        (self.d / 'cfg').mkdir()
        cfg = {'baseUrl': 'http://127.0.0.1:%d' % self.tunarr.server_port, 'tvUrl': 'http://127.0.0.1:%d' % self.site.server_port, 'tvUser': 'u',
               'fzf': str(self.d / 'fzf.py'), 'open': str(self.d / 'open.sh'), 'cast': [{'name': 'IPAD', 'rx': 'ipad'}, {'name': 'VAN', 'rx': 'van'}, {'name': 'IPAD (SIDECAR)', 'screen': 'Sidecar'}],
               'screenProbe': [str(self.d / 'probe.sh')], 'screenScript': str(self.d / 'connect.sh')}
        cfg.update(self.config); (self.d / 'cfg/config.json').write_text(json.dumps(cfg))
        env = os.environ.copy()
        env.update(TUNARRD_DIR=str(self.d / 'cfg'), TUNARRD_PORT=str(self.port), TUNARRD_MPV=str(self.d / 'mpv.py'), TUNARRD_SOCK=str(self.d / 'mpv.sock'),
                   TUNARRD_AUTH='Basic test', TUNARRD_TEST='1', TUNARRD_TVPW='pw', TUNARRD_TICK='3600', MPV_LOG=str(self.log), OPEN_LOG=str(self.open_log))
        env.update(self.env)
        self.p = subprocess.Popen([PY, str(ROOT / 'tunarrd/tunarrd.py')], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.token = self._wait_token(); self.sse_clients = []

    def tearDown(self):
        for c in self.sse_clients: c.close()
        self.p.terminate(); self.p.wait(5)
        for s in (self.tunarr, self.site): s.shutdown()
        self.tmp.cleanup()

    def _wait_token(self):
        p = self.d / 'cfg/token'
        for _ in range(200):
            if p.exists():
                try: socket.create_connection(('127.0.0.1', self.port), timeout=.2).close(); return p.read_text()
                except OSError: pass
            time.sleep(.03)
        raise AssertionError('daemon did not start')

    def req(self, path, body=None, token=True):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        headers = {'X-Tunarr-Token': self.token} if token else {}
        conn.request('GET' if body is None else 'POST', path, None if body is None else json.dumps(body), headers)
        r = conn.getresponse(); data = r.read(); conn.close(); return r.status, data

    def act(self, **kw):
        status, _ = self.req('/act', kw); self.assertEqual(status, 202); return status

    def sse(self):
        c = SSE(self.port, self.token); self.sse_clients.append(c); return c

    def state(self): return json.loads(self.req('/state')[1])

    def wait_for(self, fn, what, timeout=3):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if fn(): return
            time.sleep(.03)
        raise AssertionError('timed out waiting for ' + what)

    def cmds(self):
        time.sleep(.2)
        return [json.loads(x)['command'] for x in self.log.read_text().splitlines()] if self.log.exists() else []

    def play(self, n):
        self.assertEqual(self.req('/cmd', {'cmd': 'play', 'ch': n})[0], 202)
        self.wait_for(lambda: self.state()['channel'] == n, 'channel %d' % n)

    def tv_gets(self, prefix): return [p for m, p in Site.log if m == 'GET' and p.startswith(prefix)]

    # --- tests -------------------------------------------------------------

    def test_panel_page_has_font_and_needs_token(self):
        status, body = self.req('/panel?t=' + self.token, token=False)
        self.assertEqual(status, 200); text = body.decode()
        self.assertNotIn('{{FONT}}', text); self.assertIn('data:font/woff2;base64,', text)
        self.assertIn(base64.b64encode((ROOT / 'vt323.woff2').read_bytes()).decode()[:60], text)
        self.assertEqual(self.req('/panel', token=False)[0], 403)

    def test_fifth_event_client_gets_429(self):
        for _ in range(4): self.assertEqual(self.sse().status, 200)
        self.assertEqual(self.req('/events')[0], 429)

    def test_ready_replays_stateful_verbs_to_new_clients_in_order(self):
        self.act(act='ready')
        c = self.sse()
        self.wait_for(lambda: len(c.events) >= 2, 'replay')
        self.assertEqual(c.events[:2], [('tab', ['tv']), ('casts', [['IPAD', 'VAN', 'IPAD (SIDECAR)']])])

    def test_channels_act_emits_list_and_now_playing(self):
        c = self.sse(); self.act(act='channels')
        self.assertEqual(c.wait('channels')[0], [[{'number': 2, 'name': 'Two'}, {'number': 5, 'name': 'Five'}], False])
        self.wait_for(lambda: len([e for e in c.events if e[0] == 'np']) == 2, 'np x2')
        self.assertIn(('np', [2, 'Show S01E02 – Pilot']), c.events); self.assertIn(('np', [5, 'A Movie']), c.events)

    def test_shelves_show_cover_tape_person_xray(self):
        c = self.sse(); self.act(act='shelves')
        shelves = c.wait('shelves')[0][0]
        self.assertEqual([x['key'] for x in shelves], ['k1', 'k2', 'k3'])
        self.assertEqual([x['isNew'] for x in shelves], [True, None, None])
        self.assertEqual(self.tv_gets('/api/vhs/shelf?shelf='), ['/api/vhs/shelf?shelf=new', '/api/vhs/shelf?shelf=movies', '/api/vhs/shelf?shelf=tv'])
        self.act(act='shelves'); time.sleep(.3)  # 10-minute cache: replayed, not refetched
        self.assertEqual(len(self.tv_gets('/api/vhs/shelf?shelf=')), 3)
        self.act(act='show', key='k3')
        self.assertEqual(c.wait('show')[0], [{'title': 'Show', 'episodes': [{'key': 'e1', 'season': 1, 'episode': 1, 'title': 'Pilot', 'show': 'Show'}]}])
        self.act(act='cover', cover='1/2')
        self.assertEqual(c.wait('cover')[0], ['1/2', 'data:image/jpeg;base64,' + base64.b64encode(b'JPG').decode()])
        self.act(act='cover', cover='../etc'); time.sleep(.2)
        self.assertEqual(self.tv_gets('/api/vhs/cover/'), ['/api/vhs/cover/1/2'])
        self.act(act='person', name='Tom X' + 'y' * 100)
        name, data = c.wait('person')[0]
        self.assertEqual((len(name), data), (80, {'bio': 'x'}))
        self.act(act='xray'); self.assertEqual(c.wait('xray')[0], [None])  # nothing playing
        self.play(5); self.act(act='xray')
        self.wait_for(lambda: any(e[0] == 'xray' and e[1][0] for e in c.events), 'xray data')
        self.assertEqual([e for e in c.events if e[0] == 'xray' and e[1][0]][0][1][0]['title'], 'Now')
        self.act(act='tape', key='e1')  # ep key is known from the show act
        self.wait_for(lambda: (self.state()['tape'] or {}).get('key') == 'e1', 'tape started')

    def test_filter_ranks_with_fzf_and_open_only_wikipedia(self):
        c = self.sse()
        self.act(act='filter', seq=7, q='beta', lines=['1\tAlpha', '2\tBeta', '3\tBetamax'])
        self.assertEqual(c.wait('filtered')[0], [7, [2, 3]])
        self.act(act='open', url='https://evil.example/x'); self.act(act='open', url='https://en.wikipedia.org/wiki/Foo')
        self.wait_for(self.open_log.exists, 'open stub')
        self.assertEqual(self.open_log.read_text().split(), ['https://en.wikipedia.org/wiki/Foo'])

    def test_play_of_showing_channel_never_hides_it(self):
        self.play(5); before = len(self.cmds())
        self.act(act='play', channel=5); time.sleep(.3)
        new = self.cmds()[before:]
        self.assertNotIn(['set_property', 'mute', True], new); self.assertNotIn(['set_property', 'window-minimized', True], new)
        self.assertFalse(self.state()['hidden'])
        self.req('/cmd', {'cmd': 'play', 'ch': 5})  # the hotkey toggle hides
        self.wait_for(lambda: self.state()['hidden'], 'hidden'); before = len(self.cmds())
        self.act(act='play', channel=5)  # picking it from the panel shows it
        self.wait_for(lambda: not self.state()['hidden'], 'shown')
        self.assertIn(['set_property', 'window-minimized', False], self.cmds()[before:])

    def test_find_cmd_emits_find_and_ui(self):
        c = self.sse(); self.assertEqual(self.req('/cmd', {'cmd': 'find'})[0], 202)
        self.assertEqual(c.wait('find')[0], []); self.assertEqual(c.wait('ui')[0], [{'open': True, 'tab': 'tv', 'find': True}])
        self.req('/cmd', {'cmd': 'panel', 'tab': 'xray'})
        self.wait_for(lambda: ('ui', [{'open': True, 'tab': 'xray', 'find': False}]) in c.events, 'panel ui')

    def test_xray_want_from_mpv_is_answered_once_then_cached(self):
        self.play(5)
        want = json.dumps({'event': 'client-message', 'args': ['tunarr-xray-want']}) + '\n'
        emit = Path(str(self.log) + '.emit')
        def sets(): return [c for c in self.cmds() if c[:3] == ['script-message-to', 'xray', 'set']]
        emit.write_text(want)
        self.wait_for(lambda: any(c[3] != 'null' for c in sets()), 'xray set data')
        self.assertEqual(sets()[0][3], 'null'); self.assertEqual(json.loads(sets()[-1][3])['title'], 'Now')
        with emit.open('a') as f: f.write(want)
        self.wait_for(lambda: len(sets()) >= 3, 'second answer')
        self.assertEqual(json.loads(sets()[-1][3])['title'], 'Now')
        self.assertEqual(self.tv_gets('/api/xray/5'), ['/api/xray/5'])  # the second want hit the cache
        c = self.sse()
        with emit.open('a') as f: f.write(json.dumps({'event': 'client-message', 'args': ['tunarr-xray-click']}) + '\n')
        self.assertEqual(c.wait('ui')[0], [{'open': True, 'tab': 'xray', 'find': False}])
        self.assertEqual(c.wait('xray')[0][0]['title'], 'Now')

    def test_hotkey_commands_sync_now_and_current_to_the_panel(self):
        c = self.sse(); self.play(5)
        self.assertEqual(c.wait('now')[-1], ['▶ CH 05']); self.assertEqual(c.wait('current')[-1], [5, False])
        self.req('/cmd', {'cmd': 'play', 'ch': 5})  # toggle hides
        self.wait_for(lambda: c.events[-1] == ('current', [5, True]), 'hidden synced')
        self.req('/cmd', {'cmd': 'stop'})
        self.wait_for(lambda: ('current', [False, False]) in c.events and ('now', ['']) in c.events, 'stop synced')

    def test_cast_index_zero_is_ignored_and_one_picks_the_first_entry(self):
        self.req('/cmd', {'cmd': 'cast', 'i': 0}); time.sleep(.4)
        self.assertEqual(self.tv_gets('/api/cast/here'), [])
        self.req('/cmd', {'cmd': 'cast', 'i': 1})
        self.wait_for(lambda: self.tv_gets('/api/cast/here'), 'cast/here asked')
        self.assertEqual(self.tv_gets('/api/cast/here')[0], '/api/cast/here?rx=ipad')

    def test_sidecar_cast_entry_fills_the_screen_when_present_else_runs_the_connect_script(self):
        (self.d / 'probe.out').write_text('Sidecar Display\n')
        self.assertEqual(self.req('/cmd', {'cmd': 'cast', 'i': 3})[0], 202)
        self.wait_for(lambda: self.state()['screen'] == 'Sidecar', 'playon Sidecar')
        argsf = Path(str(self.log) + '.args'); self.wait_for(argsf.exists, 'mpv started'); args = argsf.read_text().split(); self.assertIn('--fullscreen', args); self.assertIn('--fs-screen-name=Sidecar', args)
        self.assertFalse(self.open_log.exists())
        self.req('/cmd', {'cmd': 'stop'}); self.wait_for(lambda: self.state()['screen'] is None, 'stopped')
        (self.d / 'probe.out').write_text('Built-in Retina\n')
        self.req('/cmd', {'cmd': 'cast', 'i': 3}); self.wait_for(self.open_log.exists, 'connect script')
        self.assertEqual(self.open_log.read_text().split(), ['connect']); time.sleep(.2); self.assertIsNone(self.state()['screen'])

    def test_eval_is_forbidden_unless_enabled(self):
        self.assertEqual(self.req('/eval', {'js': '1'})[0], 403)

    def test_panel_tab_and_picker_visible_in_state_file(self):
        def file(): return json.loads((self.d / 'cfg/state.json').read_text())
        self.req('/window', {'onscreen': False, 'panel': {'frame': {'x': 1, 'y': 2, 'w': 3, 'h': 4}, 'visible': True}})
        self.act(act='tab', tab='tv')
        self.wait_for(lambda: file()['panel'].get('tab') == 'tv' and file()['pickerVisible'], 'picker visible on tv tab')
        self.assertEqual(file()['panel'], {'frame': {'x': 1, 'y': 2, 'w': 3, 'h': 4}, 'visible': True, 'tab': 'tv'})
        self.act(act='tab', tab='vhs')
        self.wait_for(lambda: file()['panel']['tab'] == 'vhs', 'vhs tab'); self.assertFalse(file()['pickerVisible'])
        self.act(act='tab', tab='bogus'); time.sleep(.4); self.assertEqual(file()['panel']['tab'], 'vhs')


class PanelEval(Panel):
    env = {'TUNARRD_EVAL_ENABLED': '1'}
    only = 'test_eval_emits_source_when_enabled'

    def test_eval_emits_source_when_enabled(self):
        c = self.sse(); self.assertEqual(self.req('/eval', {'js': 'document.title'})[0], 202)
        self.assertEqual(c.wait('eval')[0], ['document.title'])
        self.assertEqual(self.req('/eval', {'js': 5})[0], 400)


class PanelVibe(Panel):
    env = {'TUNARRD_TICK': '0.3'}  # the first tick loads the vibe
    only = 'test_vibe_carries_channel_names_and_the_trophy_table'

    def test_vibe_carries_channel_names_and_the_trophy_table(self):
        self.wait_for(lambda: self.state()['vibe'], 'vibe loaded')
        c = self.sse(); self.act(act='channels'); self.wait_for(lambda: len([e for e in c.events if e[0] == 'np']) == 2, 'np x2')
        self.act(act='ready'); d = self.sse()
        vibe, names, trophies = d.wait('vibe')[-1]
        self.assertEqual(vibe['mascot']['mood'], 'idle'); self.assertEqual(names, {'2': 'Two', '5': 'Five'})
        self.assertEqual(len(trophies), 13); self.assertEqual(trophies[0], ['first_tune', 'FIRST TUNE', 'watch anything'])


# A variant reruns only its own test(s); every inherited test is switched off.
for _cls in (PanelEval, PanelVibe):
    for _n in [n for n in dir(Panel) if n.startswith('test_') and n != _cls.only]:
        setattr(_cls, _n, None)


if __name__ == '__main__':
    unittest.main()
