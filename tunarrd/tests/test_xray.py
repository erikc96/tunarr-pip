"""Drives the real mpv with xray.lua over its JSON IPC socket (no window, --vo=null).
Test hooks in the script are on only because this test starts mpv with XRAY_TEST=1."""
import json, os, shutil, socket, subprocess, tempfile, threading, time, unittest
from pathlib import Path

ROOT = Path(__file__).parents[2]
MPV = '/opt/homebrew/bin/mpv'

MOVIE = {'title': 'the matrix', 'year': 1999, 'contentRating': 'R', 'rating': 8.7, 'genres': ['Action', 'Sci-Fi', 'Drama'],
         'cast': [{'name': 'Keanu Reeves'}, {'name': 'Carrie-Anne Moss'}], 'summary': 'a hacker learns the truth. ' * 30,
         'stop': int(time.time() * 1000) + 3600_000}


class Mpv:
    def __init__(self, tmp, env_extra):
        self.sock_path = str(Path(tmp) / 'mpv.sock')
        env = dict(os.environ, **env_extra)
        self.log = open(Path(tmp) / 'mpv.out', 'w+')
        self.p = subprocess.Popen([MPV, '--no-config', '--idle=yes', '--vo=null', '--no-audio', '--no-terminal',
                                   '--msg-level=all=info', f'--input-ipc-server={self.sock_path}',
                                   f'--script={ROOT / "xray.lua"}'], env=env, stdout=self.log, stderr=subprocess.STDOUT)
        self.events, self.replies, self.cv = [], {}, threading.Condition()
        for _ in range(200):
            try:
                self.s = socket.socket(socket.AF_UNIX); self.s.connect(self.sock_path); break
            except OSError:
                self.s.close(); time.sleep(.03)
        else:
            raise AssertionError('mpv did not start')
        self.n = 0
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        buf = b''
        while True:
            try: z = self.s.recv(65536)
            except OSError: return
            if not z: return
            buf += z
            while b'\n' in buf:
                line, buf = buf.split(b'\n', 1)
                try: m = json.loads(line)
                except ValueError: continue
                with self.cv:
                    if 'request_id' in m: self.replies[m['request_id']] = m
                    elif 'event' in m: self.events.append(m)
                    self.cv.notify_all()

    def cmd(self, *command):
        self.n += 1; rid = self.n
        self.s.sendall(json.dumps({'command': list(command), 'request_id': rid}).encode() + b'\n')
        with self.cv:
            if not self.cv.wait_for(lambda: rid in self.replies, 3): raise AssertionError(f'no reply to {command}')
            return self.replies.pop(rid)

    def msg(self, *args):  # script-message to the xray script
        r = self.cmd('script-message-to', 'xray', *args); assert r['error'] == 'success', r
        time.sleep(.05)  # script-message is async: the reply comes before the Lua handler has run

    def x(self):
        return self.cmd('get_property', 'user-data/xray')['data']

    def wait_x(self, pred, timeout=3):
        end = time.time() + timeout
        while time.time() < end:
            x = self.x()
            if pred(x): return x
            time.sleep(.02)
        raise AssertionError(f'state never matched: {self.x()}')

    def client_messages(self):
        with self.cv: return [e['args'][0] for e in self.events if e['event'] == 'client-message' and e.get('args')]

    def wait_msg(self, name, timeout=2):
        end = time.time() + timeout
        while time.time() < end:
            if name in self.client_messages(): return
            time.sleep(.02)
        raise AssertionError(f'{name} not emitted; got {self.client_messages()}')

    def close(self):
        try: self.p.terminate(); self.p.wait(3)
        except Exception: self.p.kill()


