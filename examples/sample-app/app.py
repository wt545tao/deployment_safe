import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))

INDEX = """<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>sample app</title></head>
<body>
  <h1>sample app is running behind deployment_safe</h1>
  <p>只允许携带有效 token 或会话 Cookie 的访问到达这里。</p>
  <ul>
    <li>GET /healthz</li>
    <li>GET /api/info</li>
  </ul>
</body>
</html>
""".encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "sample-app"
    sys_version = ""

    def _send(self, body, content_type, status=200, include_body=True):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def _json(self, payload, include_body=True):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._send(body, "application/json; charset=utf-8", include_body=include_body)

    def _info(self):
        return {
            "service": "sample-app",
            "time": int(time.time()),
            "path": self.path,
            "client_ip": self.headers.get("X-Real-IP") or self.client_address[0],
            "host": self.headers.get("Host"),
            "user_agent": self.headers.get("User-Agent"),
        }

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            self._json({"status": "ok"})
        elif path == "/api/info":
            self._json(self._info())
        else:
            self._send(INDEX, "text/html; charset=utf-8")

    def do_HEAD(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            self._json({"status": "ok"}, include_body=False)
        else:
            self._send(INDEX, "text/html; charset=utf-8", include_body=False)

    def log_message(self, format, *args):
        pass


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("sample app listening on 0.0.0.0:{0}".format(PORT), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
