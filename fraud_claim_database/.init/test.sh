#!/usr/bin/env bash
set -euo pipefail
WS="${WS:-/home/kavia/workspace/code-generation/fraud-claims-management-system-2268-2919/fraud_claim_database}"
cd "$WS"
# source global env if present
[ -f /etc/profile.d/fraud_claim_db_env.sh ] && source /etc/profile.d/fraud_claim_db_env.sh || true
# Validate required POSTGRES env vars
: "${POSTGRES_USER:?POSTGRES_USER not set}"
: "${POSTGRES_DB:?POSTGRES_DB not set}"
: "${POSTGRES_HOST:?POSTGRES_HOST not set}"
: "${POSTGRES_PORT:?POSTGRES_PORT not set}"
# Expose PGPASSWORD for psql/psycopg2 when provided
if [ -n "${POSTGRES_PASSWORD:-}" ]; then export PGPASSWORD="$POSTGRES_PASSWORD"; fi
# Python sanity: import psycopg2 and query server version
python3 - <<'PY'
import os,sys
try:
    import psycopg2
except Exception as e:
    print('psycopg2 import failed:', e, file=sys.stderr)
    sys.exit(2)
try:
    conn = psycopg2.connect(dbname=os.getenv('POSTGRES_DB'), user=os.getenv('POSTGRES_USER'), password=os.getenv('POSTGRES_PASSWORD',''), host=os.getenv('POSTGRES_HOST'), port=os.getenv('POSTGRES_PORT'))
    cur = conn.cursor()
    cur.execute('SELECT version();')
    v = cur.fetchone()[0]
    print('PY-TEST-OK', v)
    cur.close()
    conn.close()
except Exception as e:
    print('DB connection failed:', e, file=sys.stderr)
    sys.exit(3)
PY
# Optional Node supabase-js test: only run when SUPABASE env vars present and node >=16
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 && [ -n "${SUPABASE_URL:-}" ] && [ -n "${SUPABASE_ANON_KEY:-}" ]; then
  NV_FULL=$(node -v 2>/dev/null || echo v0)
  NV_MAJOR=$(printf "%s" "$NV_FULL" | sed -E 's/^v([0-9]+).*$/\1/')
  NV_MAJOR=${NV_MAJOR:-0}
  if [ "$NV_MAJOR" -ge 16 ]; then
    mkdir -p "$WS/test_node" && cd "$WS/test_node"
    [ -f package.json ] || npm init -y >/dev/null 2>&1
    # local install only
    npm i --no-audit --no-fund --silent @supabase/supabase-js >/dev/null 2>&1 || { echo 'node deps install failed; skipping node test' >&2; exit 0; }
    cat > test_connect.js <<'JS'
const { createClient } = require('@supabase/supabase-js')
const url = process.env.SUPABASE_URL
const key = process.env.SUPABASE_ANON_KEY
if(!url || !key){ console.error('SUPABASE_URL or SUPABASE_ANON_KEY missing'); process.exit(2) }
const supabase = createClient(url, key)
;(async ()=>{
  try{
    const { data, error } = await supabase.from('fraud_claims').select('*').limit(1)
    console.log('NODE-TEST-OK', !!data, error)
  }catch(e){ console.error('NODE-TEST-ERR', e); process.exit(3) }
})();
JS
    node test_connect.js || { echo 'node test failed' >&2; exit 4; }
  else
    echo 'Node version too old for supabase-js test; skipping' >&2
  fi
fi
