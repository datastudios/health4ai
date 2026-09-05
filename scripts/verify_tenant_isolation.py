#!/usr/bin/env python3
"""
health4ai — tenant isolation prover.

Creates two disposable users in a TARGET Supabase project, writes synthetic
health samples as each, then proves from the client side that neither can see
the other's rows and that nothing outside health4ai is reachable. Deletes both
users on the way out, including on failure.

This exists because docs/TESTFLIGHT-BETA.md asks for exactly this evidence
before a wider beta and describes it as a manual checklist. A checklist that
nobody has run is not evidence. Run this instead:

    ./scripts/verify_tenant_isolation.py --url https://<ref>.supabase.co \
        --publishable <sb_publishable_...> --service-role <service_role_key>

Exit 0 only if every assertion passes AND the test actually moved rows. A run
that proves isolation by writing zero samples proves nothing (see
docs/operations/vacuous-success-antipattern.md) and exits non-zero.

Point it only at a project you are willing to have test users created in and
deleted from. Set HEALTH4AI_FORBIDDEN_REFS to a comma-separated list of project
refs it must refuse, so a shared or production project cannot be targeted by a
slip of the shell history.
"""

import argparse
import json
import sys
import urllib.error
import urllib.request
import uuid

# Refs this tool must never touch. It creates and deletes auth users, so
# pointing it at a shared or production project is destructive.
FORBIDDEN_REFS = [r.strip() for r in
                  os.environ.get("HEALTH4AI_FORBIDDEN_REFS", "").split(",") if r.strip()]

# The tables a health4ai backend is supposed to have. Anything else answering on
# PostgREST means this project is shared with something, and "isolated" is then a
# claim about one table rather than about the project.
EXPECTED_TABLES = {
    "healthkit_metrics", "healthkit_daily_summaries",
    "health4ai_user_settings", "health4ai_waitlist",
}