@unittest.skipUnless(os.path.exists(MPV), f'mpv not installed at {MPV}: X-Ray test skipped')
class XRay(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.m = Mpv(self.tmp, {'XRAY_TEST': '1'})

    def tearDown(self):
        self.m.close(); shutil.rmtree(self.tmp, ignore_errors=True)

    def hover(self, x=500, y=40): self.m.msg('xray-test', 'hover', '1', str(x), str(y))

    def test_no_lua_errors(self):
        self.m.msg('set', json.dumps(MOVIE)); self.hover(); self.m.wait_x(lambda x: x['visible']); time.sleep(.2)
        self.m.close()
        out = Path(self.tmp, 'mpv.out').read_text()
        self.assertNotIn('Lua error', out); self.assertNotIn('xray] Error', out)
        self.assertFalse([l for l in out.splitlines() if '[xray]' in l and ('error' in l.lower() or 'fatal' in l.lower())], out)

    def test_loads_without_test_env(self):
        env = dict(os.environ); env.pop('XRAY_TEST', None)
        p = subprocess.run([MPV, '--no-config', '--idle=yes', '--vo=null', '--no-audio', '--no-terminal', '--msg-level=all=info',
                            f'--script={ROOT / "xray.lua"}', '--input-commands=script-message-to xray xray-test hover 1 5 5,quit'],
                           env=env, capture_output=True, text=True, timeout=10)
        out = p.stdout + p.stderr
        self.assertNotIn('rror', out)

    def test_set_hover_text_and_hide(self):
        m = self.m
        m.msg('set', json.dumps(MOVIE))
        x = m.wait_x(lambda x: x['label'])
        self.assertFalse(x['visible'])                      # data alone does not show it
        self.assertEqual(x['title'], 'THE MATRIX')
        self.assertEqual(x['label'], '1999 · R · ★ 8.7 · ACTION · SCI-FI')
        m.msg('xray', 'idle_s', '0.3')
        self.hover()
        x = m.wait_x(lambda x: x['visible'])
        b = x['bounds']
        self.assertGreater(b['x1'] - b['x0'], 100); self.assertGreater(b['y1'] - b['y0'], 40)
        self.assertEqual(b['y0'], 8); self.assertLessEqual(b['x1'], 640 - 8 + 1)       # top-right, 8 px margin
        self.assertLessEqual(b['x1'] - b['x0'], 340)
        self.assertLessEqual(b['y1'], 360 - 8)                                          # capped at osd-height - 16
        self.assertTrue(x['ass_len'] > 0 and x['ass'].count('\n') == 1)                 # box event + text event
        self.assertNotIn('tunarr-xray-want', m.client_messages())                       # fresh stop -> no request
        self.assertIn('THE MATRIX', x['ass']); self.assertIn('WITH KEANU REEVES, CARRIE-ANNE MOSS', x['ass'])
        self.assertRegex(x['ass'], r'\\fn(VT323|Menlo)\\')                             # font is VT323 or the Menlo fallback
        self.hover(501, 41)                                                             # movement re-arms the timer
        time.sleep(.2); self.assertTrue(m.x()['visible'])
        m.wait_x(lambda x: not x['visible'], 2)                                         # hides ~0.3 s after the last move

    def test_want_only_when_stale(self):
        m = self.m
        m.msg('set', json.dumps(MOVIE)); m.msg('xray', 'idle_s', '0.2')
        self.hover(); m.wait_x(lambda x: x['visible'])
        time.sleep(.1)
        self.assertNotIn('tunarr-xray-want', m.client_messages())                       # fresh `stop` -> no request
        m.wait_x(lambda x: not x['visible'], 2)
        m.msg('set', json.dumps(dict(MOVIE, stop=int(time.time() * 1000) - 1000)))      # stop passed
        self.hover(510, 45); m.wait_x(lambda x: x['visible']); m.wait_msg('tunarr-xray-want')  # a new movement, not the old spot

    def test_error_and_looking(self):
        m = self.m
        m.msg('xray', 'idle_s', '5')
        self.hover(); m.wait_x(lambda x: x['visible'])
        self.assertEqual(m.x()['label'], 'X-RAY · LOOKING…')                            # no data yet
        m.msg('set', json.dumps({'error': 404}))
        self.assertEqual(m.wait_x(lambda x: x['label'].startswith('NO X-RAY'))['label'], 'NO X-RAY FOR THIS ONE')
        self.assertTrue(m.x()['visible'])
        m.msg('set', json.dumps(MOVIE)); m.wait_x(lambda x: x['title'] == 'THE MATRIX')
        m.msg('set', 'null')
        x = m.wait_x(lambda x: x['label'] == 'X-RAY · LOOKING…')
        self.assertEqual(x['title'], '')
        m.msg('set', '')                                                                # empty is looking too
        self.assertEqual(m.x()['label'], 'X-RAY · LOOKING…')

    def test_ass_escaping(self):
        m = self.m
        m.msg('xray', 'idle_s', '5')
        self.hover(); m.wait_x(lambda x: x['visible'])
        m.msg('set', json.dumps(dict(MOVIE, summary='plain words')))
        base = m.wait_x(lambda x: 'PLAIN WORDS' in x['ass'])['ass_len']
        nasty = 'plain {\\an5}words\nsecond line {\\b1} back\\slash'
        m.msg('set', json.dumps(dict(MOVIE, summary=nasty)))
        x = m.wait_x(lambda x: 'SECOND LINE' in x['ass'])
        self.assertGreater(x['ass_len'], base)
        self.assertNotIn('{\\an5}', x['ass'].upper().replace('{\\AN7', ''))          # raw tag cannot survive
        self.assertNotIn('{\\AN5}', x['ass'].upper())
        self.assertNotIn('{\\B1}', x['ass'].upper())
        self.assertEqual(x['ass'].count('\n'), 1)                                       # a user newline never starts a new event
        self.assertIn('\\{', x['ass']); self.assertIn('\\}', x['ass'])
        self.assertIn('\\﻿', x['ass'])                                             # backslash neutralised

    def test_wheel_scroll_and_click(self):
        m = self.m
        m.msg('xray', 'idle_s', '5')
        m.msg('set', json.dumps(dict(MOVIE, summary='a hacker learns the truth. ' * 80)))   # taller than the box
        self.hover(); x = m.wait_x(lambda x: x['visible'])
        self.assertEqual(x['scroll'], 0)
        m.msg('xray-wheel-up'); self.assertEqual(m.x()['scroll'], 0)                    # clamped at 0
        m.msg('xray-wheel-down')
        s1 = m.wait_x(lambda x: x['scroll'] > 0)['scroll']
        m.msg('xray-wheel-down'); s2 = m.wait_x(lambda x: x['scroll'] > s1)['scroll']
        self.assertAlmostEqual(s2 - s1, 3 * 14 * 1.2, delta=1.5)                        # 3 text lines
        for _ in range(15): m.msg('xray-wheel-down')
        top = m.x()['scroll']
        m.msg('xray-wheel-down'); self.assertEqual(m.x()['scroll'], top)                # clamped at the end
        self.assertGreater(top, s2)
        m.msg('xray-wheel-up'); self.assertLess(m.x()['scroll'], top)
        # the wheel/click section is defined (input-bindings lists defined sections; whether it is enabled is not visible over IPC)
        bound = lambda: [b for b in m.cmd('get_property', 'input-bindings')['data'] if b.get('cmd', '').endswith('xray-wheel-up')]
        self.assertTrue(bound())
        m.msg('xray-click'); m.wait_msg('tunarr-xray-click')
        m.msg('enable', '0')
        x = m.wait_x(lambda x: not x['visible'])
        self.assertFalse(x['enabled'])
        m.msg('xray-click')                               # hidden: click does nothing
        time.sleep(.15); self.assertEqual(m.client_messages().count('tunarr-xray-click'), 1)

    def test_enable_zero_stops_hover(self):
        m = self.m
        m.msg('set', json.dumps(MOVIE)); m.msg('enable', '0')
        self.hover(); time.sleep(.15)
        self.assertFalse(m.x()['visible'])
        m.msg('enable', '1')
        self.hover(); m.wait_x(lambda x: x['visible'])
        m.msg('xray-test', 'hover', '0', '0', '0')                                      # pointer leaves the window
        m.wait_x(lambda x: not x['visible'])


if __name__ == '__main__':
    unittest.main()
