from http.server import BaseHTTPRequestHandler, HTTPServer

INDEX = (
    b"<!doctype html><html><head><meta charset=\"utf-8\"><title>deployment_safe</title></head>"
    b"<body><h1>deployment_safe demo app</h1>"
    b"<p>Replace this container with your real application image.</p></body></html>"
)


class Handler(BaseHTTPRequestHandler):
    def _respond(self, body, content_type, include_body=True):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._respond(b'{"status":"ok"}', "application/json")
        else:
            self._respond(INDEX, "text/html; charset=utf-8")

    def do_HEAD(self):
        self._respond(INDEX, "text/html; charset=utf-8", include_body=False)

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
