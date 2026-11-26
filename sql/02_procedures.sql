/* 02_procedures.sql
   The only way money moves: usp_PostJournal.
   usp_Deposit / usp_Withdraw / usp_Transfer / usp_ReverseEntry are thin wrappers that
   build the journal lines and hand them to usp_PostJournal, so every rule lives in one place. */
USE SaccoLedger;
GO

CREATE TYPE dbo.JournalLineInput AS TABLE (
    LineNum   int           NOT NULL PRIMARY KEY,
    GLCode    varchar(20)   NOT NULL,
    AccountNo varchar(20)   NULL,      -- member account, required when GLCode is a control account
    Debit     decimal(19,4) NOT NULL DEFAULT (0),
    Credit    decimal(19,4) NOT NULL DEFAULT (0)
);
GO

/* ============================================================================
   usp_PostJournal
   Returns 0 = posted, 1 = this Reference was already posted (safe retry, nothing done).
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_PostJournal
    @Reference         varchar(50),
    @TxnDate           date,
    @Narration         nvarchar(200),
    @Channel           varchar(10),
    @BranchCode        varchar(10),
    @Lines             dbo.JournalLineInput READONLY,
    @ReversalOfEntryId bigint = NULL,
    @JournalEntryId    bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;  -- any error dooms the transaction; no half-posted entries

    DECLARE @msg nvarchar(400), @BranchId int;

    SET @TxnDate   = ISNULL(@TxnDate, CAST(SYSDATETIME() AS date));
    SET @Narration = ISNULL(@Narration, CONCAT(N'Journal entry via ', @Channel));

    /* 1. Idempotency: a retried request (network timeout, double-tap on a phone)
          must not post twice. The UNIQUE constraint on Reference is the backstop. */
    SET @JournalEntryId = (SELECT JournalEntryId FROM dbo.JournalEntry WHERE Reference = @Reference);
    IF @JournalEntryId IS NOT NULL RETURN 1;

    /* 2. Validate the request before taking any locks. */
    IF @Reference IS NULL OR LTRIM(RTRIM(@Reference)) = ''
        THROW 50010, 'Reference is required.', 1;

    SET @BranchId = (SELECT BranchId FROM dbo.Branch WHERE BranchCode = @BranchCode);
    IF @BranchId IS NULL
        THROW 50011, 'Unknown branch code.', 1;

    IF (SELECT COUNT(*) FROM @Lines) < 2
        THROW 50012, 'A journal entry needs at least two lines.', 1;

    IF EXISTS (SELECT 1 FROM @Lines WHERE NOT ((Debit > 0 AND Credit = 0) OR (Credit > 0 AND Debit = 0)))
        THROW 50013, 'Each line must be either a positive debit or a positive credit.', 1;

    IF EXISTS (SELECT 1 FROM @Lines WHERE Debit <> ROUND(Debit, 2) OR Credit <> ROUND(Credit, 2))
        THROW 50014, 'Amounts may have at most 2 decimal places.', 1;

    IF (SELECT SUM(Debit) FROM @Lines) <> (SELECT SUM(Credit) FROM @Lines)
    BEGIN
        SELECT @msg = CONCAT('Entry does not balance: debits ', SUM(Debit), ' vs credits ', SUM(Credit), '.') FROM @Lines;
        THROW 50015, @msg, 1;
    END;

    DECLARE @Resolved TABLE (
        LineNum     int PRIMARY KEY,
        AccountNo   varchar(20) NULL,
        GLAccountId int NULL,
        IsControl   bit NULL,
        GLActive    bit NULL,
        AccountId   int NULL,
        AccountGL   int NULL,
        Debit       decimal(19,4) NOT NULL,
        Credit      decimal(19,4) NOT NULL
    );

    INSERT @Resolved (LineNum, AccountNo, GLAccountId, IsControl, GLActive, AccountId, AccountGL, Debit, Credit)
    SELECT l.LineNum, l.AccountNo, g.GLAccountId, g.IsControlAccount, g.IsActive,
           a.AccountId, a.ControlGLAccountId, l.Debit, l.Credit
    FROM   @Lines AS l
    LEFT JOIN dbo.GLAccount AS g ON g.GLCode    = l.GLCode
    LEFT JOIN dbo.Account   AS a ON a.AccountNo = l.AccountNo;

    IF EXISTS (SELECT 1 FROM @Resolved WHERE GLAccountId IS NULL OR GLActive = 0)
        THROW 50016, 'Unknown or inactive GL account.', 1;
    IF EXISTS (SELECT 1 FROM @Resolved WHERE AccountNo IS NOT NULL AND AccountId IS NULL)
        THROW 50017, 'Unknown member account number.', 1;
    IF EXISTS (SELECT 1 FROM @Resolved WHERE IsControl = 1 AND AccountId IS NULL)
        THROW 50018, 'Postings to a control account must name a member account.', 1;
    IF EXISTS (SELECT 1 FROM @Resolved WHERE AccountId IS NOT NULL AND AccountGL <> GLAccountId)
        THROW 50019, 'Member account posted to the wrong GL account.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* 3. Lock the member accounts one at a time in ascending AccountId order.
              Two transfers going in opposite directions (A->B and B->A) then queue
              instead of deadlocking. Status is re-checked under the lock. */
        DECLARE @LockId int = 0, @Status varchar(10), @AccountNo varchar(20);
        WHILE 1 = 1
        BEGIN
            SET @LockId = (SELECT MIN(AccountId) FROM @Resolved WHERE AccountId > @LockId);
            IF @LockId IS NULL BREAK;

            SELECT @Status = Status, @AccountNo = AccountNo
            FROM   dbo.Account WITH (UPDLOCK, HOLDLOCK)
            WHERE  AccountId = @LockId;

            IF @Status <> 'ACTIVE'
            BEGIN
                SET @msg = CONCAT('Account ', @AccountNo, ' is ', @Status, '.');
                THROW 50020, @msg, 1;
            END;
        END;

        /* 4. Write the entry. */
        INSERT dbo.JournalEntry (Reference, TxnDate, Narration, Channel, BranchId, ReversalOfEntryId)
        VALUES (@Reference, @TxnDate, @Narration, @Channel, @BranchId, @ReversalOfEntryId);

        SET @JournalEntryId = CAST(SCOPE_IDENTITY() AS bigint);

        INSERT dbo.JournalLine (JournalEntryId, GLAccountId, AccountId, Debit, Credit)
        SELECT @JournalEntryId, GLAccountId, AccountId, Debit, Credit
        FROM   @Resolved
        ORDER BY LineNum;

        /* 5. No member deposit account may be debited below its product minimum
              (for back-office SYSTEM entries such as reversals: below zero).
              Checked AFTER the insert, inside the transaction, while we still hold the
              account locks - so no other teller can withdraw the same money in between. */
        SET @AccountNo = NULL;
        SELECT TOP (1) @AccountNo = a.AccountNo
        FROM   (SELECT DISTINCT AccountId FROM @Resolved WHERE AccountId IS NOT NULL AND Debit > 0) AS d
        JOIN   dbo.Account   AS a ON a.AccountId   = d.AccountId
        JOIN   dbo.Product   AS p ON p.ProductId   = a.ProductId
        JOIN   dbo.GLAccount AS g ON g.GLAccountId = a.ControlGLAccountId
        JOIN   dbo.vw_AccountTotals AS t WITH (NOEXPAND) ON t.AccountId = a.AccountId
        WHERE  g.NormalBalance = 'C'
          AND  t.TotalCredit - t.TotalDebit < IIF(@Channel = 'SYSTEM', 0, p.MinBalance);

        IF @AccountNo IS NOT NULL
        BEGIN
            SET @msg = CONCAT('Insufficient funds in account ', @AccountNo, '.');
            THROW 50021, @msg, 1;
        END;

        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        -- Lost a race with an identical retry: report the original entry instead of failing.
        IF ERROR_NUMBER() IN (2601, 2627)
           AND EXISTS (SELECT 1 FROM dbo.JournalEntry WHERE Reference = @Reference)
        BEGIN
            SET @JournalEntryId = (SELECT JournalEntryId FROM dbo.JournalEntry WHERE Reference = @Reference);
            RETURN 1;
        END;

        THROW;
    END CATCH;
