/* 13_dw_incremental_load.sql
   An incremental load from the ledger into a reporting fact table.

   The ledger is append-only, which makes it a good source for incremental loads.
   The catch is choosing the watermark. JournalEntryId looks like the obvious choice,
   but IDENTITY values are handed out when a row is inserted, not when it commits.
   A slow transaction can commit a LOWER id after a load has already moved past it,
   and that row is never loaded. (See demo/watermark_race.sh.)

   This load uses a rowversion column and MIN_ACTIVE_ROWVERSION() instead. Every row
   below MIN_ACTIVE_ROWVERSION() is committed, so the load never moves its watermark
   past a transaction that is still open. */
USE SaccoLedger;
GO

/* rowversion is set by the engine on insert. The ledger is append-only, so it never changes. */
ALTER TABLE dbo.JournalEntry ADD RowVer rowversion NOT NULL;
GO
CREATE UNIQUE INDEX UX_JournalEntry_RowVer ON dbo.JournalEntry (RowVer);
GO

CREATE SCHEMA dw;
GO

CREATE TABLE dw.LoadWatermark (
    TableName     sysname    NOT NULL CONSTRAINT PK_LoadWatermark PRIMARY KEY,
    NextRowVer    binary(8)  NOT NULL,     -- load rows with RowVer >= this next time
    LastLoadedAt  datetime2(3) NULL,
    LastRowCount  int          NULL
);

CREATE TABLE dw.FactJournalLine (
    JournalLineId  bigint        NOT NULL CONSTRAINT PK_FactJournalLine PRIMARY KEY,
    JournalEntryId bigint        NOT NULL,
    TxnDateKey     int           NOT NULL,   -- yyyymmdd
    Reference      varchar(50)   NOT NULL,
    Channel        varchar(10)   NOT NULL,
    BranchCode     varchar(10)   NOT NULL,
    GLCode         varchar(20)   NOT NULL,
    AccountNo      varchar(20)   NULL,
    Debit          decimal(19,4) NOT NULL,
    Credit         decimal(19,4) NOT NULL,
    IsReversal     bit           NOT NULL,
    LoadedAt       datetime2(3)  NOT NULL CONSTRAINT DF_FactJournalLine_LoadedAt DEFAULT (SYSUTCDATETIME())
);
GO

/* ============================================================================
   dw.usp_LoadFactJournalLine
   Loads every journal line whose entry committed since the last run.

   @From  = where the last run stopped (inclusive)
   @To    = MIN_ACTIVE_ROWVERSION(), the oldest rowversion still in an open
            transaction (exclusive). Everything below it has committed.

   Safe to rerun: the window is recorded only after the insert succeeds, and the
   NOT EXISTS guard skips lines that are already in the fact table.
   ============================================================================ */
CREATE OR ALTER PROCEDURE dw.usp_LoadFactJournalLine
    @RowsLoaded int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @From binary(8), @To binary(8);

    SET @From = ISNULL((SELECT NextRowVer FROM dw.LoadWatermark WHERE TableName = 'FactJournalLine'), 0x0);
    SET @To   = MIN_ACTIVE_ROWVERSION();

    BEGIN TRANSACTION;

    INSERT dw.FactJournalLine (JournalLineId, JournalEntryId, TxnDateKey, Reference, Channel, BranchCode,
                               GLCode, AccountNo, Debit, Credit, IsReversal)
    SELECT  jl.JournalLineId, je.JournalEntryId,
            CONVERT(int, CONVERT(char(8), je.TxnDate, 112)),
            je.Reference, je.Channel, b.BranchCode, g.GLCode, a.AccountNo,
            jl.Debit, jl.Credit, IIF(je.ReversalOfEntryId IS NULL, 0, 1)
    FROM    dbo.JournalEntry AS je
    JOIN    dbo.JournalLine  AS jl ON jl.JournalEntryId = je.JournalEntryId
    JOIN    dbo.Branch       AS b  ON b.BranchId        = je.BranchId
    JOIN    dbo.GLAccount    AS g  ON g.GLAccountId     = jl.GLAccountId
    LEFT JOIN dbo.Account    AS a  ON a.AccountId       = jl.AccountId
    WHERE   je.RowVer >= @From
      AND   je.RowVer <  @To
      AND   NOT EXISTS (SELECT 1 FROM dw.FactJournalLine AS f WHERE f.JournalLineId = jl.JournalLineId);

    SET @RowsLoaded = @@ROWCOUNT;

    MERGE dw.LoadWatermark AS w
    USING (SELECT 'FactJournalLine' AS TableName) AS s ON w.TableName = s.TableName
    WHEN MATCHED THEN UPDATE SET NextRowVer = @To, LastLoadedAt = SYSUTCDATETIME(), LastRowCount = @RowsLoaded
    WHEN NOT MATCHED THEN INSERT (TableName, NextRowVer, LastLoadedAt, LastRowCount)
                          VALUES ('FactJournalLine', @To, SYSUTCDATETIME(), @RowsLoaded);

    COMMIT TRANSACTION;
END;
GO

/* The naive version, kept only so the demo can show what goes wrong. */
CREATE TABLE dw.NaiveWatermark (TableName sysname PRIMARY KEY, LastId bigint NOT NULL);
CREATE TABLE dw.NaiveFactJournalLine (JournalLineId bigint PRIMARY KEY, JournalEntryId bigint NOT NULL,
                                      Debit decimal(19,4) NOT NULL, Credit decimal(19,4) NOT NULL);
GO
CREATE OR ALTER PROCEDURE dw.usp_NaiveLoad
    @RowsLoaded int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @From bigint = ISNULL((SELECT LastId FROM dw.NaiveWatermark WHERE TableName = 'FactJournalLine'), 0),
            @To   bigint;

    -- "Load everything with an id above the last one we saw."
    SET @To = (SELECT MAX(JournalEntryId) FROM dbo.JournalEntry);

    INSERT dw.NaiveFactJournalLine (JournalLineId, JournalEntryId, Debit, Credit)
    SELECT jl.JournalLineId, jl.JournalEntryId, jl.Debit, jl.Credit
    FROM   dbo.JournalLine AS jl
    WHERE  jl.JournalEntryId > @From AND jl.JournalEntryId <= @To;
    SET @RowsLoaded = @@ROWCOUNT;

    MERGE dw.NaiveWatermark AS w USING (SELECT 'FactJournalLine' AS TableName) AS s ON w.TableName = s.TableName
    WHEN MATCHED THEN UPDATE SET LastId = @To
    WHEN NOT MATCHED THEN INSERT (TableName, LastId) VALUES ('FactJournalLine', @To);
END;
GO

/* Reconciliation: the fact table must match the source line for line. */
CREATE OR ALTER VIEW dw.vw_LoadReconciliation
AS
SELECT  'source' AS Side, COUNT(*) AS Lines, SUM(Debit) AS Debits, SUM(Credit) AS Credits FROM dbo.JournalLine
UNION ALL
SELECT  'rowversion load', COUNT(*), SUM(Debit), SUM(Credit) FROM dw.FactJournalLine
UNION ALL
SELECT  'naive id load',   COUNT(*), SUM(Debit), SUM(Credit) FROM dw.NaiveFactJournalLine;
GO

PRINT 'Warehouse load objects created.';
