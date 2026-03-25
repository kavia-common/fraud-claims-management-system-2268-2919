#!/usr/bin/env bash
set -euo pipefail
WS="/home/kavia/workspace/code-generation/fraud-claims-management-system-2268-2919/fraud_claim_database"
# install minimal cli tools if missing (idempotent, non-interactive)
command -v psql >/dev/null 2>&1 || sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends -qq postgresql-client >/dev/null
command -v python3 >/dev/null 2>&1 || { echo "python3 missing" >&2; exit 2; }
command -v pip3 >/dev/null 2>&1 || sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends -qq python3-pip >/dev/null
# ensure tini is available
if ! command -v tini >/dev/null 2>&1; then sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends -qq tini >/dev/null; fi
# install psycopg2-binary into system site-packages so non-login shells can import it
if ! python3 -c "import psycopg2" >/dev/null 2>&1; then
  sudo python3 -m pip install --upgrade --quiet psycopg2-binary || { echo "failed to install psycopg2-binary" >&2; exit 3; }
fi
# verify import
python3 - <<'PY'
import sys
try:
    import psycopg2
    sys.exit(0)
except Exception as e:
    print('psycopg2 import failed:', e, file=sys.stderr)
    sys.exit(4)
PY
# install supabase native CLI into /usr/local/bin if not present (best-effort, non-fatal)
if ! command -v supabase >/dev/null 2>&1; then
  TMPDIR=$(mktemp -d)
  ARCH=$(uname -m)
  OSNAME=$(uname -s | tr '[:upper:]' '[:lower:]')
  URL="https://github.com/supabase/cli/releases/latest/download/supabase_${OSNAME}_${ARCH}.tar.gz"
  if curl -sSfL -o "$TMPDIR/sup.tar.gz" "$URL"; then
    # prefer top-level member named 'supabase'
    MEMBER=$(tar -tzf "$TMPDIR/sup.tar.gz" | awk -F/ 'NF==1{print $1}' | grep -E '^supabase$' || true)
    if [ -n "$MEMBER" ]; then
      sudo tar -xzf "$TMPDIR/sup.tar.gz" -C /usr/local/bin "$MEMBER" && sudo chmod +x "/usr/local/bin/$MEMBER"
    else
      CAND=$(tar -tzf "$TMPDIR/sup.tar.gz" | awk -F/ 'NF==1{print $1}' | head -n1 || true)
      if [ -n "$CAND" ]; then
        sudo tar -xzf "$TMPDIR/sup.tar.gz" -C /usr/local/bin "$CAND" && sudo chmod +x "/usr/local/bin/$CAND"
      fi
    fi
    rm -rf "$TMPDIR"
  fi
  if command -v supabase >/dev/null 2>&1; then
    supabase --version >/dev/null 2>&1 || echo 'supabase present but version check failed' >&2
  else
    echo 'supabase CLI not installed; continuing without it' >&2
  fi
fi
# persist non-sensitive POSTGRES_* defaults and safe PATH append (do not persist passwords)
sudo tee /etc/profile.d/fraud_claim_db_env.sh >/dev/null <<'EOF'
# fraud_claim_database non-sensitive defaults (override at runtime). Do NOT store secrets here.
export POSTGRES_USER="postgres"
export POSTGRES_DB="fraud_claims"
export POSTGRES_HOST="localhost"
export POSTGRES_PORT="5432"
# preserve a safe PATH prepend for /usr/local/bin if not already present
if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
  export PATH="/usr/local/bin:$PATH"
fi
# legacy names retained but canonical names are POSTGRES_*
export FRAUD_DB_POSTGRES_USER="${POSTGRES_USER}"
export FRAUD_DB_POSTGRES_DB="${POSTGRES_DB}"
export FRAUD_DB_POSTGRES_HOST="${POSTGRES_HOST}"
export FRAUD_DB_POSTGRES_PORT="${POSTGRES_PORT}"
EOF
sudo chmod 644 /etc/profile.d/fraud_claim_db_env.sh
# ensure workspace exists and is owned by current user
sudo mkdir -p "$WS" && sudo chown -R "$(id -u):$(id -g)" "$WS" >/dev/null 2>&1 || true
# final checks: print versions for visibility
psql --version >/dev/null 2>&1 || true
python3 --version >/dev/null 2>&1 || true
pip3 --version >/dev/null 2>&1 || true
command -v tini >/dev/null 2>&1 || true
if command -v supabase >/dev/null 2>&1; then supabase --version >/dev/null 2>&1 || true; fi
exit 0