END;
GO

/* Which GL holds the cash for each channel. */
CREATE OR ALTER FUNCTION dbo.fn_ChannelCashGL (@Channel varchar(10))
RETURNS varchar(20)
AS
BEGIN
    RETURN CASE @Channel
               WHEN 'TELLER' THEN '1010'  -- Cash at hand
               WHEN 'MOBILE' THEN '1020'  -- Mobile money float
           END;
END;
GO

/* ============================================================================
   usp_OpenAccount
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_OpenAccount
    @MemberNo    varchar(20),
    @ProductCode varchar(10),
    @OpenedOn    date = NULL,
    @AccountNo   varchar(20) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @MemberId int, @ProductId int, @ControlGL int;

    SET @MemberId = (SELECT MemberId FROM dbo.Member WHERE MemberNo = @MemberNo AND Status = 'ACTIVE');
    IF @MemberId IS NULL THROW 50050, 'Unknown or inactive member.', 1;

    SELECT @ProductId = ProductId, @ControlGL = ControlGLAccountId
    FROM   dbo.Product WHERE ProductCode = @ProductCode;
    IF @ProductId IS NULL THROW 50051, 'Unknown product.', 1;

    SET @AccountNo = CONCAT(@ProductCode, '-', @MemberNo);   -- e.g. SAV-M00042

    INSERT dbo.Account (AccountNo, MemberId, ProductId, ControlGLAccountId, OpenedOn)
    VALUES (@AccountNo, @MemberId, @ProductId, @ControlGL, ISNULL(@OpenedOn, CAST(SYSDATETIME() AS date)));
END;
GO

/* ============================================================================
   usp_Deposit:   Dr Cash (teller) or Mobile float   /   Cr Member account
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_Deposit
    @AccountNo      varchar(20),
    @Amount         decimal(19,4),
    @Reference      varchar(50),
    @Channel        varchar(10)   = 'TELLER',
    @TxnDate        date          = NULL,
    @Narration      nvarchar(200) = NULL,
    @JournalEntryId bigint        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ControlGL varchar(20), @BranchCode varchar(10), @CashGL varchar(20), @rc int;

    IF @Amount IS NULL OR @Amount <= 0 THROW 50030, 'Amount must be greater than zero.', 1;

    SET @CashGL = dbo.fn_ChannelCashGL(@Channel);
    IF @CashGL IS NULL THROW 50031, 'Deposits must come through TELLER or MOBILE.', 1;
    SET @Narration = ISNULL(@Narration, CONCAT(N'Deposit via ', @Channel));

    SELECT @ControlGL = g.GLCode, @BranchCode = b.BranchCode
    FROM   dbo.Account   AS a
    JOIN   dbo.GLAccount AS g ON g.GLAccountId = a.ControlGLAccountId
    JOIN   dbo.Member    AS m ON m.MemberId    = a.MemberId
    JOIN   dbo.Branch    AS b ON b.BranchId    = m.BranchId
    WHERE  a.AccountNo = @AccountNo;
    IF @ControlGL IS NULL THROW 50032, 'Unknown account number.', 1;

    DECLARE @Lines dbo.JournalLineInput;
    INSERT @Lines (LineNum, GLCode, AccountNo, Debit, Credit)
    VALUES (1, @CashGL,    NULL,       @Amount, 0),
           (2, @ControlGL, @AccountNo, 0,       @Amount);

    EXEC @rc = dbo.usp_PostJournal
         @Reference      = @Reference,
         @TxnDate        = @TxnDate,
         @Narration      = @Narration,
         @Channel        = @Channel,
         @BranchCode     = @BranchCode,
         @Lines          = @Lines,
         @JournalEntryId = @JournalEntryId OUTPUT;
    RETURN @rc;
END;
GO

/* ============================================================================
   usp_Withdraw:  Dr Member account (amount + fee)  /  Cr Cash or Mobile float (amount)
                                                    /  Cr Fee income (fee)
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_Withdraw
    @AccountNo      varchar(20),
    @Amount         decimal(19,4),
    @Reference      varchar(50),
    @Channel        varchar(10)   = 'TELLER',
    @Fee            decimal(19,4) = 0,
    @TxnDate        date          = NULL,
    @Narration      nvarchar(200) = NULL,
    @JournalEntryId bigint        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ControlGL varchar(20), @BranchCode varchar(10), @CashGL varchar(20),
            @IsWithdrawable bit, @rc int;

    IF @Amount IS NULL OR @Amount <= 0 THROW 50030, 'Amount must be greater than zero.', 1;
    IF @Fee IS NULL OR @Fee < 0        THROW 50033, 'Fee cannot be negative.', 1;

    SET @CashGL = dbo.fn_ChannelCashGL(@Channel);
    IF @CashGL IS NULL THROW 50031, 'Withdrawals must go through TELLER or MOBILE.', 1;
    SET @Narration = ISNULL(@Narration, CONCAT(N'Withdrawal via ', @Channel));

    SELECT @ControlGL = g.GLCode, @BranchCode = b.BranchCode, @IsWithdrawable = p.IsWithdrawable
    FROM   dbo.Account   AS a
    JOIN   dbo.Product   AS p ON p.ProductId   = a.ProductId
    JOIN   dbo.GLAccount AS g ON g.GLAccountId = a.ControlGLAccountId
    JOIN   dbo.Member    AS m ON m.MemberId    = a.MemberId
    JOIN   dbo.Branch    AS b ON b.BranchId    = m.BranchId
    WHERE  a.AccountNo = @AccountNo;
    IF @ControlGL IS NULL   THROW 50032, 'Unknown account number.', 1;
    IF @IsWithdrawable = 0  THROW 50034, 'This product does not allow withdrawals.', 1;

    DECLARE @Lines dbo.JournalLineInput;
    INSERT @Lines (LineNum, GLCode, AccountNo, Debit, Credit)
    VALUES (1, @ControlGL, @AccountNo, @Amount + @Fee, 0),
           (2, @CashGL,    NULL,       0,              @Amount);
    IF @Fee > 0
        INSERT @Lines (LineNum, GLCode, AccountNo, Debit, Credit)
        VALUES (3, '4010', NULL, 0, @Fee);   -- Fee income

    EXEC @rc = dbo.usp_PostJournal
         @Reference      = @Reference,
         @TxnDate        = @TxnDate,
         @Narration      = @Narration,
         @Channel        = @Channel,
         @BranchCode     = @BranchCode,
         @Lines          = @Lines,
         @JournalEntryId = @JournalEntryId OUTPUT;
    RETURN @rc;
END;
GO

/* ============================================================================
   usp_Transfer:  Dr From member account  /  Cr To member account
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_Transfer
    @FromAccountNo  varchar(20),
    @ToAccountNo    varchar(20),
    @Amount         decimal(19,4),
    @Reference      varchar(50),
    @Channel        varchar(10)   = 'MOBILE',
    @TxnDate        date          = NULL,
    @Narration      nvarchar(200) = NULL,
    @JournalEntryId bigint        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @FromGL varchar(20), @ToGL varchar(20), @BranchCode varchar(10),
            @IsWithdrawable bit, @rc int;

    IF @Amount IS NULL OR @Amount <= 0   THROW 50030, 'Amount must be greater than zero.', 1;
    IF @FromAccountNo = @ToAccountNo     THROW 50035, 'Cannot transfer to the same account.', 1;
    SET @Narration = ISNULL(@Narration, CONCAT(N'Transfer ', @FromAccountNo, N' to ', @ToAccountNo));

    SELECT @FromGL = g.GLCode, @BranchCode = b.BranchCode, @IsWithdrawable = p.IsWithdrawable
    FROM   dbo.Account   AS a
    JOIN   dbo.Product   AS p ON p.ProductId   = a.ProductId
    JOIN   dbo.GLAccount AS g ON g.GLAccountId = a.ControlGLAccountId
    JOIN   dbo.Member    AS m ON m.MemberId    = a.MemberId
    JOIN   dbo.Branch    AS b ON b.BranchId    = m.BranchId
    WHERE  a.AccountNo = @FromAccountNo;

    SELECT @ToGL = g.GLCode
    FROM   dbo.Account   AS a
    JOIN   dbo.GLAccount AS g ON g.GLAccountId = a.ControlGLAccountId
    WHERE  a.AccountNo = @ToAccountNo;

    IF @FromGL IS NULL OR @ToGL IS NULL THROW 50032, 'Unknown account number.', 1;
    IF @IsWithdrawable = 0              THROW 50034, 'This product does not allow withdrawals.', 1;

    DECLARE @Lines dbo.JournalLineInput;
    INSERT @Lines (LineNum, GLCode, AccountNo, Debit, Credit)
    VALUES (1, @FromGL, @FromAccountNo, @Amount, 0),
           (2, @ToGL,   @ToAccountNo,   0,       @Amount);

    EXEC @rc = dbo.usp_PostJournal
         @Reference      = @Reference,
         @TxnDate        = @TxnDate,
         @Narration      = @Narration,
         @Channel        = @Channel,
         @BranchCode     = @BranchCode,
         @Lines          = @Lines,
         @JournalEntryId = @JournalEntryId OUTPUT;
    RETURN @rc;
END;
GO

/* ============================================================================
   usp_ReverseEntry: posts the mirror image of an entry (every debit becomes a
   credit and vice versa). The original stays untouched - the audit trail shows
   both the mistake and the correction.
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_ReverseEntry
    @JournalEntryId  bigint,
    @Reason          nvarchar(150),
    @Reference       varchar(50) = NULL,
    @TxnDate         date        = NULL,
    @ReversalEntryId bigint      = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OrigRef varchar(50), @BranchCode varchar(10), @OrigReversalOf bigint,
            @Narration nvarchar(200), @rc int;

    SELECT @OrigRef = je.Reference, @BranchCode = b.BranchCode, @OrigReversalOf = je.ReversalOfEntryId
    FROM   dbo.JournalEntry AS je
    JOIN   dbo.Branch       AS b ON b.BranchId = je.BranchId
    WHERE  je.JournalEntryId = @JournalEntryId;

    IF @OrigRef IS NULL                THROW 50040, 'Journal entry not found.', 1;
    IF @OrigReversalOf IS NOT NULL     THROW 50041, 'This entry is itself a reversal. Post a new entry instead.', 1;
    IF EXISTS (SELECT 1 FROM dbo.JournalEntry WHERE ReversalOfEntryId = @JournalEntryId)
                                       THROW 50042, 'This entry has already been reversed.', 1;
    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason)) = ''
                                       THROW 50043, 'A reason is required for a reversal.', 1;

    SET @Reference = ISNULL(@Reference, LEFT(CONCAT('REV-', @OrigRef), 50));
    SET @Narration = LEFT(CONCAT(N'Reversal of ', @OrigRef, N': ', @Reason), 200);

    DECLARE @Lines dbo.JournalLineInput;
    INSERT @Lines (LineNum, GLCode, AccountNo, Debit, Credit)
    SELECT ROW_NUMBER() OVER (ORDER BY jl.JournalLineId), g.GLCode, a.AccountNo,
           jl.Credit, jl.Debit                     -- swapped
    FROM   dbo.JournalLine AS jl
    JOIN   dbo.GLAccount   AS g ON g.GLAccountId = jl.GLAccountId
    LEFT JOIN dbo.Account  AS a ON a.AccountId   = jl.AccountId
    WHERE  jl.JournalEntryId = @JournalEntryId;

    EXEC @rc = dbo.usp_PostJournal
         @Reference         = @Reference,
         @TxnDate           = @TxnDate,
         @Narration         = @Narration,
         @Channel           = 'SYSTEM',
         @BranchCode        = @BranchCode,
         @Lines             = @Lines,
         @ReversalOfEntryId = @JournalEntryId,
         @JournalEntryId    = @ReversalEntryId OUTPUT;
    RETURN @rc;
END;
GO

PRINT 'Procedures created.';
