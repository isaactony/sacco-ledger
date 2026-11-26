/* 01_schema.sql
   Core tables for a double-entry SACCO / co-op ledger.

   Design rules:
   1. Money only moves through journal entries. There is no "balance" column to UPDATE.
   2. Every journal entry has 2+ lines and total debits = total credits.
   3. Journal rows are append-only. Mistakes are fixed with a reversal entry, never an edit.
   4. Member accounts are a sub-ledger under a GL "control account"
      (e.g. every member savings account rolls up to GL 2010 Member Savings). */
USE SaccoLedger;
GO

/* ---------- Reference data ---------- */

CREATE TABLE dbo.Branch (
    BranchId    int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Branch PRIMARY KEY,
    BranchCode  varchar(10)   NOT NULL CONSTRAINT UQ_Branch_Code UNIQUE,
    BranchName  nvarchar(100) NOT NULL
);

/* Chart of accounts (general ledger). */
CREATE TABLE dbo.GLAccount (
    GLAccountId      int IDENTITY(1,1) NOT NULL CONSTRAINT PK_GLAccount PRIMARY KEY,
    GLCode           varchar(20)   NOT NULL CONSTRAINT UQ_GLAccount_Code UNIQUE,
    GLName           nvarchar(100) NOT NULL,
    AccountClass     varchar(10)   NOT NULL
        CONSTRAINT CK_GLAccount_Class CHECK (AccountClass IN ('ASSET','LIABILITY','EQUITY','INCOME','EXPENSE')),
    -- Assets and expenses grow with debits; liabilities, equity and income grow with credits.
    NormalBalance    AS CAST(CASE WHEN AccountClass IN ('ASSET','EXPENSE') THEN 'D' ELSE 'C' END AS char(1)) PERSISTED,
    -- A control account summarises a member sub-ledger. Postings to it must name a member account.
    IsControlAccount bit NOT NULL CONSTRAINT DF_GLAccount_IsControl DEFAULT (0),
    IsActive         bit NOT NULL CONSTRAINT DF_GLAccount_IsActive  DEFAULT (1)
);

CREATE TABLE dbo.Product (
    ProductId          int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Product PRIMARY KEY,
    ProductCode        varchar(10)   NOT NULL CONSTRAINT UQ_Product_Code UNIQUE,
    ProductName        nvarchar(100) NOT NULL,
    ProductType        varchar(10)   NOT NULL
        CONSTRAINT CK_Product_Type CHECK (ProductType IN ('SAVINGS','SHARES','LOAN')),
    ControlGLAccountId int NOT NULL CONSTRAINT FK_Product_GLAccount REFERENCES dbo.GLAccount (GLAccountId),
    IsWithdrawable     bit NOT NULL,  -- share capital is usually not withdrawable
    MinBalance         decimal(19,4) NOT NULL CONSTRAINT DF_Product_MinBalance DEFAULT (0)
        CONSTRAINT CK_Product_MinBalance CHECK (MinBalance >= 0),
    CONSTRAINT UQ_Product_Id_GL UNIQUE (ProductId, ControlGLAccountId)  -- target for Account's composite FK
);

/* ---------- Members and their accounts ---------- */

CREATE TABLE dbo.Member (
    MemberId    int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Member PRIMARY KEY,
    MemberNo    varchar(20)  NOT NULL CONSTRAINT UQ_Member_No UNIQUE,
    FirstName   nvarchar(50) NOT NULL,
    LastName    nvarchar(50) NOT NULL,
    NationalId  varchar(20)  NOT NULL CONSTRAINT UQ_Member_NationalId UNIQUE,
    PhoneNumber varchar(20)  NULL,
    BranchId    int NOT NULL CONSTRAINT FK_Member_Branch REFERENCES dbo.Branch (BranchId),
    JoinedOn    date NOT NULL,
    Status      varchar(10)  NOT NULL CONSTRAINT DF_Member_Status DEFAULT ('ACTIVE')
        CONSTRAINT CK_Member_Status CHECK (Status IN ('ACTIVE','DORMANT','EXITED'))
);

