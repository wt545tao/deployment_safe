import os
import shutil
import sys
import tempfile
import time

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(BASE_DIR, "..", "auth-service"))

import verify

SECRET = b"test-secret-key"
FAILS = []
LOG_FILE = None


def make_store():
    tmp = tempfile.mkdtemp(prefix="safe-auth-test-")
    global LOG_FILE
    LOG_FILE = os.path.join(tmp, "auth.log")
    store = verify.Store(os.path.join(tmp, "auth.db"), log_path=LOG_FILE)
    store.init_db()
    return store, tmp


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)
    print("PASS {0}".format(msg))


def test_cookie():
    cookie = verify.make_cookie(SECRET, "1.2.3.4", 60)
    check(verify.check_cookie(SECRET, "1.2.3.4", cookie), "cookie accepted for same ip")
    check(not verify.check_cookie(SECRET, "1.2.3.5", cookie), "cookie rejected for other ip")
    check(not verify.check_cookie(SECRET, "1.2.3.4", cookie, now=time.time() + 120), "expired cookie rejected")
    check(not verify.check_cookie(SECRET, "1.2.3.4", "garbage"), "malformed cookie rejected")
    check(not verify.check_cookie(b"other-secret", "1.2.3.4", cookie), "cookie rejected with other secret")


def test_token_lifecycle():
    store, tmp = make_store()
    try:
        store.add_token("alice", "tk_secret_value")
        check(store.check_token("tk_secret_value"), "valid token accepted")
        check(not store.check_token("tk_wrong_value"), "wrong token rejected")
        check(not store.check_token(""), "empty token rejected")
        try:
            store.add_token("alice", "tk_another")
            raise AssertionError("duplicate name should fail")
        except ValueError:
            print("PASS duplicate token name rejected")
        store.revoke_token("alice")
        check(not store.check_token("tk_secret_value"), "revoked token rejected")
        try:
            store.revoke_token("missing")
            raise AssertionError("missing token should fail")
        except ValueError:
            print("PASS revoking unknown token rejected")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_rate_limit_drop():
    store, tmp = make_store()
    try:
        store.add_token("bob", "tk_good")
        cfg = {"max_fails": 3, "fail_window": 600, "session_ttl": 60}
        status, cookie, _ = verify.decide(store, "9.9.9.9", "tk_bad", None, SECRET, cfg)
        check(status == 401 and cookie is None, "1st failure returns 401")
        status, _, _ = verify.decide(store, "9.9.9.9", "tk_bad", None, SECRET, cfg)
        check(status == 401, "2nd failure returns 401")
        status, _, _ = verify.decide(store, "9.9.9.9", "tk_bad", None, SECRET, cfg)
        check(status == 401, "3rd failure returns 401")
        status, _, _ = verify.decide(store, "9.9.9.9", "tk_bad", None, SECRET, cfg)
        check(status == verify.DROP, "4th failure is dropped silently")
        status, _, _ = verify.decide(store, "9.9.9.9", "tk_bad", None, SECRET, cfg)
        check(status == verify.DROP, "further failures stay dropped")
        status, _, _ = verify.decide(store, "9.9.9.9", "tk_good", None, SECRET, cfg)
        check(status == 200, "authorized token still passes during drop window")
        other, _, _ = verify.decide(store, "8.8.8.8", "tk_good", None, SECRET, cfg)
        check(other == 200, "other ip is not affected by the drop")
        store.clear_fails("9.9.9.9")
        status, _, _ = verify.decide(store, "9.9.9.9", "tk_bad", None, SECRET, cfg)
        check(status == 401, "clearing counters restores the 401 hint")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_fail_window_reset():
    store, tmp = make_store()
    try:
        check(store.record_fail("7.7.7.7", 600) == 1, "first failure counted")
        check(store.record_fail("7.7.7.7", 600) == 2, "second failure counted")
        conn = store._connect()
        conn.execute("UPDATE attempts SET first_ts=? WHERE ip=?", (int(time.time()) - 1000, "7.7.7.7"))
        conn.commit()
        conn.close()
        check(store.record_fail("7.7.7.7", 600) == 1, "counter reset after fail window")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_drop_window_expiry():
    store, tmp = make_store()
    try:
        cfg = {"max_fails": 3, "fail_window": 600, "session_ttl": 60}
        status = 0
        for _ in range(4):
            status, _, _ = verify.decide(store, "6.6.6.6", "tk_bad", None, SECRET, cfg)
        check(status == verify.DROP, "traffic is dropped after the threshold")
        conn = store._connect()
        conn.execute("UPDATE attempts SET first_ts=? WHERE ip=?", (int(time.time()) - 1000, "6.6.6.6"))
        conn.commit()
        conn.close()
        status, _, _ = verify.decide(store, "6.6.6.6", "tk_bad", None, SECRET, cfg)
        check(status == 401, "drop window expires automatically")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_session_cookie_flow():
    store, tmp = make_store()
    try:
        store.add_token("carol", "tk_carol")
        cfg = {"max_fails": 3, "fail_window": 600, "session_ttl": 3600}
        status, cookie, _ = verify.decide(store, "5.5.5.5", "tk_carol", None, SECRET, cfg)
        check(status == 200 and cookie, "token login issues a session cookie")
        status, again, _ = verify.decide(store, "5.5.5.5", "", cookie, SECRET, cfg)
        check(status == 200 and again is None, "session cookie is accepted without token")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_log_file():
    store, tmp = make_store()
    try:
        cfg = {"max_fails": 1, "fail_window": 600, "session_ttl": 60}
        verify.decide(store, "4.4.4.4", "tk_bad", None, SECRET, cfg)
        verify.decide(store, "4.4.4.4", "tk_bad", None, SECRET, cfg)
        with open(LOG_FILE, encoding="utf-8") as fh:
            content = fh.read()
        check("AUTH_FAIL 4.4.4.4" in content, "auth failure is logged")
        check("AUTH_DROP 4.4.4.4" in content, "rate-limit drop is logged")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    test_cookie()
    test_token_lifecycle()
    test_rate_limit_drop()
    test_fail_window_reset()
    test_drop_window_expiry()
    test_session_cookie_flow()
    test_log_file()
    print("ALL TESTS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