def call(url, method="GET", token=None, apikey=None, body=None, extra=None):
    req = urllib.request.Request(
        url, method=method,
        data=json.dumps(body).encode() if body is not None else None,
    )
    if apikey:
        req.add_header("apikey", apikey)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    for k, v in (extra or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw.strip() else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw


class Checks:
    def __init__(self):
        self.rows = []

    def add(self, name, ok, detail=""):
        self.rows.append((name, bool(ok), detail))
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
        return ok

    @property
    def failed(self):
        return [r for r in self.rows if not r[1]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True, help="https://<ref>.supabase.co")
    ap.add_argument("--publishable", required=True, help="publishable / anon key")
    ap.add_argument("--service-role", required=True)
    ap.add_argument("--samples", type=int, default=5)
    args = ap.parse_args()

    url = args.url.rstrip("/")
    for ref in FORBIDDEN_REFS:
        if ref in url:
            sys.exit(f"REFUSED: {ref} is in HEALTH4AI_FORBIDDEN_REFS. This tool creates "
                     "and deletes auth users; point it only at a project you own and "
                     "are willing to have it write to.")

    pub, sr = args.publishable, args.service_role
    admin = {"apikey": sr, "token": sr}
    c = Checks()
    users = []

    try:
        # --- create two disposable users -----------------------------------
        for _ in range(2):
            email = f"h4-isolation-{uuid.uuid4().hex[:10]}@example.com"
            pw = "Pr0be!" + uuid.uuid4().hex[:14]
            s, b = call(f"{url}/auth/v1/admin/users", "POST",
                        body={"email": email, "password": pw, "email_confirm": True}, **admin)
            if s >= 300:
                sys.exit(f"could not create probe user: {s} {b}")
            s2, b2 = call(f"{url}/auth/v1/token?grant_type=password", "POST",
                          apikey=pub, body={"email": email, "password": pw})
            if s2 >= 300:
                sys.exit(f"could not sign in probe user: {s2} {b2}")
            users.append({"id": b["id"], "email": email, "token": b2["access_token"]})

        a, b_ = users
        print(f"\nprobe users: {a['email']} / {b_['email']}\n")

        # --- each user ingests synthetic samples ---------------------------
        print("ingest:")
        written = {}
        for u in users:
            samples = [{
                "metric_type": "HKQuantityTypeIdentifierStepCount",
                "value": float(1000 + i), "unit": "count",
                "source_device": "isolation-probe",
                "started_at": f"2026-01-0{i+1}T12:00:00Z",
                "ended_at": None, "metadata": None,
            } for i in range(args.samples)]
            s, resp = call(f"{url}/functions/v1/healthkit-ingest", "POST",
                           token=u["token"], apikey=pub, body={"samples": samples})
            n = (resp or {}).get("inserted", 0) if isinstance(resp, dict) else 0
            written[u["id"]] = n
            c.add(f"ingest accepted for {u['email'][:22]}", s == 200 and n == args.samples,
                  f"HTTP {s}, inserted={n}")

        # MAGNITUDE GATE. Everything below is trivially true against an empty
        # table, so a zero here invalidates the whole run rather than passing it.
        if not c.add("magnitude: both users actually wrote rows",
                     all(v == args.samples for v in written.values()),
                     f"expected {args.samples} each, got {list(written.values())}"):
            raise SystemExit(1)

        # --- the actual isolation assertions -------------------------------
        print("\nisolation:")
        for me, other in ((a, b_), (b_, a)):
            s, rows = call(
                f"{url}/rest/v1/healthkit_metrics?select=user_id,value&limit=200",
                token=me["token"], apikey=pub)
            rows = rows if isinstance(rows, list) else []
            owners = {r.get("user_id") for r in rows}
            c.add(f"{me['email'][:22]} sees only own rows",
                  s == 200 and owners in ({me["id"]}, set()),
                  f"HTTP {s}, {len(rows)} rows, owners={len(owners)}")
            c.add(f"{me['email'][:22]} sees none of the other user's rows",
                  other["id"] not in owners)

            # Direct write must be refused — user_id is the ingest function's to set.
            s, _ = call(f"{url}/rest/v1/healthkit_metrics", "POST", token=me["token"], apikey=pub,
                        body={"user_id": other["id"], "metric_type": "forged",
                              "started_at": "2026-01-01T00:00:00Z", "source_device": "probe"},
                        extra={"Prefer": "return=minimal"})
            c.add(f"{me['email'][:22]} cannot write directly to healthkit_metrics",
                  s in (401, 403, 404), f"HTTP {s}")

            # Cross-tenant summarize would DELETE the victim's raw rows.
            s, _ = call(f"{url}/rest/v1/rpc/summarize_healthkit_metric", "POST",
                        token=me["token"], apikey=pub,
                        body={"p_user_id": other["id"],
                              "p_metric_type": "HKQuantityTypeIdentifierStepCount",
                              "p_cutoff": "2030-01-01"})
            c.add(f"{me['email'][:22]} cannot call summarize on another user",
                  s in (401, 403, 404), f"HTTP {s}")

            # Waitlist must not be readable with a signed-in session either.
            s, _ = call(f"{url}/rest/v1/health4ai_waitlist?select=email&limit=1",
                        token=me["token"], apikey=pub)
            c.add(f"{me['email'][:22]} cannot read the waitlist", s in (401, 403, 404), f"HTTP {s}")

        # --- the project holds health4ai and nothing else -------------------
        # PostgREST's root lists every table it can see for this role.
        print("\nproject is health4ai-only:")
        s, root = call(f"{url}/rest/v1/", token=a["token"], apikey=pub)
        if s == 200 and isinstance(root, dict):
            seen = set((root.get("paths") or {}).keys())
            extra = {p.lstrip("/") for p in seen if p.strip("/")} - EXPECTED_TABLES
            c.add("no tables beyond health4ai's own are exposed",
                  not extra, f"unexpected: {sorted(extra)[:8]}" if extra else "")
        else:
            c.add("could not enumerate exposed tables", False, f"HTTP {s}")

    finally:
        for u in users:
            call(f"{url}/auth/v1/admin/users/{u['id']}", "DELETE", **admin)
        if users:
            print(f"\ncleaned up {len(users)} probe user(s)")

    print()
    if c.failed:
        print(f"RESULT: FAIL — {len(c.failed)} of {len(c.rows)} checks failed")
        for n, _, d in c.failed:
            print(f"  - {n} ({d})")
        return 1
    print(f"RESULT: PASS — {len(c.rows)} checks, {args.samples} samples per user, 2 users")
    return 0


if __name__ == "__main__":
    sys.exit(main())