CREATE TABLE dbo.Account (
    AccountId          int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Account PRIMARY KEY,
    AccountNo          varchar(20) NOT NULL CONSTRAINT UQ_Account_No UNIQUE,
    MemberId           int NOT NULL CONSTRAINT FK_Account_Member REFERENCES dbo.Member (MemberId),
    ProductId          int NOT NULL,
    -- Copied from Product so journal lines can be checked with a plain foreign key (see JournalLine).
    ControlGLAccountId int NOT NULL,
    OpenedOn           date NOT NULL,
    Status             varchar(10) NOT NULL CONSTRAINT DF_Account_Status DEFAULT ('ACTIVE')
        CONSTRAINT CK_Account_Status CHECK (Status IN ('ACTIVE','FROZEN','CLOSED')),
    -- The copied GL must match the product's GL.
    CONSTRAINT FK_Account_Product FOREIGN KEY (ProductId, ControlGLAccountId)
        REFERENCES dbo.Product (ProductId, ControlGLAccountId),
    CONSTRAINT UQ_Account_Id_GL UNIQUE (AccountId, ControlGLAccountId),
    -- One account per product per member keeps the demo simple.
    CONSTRAINT UQ_Account_Member_Product UNIQUE (MemberId, ProductId)
);

/* ---------- The ledger ---------- */

CREATE TABLE dbo.JournalEntry (
    JournalEntryId    bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_JournalEntry PRIMARY KEY,
    -- External reference (teller slip no., mobile money receipt). Unique = safe retries (idempotency).
    Reference         varchar(50)   NOT NULL CONSTRAINT UQ_JournalEntry_Reference UNIQUE,
    TxnDate           date          NOT NULL,
    Narration         nvarchar(200) NOT NULL,
    Channel           varchar(10)   NOT NULL
        CONSTRAINT CK_JournalEntry_Channel CHECK (Channel IN ('TELLER','MOBILE','SYSTEM')),
    BranchId          int NOT NULL CONSTRAINT FK_JournalEntry_Branch REFERENCES dbo.Branch (BranchId),
    ReversalOfEntryId bigint NULL CONSTRAINT FK_JournalEntry_ReversalOf REFERENCES dbo.JournalEntry (JournalEntryId),
    PostedBy          sysname      NOT NULL CONSTRAINT DF_JournalEntry_PostedBy DEFAULT (ORIGINAL_LOGIN()),
    PostedAt          datetime2(3) NOT NULL CONSTRAINT DF_JournalEntry_PostedAt DEFAULT (SYSUTCDATETIME())
);

-- An entry can be reversed at most once.
CREATE UNIQUE INDEX UX_JournalEntry_ReversalOf
    ON dbo.JournalEntry (ReversalOfEntryId) WHERE ReversalOfEntryId IS NOT NULL;
CREATE INDEX IX_JournalEntry_TxnDate ON dbo.JournalEntry (TxnDate);

CREATE TABLE dbo.JournalLine (
    JournalLineId  bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_JournalLine PRIMARY KEY,
    JournalEntryId bigint NOT NULL CONSTRAINT FK_JournalLine_Entry REFERENCES dbo.JournalEntry (JournalEntryId),
    GLAccountId    int    NOT NULL CONSTRAINT FK_JournalLine_GLAccount REFERENCES dbo.GLAccount (GLAccountId),
    AccountId      int    NULL,  -- member sub-ledger account, when the GL is a control account
    Debit          decimal(19,4) NOT NULL CONSTRAINT DF_JournalLine_Debit  DEFAULT (0),
    Credit         decimal(19,4) NOT NULL CONSTRAINT DF_JournalLine_Credit DEFAULT (0),
    -- Each line is either a debit or a credit, never both, never zero, never negative.
    CONSTRAINT CK_JournalLine_OneSided CHECK ((Debit > 0 AND Credit = 0) OR (Credit > 0 AND Debit = 0)),
    -- If a member account is named, the GL must be that account's control GL.
    -- (Composite FKs are not checked when AccountId is NULL, which is what we want for cash, fees etc.)
    CONSTRAINT FK_JournalLine_Account FOREIGN KEY (AccountId, GLAccountId)
        REFERENCES dbo.Account (AccountId, ControlGLAccountId)
);

CREATE INDEX IX_JournalLine_Entry   ON dbo.JournalLine (JournalEntryId);
CREATE INDEX IX_JournalLine_Account ON dbo.JournalLine (AccountId, JournalEntryId)
    INCLUDE (Debit, Credit) WHERE AccountId IS NOT NULL;
GO

/* ---------- Append-only ledger ---------- */

CREATE TRIGGER dbo.trg_JournalEntry_AppendOnly ON dbo.JournalEntry
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50001, 'JournalEntry is append-only. Post a reversal entry instead of editing or deleting.', 1;
END;
GO

