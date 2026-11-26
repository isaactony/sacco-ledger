# SACCO Ledger: a double-entry core banking database in SQL Server

A small but realistic ledger for a savings and credit co-operative (SACCO / financial co-op), built in
T-SQL on SQL Server 2022. It covers members, savings and share accounts, deposits, withdrawals,
transfers and reversals, and it is designed so that **money can't be created, lost or quietly edited**.

> All data is generated. Names come from a short list, ID numbers start with `FAKE`, and no real
> people, accounts or institutions are represented.

## The problem

Many small financial institutions start with a `Balance` column and statements like
`UPDATE Account SET Balance = Balance + 500`. This works until one of these happens.

- a phone app retries after a timeout and the deposit is posted twice
- two tellers withdraw from the same account at the same moment and both see enough money
- someone "fixes" a wrong posting by editing it, and the audit trail is gone
- month-end totals don't match the sum of member balances, and nobody can say why

This project replaces that design with a **double-entry ledger**, the same model accountants and core
banking systems use, and pushes the rules down into the database where an application bug can't
bypass them.

## Design at a glance

```mermaid
erDiagram
    Branch       ||--o{ Member       : "home branch"
    Member       ||--o{ Account      : owns
    Product      ||--o{ Account      : "type of"
    GLAccount    ||--o{ Product      : "control GL"
    JournalEntry ||--|{ JournalLine  : "2+ lines"
    GLAccount    ||--o{ JournalLine  : posts to
    Account      |o--o{ JournalLine  : "sub-ledger"
    JournalEntry |o--o| JournalEntry : "reverses"
    Branch       ||--o{ JournalEntry : "posted at"

    JournalEntry {
        bigint JournalEntryId PK
        varchar Reference UK "idempotency key"
        date TxnDate
        varchar Channel "TELLER / MOBILE / SYSTEM"
        bigint ReversalOfEntryId FK "unique when set"
    }
    JournalLine {
        bigint JournalLineId PK
        bigint JournalEntryId FK
        int GLAccountId FK
        int AccountId FK "nullable"
        decimal Debit
        decimal Credit
    }
    Account {
        int AccountId PK
        varchar AccountNo UK
        int ControlGLAccountId "copied from Product"
        varchar Status "ACTIVE / FROZEN / CLOSED"
    }
    GLAccount {
        int GLAccountId PK
        varchar GLCode UK
        varchar AccountClass
        bit IsControlAccount
    }
```

There is deliberately **no balance column**. Balances come from two indexed views,
`vw_AccountTotals` (per member account) and `vw_GLTotals` (per GL account).

| Rule | How it's enforced |
|---|---|
| Every entry balances (debits = credits) | `usp_PostJournal` validates before writing. Apps have no INSERT rights on ledger tables. `vw_UnbalancedEntries` is a detective check. |
| A line is a debit **or** a credit, positive, never both | `CHECK` constraint on `JournalLine` |
| Member account lines hit the right GL control account | Composite foreign key `(AccountId, GLAccountId)` → `Account(AccountId, ControlGLAccountId)` |
| The ledger is append-only | `INSTEAD OF UPDATE, DELETE` triggers. Mistakes are corrected with `usp_ReverseEntry`. |
| An entry can be reversed only once | Filtered unique index on `ReversalOfEntryId` |
| Retries don't double-post | Unique `Reference` + an idempotency check that returns the original entry |
| No overdrafts or breaking the minimum balance | Checked **after** insert, inside the transaction, while holding the account lock |
| No deadlocks between opposite transfers | Accounts are locked one by one in ascending `AccountId` order |
| Balances never drift from the ledger | Balances are **indexed views** over `JournalLine`, maintained by the engine in the same transaction |
| Segregation of duties | Roles: `ledger_app` (deposit/withdraw/transfer), `ledger_supervisor` (reversals, manual journals), `ledger_reporting` (read-only) |

### Example: a mobile withdrawal of 400 with a 30 fee

| GL | Member account | Debit | Credit |
|---|---|---:|---:|
| 2010 Member Savings Deposits | SAV-M00042 | 430.00 | |
| 1020 Mobile Money Float | | | 400.00 |
| 4010 Fee Income | | | 30.00 |
| **Total** | | **430.00** | **430.00** |

## Project layout

```
sql/
  00_reset_database.sql      drop + create the database (dev only)
  01_schema.sql              tables, constraints, append-only triggers, indexed views, reporting views
  02_procedures.sql          usp_PostJournal and the deposit / withdraw / transfer / reverse wrappers
  03_security.sql            roles and permissions
  04_seed_reference.sql      branches, chart of accounts, products
  05_generate_fake_data.sql  500 members, ~6,000 transactions through the real procedures
  06_tests.sql               24 automated checks (fails the run if any check fails)
  07_sample_reports.sql      statement with running balance, trial balance, reconciliation...
scripts/run-all.sh           rebuild everything and run the tests
docs/images/                 diagrams and result tables used in the write-up
```

## Run it

You need Docker Desktop. On Apple Silicon, turn on **Settings → General → Use Rosetta for x86_64/amd64
emulation**.

```bash
cp .env.example .env        # then set your own local password
docker compose up -d
./scripts/run-all.sh
```

Run a single script, for example the reports.

```bash
./scripts/run-all.sh 07_sample_reports.sql
```

To browse the data in a GUI, connect VS Code (mssql extension), Azure Data Studio or DBeaver to
`localhost,1433` as `sa` with the password from `.env`.

## What the tests prove

`06_tests.sql` checks individual rules (overdrafts, idempotent retries, reversals, frozen accounts,
permissions, append-only tables) and then checks invariants across the **whole** ledger, including
all the generated data.

- every journal entry balances
- the trial balance balances
- indexed-view balances match a full recalculation from journal lines
- each GL control account equals the sum of its member accounts
- no member account is negative

## Trade-offs and what's next

- **SQL Server has no deferred constraints**, so "debits = credits" can't be a declarative constraint
  across rows. This project combines a single posting procedure, permissions and a detective view.
  The README says so openly because a reviewer will ask.
- Indexed views make reads instant but add a little cost to every insert. For a SACCO's volumes this
  is a good trade. At very high volumes you'd consider periodic balance snapshots.
- `PostedBy` uses `ORIGINAL_LOGIN()`. A real deployment would pass the teller's user ID from the
  application and use one login per app, not shared accounts.
- Next in the series: **loans** (GL 1100 is already in the chart of accounts), interest accrual,
  month-end close, and temporal tables for member data changes.

## Tech

SQL Server 2022 Developer Edition · T-SQL · Docker
