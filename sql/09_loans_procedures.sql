/* 09_loans_procedures.sql
   The loan life cycle. Every shilling still moves through usp_PostJournal.

     APPLIED --approve--> APPROVED --disburse--> ACTIVE --repaid--> CLOSED
        |                     |
        +------reject---------+--> REJECTED                                         */
USE SaccoLedger;
GO

/* ============================================================================
   fn_AmortizationSchedule
   Builds a repayment schedule with a recursive CTE.

   REDUCING: equal monthly payments (an annuity). Interest each month is charged on
             the principal still owed, so the interest part shrinks and the principal
             part grows.
   FLAT:     interest is charged on the original principal every month. Cheaper to
             explain, much more expensive for the borrower.

   Amounts are rounded to cents every month and the last installment takes whatever
   principal is left, so the principal column always adds up to the loan amount. */
CREATE OR ALTER FUNCTION dbo.fn_AmortizationSchedule
(
    @Principal     decimal(19,2),
    @AnnualRatePct decimal(9,4),
    @TermMonths    smallint,
    @Method        varchar(10),
    @FirstDueDate  date
)
RETURNS TABLE
AS
RETURN
WITH p AS (
    SELECT  CAST(@AnnualRatePct / 1200 AS decimal(19,12)) AS MonthlyRate,
            CAST(ROUND(@Principal / @TermMonths, 2) AS decimal(19,2)) AS FlatPrincipal,
            CAST(ROUND(@Principal * @AnnualRatePct / 1200, 2) AS decimal(19,2)) AS FlatInterest,
            CAST(CASE WHEN @AnnualRatePct = 0 THEN ROUND(@Principal / @TermMonths, 2)
                      ELSE ROUND(@Principal * (@AnnualRatePct / 1200)
                                 / (1 - POWER(1 + CAST(@AnnualRatePct AS float) / 1200, -@TermMonths)), 2)
                 END AS decimal(19,2)) AS Payment
),
s AS (
    SELECT  CAST(1 AS smallint) AS InstallmentNo,
            @Principal AS OpeningPrincipal
    UNION ALL
    SELECT  CAST(s.InstallmentNo + 1 AS smallint),
            CAST(s.OpeningPrincipal
                 - CASE @Method WHEN 'FLAT' THEN p.FlatPrincipal
                                ELSE p.Payment - ROUND(s.OpeningPrincipal * p.MonthlyRate, 2) END
                 AS decimal(19,2))
    FROM    s CROSS JOIN p
    WHERE   s.InstallmentNo < @TermMonths
)
SELECT  s.InstallmentNo,
        -- Always count from the first due date. Adding one month to the previous date
        -- would drift: 31 Jan -> 28 Feb -> 28 Mar.
        DATEADD(month, s.InstallmentNo - 1, @FirstDueDate) AS DueDate,
        s.OpeningPrincipal,
        pr.PrincipalDue,
        i.InterestDue,
        CAST(pr.PrincipalDue + i.InterestDue AS decimal(19,2)) AS TotalDue,
        CAST(s.OpeningPrincipal - pr.PrincipalDue AS decimal(19,2)) AS ClosingPrincipal
FROM    s
CROSS JOIN p
CROSS APPLY (SELECT CAST(CASE @Method WHEN 'FLAT' THEN p.FlatInterest
                                      ELSE ROUND(s.OpeningPrincipal * p.MonthlyRate, 2) END
                         AS decimal(19,2)) AS InterestDue) AS i
CROSS APPLY (SELECT CAST(CASE WHEN s.InstallmentNo = @TermMonths THEN s.OpeningPrincipal
                              WHEN @Method = 'FLAT'              THEN p.FlatPrincipal
                              ELSE p.Payment - i.InterestDue END
                         AS decimal(19,2)) AS PrincipalDue) AS pr;
GO

/* ============================================================================
   Balances, read from the ledger
   ============================================================================ */
CREATE OR ALTER VIEW dbo.vw_LoanBalance
AS
SELECT  l.LoanId,
        l.LoanNo,
        l.MemberId,
        l.Status,
        l.Principal,
        CAST(ISNULL(pt.TotalDebit - pt.TotalCredit, 0) AS decimal(19,2)) AS PrincipalOutstanding,
        CAST(ISNULL(it.TotalDebit - it.TotalCredit, 0) AS decimal(19,2)) AS InterestOutstanding
FROM    dbo.Loan AS l
LEFT JOIN dbo.vw_AccountTotals AS pt WITH (NOEXPAND) ON pt.AccountId = l.PrincipalAccountId
LEFT JOIN dbo.vw_AccountTotals AS it WITH (NOEXPAND) ON it.AccountId = l.InterestAccountId;
GO

