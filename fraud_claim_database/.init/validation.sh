#!/usr/bin/env bash
set -euo pipefail
# validation - apply migrations, healthcheck, verify migration results, manage supervisor and produce artifact
WS="${WS:-/home/kavia/workspace/code-generation/fraud-claims-management-system-2268-2919/fraud_claim_database}"
cd "$WS"
# load optional persisted defaults (non-sensitive)
[ -f /etc/profile.d/fraud_claim_db_env.sh ] && source /etc/profile.d/fraud_claim_db_env.sh || true
: "${POSTGRES_USER:-postgres}"; : "${POSTGRES_DB:-fraud_claims}"; : "${POSTGRES_HOST:-localhost}"; : "${POSTGRES_PORT:-5432}"
if [ -n "${POSTGRES_PASSWORD:-}" ]; then export PGPASSWORD="$POSTGRES_PASSWORD"; fi
# ensure scripts exist
for s in scripts/apply-migrations.sh scripts/healthcheck.sh scripts/start-supervisor.sh; do
  if [ ! -x "$WS/$s" ]; then echo "required script missing or not executable: $s" >&2; exit 2; fi
done
# Run apply-migrations (may need CREATEDB privilege). Exit codes:
# 3 -> permission/create-db error, 4 -> healthcheck failed, 6 -> migration verification failed, 7..9 -> supervisor issues
set -o pipefail
if ! "$WS/scripts/apply-migrations.sh" >/tmp/.validation.apply.log 2>&1; then
  # inspect for permission/connectivity hints
  if grep -qi "permission denied\|must be superuser\|CREATE DATABASE" /tmp/.validation.apply.log || grep -qi "permission" /tmp/.validation.apply.log; then
    cat /tmp/.validation.apply.log >&2
    echo 'apply-migrations failed: permission or createdb missing' >&2
    exit 3
  else
    cat /tmp/.validation.apply.log >&2
    echo 'apply-migrations failed: unknown error' >&2
    exit 5
  fi
fi
# healthcheck with retry
RETRIES=5; SLEEP=1
for i in $(seq 1 $RETRIES); do
  if "$WS/scripts/healthcheck.sh" >/dev/null 2>&1; then break; fi
  sleep $SLEEP
done
if ! "$WS/scripts/healthcheck.sh" >/dev/null 2>&1; then echo 'HEALTHCHECK failed' >&2; exit 4; fi
# verify migration-created table exists by querying count(*)
if ! psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc "SELECT count(*) FROM fraud_claims;" >/tmp/.validation.count 2>/tmp/.validation.count.err; then
  # connectivity or permission error
  cat /tmp/.validation.count.err >&2
  echo 'MIGRATION verify failed (connectivity/permission)' >&2
  exit 6
fi
COUNT=$(sed -n '1p' /tmp/.validation.count | tr -d '[:space:]' || true)
if [ -z "$COUNT" ]; then
  echo 'MIGRATION verify failed: empty count' >&2
  exit 6
fi
# start supervisor
if ! "$WS/scripts/start-supervisor.sh" >/tmp/.validation.supervisor.start.log 2>&1; then
  cat /tmp/.validation.supervisor.start.log >&2
  echo 'failed to start supervisor' >&2
  exit 7
fi
PIDFILE="$WS/.supervisor.pid"
if [ ! -f "$PIDFILE" ]; then echo 'supervisor pidfile missing' >&2; exit 7; fi
PID=$(cat "$PIDFILE" 2>/dev/null || true)
if [ -z "$PID" ]; then echo 'supervisor pidfile empty' >&2; rm -f "$PIDFILE" || true; exit 7; fi
# ensure process exists
if ! kill -0 "$PID" >/dev/null 2>&1; then echo 'supervisor process not running' >&2; rm -f "$PIDFILE" || true; exit 8; fi
# stop supervisor cleanly
kill "$PID" >/dev/null 2>&1 || true
# wait for termination
for i in {1..10}; do
  if kill -0 "$PID" >/dev/null 2>&1; then sleep 0.2; else break; fi
done
if kill -0 "$PID" >/dev/null 2>&1; then echo 'failed to stop supervisor' >&2; exit 9; fi
rm -f "$PIDFILE" || true
# evidence artifact (do not include password)
cat > "$WS/.validation_ok" <<EOF
validation_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
postgres_host=${POSTGRES_HOST}
postgres_db=${POSTGRES_DB}
postgres_user=${POSTGRES_USER}
migration_count=${COUNT}
EOF
# list top workspace contents as brief evidence
ls -la "$WS" | sed -n '1,120p'
# exit success
exit 0
