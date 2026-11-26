#!/usr/bin/env bash
# The same payment webhook delivered twice, 300 ms apart, against three handler versions.
# Run after scripts/run-all.sh and 14_webhook_idempotency.sql.
set -euo pipefail
cd "$(dirname "$0")/.."
run() {
  docker exec sacco-sql bash -c \
    'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -d SaccoLedger -C -I -W -s " | " "$@"' _ "$@"
}
stamp=$(date +%H%M%S)
for v in 1 2 3; do
  evt="evt_${stamp}_v${v}"
  run -i /sql/demo/webhook_delivery.sql -v Version=$v EventId=$evt Delivery=1 StartDelay=00:00:00.000 &
  run -i /sql/demo/webhook_delivery.sql -v Version=$v EventId=$evt Delivery=2 StartDelay=00:00:00.300 &
  wait
  echo
done

run -Q "
SELECT 'v1 check then insert' AS Handler, COUNT(*) AS Credits, SUM(Amount) AS Credited
FROM hook.NaiveCredit WHERE EventId = 'evt_${stamp}_v1'
UNION ALL
SELECT 'v2 plus UNIQUE', COUNT(*), SUM(Amount) FROM hook.UniqueCredit WHERE EventId = 'evt_${stamp}_v2'
UNION ALL
SELECT 'v3 claim event first', COUNT(*), SUM(jl.Credit)
FROM dbo.JournalEntry je JOIN dbo.JournalLine jl ON jl.JournalEntryId = je.JournalEntryId AND jl.AccountId IS NOT NULL
WHERE je.Reference = 'WH-evt_${stamp}_v3';
SELECT EventId, JournalEntryId, DeliveryCount FROM hook.WebhookEvent WHERE EventId = 'evt_${stamp}_v3';"