/* How much of each member's savings is tied up guaranteeing other people's loans.
   Before disbursement the full pledge counts. After disbursement the pledge shrinks
   in step with the principal still owed, so guarantors get their money back as the
   borrower repays. */
CREATE OR ALTER VIEW dbo.vw_GuarantorExposure
AS
SELECT  g.GuarantorMemberId,
        CAST(SUM(CASE WHEN l.Status IN ('APPLIED', 'APPROVED') THEN g.AmountGuaranteed
                      ELSE CEILING(g.AmountGuaranteed * b.PrincipalOutstanding / l.Principal * 100) / 100
                 END) AS decimal(19,2)) AS Exposure
FROM    dbo.LoanGuarantor AS g
JOIN    dbo.Loan          AS l ON l.LoanId = g.LoanId
JOIN    dbo.vw_LoanBalance AS b ON b.LoanId = g.LoanId
WHERE   l.Status IN ('APPLIED', 'APPROVED', 'ACTIVE')
GROUP BY g.GuarantorMemberId;
GO

/* Replaces the part 1 stub. Pledged savings can't be withdrawn or transferred. */
CREATE OR ALTER FUNCTION dbo.fn_LockedAmount (@AccountId int)
RETURNS decimal(19,4)
AS
BEGIN
    RETURN ISNULL((SELECT e.Exposure
                   FROM   dbo.Account AS a
                   JOIN   dbo.Product AS p ON p.ProductId = a.ProductId AND p.ProductType = 'SAVINGS'
                   JOIN   dbo.vw_GuarantorExposure AS e ON e.GuarantorMemberId = a.MemberId
                   WHERE  a.AccountId = @AccountId), 0);
END;
GO

/* ============================================================================
   fn_LoanArrears: where every loan stands on a given date.

   Arrears come from comparing two running totals rather than marking installments
   as paid. Everything the schedule says should have been paid before @AsOfDate, minus
   everything the member has actually paid by then. The oldest installment that
   the payments don't reach gives the days past due. Payments are applied to the
   oldest installment first, so a member can't hide an old missed payment by paying
   this month's.
   ============================================================================ */
CREATE OR ALTER FUNCTION dbo.fn_LoanArrears (@AsOfDate date)
RETURNS TABLE
AS
RETURN
WITH ledger AS (
    SELECT  l.LoanId,
            SUM(IIF(jl.AccountId = l.PrincipalAccountId, jl.Debit - jl.Credit, 0)) AS PrincipalOutstanding,
            SUM(IIF(jl.AccountId = l.InterestAccountId,  jl.Debit - jl.Credit, 0)) AS InterestOutstanding,
            -- Credits are repayments. A reversed repayment comes back as a debit on a reversal entry.
            SUM(jl.Credit) - SUM(IIF(je.ReversalOfEntryId IS NOT NULL, jl.Debit, 0)) AS PaidToDate
    FROM    dbo.Loan         AS l
    JOIN    dbo.JournalLine  AS jl ON jl.AccountId IN (l.PrincipalAccountId, l.InterestAccountId)
    JOIN    dbo.JournalEntry AS je ON je.JournalEntryId = jl.JournalEntryId
    WHERE   l.DisbursedOn <= @AsOfDate
      AND   je.TxnDate    <= @AsOfDate
    GROUP BY l.LoanId
),
due AS (
    SELECT  s.LoanId,
            s.DueDate,
            SUM(s.TotalDue) OVER (PARTITION BY s.LoanId ORDER BY s.InstallmentNo
                                  ROWS UNBOUNDED PRECEDING) AS CumulativeDue
    FROM    dbo.LoanSchedule AS s
    WHERE   s.DueDate < @AsOfDate     -- an installment due today isn't late until tomorrow
)
SELECT  l.LoanId,
        l.LoanNo,
        m.MemberNo,
        lp.LoanProductCode,
        l.Principal,
        CAST(x.PrincipalOutstanding AS decimal(19,2)) AS PrincipalOutstanding,
        CAST(x.InterestOutstanding  AS decimal(19,2)) AS InterestOutstanding,
        CAST(ISNULL(d.DueToDate, 0) AS decimal(19,2)) AS DueToDate,
        CAST(x.PaidToDate AS decimal(19,2))           AS PaidToDate,
        CAST(IIF(ISNULL(d.DueToDate, 0) > x.PaidToDate, d.DueToDate - x.PaidToDate, 0) AS decimal(19,2)) AS ArrearsAmount,
        dpd.DaysPastDue,
        r.Classification,
        r.ProvisionPct,
        CAST(ROUND(x.PrincipalOutstanding * r.ProvisionPct / 100, 2) AS decimal(19,2)) AS ProvisionAmount
