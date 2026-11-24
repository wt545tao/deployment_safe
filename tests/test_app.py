import os
import shutil
import sys
import tempfile
import threading
import urllib.error
import urllib.request

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
TMP = tempfile.mkdtemp(prefix="safe-app-test-")
os.environ["SECRET_KEY"] = "integration-secret"
os.environ["AUTH_DB"] = os.path.join(TMP, "auth.db")
os.environ["AUTH_LOG"] = os.path.join(TMP, "auth.log")
os.environ["MAX_FAILS"] = "3"
os.environ["FAIL_WINDOW"] = "600"
os.environ["SESSION_TTL"] = "600"

sys.path.insert(0, os.path.join(BASE_DIR, "..", "auth-service"))

import app as service


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(NoRedirect)
SERVER = service.build_server("127.0.0.1", 0)
BASE_URL = "http://127.0.0.1:{0}".format(SERVER.server_address[1])
THREAD = threading.Thread(target=SERVER.serve_forever, daemon=True)
THREAD.start()


def request(path, token=None, cookie=None, ip="203.0.113.10"):
    req = urllib.request.Request(BASE_URL + path)
    req.add_header("X-Real-IP", ip)
    if token:
        req.add_header("X-Auth-Token", token)
    if cookie:
        req.add_header("Cookie", cookie)
    try:
        with OPENER.open(req, timeout=5) as resp:
            return resp.status, dict(resp.headers), resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers), exc.read().decode("utf-8")


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)
    print("PASS {0}".format(msg))


def test_health():
    status, _headers, body = request("/healthz")
    check(status == 200 and "ok" in body, "healthz returns 200")


def test_reject_without_token():
    status, _headers, body = request("/verify", ip="198.51.100.1")
    check(status == 401, "verify without token returns 401")
    check("unauthorized" in body, "verify without token returns unauthorized body")


def test_valid_token_and_cookie():
    service.store.add_token("tester", "tk_valid")
    status, headers, _body = request("/verify", token="tk_valid", ip="198.51.100.2")
    check(status == 200, "verify with valid token returns 200")
    set_cookie = headers.get("Set-Cookie", "")
    check(set_cookie.startswith("safe_session="), "verify sets session cookie")
    cookie = set_cookie.split(";", 1)[0]
    status, _headers, _body = request("/verify", cookie=cookie, ip="198.51.100.2")
    check(status == 200, "verify with session cookie returns 200")


def test_login_flow():
    status, headers, _body = request("/login?token=tk_valid", ip="198.51.100.3")
    check(status == 302, "login with valid token redirects")
    check(headers.get("Location") == "/", "login redirects to root")
    check(
        headers.get("Set-Cookie", "").startswith("safe_session="),
        "login sets session cookie",
    )
    status, _headers, _body = request("/login?token=wrong-token", ip="198.51.100.3")
    check(status == 401, "login with bad token returns 401")


def test_rate_limit_drop():
    ip = "198.51.100.9"
    status, _headers, _body = request("/verify", token="bad-1", ip=ip)
    check(status == 401, "1st bad token returns 401")
    status, _headers, _body = request("/verify", token="bad-2", ip=ip)
    check(status == 401, "2nd bad token returns 401")
    status, _headers, _body = request("/verify", token="bad-3", ip=ip)
    check(status == 401, "3rd bad token returns 401")
    status, _headers, body = request("/verify", token="bad-4", ip=ip)
    check(status == 403 and body == "", "4th bad token is dropped silently")
    status, _headers, _body = request("/verify", token="bad-5", ip=ip)
    check(status == 403, "further bad tokens stay dropped")
    status, _headers, _body = request("/verify", token="tk_valid", ip=ip)
    check(status == 200, "authorized token still passes during drop window")
    status, _headers, _body = request("/verify", token="tk_valid", ip="198.51.100.10")
    check(status == 200, "other ip still works after a drop")


def test_unknown_path():
    status, _headers, _body = request("/nope", ip="198.51.100.11")
    check(status == 404, "unknown path returns 404")


def main():
    try:
        test_health()
        test_reject_without_token()
        test_valid_token_and_cookie()
        test_login_flow()
        test_rate_limit_drop()
        test_unknown_path()
        print("ALL INTEGRATION TESTS PASSED")
        return 0
    finally:
        SERVER.shutdown()
        SERVER.server_close()
        shutil.rmtree(TMP, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
