#!/usr/bin/env python3
"""Copy the PUBLIC catalog tables from prod (read-only, anon REST) into the LOCAL Supabase database.

Reads: sets, set_prices, minifigs, set_minifigs — reference data any signed-out app user can read.
Writes: only the local Docker database (psql as postgres inside the db container). Never writes to prod.
Idempotent: existing rows are left alone (ON CONFLICT DO NOTHING), so it can be re-run to pick up NEW
sets; it does not refresh rows that changed on prod — `supabase db reset` first for a clean copy.

The local stack must be running (see the iOS handoff doc, "Local Supabase on the Mac"):
    python3 scripts/copy_catalog_to_local.py [db-container-name]
"""
import json, os, plistlib, subprocess, sys, urllib.request

PROD = "https://thntvdpsixepidwvrxxj.supabase.co"
# The prod publishable key, from the gitignored Secrets.plist next to the app sources.
SECRETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "BrickWares", "Secrets.plist")
KEY = plistlib.load(open(SECRETS, "rb"))["SUPABASE_ANON_KEY"]
CONTAINER = sys.argv[1] if len(sys.argv) > 1 else "supabase_db_BrickWares"
PAGE = 1000
# Parents before children (foreign keys).
TABLES = [("sets", "set_id"), ("minifigs", "fig_num"), ("set_prices", "set_id,region"), ("set_minifigs", "set_id,fig_num")]


def fetch(table, order, offset):
    req = urllib.request.Request(
        f"{PROD}/rest/v1/{table}?select=*&order={order}&limit={PAGE}&offset={offset}",
        headers={"apikey": KEY, "Authorization": "Bearer " + KEY},
    )
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read())
        except Exception as e:  # transient network error: retry
            if attempt == 2:
                raise
            print(f"  retry {table}@{offset}: {e}", flush=True)


def load(table, rows):
    body = json.dumps(rows, ensure_ascii=False)
    assert "$bwcat$" not in body
    sql = (
        f"insert into public.{table} select * from jsonb_populate_recordset(null::public.{table}, "
        f"$bwcat${body}$bwcat$::jsonb) on conflict do nothing;\n"
    )
    subprocess.run(
        ["docker", "exec", "-i", CONTAINER, "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-q"],
        input=sql.encode("utf-8"), check=True, stdout=subprocess.DEVNULL,
    )


for table, order in TABLES:
    offset = total = 0
    while True:
        rows = fetch(table, order, offset)
        if not rows:
            break
        load(table, rows)
        total += len(rows)
        offset += PAGE
        if len(rows) < PAGE:
            break
    print(f"{table}: {total} rows copied", flush=True)