FROM    ledger AS x
JOIN    dbo.Loan        AS l  ON l.LoanId         = x.LoanId
JOIN    dbo.Member      AS m  ON m.MemberId       = l.MemberId
JOIN    dbo.LoanProduct AS lp ON lp.LoanProductId = l.LoanProductId
OUTER APPLY (SELECT MAX(CumulativeDue) AS DueToDate FROM due WHERE due.LoanId = x.LoanId) AS d
OUTER APPLY (SELECT MIN(DueDate) AS OldestUnpaid FROM due
             WHERE due.LoanId = x.LoanId AND due.CumulativeDue > x.PaidToDate) AS u
CROSS APPLY (SELECT ISNULL(DATEDIFF(day, u.OldestUnpaid, @AsOfDate), 0) AS DaysPastDue) AS dpd
JOIN    dbo.LoanProvisionRule AS r
        ON dpd.DaysPastDue BETWEEN r.MinDaysPastDue AND ISNULL(r.MaxDaysPastDue, 2147483647)
WHERE   x.PrincipalOutstanding + x.InterestOutstanding > 0;
GO

/* ============================================================================
   usp_ApplyForLoan
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_ApplyForLoan
    @MemberNo        varchar(20),
    @LoanProductCode varchar(10),
    @Principal       decimal(19,4),
    @TermMonths      smallint,
    @ApplicationDate date    = NULL,
    @AppliedBy       sysname = NULL,
    @LoanNo          varchar(20) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @MemberId int, @LoanProductId int, @Rate decimal(9,4), @Method varchar(10),
            @MaxTerm smallint, @Multiple decimal(5,2), @FeePct decimal(9,4),
            @SavingsAccountId int, @FreeSavings decimal(19,2), @msg nvarchar(400);

    SET @ApplicationDate = ISNULL(@ApplicationDate, CAST(SYSDATETIME() AS date));
    SET @AppliedBy       = ISNULL(@AppliedBy, ORIGINAL_LOGIN());

    SET @MemberId = (SELECT MemberId FROM dbo.Member WHERE MemberNo = @MemberNo AND Status = 'ACTIVE');
    IF @MemberId IS NULL THROW 50050, 'Unknown or inactive member.', 1;

    SELECT @LoanProductId = LoanProductId, @Rate = AnnualRatePct, @Method = InterestMethod,
           @MaxTerm = MaxTermMonths, @Multiple = SavingsMultiple, @FeePct = ProcessingFeePct
    FROM   dbo.LoanProduct WHERE LoanProductCode = @LoanProductCode;
    IF @LoanProductId IS NULL THROW 50060, 'Unknown loan product.', 1;

    IF @TermMonths IS NULL OR @TermMonths < 1 OR @TermMonths > @MaxTerm
    BEGIN
        SET @msg = CONCAT('Term must be between 1 and ', @MaxTerm, ' months for this product.');
        THROW 50061, @msg, 1;
    END;
    IF @Principal IS NULL OR @Principal <= 0 OR @Principal <> ROUND(@Principal, 2)
        THROW 50062, 'Loan amount must be positive with at most 2 decimal places.', 1;

    /* Eligibility: savings that aren't already pledged for someone else, times the product multiple. */
    SELECT @SavingsAccountId = a.AccountId,
           @FreeSavings      = v.Balance - dbo.fn_LockedAmount(a.AccountId)
    FROM   dbo.Account AS a
    JOIN   dbo.Product AS p ON p.ProductId = a.ProductId AND p.ProductType = 'SAVINGS'
    JOIN   dbo.vw_AccountBalance AS v ON v.AccountId = a.AccountId
    WHERE  a.MemberId = @MemberId AND a.Status = 'ACTIVE';

    IF @SavingsAccountId IS NULL THROW 50063, 'The member needs an active savings account to borrow.', 1;

    IF @Principal > @FreeSavings * @Multiple
    BEGIN
        SET @msg = CONCAT('Loan limit is ', CAST(@FreeSavings * @Multiple AS decimal(19,2)),
                          ' (', @Multiple, ' x free savings of ', @FreeSavings, ').');
        THROW 50064, @msg, 1;
    END;

    SET @LoanNo = CONCAT('LN', RIGHT(CONCAT('000000', NEXT VALUE FOR dbo.LoanNoSeq), 6));

    BEGIN TRY
        INSERT dbo.Loan (LoanNo, MemberId, LoanProductId, Principal, AnnualRatePct, InterestMethod,
                         TermMonths, ProcessingFeePct, ApplicationDate, AppliedBy)
        VALUES (@LoanNo, @MemberId, @LoanProductId, @Principal, @Rate, @Method,
                @TermMonths, @FeePct, @ApplicationDate, @AppliedBy);
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() = 2601   -- UX_Loan_OneOpenPerProduct
            THROW 50065, 'The member already has an open loan of this product.', 1;
        THROW;
    END CATCH;
END;
GO