CREATE TRIGGER dbo.trg_JournalLine_AppendOnly ON dbo.JournalLine
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50002, 'JournalLine is append-only. Post a reversal entry instead of editing or deleting.', 1;
END;
GO

/* ---------- Balances: derived from the ledger, maintained by the engine ----------
   Indexed views store the totals physically and SQL Server updates them in the
   same transaction as every insert into JournalLine. The balance can never drift
   from the ledger, and reading it is a single-row seek. */

CREATE VIEW dbo.vw_AccountTotals
WITH SCHEMABINDING
AS
SELECT  jl.AccountId,
        SUM(jl.Debit)  AS TotalDebit,
        SUM(jl.Credit) AS TotalCredit,
        COUNT_BIG(*)   AS LineCount
FROM    dbo.JournalLine AS jl
WHERE   jl.AccountId IS NOT NULL
GROUP BY jl.AccountId;
GO
CREATE UNIQUE CLUSTERED INDEX UCX_vw_AccountTotals ON dbo.vw_AccountTotals (AccountId);
GO

CREATE VIEW dbo.vw_GLTotals
WITH SCHEMABINDING
AS
SELECT  jl.GLAccountId,
        SUM(jl.Debit)  AS TotalDebit,
        SUM(jl.Credit) AS TotalCredit,
        COUNT_BIG(*)   AS LineCount
FROM    dbo.JournalLine AS jl
GROUP BY jl.GLAccountId;
GO
CREATE UNIQUE CLUSTERED INDEX UCX_vw_GLTotals ON dbo.vw_GLTotals (GLAccountId);
GO

/* ---------- Reporting views ---------- */

CREATE VIEW dbo.vw_AccountBalance
AS
SELECT  a.AccountId,
        a.AccountNo,
        m.MemberNo,
        m.FirstName + N' ' + m.LastName AS MemberName,
        p.ProductCode,
        a.Status,
        CAST(CASE g.NormalBalance
                 WHEN 'C' THEN ISNULL(t.TotalCredit - t.TotalDebit, 0)
                 ELSE          ISNULL(t.TotalDebit - t.TotalCredit, 0)
             END AS decimal(19,2)) AS Balance,
        ISNULL(t.LineCount, 0) AS PostingCount
FROM    dbo.Account   AS a
JOIN    dbo.Member    AS m ON m.MemberId    = a.MemberId
JOIN    dbo.Product   AS p ON p.ProductId   = a.ProductId
JOIN    dbo.GLAccount AS g ON g.GLAccountId = a.ControlGLAccountId
LEFT JOIN dbo.vw_AccountTotals AS t WITH (NOEXPAND) ON t.AccountId = a.AccountId;
GO

CREATE VIEW dbo.vw_TrialBalance
AS
SELECT  g.GLCode,
        g.GLName,
        g.AccountClass,
        CAST(CASE WHEN ISNULL(t.TotalDebit, 0) >= ISNULL(t.TotalCredit, 0)
                  THEN ISNULL(t.TotalDebit, 0) - ISNULL(t.TotalCredit, 0) ELSE 0 END AS decimal(19,2)) AS DebitBalance,
        CAST(CASE WHEN ISNULL(t.TotalCredit, 0) > ISNULL(t.TotalDebit, 0)
                  THEN ISNULL(t.TotalCredit, 0) - ISNULL(t.TotalDebit, 0) ELSE 0 END AS decimal(19,2)) AS CreditBalance
FROM    dbo.GLAccount AS g
LEFT JOIN dbo.vw_GLTotals AS t WITH (NOEXPAND) ON t.GLAccountId = g.GLAccountId;
GO

/* Detective control: should always return zero rows. */
CREATE VIEW dbo.vw_UnbalancedEntries
AS
SELECT  je.JournalEntryId,
        je.Reference,
        COUNT(jl.JournalLineId)      AS LineCount,
        ISNULL(SUM(jl.Debit), 0)     AS TotalDebit,
        ISNULL(SUM(jl.Credit), 0)    AS TotalCredit
FROM    dbo.JournalEntry AS je
LEFT JOIN dbo.JournalLine AS jl ON jl.JournalEntryId = je.JournalEntryId
GROUP BY je.JournalEntryId, je.Reference
HAVING  COUNT(jl.JournalLineId) < 2
     OR ISNULL(SUM(jl.Debit), 0) <> ISNULL(SUM(jl.Credit), 0);
GO

PRINT 'Schema created.';
