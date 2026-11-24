import argparse
import os
import secrets
import sys

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(BASE_DIR)
sys.path.insert(0, BASE_DIR)

from verify import Store

DEFAULT_DB = os.path.join(ROOT_DIR, "data", "auth.db")


def build_store():
    db_path = os.environ.get("AUTH_DB", DEFAULT_DB)
    parent = os.path.dirname(os.path.abspath(db_path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
    store = Store(db_path)
    store.init_db()
    return store


def main():
    parser = argparse.ArgumentParser(
        prog="manage_tokens.py",
        description="manage access tokens and rate-limit counters",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    add_parser = sub.add_parser("add", help="create a new token")
    add_parser.add_argument("name", help="unique token name, e.g. alice-laptop")

    sub.add_parser("list", help="list tokens without secrets")

    revoke_parser = sub.add_parser("revoke", help="revoke a token by name")
    revoke_parser.add_argument("name")

    reset_parser = sub.add_parser(
        "reset", help="reset the failure counter of an ip address"
    )
    reset_parser.add_argument("ip")

    args = parser.parse_args()
    store = build_store()

    if args.cmd == "add":
        plain = "tk_" + secrets.token_urlsafe(24)
        try:
            store.add_token(args.name, plain)
        except ValueError as exc:
            parser.error(str(exc))
        print("token created: {0}".format(args.name))
        print("token: {0}".format(plain))
        print("store it now, it will not be shown again")
        return 0

    if args.cmd == "list":
        rows = store.list_tokens()
        if not rows:
            print("no tokens")
            return 0
        for name, created_at, revoked in rows:
            state = "revoked" if revoked else "active"
            print("{0}\t{1}\t{2}".format(name, state, created_at))
        return 0

    if args.cmd == "revoke":
        try:
            store.revoke_token(args.name)
        except ValueError as exc:
            parser.error(str(exc))
        print("revoked: {0}".format(args.name))
        return 0

    if args.cmd == "reset":
        store.clear_fails(args.ip)
        print("reset: {0}".format(args.ip))
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