/* ============================================================================
   usp_AddGuarantor
   The guarantor's savings account is locked (UPDLOCK) while we check their free
   savings. usp_PostJournal takes the same lock for withdrawals, so a guarantor
   can't pledge money and withdraw it at the same moment.
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_AddGuarantor
    @LoanNo            varchar(20),
    @GuarantorMemberNo varchar(20),
    @Amount            decimal(19,4),
    @PledgedOn         date = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @LoanId int, @BorrowerId int, @Status varchar(10), @GuarantorId int,
            @SavingsAccountId int, @Free decimal(19,2), @msg nvarchar(400);

    IF @Amount IS NULL OR @Amount <= 0 OR @Amount <> ROUND(@Amount, 2)
        THROW 50062, 'Amount must be positive with at most 2 decimal places.', 1;
    SET @PledgedOn = ISNULL(@PledgedOn, CAST(SYSDATETIME() AS date));

    SET @GuarantorId = (SELECT MemberId FROM dbo.Member WHERE MemberNo = @GuarantorMemberNo AND Status = 'ACTIVE');
    IF @GuarantorId IS NULL THROW 50066, 'Unknown or inactive guarantor.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @LoanId = LoanId, @BorrowerId = MemberId, @Status = Status
        FROM   dbo.Loan WITH (UPDLOCK, HOLDLOCK)
        WHERE  LoanNo = @LoanNo;
        IF @LoanId IS NULL       THROW 50067, 'Unknown loan number.', 1;
        IF @Status <> 'APPLIED'  THROW 50068, 'Guarantors can only be added before the loan is approved.', 1;

        SELECT @SavingsAccountId = a.AccountId
        FROM   dbo.Account AS a WITH (UPDLOCK, HOLDLOCK)
        JOIN   dbo.Product AS p ON p.ProductId = a.ProductId AND p.ProductType = 'SAVINGS'
        WHERE  a.MemberId = @GuarantorId AND a.Status = 'ACTIVE';
        IF @SavingsAccountId IS NULL THROW 50069, 'The guarantor needs an active savings account.', 1;

        SELECT @Free = v.Balance - p.MinBalance - dbo.fn_LockedAmount(v.AccountId)
        FROM   dbo.vw_AccountBalance AS v
        JOIN   dbo.Account AS a ON a.AccountId = v.AccountId
        JOIN   dbo.Product AS p ON p.ProductId = a.ProductId
        WHERE  v.AccountId = @SavingsAccountId;

        IF @Free < @Amount
        BEGIN
            SET @msg = CONCAT('Guarantor ', @GuarantorMemberNo, ' has only ', @Free, ' in free savings.');
            THROW 50070, @msg, 1;
        END;

        INSERT dbo.LoanGuarantor (LoanId, BorrowerMemberId, GuarantorMemberId, AmountGuaranteed, PledgedOn)
        VALUES (@LoanId, @BorrowerId, @GuarantorId, @Amount, @PledgedOn);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* ============================================================================
   usp_ApproveLoan / usp_RejectLoan
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_ApproveLoan
    @LoanNo     varchar(20),
    @ApprovedBy sysname = NULL,
    @ApprovedOn date    = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @LoanId int, @Status varchar(10), @AppliedBy sysname, @Principal decimal(19,2),
            @Cover decimal(19,2), @msg nvarchar(400);

    SET @ApprovedBy = ISNULL(@ApprovedBy, ORIGINAL_LOGIN());
    SET @ApprovedOn = ISNULL(@ApprovedOn, CAST(SYSDATETIME() AS date));

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @LoanId = LoanId, @Status = Status, @AppliedBy = AppliedBy, @Principal = Principal
        FROM   dbo.Loan WITH (UPDLOCK, HOLDLOCK)
        WHERE  LoanNo = @LoanNo;

        IF @LoanId IS NULL          THROW 50067, 'Unknown loan number.', 1;
        IF @Status <> 'APPLIED'     THROW 50071, 'Only loans in APPLIED status can be approved.', 1;
        IF @ApprovedBy = @AppliedBy THROW 50072, 'The person who captured the application cannot approve it.', 1;

        SET @Cover = ISNULL((SELECT SUM(AmountGuaranteed) FROM dbo.LoanGuarantor WHERE LoanId = @LoanId), 0);
        IF @Cover < @Principal
        BEGIN
            SET @msg = CONCAT('Guarantees of ', @Cover, ' do not cover the loan of ', @Principal, '.');
            THROW 50073, @msg, 1;
        END;

        UPDATE dbo.Loan
        SET    Status = 'APPROVED', ApprovedBy = @ApprovedBy, ApprovedOn = @ApprovedOn
        WHERE  LoanId = @LoanId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RejectLoan
    @LoanNo varchar(20),
    @Reason nvarchar(200)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason)) = '' THROW 50074, 'A reason is required.', 1;

    UPDATE dbo.Loan
    SET    Status = 'REJECTED', RejectionReason = @Reason
    WHERE  LoanNo = @LoanNo AND Status IN ('APPLIED', 'APPROVED');

    IF @@ROWCOUNT = 0 THROW 50075, 'Only loans that have not been disbursed can be rejected.', 1;
END;
GO

/* ============================================================================
   usp_DisburseLoan
   One transaction does four things. It opens the loan's two ledger accounts,
   posts the disbursement, writes the schedule and marks the loan ACTIVE.
   If any part fails, none of it happened.

     Dr 1100 Loans to Members          principal
         Cr 2010 Member Savings        principal - fee   (money lands in the member's savings)
         Cr 4010 Fee Income            processing fee
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_DisburseLoan
    @LoanNo         varchar(20),
    @DisbursedOn    date   = NULL,
    @JournalEntryId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @LoanId int, @MemberId int, @Status varchar(10), @Principal decimal(19,2),
            @Rate decimal(9,4), @Method varchar(10), @Term smallint, @FeePct decimal(9,4),
            @Fee decimal(19,2), @PrincipalProductId int, @InterestProductId int,
            @PrincipalAccountId int, @InterestAccountId int,
            @PrincipalAccountNo varchar(20), @InterestAccountNo varchar(20),
            @SavingsAccountNo varchar(20), @BranchCode varchar(10), @PrincipalGL varchar(20),
            @FirstDueDate date, @rc int;

    SET @DisbursedOn = ISNULL(@DisbursedOn, CAST(SYSDATETIME() AS date));

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @LoanId = l.LoanId, @MemberId = l.MemberId, @Status = l.Status, @Principal = l.Principal,
               @Rate = l.AnnualRatePct, @Method = l.InterestMethod, @Term = l.TermMonths,
               @FeePct = l.ProcessingFeePct, @PrincipalProductId = lp.PrincipalProductId,
               @InterestProductId = lp.InterestProductId, @JournalEntryId = l.DisbursementEntryId
        FROM   dbo.Loan AS l WITH (UPDLOCK, HOLDLOCK)
        JOIN   dbo.LoanProduct AS lp ON lp.LoanProductId = l.LoanProductId
        WHERE  l.LoanNo = @LoanNo;

        IF @LoanId IS NULL THROW 50067, 'Unknown loan number.', 1;

        -- Retried request for a loan that already went out: report it, change nothing.
        IF @Status IN ('ACTIVE', 'CLOSED')
        BEGIN
            COMMIT TRANSACTION;
            RETURN 1;
        END;
        IF @Status <> 'APPROVED' THROW 50076, 'Only approved loans can be disbursed.', 1;

        SELECT @SavingsAccountNo = a.AccountNo, @BranchCode = b.BranchCode
        FROM   dbo.Account AS a
        JOIN   dbo.Product AS p ON p.ProductId = a.ProductId AND p.ProductType = 'SAVINGS'
        JOIN   dbo.Member  AS m ON m.MemberId  = a.MemberId
        JOIN   dbo.Branch  AS b ON b.BranchId  = m.BranchId
        WHERE  a.MemberId = @MemberId;

        /* Open the loan's principal and interest accounts. */
        SET @PrincipalAccountNo = CONCAT(@LoanNo, '-P');
        SET @InterestAccountNo  = CONCAT(@LoanNo, '-I');

        INSERT dbo.Account (AccountNo, MemberId, ProductId, ControlGLAccountId, OpenedOn, AccountSeq)
        SELECT v.AccountNo, @MemberId, p.ProductId, p.ControlGLAccountId, @DisbursedOn,
               1 + ISNULL((SELECT MAX(AccountSeq) FROM dbo.Account
                           WHERE MemberId = @MemberId AND ProductId = p.ProductId), 0)
        FROM   (VALUES (@PrincipalAccountNo, @PrincipalProductId),
                       (@InterestAccountNo,  @InterestProductId)) AS v (AccountNo, ProductId)
        JOIN   dbo.Product AS p ON p.ProductId = v.ProductId;

        SELECT @PrincipalAccountId = a.AccountId, @PrincipalGL = g.GLCode
        FROM   dbo.Account AS a JOIN dbo.GLAccount AS g ON g.GLAccountId = a.ControlGLAccountId
        WHERE  a.AccountNo = @PrincipalAccountNo;
        SET @InterestAccountId = (SELECT AccountId FROM dbo.Account WHERE AccountNo = @InterestAccountNo);

        /* Post the money. */
        SET @Fee = ROUND(@Principal * @FeePct / 100, 2);

        DECLARE @Lines dbo.JournalLineInput;
        INSERT @Lines (LineNum, GLCode, AccountNo, Debit, Credit)
        VALUES (1, @PrincipalGL, @PrincipalAccountNo, @Principal, 0),
               (2, '2010',       @SavingsAccountNo,   0,          @Principal - @Fee);
        IF @Fee > 0
            INSERT @Lines (LineNum, GLCode, AccountNo, Debit, Credit) VALUES (3, '4010', NULL, 0, @Fee);

        DECLARE @Ref varchar(50) = CONCAT('DSB-', @LoanNo),
                @Narration nvarchar(200) = CONCAT(N'Loan disbursement ', @LoanNo);
        EXEC @rc = dbo.usp_PostJournal
             @Reference = @Ref, @TxnDate = @DisbursedOn, @Narration = @Narration,
             @Channel = 'SYSTEM', @BranchCode = @BranchCode, @Lines = @Lines,
             @JournalEntryId = @JournalEntryId OUTPUT;

        /* Write the schedule. First payment is due one month after disbursement. */
        SET @FirstDueDate = DATEADD(month, 1, @DisbursedOn);

        INSERT dbo.LoanSchedule (LoanId, InstallmentNo, DueDate, OpeningPrincipal, PrincipalDue, InterestDue, ClosingPrincipal)
        SELECT @LoanId, InstallmentNo, DueDate, OpeningPrincipal, PrincipalDue, InterestDue, ClosingPrincipal
        FROM   dbo.fn_AmortizationSchedule(@Principal, @Rate, @Term, @Method, @FirstDueDate);

        UPDATE dbo.Loan
        SET    Status = 'ACTIVE', DisbursedOn = @DisbursedOn, FirstDueDate = @FirstDueDate,
               PrincipalAccountId = @PrincipalAccountId, InterestAccountId = @InterestAccountId,
               DisbursementEntryId = @JournalEntryId
        WHERE  LoanId = @LoanId;

        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* ============================================================================
   usp_AccrueLoanInterest
   For every installment that has fallen due, move its interest onto the member's
   interest account and into income.

     Dr 1110 Interest Receivable    InterestDue
         Cr 4020 Interest Income    InterestDue

   Each accrual has the reference ACR-<loan>-<installment>, so running the job twice
   (or after a crash halfway through) can never charge interest twice.
   Loans with no principal left stop accruing.
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_AccrueLoanInterest
    @AsOfDate      date,
    @EntriesPosted int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LoanNo varchar(20), @AccountNo varchar(20), @InstallmentNo smallint, @DueDate date,
            @Interest decimal(19,2), @BranchCode varchar(10), @Ref varchar(50),
            @Narration nvarchar(200), @rc int;
    DECLARE @Lines dbo.JournalLineInput;

    SET @EntriesPosted = 0;

    DECLARE due CURSOR LOCAL FAST_FORWARD FOR
        SELECT l.LoanNo, ia.AccountNo, s.InstallmentNo, s.DueDate, s.InterestDue, b.BranchCode
        FROM   dbo.LoanSchedule AS s
        JOIN   dbo.Loan         AS l  ON l.LoanId     = s.LoanId AND l.Status = 'ACTIVE'
        JOIN   dbo.Account      AS ia ON ia.AccountId = l.InterestAccountId
        JOIN   dbo.Member       AS m  ON m.MemberId   = l.MemberId
        JOIN   dbo.Branch       AS b  ON b.BranchId   = m.BranchId
        JOIN   dbo.vw_AccountTotals AS pt WITH (NOEXPAND) ON pt.AccountId = l.PrincipalAccountId
        WHERE  s.DueDate <= @AsOfDate
          AND  s.InterestDue > 0
          AND  pt.TotalDebit - pt.TotalCredit > 0
          AND  NOT EXISTS (SELECT 1 FROM dbo.JournalEntry AS je
                           WHERE je.Reference = CONCAT('ACR-', l.LoanNo, '-', s.InstallmentNo))
        ORDER BY s.DueDate, l.LoanNo, s.InstallmentNo;

    OPEN due;
    FETCH NEXT FROM due INTO @LoanNo, @AccountNo, @InstallmentNo, @DueDate, @Interest, @BranchCode;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DELETE @Lines;
        INSERT @Lines (LineNum, GLCode, AccountNo, Debit, Credit)
        VALUES (1, '1110', @AccountNo, @Interest, 0),
               (2, '4020', NULL,       0,         @Interest);

        SET @Ref       = CONCAT('ACR-', @LoanNo, '-', @InstallmentNo);
        SET @Narration = CONCAT(N'Interest on ', @LoanNo, N' installment ', @InstallmentNo);

        EXEC @rc = dbo.usp_PostJournal
             @Reference = @Ref, @TxnDate = @DueDate, @Narration = @Narration,
             @Channel = 'SYSTEM', @BranchCode = @BranchCode, @Lines = @Lines;
        IF @rc = 0 SET @EntriesPosted += 1;

        FETCH NEXT FROM due INTO @LoanNo, @AccountNo, @InstallmentNo, @DueDate, @Interest, @BranchCode;
    END;
    CLOSE due;
    DEALLOCATE due;
