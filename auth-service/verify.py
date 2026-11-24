import hashlib
import hmac
import os
import sqlite3
import time


DROP = 444

DEFAULT_CFG = {
    "session_ttl": 28800,
    "fail_window": 600,
    "max_fails": 3,
}

DDL = """
CREATE TABLE IF NOT EXISTS tokens (
    name       TEXT PRIMARY KEY,
    token_hash TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    revoked    INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS attempts (
    ip       TEXT PRIMARY KEY,
    count    INTEGER NOT NULL,
    first_ts INTEGER NOT NULL
);
"""


def sha256_hex(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def make_cookie(secret, ip, ttl, now=None):
    current = int(time.time()) if now is None else int(now)
    exp = current + int(ttl)
    payload = "{0}|{1}".format(ip, exp)
    sig = hmac.new(secret, payload.encode("utf-8"), hashlib.sha256).hexdigest()
    return "{0}|{1}".format(exp, sig)


def check_cookie(secret, ip, value, now=None):
    if not value:
        return False
    parts = value.split("|", 1)
    if len(parts) != 2:
        return False
    try:
        exp = int(parts[0])
    except ValueError:
        return False
    current = int(time.time()) if now is None else int(now)
    if exp < current:
        return False
    payload = "{0}|{1}".format(ip, exp)
    expected = hmac.new(secret, payload.encode("utf-8"), hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, parts[1])


class Store:
    def __init__(self, db_path, log_path=None):
        self.db_path = db_path
        self.log_path = log_path

    def _connect(self):
        conn = sqlite3.connect(self.db_path, timeout=5)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=5000")
        return conn

    def init_db(self):
        parent = os.path.dirname(os.path.abspath(self.db_path))
        if parent and not os.path.isdir(parent):
            os.makedirs(parent, exist_ok=True)
        conn = self._connect()
        try:
            conn.executescript(DDL)
            conn.execute("DROP TABLE IF EXISTS bans")
            conn.commit()
        finally:
            conn.close()

    def log(self, line):
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        text = "{0} {1}\n".format(stamp, line)
        if self.log_path:
            parent = os.path.dirname(os.path.abspath(self.log_path))
            if parent and not os.path.isdir(parent):
                os.makedirs(parent, exist_ok=True)
            with open(self.log_path, "a", encoding="utf-8") as fh:
                fh.write(text)

    def add_token(self, name, plain):
        token_hash = sha256_hex(plain)
        conn = self._connect()
        try:
            exists = conn.execute(
                "SELECT 1 FROM tokens WHERE name=? OR token_hash=?", (name, token_hash)
            ).fetchone()
            if exists:
                raise ValueError("token name already exists: {0}".format(name))
            conn.execute(
                "INSERT INTO tokens(name, token_hash, created_at, revoked) VALUES(?,?,?,0)",
                (name, token_hash, int(time.time())),
            )
            conn.commit()
        finally:
            conn.close()

    def list_tokens(self):
        conn = self._connect()
        try:
            rows = conn.execute(
                "SELECT name, created_at, revoked FROM tokens ORDER BY created_at"
            ).fetchall()
        finally:
            conn.close()
        return rows

    def revoke_token(self, name):
        conn = self._connect()
        try:
            cur = conn.execute("UPDATE tokens SET revoked=1 WHERE name=?", (name,))
            conn.commit()
            if cur.rowcount == 0:
                raise ValueError("token not found: {0}".format(name))
        finally:
            conn.close()

    def check_token(self, plain):
        if not plain:
            return False
        token_hash = sha256_hex(plain)
        conn = self._connect()
        try:
            row = conn.execute(
                "SELECT 1 FROM tokens WHERE token_hash=? AND revoked=0", (token_hash,)
            ).fetchone()
        finally:
            conn.close()
        return row is not None

    def record_fail(self, ip, window):
        now = int(time.time())
        conn = self._connect()
        try:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute(
                "SELECT count, first_ts FROM attempts WHERE ip=?", (ip,)
            ).fetchone()
            if row is None or now - row[1] > int(window):
                count = 1
                first_ts = now
            else:
                count = row[0] + 1
                first_ts = row[1]
            conn.execute(
                "INSERT INTO attempts(ip, count, first_ts) VALUES(?,?,?) "
                "ON CONFLICT(ip) DO UPDATE SET count=excluded.count, first_ts=excluded.first_ts",
                (ip, count, first_ts),
            )
            conn.commit()
        finally:
            conn.close()
        return count

    def clear_fails(self, ip):
        conn = self._connect()
        try:
            conn.execute("DELETE FROM attempts WHERE ip=?", (ip,))
            conn.commit()
        finally:
            conn.close()


def decide(store, ip, token, cookie, secret, cfg=None):
    config = dict(DEFAULT_CFG)
    if cfg:
        config.update(cfg)

    logs = []
    if check_cookie(secret, ip, cookie):
        store.clear_fails(ip)
        return 200, None, logs

    if token and store.check_token(token):
        store.clear_fails(ip)
        cookie_value = make_cookie(secret, ip, config["session_ttl"])
        logs.append("AUTH_OK {0} via=token".format(ip))
        for line in logs:
            store.log(line)
        return 200, cookie_value, logs

    count = store.record_fail(ip, config["fail_window"])
    if count > config["max_fails"]:
        logs.append(
            "AUTH_DROP {0} count={1} window={2}".format(
                ip, count, config["fail_window"]
            )
        )
        for line in logs:
            store.log(line)
        return DROP, None, logs

    logs.append("AUTH_FAIL {0} count={1}".format(ip, count))
    for line in logs:
        store.log(line)
    return 401, None, logs
