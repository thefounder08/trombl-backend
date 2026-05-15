#!/usr/bin/env python3
"""
Mint Supabase-compatible JWTs for QA test users.

Usage:
  python3 tests/auth/mint_jwt.py                  # print all 6 test user tokens
  python3 tests/auth/mint_jwt.py alice            # print Alice's token only
  python3 tests/auth/mint_jwt.py alice --hours 1  # token valid for 1 hour
  python3 tests/auth/mint_jwt.py --export         # print export lines for bash

The JWT secret is read from backend/.env.local (SUPABASE_JWT_SECRET).
Secret is used as raw UTF-8 bytes (NOT base64-decoded) — this matches
how Supabase/PostgREST verifies tokens.
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import time

USERS = {
    "alice":   ("aaaaaaaa-0001-4000-a000-000000000001", "alice@trombl-qa.dev"),
    "bob":     ("aaaaaaaa-0002-4000-a000-000000000002", "bob@trombl-qa.dev"),
    "carol":   ("aaaaaaaa-0003-4000-a000-000000000003", "carol@trombl-qa.dev"),
    "dave":    ("aaaaaaaa-0004-4000-a000-000000000004", "dave@trombl-qa.dev"),
    "eve":     ("aaaaaaaa-0005-4000-a000-000000000005", "eve@trombl-qa.dev"),
    "mallory": ("aaaaaaaa-0006-4000-a000-000000000006", "mallory@trombl-qa.dev"),
}


def load_secret():
    env_path = os.path.join(os.path.dirname(__file__), "../../.env.local")
    env_path = os.path.normpath(env_path)
    if not os.path.exists(env_path):
        sys.exit(f"ERROR: {env_path} not found. Copy .env.local.example and fill in values.")
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("SUPABASE_JWT_SECRET="):
                return line.split("=", 1)[1].strip()
    sys.exit("ERROR: SUPABASE_JWT_SECRET not found in .env.local")


def load_project_url():
    env_path = os.path.join(os.path.dirname(__file__), "../../.env.local")
    env_path = os.path.normpath(env_path)
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("SUPABASE_URL="):
                    return line.split("=", 1)[1].strip()
    sys.exit("ERROR: SUPABASE_URL not found in .env.local")


def b64url(data):
    if isinstance(data, (dict, list)):
        data = json.dumps(data, separators=(",", ":")).encode()
    elif isinstance(data, str):
        data = data.encode()
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def mint_jwt(user_id, email, secret_bytes, issuer, exp_hours=24):
    now = int(time.time())
    header  = b64url({"alg": "HS256", "typ": "JWT"})
    payload = b64url({
        "aud": "authenticated",
        "exp": now + int(exp_hours * 3600),
        "iat": now,
        "iss": f"{issuer}/auth/v1",
        "sub": user_id,
        "email": email,
        "phone": "",
        "app_metadata": {"provider": "email", "providers": ["email"]},
        "user_metadata": {},
        "role": "authenticated",
        "aal": "aal1",
        "amr": [{"method": "password", "timestamp": now}],
        "session_id": user_id[:36],
    })
    msg = f"{header}.{payload}".encode()
    sig = hmac.new(secret_bytes, msg, hashlib.sha256).digest()
    return f"{header}.{payload}.{b64url(sig)}"


def main():
    parser = argparse.ArgumentParser(description="Mint QA JWTs for Trombl test users")
    parser.add_argument("user", nargs="?", choices=list(USERS.keys()) + ["all"], default="all")
    parser.add_argument("--hours", type=float, default=24.0)
    parser.add_argument("--export", action="store_true", help="Print bash export lines")
    args = parser.parse_args()

    secret   = load_secret()
    secret_bytes = secret.encode("utf-8")
    issuer   = load_project_url()

    targets = USERS if args.user == "all" else {args.user: USERS[args.user]}

    for name, (uid, email) in targets.items():
        token = mint_jwt(uid, email, secret_bytes, issuer, args.hours)
        varname = f"TOK_{name.upper()}"
        if args.export:
            print(f'export {varname}="{token}"')
        else:
            print(f"# {name} ({email})")
            print(f'{varname}="{token}"')
            print()


if __name__ == "__main__":
    main()
