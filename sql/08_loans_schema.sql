/* 08_loans_schema.sql
   Part 2 adds loans on top of the part 1 ledger.

   The ledger is still the only place money lives. The loan tables below hold the
   contract (amount, rate, term, guarantors, schedule). Balances such as "principal
   outstanding" are always read from journal lines, never stored on the loan. */
USE SaccoLedger;
GO

/* ---------- A member can now hold more than one account of a product ----------
   Part 1 allowed one account per member per product. A member can take a second
   loan after clearing the first, so accounts get a sequence number. */
ALTER TABLE dbo.Account DROP CONSTRAINT UQ_Account_Member_Product;
ALTER TABLE dbo.Account ADD AccountSeq smallint NOT NULL CONSTRAINT DF_Account_Seq DEFAULT (1);
GO
ALTER TABLE dbo.Account ADD
    CONSTRAINT UQ_Account_Member_Product_Seq UNIQUE (MemberId, ProductId, AccountSeq),
    -- Target for the Loan composite foreign keys below (the loan account must belong to the borrower).
    CONSTRAINT UQ_Account_Id_Member UNIQUE (AccountId, MemberId);
GO

/* ---------- Chart of accounts and products for lending ---------- */
INSERT dbo.GLAccount (GLCode, GLName, AccountClass, IsControlAccount) VALUES
    ('1110', N'Interest Receivable on Loans',   'ASSET',   1),
    ('1190', N'Provision for Loan Losses',      'ASSET',   0),  -- contra-asset, carries a credit balance
    ('5030', N'Loan Loss Provision Expense',    'EXPENSE', 0);

INSERT dbo.Product (ProductCode, ProductName, ProductType, ControlGLAccountId, IsWithdrawable, MinBalance)
SELECT v.ProductCode, v.ProductName, 'LOAN', g.GLAccountId, 0, 0
FROM (VALUES ('LDV', N'Development Loan principal', '1100'),
             ('LEM', N'Emergency Loan principal',   '1100'),
             ('LIN', N'Loan interest receivable',   '1110')) AS v (ProductCode, ProductName, GLCode)
JOIN dbo.GLAccount AS g ON g.GLCode = v.GLCode;
GO

/* ---------- Loan products ---------- */
CREATE TABLE dbo.LoanProduct (
    LoanProductId      int IDENTITY(1,1) NOT NULL CONSTRAINT PK_LoanProduct PRIMARY KEY,
    LoanProductCode    varchar(10)   NOT NULL CONSTRAINT UQ_LoanProduct_Code UNIQUE,
    LoanProductName    nvarchar(100) NOT NULL,
    PrincipalProductId int NOT NULL CONSTRAINT FK_LoanProduct_Principal REFERENCES dbo.Product (ProductId),
    InterestProductId  int NOT NULL CONSTRAINT FK_LoanProduct_Interest  REFERENCES dbo.Product (ProductId),
    InterestMethod     varchar(10)  NOT NULL
        CONSTRAINT CK_LoanProduct_Method CHECK (InterestMethod IN ('REDUCING', 'FLAT')),
    AnnualRatePct      decimal(9,4) NOT NULL CONSTRAINT CK_LoanProduct_Rate CHECK (AnnualRatePct BETWEEN 0 AND 100),
    MaxTermMonths      smallint     NOT NULL CONSTRAINT CK_LoanProduct_Term CHECK (MaxTermMonths BETWEEN 1 AND 60),
    -- A member can borrow up to this multiple of their savings.
    SavingsMultiple    decimal(5,2) NOT NULL CONSTRAINT CK_LoanProduct_Multiple CHECK (SavingsMultiple > 0),
    ProcessingFeePct   decimal(9,4) NOT NULL CONSTRAINT CK_LoanProduct_Fee CHECK (ProcessingFeePct BETWEEN 0 AND 10)
);

INSERT dbo.LoanProduct (LoanProductCode, LoanProductName, PrincipalProductId, InterestProductId,
                        InterestMethod, AnnualRatePct, MaxTermMonths, SavingsMultiple, ProcessingFeePct)
SELECT v.Code, v.Name, pp.ProductId, ip.ProductId, v.Method, v.Rate, v.Term, v.Multiple, v.Fee
FROM (VALUES ('DEV', N'Development Loan', 'LDV', 'REDUCING', 12.0, 36, 3.0, 1.0),
             ('EMG', N'Emergency Loan',   'LEM', 'FLAT',     12.0, 12, 1.0, 0.0))
     AS v (Code, Name, PrincipalCode, Method, Rate, Term, Multiple, Fee)
