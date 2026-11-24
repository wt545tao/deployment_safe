import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import verify

SECRET_KEY = os.environ["SECRET_KEY"].encode("utf-8")
COOKIE_NAME = "safe_session"
SESSION_TTL = int(os.environ.get("SESSION_TTL", "28800"))
FAIL_WINDOW = int(os.environ.get("FAIL_WINDOW", "600"))
MAX_FAILS = int(os.environ.get("MAX_FAILS", "3"))

CFG = {
    "session_ttl": SESSION_TTL,
    "fail_window": FAIL_WINDOW,
    "max_fails": MAX_FAILS,
}

store = verify.Store(
    os.environ.get("AUTH_DB", "/data/auth.db"),
    log_path=os.environ.get("AUTH_LOG", "/data/auth.log"),
)
store.init_db()


class Handler(BaseHTTPRequestHandler):
    server_version = "safe-auth"
    sys_version = ""

    def _ip(self):
        return self.headers.get("X-Real-IP") or self.client_address[0]

    def _token(self):
        token = self.headers.get("X-Auth-Token")
        if token:
            return token
        query = parse_qs(urlparse(self.path).query)
        return (query.get("token") or [""])[0]

    def _cookie(self):
        raw = self.headers.get("Cookie") or ""
        for part in raw.split(";"):
            part = part.strip()
            if part.startswith(COOKIE_NAME + "="):
                return part[len(COOKIE_NAME) + 1:]
        return None

    def _cookie_header(self, value):
        return "{0}={1}; Path=/; Max-Age={2}; HttpOnly; Secure; SameSite=Strict".format(
            COOKIE_NAME, value, SESSION_TTL
        )

    def _send(self, status, body, extra_headers=None):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        for name, value in (extra_headers or []):
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def _decide(self):
        return verify.decide(
            store, self._ip(), self._token(), self._cookie(), SECRET_KEY, CFG
        )

    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/healthz":
            self._send(200, '{"status":"ok"}')
            return

        if path == "/verify":
            status, cookie_value, _logs = self._decide()
            if status == 200:
                headers = []
                if cookie_value:
                    headers.append(("Set-Cookie", self._cookie_header(cookie_value)))
                self._send(200, '{"authenticated":true}', headers)
            elif status == verify.DROP:
                self._send(403, "")
            else:
                self._send(401, '{"error":"unauthorized"}')
            return

        if path == "/login":
            status, cookie_value, _logs = self._decide()
            if status == 200:
                headers = [("Location", "/")]
                if cookie_value:
                    headers.append(("Set-Cookie", self._cookie_header(cookie_value)))
                self._send(302, '{"redirect":"/"}', headers)
            elif status == verify.DROP:
                self._send(403, "")
            else:
                self._send(
                    401,
                    '{"error":"unauthorized","hint":"use /auth/login?token=YOUR_TOKEN or send the X-Auth-Token header"}',
                )
            return

        self._send(404, '{"error":"not found"}')

    def log_message(self, format, *args):
        pass


def build_server(host="0.0.0.0", port=None):
    return ThreadingHTTPServer(
        (host, port if port is not None else int(os.environ.get("PORT", "8000"))),
        Handler,
    )


def main():
    build_server().serve_forever()


if __name__ == "__main__":
    main()
