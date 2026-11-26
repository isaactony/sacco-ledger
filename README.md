# SACCO Ledger

A double-entry ledger for a savings and credit co-op (SACCO), written in T-SQL for SQL Server 2022.

It handles members, savings and share accounts, deposits, withdrawals, transfers and reversals. I built it to learn how core banking systems keep money from being double-posted, overdrawn or edited after the fact, and to write about it.

All the data is fake. Member ID numbers start with `FAKE`.

## Why

A lot of small systems keep a `Balance` column and run `UPDATE Account SET Balance = Balance + 500`. That breaks when an app retries a request, when two tellers hit the same account at once, or when someone edits a wrong transaction instead of reversing it.

This project stores every transaction as journal lines (debits and credits) and works out balances from those lines. The database enforces the rules, so a bug in the app can't get around them.

## What it does

- Every journal entry must balance. Apps can only post through stored procedures, not insert into the tables directly.
- Journal tables are append-only. Mistakes are fixed with a reversal, and an entry can only be reversed once.
- Each transaction has a unique reference, so a retried request returns the original entry instead of posting twice.
- Accounts are locked in a fixed order and funds are checked after the insert, inside the transaction. This stops overdrafts and deadlocks when two transfers run at the same time.
- Balances come from indexed views, so they can't drift from the journal.
- There are three roles, for the app, supervisors and read-only reporting.

## Files

- `sql/00_reset_database.sql` drops and recreates the database
- `sql/01_schema.sql` has the tables, constraints, triggers and views
- `sql/02_procedures.sql` has the posting procedure and the deposit, withdraw, transfer and reverse procedures
- `sql/03_security.sql` sets up roles and permissions
- `sql/04_seed_reference.sql` adds branches, the chart of accounts and products
- `sql/05_generate_fake_data.sql` creates 500 members and about 6,000 transactions
- `sql/06_tests.sql` runs 24 checks and fails if any of them fail
- `sql/07_sample_reports.sql` has a member statement, trial balance and a few other reports
- `scripts/run-all.sh` rebuilds everything and runs the tests

## Running it

You need Docker. On an Apple Silicon Mac, turn on Rosetta in Docker Desktop settings.

```bash
cp .env.example .env
docker compose up -d
./scripts/run-all.sh
```

Set your own password in `.env` first. To run just one script, pass its name.

```bash
./scripts/run-all.sh 07_sample_reports.sql
```

You can also connect with Azure Data Studio, DBeaver or VS Code to `localhost,1433` as `sa`.

## Limitations

- SQL Server doesn't have deferred constraints, so "debits equal credits" is checked in the posting procedure, not as a table constraint.
- Indexed views make reads fast but add a small cost to every insert.
- `PostedBy` uses the SQL login. A real system would pass in the teller's user ID.

Next I'm adding loans, interest and month-end close.