JOIN dbo.Product AS pp ON pp.ProductCode = v.PrincipalCode
JOIN dbo.Product AS ip ON ip.ProductCode = 'LIN';
GO

/* ---------- Loans ---------- */
CREATE SEQUENCE dbo.LoanNoSeq AS int START WITH 1;
GO

CREATE TABLE dbo.Loan (
    LoanId              int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Loan PRIMARY KEY,
    LoanNo              varchar(20)  NOT NULL CONSTRAINT UQ_Loan_No UNIQUE,
    MemberId            int          NOT NULL CONSTRAINT FK_Loan_Member REFERENCES dbo.Member (MemberId),
    LoanProductId       int          NOT NULL CONSTRAINT FK_Loan_Product REFERENCES dbo.LoanProduct (LoanProductId),
    -- Terms are copied from the product when the member applies. Changing a product's
    -- rate later must not change loans that are already running.
    Principal           decimal(19,2) NOT NULL CONSTRAINT CK_Loan_Principal CHECK (Principal > 0),
    AnnualRatePct       decimal(9,4)  NOT NULL,
    InterestMethod      varchar(10)   NOT NULL CONSTRAINT CK_Loan_Method CHECK (InterestMethod IN ('REDUCING', 'FLAT')),
    TermMonths          smallint      NOT NULL CONSTRAINT CK_Loan_Term CHECK (TermMonths BETWEEN 1 AND 60),
    ProcessingFeePct    decimal(9,4)  NOT NULL,
    Status              varchar(10)   NOT NULL CONSTRAINT DF_Loan_Status DEFAULT ('APPLIED')
        CONSTRAINT CK_Loan_Status CHECK (Status IN ('APPLIED', 'APPROVED', 'REJECTED', 'ACTIVE', 'CLOSED')),
    ApplicationDate     date          NOT NULL,
    AppliedBy           sysname       NOT NULL,
    ApprovedBy          sysname       NULL,
    ApprovedOn          date          NULL,
    DisbursedOn         date          NULL,
    FirstDueDate        date          NULL,
    ClosedOn            date          NULL,
    RejectionReason     nvarchar(200) NULL,
    PrincipalAccountId  int           NULL,
    InterestAccountId   int           NULL,
    DisbursementEntryId bigint        NULL CONSTRAINT FK_Loan_Disbursement REFERENCES dbo.JournalEntry (JournalEntryId),

    -- Maker-checker: whoever captured the application can't approve it.
    CONSTRAINT CK_Loan_MakerChecker CHECK (ApprovedBy <> AppliedBy),
    -- Once money has gone out, the loan must point at its ledger accounts.
    CONSTRAINT CK_Loan_DisbursedHasAccounts CHECK (
        Status IN ('APPLIED', 'APPROVED', 'REJECTED')
        OR (PrincipalAccountId IS NOT NULL AND InterestAccountId IS NOT NULL
            AND DisbursedOn IS NOT NULL AND FirstDueDate IS NOT NULL AND DisbursementEntryId IS NOT NULL)),
    -- The loan's accounts must belong to the borrower.
    CONSTRAINT FK_Loan_PrincipalAccount FOREIGN KEY (PrincipalAccountId, MemberId) REFERENCES dbo.Account (AccountId, MemberId),
    CONSTRAINT FK_Loan_InterestAccount  FOREIGN KEY (InterestAccountId,  MemberId) REFERENCES dbo.Account (AccountId, MemberId),
    CONSTRAINT UQ_Loan_Id_Member UNIQUE (LoanId, MemberId)   -- target for LoanGuarantor
);

-- One open loan per member per product. Closed and rejected loans don't count.
CREATE UNIQUE INDEX UX_Loan_OneOpenPerProduct ON dbo.Loan (MemberId, LoanProductId)
    WHERE Status IN ('APPLIED', 'APPROVED', 'ACTIVE');
CREATE UNIQUE INDEX UX_Loan_PrincipalAccount ON dbo.Loan (PrincipalAccountId) WHERE PrincipalAccountId IS NOT NULL;
CREATE UNIQUE INDEX UX_Loan_InterestAccount  ON dbo.Loan (InterestAccountId)  WHERE InterestAccountId  IS NOT NULL;
GO

