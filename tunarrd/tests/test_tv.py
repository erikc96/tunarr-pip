import json
import os
import sys
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).parents[2]
sys.path.insert(0, str(ROOT / 'tunarrd'))
from tunarrd import Daemon
from tvsite import TvSite


class Site(BaseHTTPRequestHandler):
    requests = []
    protected_calls = 0

    def _send(self, status, value=None, cookie=False):
        self.send_response(status)
        if cookie:
            self.send_header('Set-Cookie', 'tv_session=test-session; Path=/')
        self.end_headers()
        if value is not None:
            self.wfile.write(json.dumps(value).encode())

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        self.__class__.requests.append((self.command, self.path, body))
        if self.path == '/api/login':
            self._send(200, {'ok': True}, True)
        else:
            self._send(200, {'ok': True})

    def do_GET(self):
        self.__class__.requests.append((self.command, self.path, b''))
        if self.path == '/api/protected' and self.__class__.protected_calls == 0:
            self.__class__.protected_calls += 1
            self._send(401)
        else:
            self._send(200, {'ok': True})

    def log_message(self, *args):
        pass


class FakePool:
    def __init__(self):
        self.calls = []

    def submit(self, fn, *args):
        self.calls.append((fn, args))


class FakeMpv:
    pid = None
    def __init__(self, pos=0, duration=0):
        self.values = {'time-pos': pos, 'duration': duration}
    def get_property(self, name):
        return self.values.get(name)


class FakeTv:
    def __init__(self):
        self.calls = []
    def request(self, method, path, body=None):
        self.calls.append((method, path, body))
        if path.startswith('/api/cast?'):
            return 200, {'topic': 'receiver-topic'}, b'{"topic":"receiver-topic"}'
        return 200, {}, b'{}'


class TvTests(unittest.TestCase):
    def setUp(self):
        Site.requests = []
        Site.protected_calls = 0
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Site)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.old_test = os.environ.get('TUNARRD_TEST')
        os.environ['TUNARRD_TEST'] = '1'

    def tearDown(self):
        self.server.shutdown()
        if self.old_test is None:
            os.environ.pop('TUNARRD_TEST', None)
        else:
            os.environ['TUNARRD_TEST'] = self.old_test

    def daemon(self):
        d = Daemon.__new__(Daemon)
        d.tv = FakeTv(); d.pool = FakePool(); d.tape = None; d.cast_to = None
        d.cast_ch = None; d.cast_topics = {}; d.config = {'tvUrl': 'http://tv.example', 'cast': []}
        d.stop_event = threading.Event(); d.last = 7; d.channel = None; d.hidden = False
        d.mpv = FakeMpv(); d.beating = False; d._write_state = lambda *args: None
        d.store = type('Store', (), {'values': {}, 'set': lambda s, k, v: s.values.__setitem__(k, v)})()
        return d

    def test_login_and_401_retry(self):
        tv = TvSite('http://127.0.0.1:' + str(self.server.server_port), 'me', 'secret')
        status, data, _ = tv.request('GET', '/api/protected')
        self.assertEqual((status, data), (200, {'ok': True}))
        self.assertEqual([path for _, path, _ in Site.requests], ['/api/login', '/api/protected', '/api/login', '/api/protected'])

    def test_tape_stop_sid_and_eof_rewind(self):
        d = self.daemon(); d.tape = {'key': 'movie', 'sid': 'abc', 'duration': 1000}; d.mpv = FakeMpv(850, 1000)
        d.end_tape(True)
        self.assertEqual(d.store.values['done.movie'], True)
        self.assertEqual(d.pool.calls[0][1], ('GET', '/api/vhs/stop?s=abc'))
        self.assertEqual(d.pool.calls[1][0].__name__, '_rewind')
        d = self.daemon(); d.tape = {'key': 'movie', 'sid': 'abc', 'duration': 1000}; d.mpv = FakeMpv(850, 1000)
        d.end_tape(False)
        self.assertEqual(d.store.values['pos.movie'], 850)
        self.assertEqual(len(d.pool.calls), 1)

    def test_cast_config_index_and_json_body(self):
        d = self.daemon()
        d.config['cast'] = [{'name': 'IPAD', 'rx': 'ipad', 'wake': 'wake-topic'}]
        d.tv.request = lambda method, path, body=None: (200, {'here': True, 'ch': 4}, b'{}') if 'here?' in path else (200, {'topic': 'receiver-topic'}, b'{}')
        sent = []
        d._ntfy = lambda topic, body, headers=None: sent.append((topic, body, headers))
        d.cast(1)
        self.assertEqual(d.cast_to, 'ipad')
        self.assertEqual(json.loads(sent[-1][1]), {'cmd': 'tune', 'ch': 4})
        d._cast_tune('off')
        self.assertEqual(json.loads(sent[-1][1]), {'cmd': 'off'})


    def test_canary_notifies_on_any_answer(self):
        d = self.daemon(); d.config['canaryUrl'] = 'http://127.0.0.1:%d/x' % self.server.server_port
        marker = Path(tempfile.mkdtemp()) / 'notified'
        script = Path(tempfile.mkdtemp()) / 'notify.sh'
        script.write_text('#!/bin/sh\ntouch %s\n' % marker); script.chmod(0o755)
        os.environ['TUNARRD_NOTIFY'] = str(script)
        try: d.canary()
        finally: os.environ.pop('TUNARRD_NOTIFY')
        self.assertTrue(marker.exists())

    def test_vibe_is_exposed_unchanged_in_state(self):
        d = self.daemon(); d.vibe = {'mascot': {'mood': 'happy', 'idle': 0}, 'me': {'streak': 3}, 'live': []}
        d.frame = None; d.screen = None; d.receivers = []; d.mpv = type('M', (), {'pid': None})()
        self.assertEqual(d._state()['vibe'], d.vibe)

    def test_positions_import_once_and_survive_restart(self):
        import plistlib
        from store import PositionStore
        directory = tempfile.mkdtemp(); plist = Path(directory) / 'in.plist'
        plist.write_bytes(plistlib.dumps({'tunarr-pip.vhs.k1': 42, 'tunarr-pip.vhs.done.k2': True, 'other': 1}))
        os.environ['TUNARRD_DEFAULTS_PLIST'] = str(plist)
        try:
            s = PositionStore(directory); self.assertEqual((s.get('pos.k1'), s.get('done.k2')), (42, True))
            s.set('pos.k1', 99)
            plist.write_bytes(plistlib.dumps({'tunarr-pip.vhs.k1': 1}))  # a second import would overwrite
            self.assertEqual(PositionStore(directory).get('pos.k1'), 99)
        finally: os.environ.pop('TUNARRD_DEFAULTS_PLIST')

    def test_beat_when_active_not_twice_and_unbeat_on_idle(self):
        d = self.daemon(); d.channel = 3; d.last_beat = 0; d.load_vibe = lambda: None
        d.mpv = FakeMpv(); d.mpv.values['core-idle'] = False
        d.tv.request = lambda m, p, b=None: (d.tv.calls.append((m, p, b)) or (200, {}, b'{}'))
        d._watch(); d._watch()
        self.assertEqual([c[1] for c in d.tv.calls if c[1] == '/api/beat' and c[0] == 'POST'], ['/api/beat'])
        self.assertTrue(d.beating)
        d.mpv.values['core-idle'] = True; d._watch()
        self.assertIn(('DELETE', '/api/beat', None), d.tv.calls); self.assertFalse(d.beating)
