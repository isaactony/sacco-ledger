#!/usr/bin/env bash
# Reproduces the "IDENTITY watermark" bug: three sessions at once, then a reconciliation.
# Run after scripts/run-all.sh and 13_dw_incremental_load.sql.
set -euo pipefail
cd "$(dirname "$0")/.."
run() {
  docker exec sacco-sql bash -c \
    'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -d SaccoLedger -C -I -W -s " | " -i "$1"' _ "/sql/demo/$1"
}
run session_a_slow.sql &
run session_b_fast.sql &
run session_c_load.sql &
wait
echo
run after.sql