/* ---------- Guarantors ---------- */
CREATE TABLE dbo.LoanGuarantor (
    LoanId            int           NOT NULL,
    BorrowerMemberId  int           NOT NULL,
    GuarantorMemberId int           NOT NULL CONSTRAINT FK_LoanGuarantor_Member REFERENCES dbo.Member (MemberId),
    AmountGuaranteed  decimal(19,2) NOT NULL CONSTRAINT CK_LoanGuarantor_Amount CHECK (AmountGuaranteed > 0),
    PledgedOn         date          NOT NULL,
    CONSTRAINT PK_LoanGuarantor PRIMARY KEY (LoanId, GuarantorMemberId),
    CONSTRAINT FK_LoanGuarantor_Loan FOREIGN KEY (LoanId, BorrowerMemberId) REFERENCES dbo.Loan (LoanId, MemberId),
    -- Nobody guarantees their own loan.
    CONSTRAINT CK_LoanGuarantor_NotSelf CHECK (GuarantorMemberId <> BorrowerMemberId)
);
CREATE INDEX IX_LoanGuarantor_Guarantor ON dbo.LoanGuarantor (GuarantorMemberId) INCLUDE (AmountGuaranteed);
GO

/* ---------- Repayment schedule ----------
   Written once at disbursement and never changed. */
CREATE TABLE dbo.LoanSchedule (
    LoanId           int           NOT NULL CONSTRAINT FK_LoanSchedule_Loan REFERENCES dbo.Loan (LoanId),
    InstallmentNo    smallint      NOT NULL,
    DueDate          date          NOT NULL,
    OpeningPrincipal decimal(19,2) NOT NULL,
    PrincipalDue     decimal(19,2) NOT NULL,
    InterestDue      decimal(19,2) NOT NULL,
    TotalDue         AS (PrincipalDue + InterestDue) PERSISTED,
    ClosingPrincipal decimal(19,2) NOT NULL,
    CONSTRAINT PK_LoanSchedule PRIMARY KEY (LoanId, InstallmentNo),
    CONSTRAINT CK_LoanSchedule_Amounts CHECK (PrincipalDue >= 0 AND InterestDue >= 0 AND ClosingPrincipal >= 0),
    CONSTRAINT CK_LoanSchedule_Rolls   CHECK (ClosingPrincipal = OpeningPrincipal - PrincipalDue)
);
CREATE INDEX IX_LoanSchedule_DueDate ON dbo.LoanSchedule (DueDate) INCLUDE (InterestDue);
GO

CREATE TRIGGER dbo.trg_LoanSchedule_ReadOnly ON dbo.LoanSchedule
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50003, 'A repayment schedule cannot be changed once the loan is disbursed.', 1;
END;
GO

/* ---------- Provisioning rules ----------
   How much of a loan's outstanding principal to set aside as a likely loss, by how
   many days it is past due. The classes follow the usual regulatory pattern
   (Kenya's SASRA uses these five names). Rates are data, so a SACCO can match its regulator. */
CREATE TABLE dbo.LoanProvisionRule (
    Classification   varchar(12)  NOT NULL CONSTRAINT PK_LoanProvisionRule PRIMARY KEY,
    SortOrder        tinyint      NOT NULL CONSTRAINT UQ_LoanProvisionRule_Sort UNIQUE,
    MinDaysPastDue   int          NOT NULL,
    MaxDaysPastDue   int          NULL,      -- NULL = no upper limit
    ProvisionPct     decimal(5,2) NOT NULL CONSTRAINT CK_LoanProvisionRule_Pct CHECK (ProvisionPct BETWEEN 0 AND 100),
    CONSTRAINT CK_LoanProvisionRule_Range CHECK (MaxDaysPastDue IS NULL OR MaxDaysPastDue >= MinDaysPastDue)
);

INSERT dbo.LoanProvisionRule (Classification, SortOrder, MinDaysPastDue, MaxDaysPastDue, ProvisionPct) VALUES
    ('Performing',  1,   0,    0,   1.00),
    ('Watch',       2,   1,   30,   5.00),
    ('Substandard', 3,  31,  180,  25.00),
    ('Doubtful',    4, 181,  360,  50.00),
    ('Loss',        5, 361, NULL, 100.00);
GO

PRINT 'Loan schema created.';
