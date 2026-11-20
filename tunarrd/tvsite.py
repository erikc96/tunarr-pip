"""Small cookie-authenticated client for craigo.tv."""
import json
import os
from http.cookiejar import CookieJar
from urllib.error import HTTPError, URLError
from urllib.request import HTTPCookieProcessor, Request, build_opener
from urllib.parse import urlparse


class TvSite:
    def __init__(self, base_url, user, password, opener=None):
        self.base_url = base_url.rstrip('/')
        self.user, self.password = user, password
        self.jar = CookieJar()
        self.opener = opener or build_opener(HTTPCookieProcessor(self.jar))

    def login(self):
        body = json.dumps({'username': self.user, 'password': self.password}).encode()
        status, _, _ = self._request('POST', '/api/login', body)
        return status in (200, 201, 204)

    def _request(self, method, path, body=None):
        # Hermetic tests may only talk to their explicitly configured loopback stub.
        if os.getenv('TUNARRD_TEST') == '1' and urlparse(self.base_url).hostname not in ('127.0.0.1', 'localhost', '::1'):
            return 0, None, b''
        headers = {'User-Agent': 'tunarrd/1.0'} # Cloudflare answers 1010 to urllib's default agent
        if body is not None: headers['Content-Type'] = 'application/json'
        req = Request(self.base_url + '/' + path.lstrip('/'), data=body,
                      headers=headers, method=method)
        try:
            response = self.opener.open(req, timeout=5)
            raw = response.read()
            status = response.status
        except HTTPError as exc:
            raw, status = exc.read(), exc.code
        except URLError:
            return 0, None, b''
        try:
            decoded = json.loads(raw) if raw else None
        except (UnicodeDecodeError, json.JSONDecodeError):
            decoded = None
        return status, decoded, raw

    def request(self, method, path, body=None):
        if not any(c.name == 'tv_session' for c in self.jar):
            self.login()
        encoded = json.dumps(body).encode() if body is not None else None
        result = self._request(method, path, encoded)
        if result[0] == 401 and self.login():
            result = self._request(method, path, encoded)
        return result

    def cookie_header(self):
        """The media player needs the session cookie outside urllib's jar."""
        return '; '.join(c.name + '=' + c.value for c in self.jar)
