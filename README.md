# SACCO Ledger

A double-entry ledger for a savings and credit co-op (SACCO), written in T-SQL for SQL Server 2022.

It handles members, savings and share accounts, deposits, withdrawals, transfers, reversals and loans. I built it to learn how core banking systems keep money from being double-posted, overdrawn or edited after the fact, and to write about it.

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

## Loans (part 2)

- Members can borrow a multiple of their savings. Every loan must be fully guaranteed by other members.
- Pledged savings are frozen, and the frozen amount shrinks as the borrower repays.
- The person who captures an application can't approve it.
- Repayment schedules are built with a recursive CTE, for reducing-balance and flat-rate loans.
- Interest is charged by a daily job that is safe to run twice.
- Repayments pay interest first, then principal. Overpayments go to savings.
- An ageing report works out days past due from the ledger, and a month-end job keeps the loan loss provision in line with it.

## Files

- `sql/00_reset_database.sql` drops and recreates the database
- `sql/01_schema.sql` has the tables, constraints, triggers and views
- `sql/02_procedures.sql` has the posting procedure and the deposit, withdraw, transfer and reverse procedures
- `sql/03_security.sql` sets up roles and permissions
- `sql/04_seed_reference.sql` adds branches, the chart of accounts and products
- `sql/05_generate_fake_data.sql` creates 500 members and about 6,000 transactions
- `sql/06_tests.sql` runs 24 checks and fails if any of them fail
- `sql/07_sample_reports.sql` has a member statement, trial balance and a few other reports
- `sql/08_loans_schema.sql` adds the loan tables
- `sql/09_loans_procedures.sql` has the loan procedures, schedule function and ageing function
- `sql/10_generate_fake_loans.sql` runs a year of fake lending day by day
- `sql/11_loan_tests.sql` runs 33 loan checks
- `sql/12_loan_reports.sql` has the ageing report, PAR30, guarantor exposure and monthly income
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
- Interest on badly overdue loans still goes to income. Most regulators want it held in suspense until paid.

Next I'm adding month-end close and financial statements.
