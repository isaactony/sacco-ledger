#!/usr/bin/env bash
# Rebuilds the SaccoLedger database from scratch, loads fake data and runs the tests.
# Usage: ./scripts/run-all.sh            (container must be running: docker compose up -d)
#        ./scripts/run-all.sh 07_sample_reports.sql   (run a single script)
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER=sacco-sql

# sqlcmd runs inside the container and reads the SA password from the container's own
# environment, so the password never appears on this machine's command line.
sql() {
  docker exec "$CONTAINER" bash -c \
    'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -I -b -W -s " | " "$@"' \
    _ "$@"
}

echo "Waiting for SQL Server to accept connections..."
for _ in $(seq 1 60); do
  if sql -Q "SELECT 1" >/dev/null 2>&1; then break; fi
  sleep 2
done
sql -Q "SELECT 1" >/dev/null

if [[ $# -gt 0 ]]; then
  sql -i "/sql/$1"
  exit 0
fi

for f in 00_reset_database.sql 01_schema.sql 02_procedures.sql 03_security.sql \
         04_seed_reference.sql 05_generate_fake_data.sql 06_tests.sql \
         08_loans_schema.sql 09_loans_procedures.sql 10_generate_fake_loans.sql 11_loan_tests.sql \
         13_dw_incremental_load.sql; do
  echo
  echo "=== $f ==="
  start=$(date +%s)
  sql -i "/sql/$f"
  echo "($(( $(date +%s) - start ))s)"
done