END;
GO

/* ============================================================================
   usp_RepayLoan
   Splits a payment in a fixed order. Interest that has fallen due is paid first,
   then principal. Anything left over goes to the member's savings, because a loan
   account can't go below zero.

     Dr 1010/1020 Cash or Mobile float   amount
         Cr 1110 Interest Receivable     interest part
         Cr 1100 Loans to Members        principal part
         Cr 2010 Member Savings          overpayment, if any

   The loan row is locked first. Two payments for the same loan arriving together
   are handled one after the other, and the second one sees what the first paid.
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_RepayLoan
    @LoanNo         varchar(20),
    @Amount         decimal(19,4),
    @Reference      varchar(50),
    @Channel        varchar(10) = 'MOBILE',
    @TxnDate        date        = NULL,
    @JournalEntryId bigint      = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @LoanId int, @Status varchar(10), @MemberId int, @CashGL varchar(20),
            @PrincipalAccountNo varchar(20), @InterestAccountNo varchar(20), @SavingsAccountNo varchar(20),
            @PrincipalGL varchar(20), @BranchCode varchar(10),
            @PrincipalOut decimal(19,2), @InterestOut decimal(19,2),
            @ToInterest decimal(19,2), @ToPrincipal decimal(19,2), @ToSavings decimal(19,2),
            @Narration nvarchar(200), @rc int;

    IF @Amount IS NULL OR @Amount <= 0 THROW 50030, 'Amount must be greater than zero.', 1;
    SET @CashGL = dbo.fn_ChannelCashGL(@Channel);
    IF @CashGL IS NULL THROW 50031, 'Repayments must come through TELLER or MOBILE.', 1;
    SET @TxnDate = ISNULL(@TxnDate, CAST(SYSDATETIME() AS date));

    -- Retry of a payment we already have.
    SET @JournalEntryId = (SELECT JournalEntryId FROM dbo.JournalEntry WHERE Reference = @Reference);
    IF @JournalEntryId IS NOT NULL RETURN 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @LoanId = l.LoanId, @Status = l.Status, @MemberId = l.MemberId,
               @PrincipalAccountNo = pa.AccountNo, @InterestAccountNo = ia.AccountNo,
               @PrincipalGL = g.GLCode
        FROM   dbo.Loan AS l WITH (UPDLOCK, HOLDLOCK)
        LEFT JOIN dbo.Account   AS pa ON pa.AccountId  = l.PrincipalAccountId
        LEFT JOIN dbo.Account   AS ia ON ia.AccountId  = l.InterestAccountId
        LEFT JOIN dbo.GLAccount AS g  ON g.GLAccountId = pa.ControlGLAccountId
        WHERE  l.LoanNo = @LoanNo;

        IF @LoanId IS NULL      THROW 50067, 'Unknown loan number.', 1;
        IF @Status <> 'ACTIVE'  THROW 50077, 'Repayments can only be made on active loans.', 1;

        SELECT @PrincipalOut = PrincipalOutstanding, @InterestOut = InterestOutstanding
        FROM   dbo.vw_LoanBalance WHERE LoanId = @LoanId;

        SELECT @SavingsAccountNo = a.AccountNo, @BranchCode = b.BranchCode
        FROM   dbo.Account AS a
        JOIN   dbo.Product AS p ON p.ProductId = a.ProductId AND p.ProductType = 'SAVINGS'
        JOIN   dbo.Member  AS m ON m.MemberId  = a.MemberId
        JOIN   dbo.Branch  AS b ON b.BranchId  = m.BranchId
        WHERE  a.MemberId = @MemberId;

        /* Allocation: interest due, then principal, then savings. */
        SET @ToInterest  = IIF(@Amount < @InterestOut, @Amount, @InterestOut);
        SET @ToPrincipal = IIF(@Amount - @ToInterest < @PrincipalOut, @Amount - @ToInterest, @PrincipalOut);
        SET @ToSavings   = @Amount - @ToInterest - @ToPrincipal;

        DECLARE @Lines dbo.JournalLineInput;
        INSERT @Lines (LineNum, GLCode, AccountNo, Debit, Credit)
        VALUES (1, @CashGL, NULL, @Amount, 0);
        IF @ToInterest  > 0 INSERT @Lines VALUES (2, '1110',       @InterestAccountNo,  0, @ToInterest);
        IF @ToPrincipal > 0 INSERT @Lines VALUES (3, @PrincipalGL, @PrincipalAccountNo, 0, @ToPrincipal);
        IF @ToSavings   > 0 INSERT @Lines VALUES (4, '2010',       @SavingsAccountNo,   0, @ToSavings);

        SET @Narration = CONCAT(N'Loan repayment ', @LoanNo, N' via ', @Channel);
        EXEC @rc = dbo.usp_PostJournal
             @Reference = @Reference, @TxnDate = @TxnDate, @Narration = @Narration,
             @Channel = @Channel, @BranchCode = @BranchCode, @Lines = @Lines,
             @JournalEntryId = @JournalEntryId OUTPUT;

        /* Nothing left to pay: close the loan. Guarantors are released automatically
           because vw_GuarantorExposure only counts open loans. */
        IF @PrincipalOut - @ToPrincipal = 0 AND @InterestOut - @ToInterest = 0
            UPDATE dbo.Loan SET Status = 'CLOSED', ClosedOn = @TxnDate WHERE LoanId = @LoanId;

        COMMIT TRANSACTION;
        RETURN @rc;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* ============================================================================
   usp_PostLoanProvision
   Brings the provision for loan losses (GL 1190) up or down to what the ageing
   report says it should be on @AsOfDate. Only the difference is posted.

     More needed:  Dr 5030 Provision Expense   /  Cr 1190 Provision for Loan Losses
     Less needed:  Dr 1190                     /  Cr 5030
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_PostLoanProvision
    @AsOfDate       date,
    @JournalEntryId bigint = NULL OUTPUT,
    @Required       decimal(19,2) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Current decimal(19,2), @Diff decimal(19,2), @Ref varchar(50), @Narration nvarchar(200), @rc int;

    SET @Required = ISNULL((SELECT SUM(ProvisionAmount) FROM dbo.fn_LoanArrears(@AsOfDate)), 0);

    SET @Current = ISNULL((SELECT SUM(jl.Credit - jl.Debit)
                           FROM   dbo.JournalLine  AS jl
                           JOIN   dbo.JournalEntry AS je ON je.JournalEntryId = jl.JournalEntryId
                           JOIN   dbo.GLAccount    AS g  ON g.GLAccountId     = jl.GLAccountId
                           WHERE  g.GLCode = '1190' AND je.TxnDate <= @AsOfDate), 0);

    SET @Diff = @Required - @Current;
    IF @Diff = 0 RETURN 2;   -- nothing to post

    DECLARE @Lines dbo.JournalLineInput;
    IF @Diff > 0
        INSERT @Lines VALUES (1, '5030', NULL, @Diff, 0), (2, '1190', NULL, 0, @Diff);
    ELSE
        INSERT @Lines VALUES (1, '1190', NULL, -@Diff, 0), (2, '5030', NULL, 0, -@Diff);

    SET @Ref       = CONCAT('PROV-', CONVERT(char(8), @AsOfDate, 112));
    SET @Narration = CONCAT(N'Loan loss provision as at ', CONVERT(char(10), @AsOfDate, 23));

    EXEC @rc = dbo.usp_PostJournal
         @Reference = @Ref, @TxnDate = @AsOfDate, @Narration = @Narration,
         @Channel = 'SYSTEM', @BranchCode = 'HQ', @Lines = @Lines,
         @JournalEntryId = @JournalEntryId OUTPUT;
    RETURN @rc;
