#!/usr/bin/env bash
set -euo pipefail
WS="${WS:-/home/kavia/workspace/code-generation/fraud-claims-management-system-2268-2919/fraud_claim_database}"
mkdir -p "$WS" && cd "$WS"
mkdir -p migrations sql scripts
cat > "$WS/migrations/001_create_table_fraud_claims.sql" <<'SQL'
-- idempotent migration
CREATE TABLE IF NOT EXISTS fraud_claims (
  id SERIAL PRIMARY KEY,
  claimant_name text NOT NULL,
  amount numeric NOT NULL,
  created_at timestamptz DEFAULT now()
);
SQL
# start-supervisor: exec tini in foreground and record PID file
cat > "$WS/scripts/start-supervisor.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
WS="${WS:-/home/kavia/workspace/code-generation/fraud-claims-management-system-2268-2919/fraud_claim_database}"
PIDFILE="$WS/.supervisor.pid"
command -v tini >/dev/null || { echo "tini missing" >&2; exit 2; }
# run tini in background but record its PID
( exec tini -- sleep infinity ) &
TID=$!
sleep 0.2
if kill -0 "$TID" >/dev/null 2>&1; then
  echo "$TID" > "$PIDFILE"
else
  echo "failed to start tini supervisor" >&2; exit 3
fi
SH
chmod +x "$WS/scripts/start-supervisor.sh"
# healthcheck: concise psql connectivity check
cat > "$WS/scripts/healthcheck.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ -f /etc/profile.d/fraud_claim_db_env.sh ] && source /etc/profile.d/fraud_claim_db_env.sh || true
: "${POSTGRES_USER:-postgres}"; : "${POSTGRES_DB:-fraud_claims}"; : "${POSTGRES_HOST:-localhost}"; : "${POSTGRES_PORT:-5432}"
if [ -n "${POSTGRES_PASSWORD:-}" ]; then export PGPASSWORD="$POSTGRES_PASSWORD"; fi
psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c 'SELECT 1;' >/dev/null 2>&1 && echo OK || (echo FAIL >&2; exit 1)
SH
chmod +x "$WS/scripts/healthcheck.sh"
# apply-migrations: check DB existence and CREATEDB privilege before creating DB, track applied migrations
cat > "$WS/scripts/apply-migrations.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
WS="${WS:-/home/kavia/workspace/code-generation/fraud-claims-management-system-2268-2919/fraud_claim_database}"
[ -f /etc/profile.d/fraud_claim_db_env.sh ] && source /etc/profile.d/fraud_claim_db_env.sh || true
POSTGRES_USER="${POSTGRES_USER:-postgres}"; POSTGRES_DB="${POSTGRES_DB:-fraud_claims}"; POSTGRES_HOST="${POSTGRES_HOST:-localhost}"; POSTGRES_PORT="${POSTGRES_PORT:-5432}"
if [ -n "${POSTGRES_PASSWORD:-}" ]; then export PGPASSWORD="$POSTGRES_PASSWORD"; fi
# Check if DB exists
EXISTS=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d postgres -At -c "SELECT 1 FROM pg_database WHERE datname='$POSTGRES_DB'" 2>/dev/null || true)
if [ "$EXISTS" != "1" ]; then
  # check CREATEDB or superuser privilege
  CAN_CREATEDB=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d postgres -At -c "SELECT rolsuper OR rolcreatedb FROM pg_roles WHERE rolname='$POSTGRES_USER'" 2>/dev/null || true)
  if [ "$CAN_CREATEDB" = "t" ] || [ "$CAN_CREATEDB" = "true" ]; then
    psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE \"$POSTGRES_DB\";"
  else
    echo "User $POSTGRES_USER lacks CREATEDB privileges. Create database $POSTGRES_DB manually or run with a superuser." >&2
    exit 5
  fi
fi
# ensure migrations tracking table
psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, applied_at timestamptz DEFAULT now());"
for f in "$WS"/migrations/*.sql; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  APPLIED=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -c "SELECT 1 FROM schema_migrations WHERE name='$name'" 2>/dev/null || true)
  if [ "$APPLIED" = "1" ]; then continue; fi
  psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f "$f"
  psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "INSERT INTO schema_migrations(name) VALUES('$name') ON CONFLICT DO NOTHING;"
done
SH
chmod +x "$WS/scripts/apply-migrations.sh"

echo "scaffold: created workspace and scripts at $WS"
