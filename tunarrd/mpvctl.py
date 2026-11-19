"""Small persistent JSON IPC client and process owner for mpv."""
import json, os, socket, subprocess, threading, time


class MPV:
    def __init__(self, path, sock, on_exit=None):
        self.path, self.sock, self.on_exit = path, sock, on_exit
        self.proc = None; self._conn = None; self._lock = threading.Lock(); self._rid = 0

    @property
    def pid(self):
        return self.proc.pid if self.proc and self.proc.poll() is None else None

    def _connect(self):
        if self._conn:
            return self._conn
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(.5)
        s.connect(self.sock); s.settimeout(None); self._conn = s
        threading.Thread(target=self._reader, args=(s,), daemon=True).start()
        return s

    def _reader(self, conn):
        """Drain replies continuously so mpv's IPC output can never fill."""
        try:
            while conn.recv(4096):
                pass
        except OSError:
            pass
        finally:
            if self._conn is conn:
                self._conn = None

    def command(self, command):
        """Best effort: IPC may not be ready during spawn/exit."""
        with self._lock:
            self._rid += 1
            msg = json.dumps({'command': command, 'request_id': self._rid}, separators=(',', ':')).encode()+b'\n'
            for _ in range(2):
                try:
                    self._connect().sendall(msg); return True
                except OSError:
                    if self._conn:
                        try: self._conn.close()
                        except OSError: pass
                    self._conn = None
                    time.sleep(.03)
        return False

    def start(self, args):
        self.quit_leftover()
        try: os.unlink(self.sock)
        except FileNotFoundError: pass
        self.proc = subprocess.Popen([self.path] + args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        threading.Thread(target=self._wait, args=(self.proc,), daemon=True).start()
        # Commands following a just-created player must not race socket creation.
        end = time.monotonic() + 2
        while time.monotonic() < end and self.proc.poll() is None:
            try:
                self._connect()
                break
            except OSError:
                time.sleep(.02)

    def _wait(self, proc):
        proc.wait()
        if self.proc is proc:
            self._conn = None
            if self.on_exit: self.on_exit(proc)

    def quit_leftover(self):
        # A prior daemon might have left an mpv on this private socket.
        old = self._conn; self._conn = None
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(.25); s.connect(self.sock)
            s.sendall(b'{"command":["quit"]}\n'); s.close(); time.sleep(.1)
        except OSError: pass
        if old:
            try: old.close()
            except OSError: pass

    def stop(self):
        p = self.proc
        if not p: return
        self.command(['quit'])
        try: p.wait(1.5)
        except subprocess.TimeoutExpired: p.terminate()
