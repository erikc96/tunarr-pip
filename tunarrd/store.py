"""Crash-safe tape position persistence."""
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path


class PositionStore:
    def __init__(self, directory):
        self.path = Path(directory) / 'positions.json'
        self.values = {}
        if self.path.exists():
            import json
            self.values = json.loads(self.path.read_text())
        else:
            self._import_defaults()
            self._save()

    def _import_defaults(self):
        source = os.getenv('TUNARRD_DEFAULTS_PLIST')
        try:
            raw = Path(source).read_bytes() if source else subprocess.check_output(
                ['defaults', 'export', 'org.hammerspoon.Hammerspoon', '-'], stderr=subprocess.DEVNULL)
            values = plistlib.loads(raw)
        except (OSError, plistlib.InvalidFileException, subprocess.CalledProcessError):
            return
        for key, value in values.items():
            if key.startswith('tunarr-pip.vhs.'):
                suffix = key[len('tunarr-pip.vhs.'):]
                if suffix.startswith('done.'):
                    self.values['done.' + suffix[5:]] = bool(value)
                else:
                    try:
                        self.values['pos.' + suffix] = int(value)
                    except (ValueError, TypeError):
                        pass

    def _save(self):
        import json
        fd, name = tempfile.mkstemp(prefix='positions.', dir=self.path.parent)
        try:
            os.fchmod(fd, 0o600)
            os.write(fd, json.dumps(self.values, separators=(',', ':')).encode())
            os.fsync(fd)
            os.close(fd)
            os.replace(name, self.path)
        finally:
            try: os.close(fd)
            except OSError: pass

    def get(self, key, default=None):
        return self.values.get(key, default)

    def set(self, key, value):
        self.values[key] = value
        self._save()