END;
GO

/* ============================================================================
   Permissions
   Front office captures applications, guarantors and repayments. Approval,
   disbursement and the month-end jobs belong to the back office.
   ============================================================================ */
GRANT EXECUTE ON OBJECT::dbo.usp_ApplyForLoan  TO ledger_app;
GRANT EXECUTE ON OBJECT::dbo.usp_AddGuarantor  TO ledger_app;
GRANT EXECUTE ON OBJECT::dbo.usp_RepayLoan     TO ledger_app;
GRANT SELECT  ON OBJECT::dbo.vw_LoanBalance    TO ledger_app;

GRANT EXECUTE ON OBJECT::dbo.usp_ApproveLoan         TO ledger_supervisor;
GRANT EXECUTE ON OBJECT::dbo.usp_RejectLoan          TO ledger_supervisor;
GRANT EXECUTE ON OBJECT::dbo.usp_DisburseLoan        TO ledger_supervisor;
GRANT EXECUTE ON OBJECT::dbo.usp_AccrueLoanInterest  TO ledger_supervisor;
GRANT EXECUTE ON OBJECT::dbo.usp_PostLoanProvision   TO ledger_supervisor;
GRANT SELECT  ON OBJECT::dbo.vw_LoanBalance          TO ledger_supervisor;
GRANT SELECT  ON OBJECT::dbo.fn_LoanArrears          TO ledger_supervisor;
GO

PRINT 'Loan procedures created.';
