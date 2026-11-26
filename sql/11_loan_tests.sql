/* 11_loan_tests.sql
   Checks the loan rules with a small loan we control, then checks invariants across
   the whole ledger, including all the generated loans. Fails the run if anything fails. */
USE SaccoLedger;
GO
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
CREATE TABLE #Results (TestNo int IDENTITY(1,1), TestName nvarchar(200), Passed bit, Detail nvarchar(400));

-- Four test members with known savings.
INSERT dbo.Member (MemberNo, FirstName, LastName, NationalId, BranchId, JoinedOn) VALUES
    ('LT001', N'Test', N'Borrower',   'TEST-L001', 1, '2026-01-01'),
    ('LT002', N'Test', N'GuarantorA', 'TEST-L002', 1, '2026-01-01'),
    ('LT003', N'Test', N'GuarantorB', 'TEST-L003', 1, '2026-01-01'),
    ('LT004', N'Test', N'GuarantorC', 'TEST-L004', 1, '2026-01-01');
EXEC dbo.usp_OpenAccount @MemberNo = 'LT001', @ProductCode = 'SAV', @OpenedOn = '2026-01-01';
EXEC dbo.usp_OpenAccount @MemberNo = 'LT002', @ProductCode = 'SAV', @OpenedOn = '2026-01-01';
EXEC dbo.usp_OpenAccount @MemberNo = 'LT003', @ProductCode = 'SAV', @OpenedOn = '2026-01-01';
EXEC dbo.usp_OpenAccount @MemberNo = 'LT004', @ProductCode = 'SAV', @OpenedOn = '2026-01-01';
EXEC dbo.usp_Deposit @AccountNo = 'SAV-LT001', @Amount = 20000, @Reference = 'LTEST-DEP-1', @TxnDate = '2026-01-02';
EXEC dbo.usp_Deposit @AccountNo = 'SAV-LT002', @Amount = 50000, @Reference = 'LTEST-DEP-2', @TxnDate = '2026-01-02';
EXEC dbo.usp_Deposit @AccountNo = 'SAV-LT003', @Amount = 3000,  @Reference = 'LTEST-DEP-3', @TxnDate = '2026-01-02';
EXEC dbo.usp_Deposit @AccountNo = 'SAV-LT004', @Amount = 15000, @Reference = 'LTEST-DEP-4', @TxnDate = '2026-01-02';
GO

DECLARE @err int, @rc int, @n int, @LoanNo varchar(20), @x varchar(20), @id bigint, @id2 bigint,
        @a decimal(19,2), @b decimal(19,2), @c decimal(19,2), @d date, @s varchar(20), @cls varchar(12);
DECLARE @L dbo.JournalLineInput;

/* ---------- Schedules ---------- */

SELECT @a = MIN(TotalDue), @b = SUM(PrincipalDue), @c = SUM(InterestDue)
FROM   dbo.fn_AmortizationSchedule(100000, 12, 12, 'REDUCING', '2026-01-31') WHERE InstallmentNo < 12;
SELECT @b = SUM(PrincipalDue), @c = SUM(InterestDue)
FROM   dbo.fn_AmortizationSchedule(100000, 12, 12, 'REDUCING', '2026-01-31');
INSERT #Results VALUES (N'Reducing balance: 100,000 at 12% over 12 months pays 8,884.88 a month',
    IIF(@a = 8884.88 AND @b = 100000 AND @c = 6618.53, 1, 0), CONCAT('payment=', @a, ' principal=', @b, ' interest=', @c));

SELECT @a = MIN(InterestDue), @b = MAX(InterestDue), @c = SUM(InterestDue)
FROM   dbo.fn_AmortizationSchedule(100000, 12, 12, 'FLAT', '2026-01-31');
INSERT #Results VALUES (N'Flat rate: same interest every month, 12,000 in total',
    IIF(@a = 1000 AND @b = 1000 AND @c = 12000, 1, 0), CONCAT('min=', @a, ' max=', @b, ' total=', @c));

SET @n = (SELECT COUNT(*) FROM dbo.fn_AmortizationSchedule(100000, 12, 12, 'REDUCING', '2026-01-31')
          WHERE (InstallmentNo = 2 AND DueDate = '2026-02-28') OR (InstallmentNo = 3 AND DueDate = '2026-03-31'));
INSERT #Results VALUES (N'Due dates do not drift after a short month (31 Jan, 28 Feb, 31 Mar)', IIF(@n = 2, 1, 0), CONCAT('matches=', @n));

SET @n = (SELECT COUNT(*) FROM (VALUES (1000.01, 7), (999999.99, 60), (5000, 1), (12345.67, 36)) AS v (P, T)
          CROSS APPLY (SELECT SUM(PrincipalDue) AS S FROM dbo.fn_AmortizationSchedule(v.P, 12, v.T, 'REDUCING', '2026-01-31')) AS x
          WHERE x.S <> v.P);
INSERT #Results VALUES (N'Principal column always adds up to the loan amount', IIF(@n = 0, 1, 0), CONCAT('mismatches=', @n));

/* ---------- Application rules ---------- */

SET @err = NULL;
BEGIN TRY EXEC dbo.usp_ApplyForLoan @MemberNo = 'LT001', @LoanProductCode = 'DEV', @Principal = 70000,
               @TermMonths = 12, @ApplicationDate = '2026-03-01', @AppliedBy = 'officer.a'; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'Cannot borrow more than 3 x savings', IIF(@err = 50064, 1, 0), CONCAT('err=', @err));

SET @err = NULL;
BEGIN TRY EXEC dbo.usp_ApplyForLoan @MemberNo = 'LT001', @LoanProductCode = 'EMG', @Principal = 5000,
               @TermMonths = 24, @ApplicationDate = '2026-03-01', @AppliedBy = 'officer.a'; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'Term longer than the product allows is refused', IIF(@err = 50061, 1, 0), CONCAT('err=', @err));

EXEC dbo.usp_ApplyForLoan @MemberNo = 'LT001', @LoanProductCode = 'DEV', @Principal = 40000, @TermMonths = 12,
     @ApplicationDate = '2026-03-01', @AppliedBy = 'officer.a', @LoanNo = @LoanNo OUTPUT;

SET @err = NULL;
BEGIN TRY EXEC dbo.usp_ApplyForLoan @MemberNo = 'LT001', @LoanProductCode = 'DEV', @Principal = 1000,
               @TermMonths = 6, @ApplicationDate = '2026-03-02', @AppliedBy = 'officer.a'; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'Only one open loan per member per product', IIF(@err = 50065, 1, 0), CONCAT('err=', @err));

/* ---------- Guarantors ---------- */

SET @err = NULL;
BEGIN TRY EXEC dbo.usp_AddGuarantor @LoanNo = @LoanNo, @GuarantorMemberNo = 'LT001', @Amount = 1000, @PledgedOn = '2026-03-01'; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'Borrower cannot guarantee their own loan', IIF(@err = 547, 1, 0), CONCAT('err=', @err));

SET @err = NULL;
BEGIN TRY EXEC dbo.usp_AddGuarantor @LoanNo = @LoanNo, @GuarantorMemberNo = 'LT003', @Amount = 10000, @PledgedOn = '2026-03-01'; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'Guarantor cannot pledge more than their free savings', IIF(@err = 50070, 1, 0), CONCAT('err=', @err));

EXEC dbo.usp_AddGuarantor @LoanNo = @LoanNo, @GuarantorMemberNo = 'LT002', @Amount = 30000, @PledgedOn = '2026-03-01';

SET @err = NULL;
BEGIN TRY EXEC dbo.usp_ApproveLoan @LoanNo = @LoanNo, @ApprovedBy = 'committee.b', @ApprovedOn = '2026-03-10'; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'Loan not fully guaranteed cannot be approved', IIF(@err = 50073, 1, 0), CONCAT('err=', @err));

SET @err = NULL;
BEGIN TRY EXEC dbo.usp_Withdraw @AccountNo = 'SAV-LT002', @Amount = 25000, @Reference = 'LTEST-WDL-1', @TxnDate = '2026-03-05'; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
SET @rc = NULL;
EXEC @rc = dbo.usp_Withdraw @AccountNo = 'SAV-LT002', @Amount = 19900, @Reference = 'LTEST-WDL-2', @TxnDate = '2026-03-05';
SELECT @a = Balance FROM dbo.vw_AccountBalance WHERE AccountNo = 'SAV-LT002';
INSERT #Results VALUES (N'Pledged savings cannot be withdrawn, the free part can',
    IIF(@err = 50021 AND @rc = 0 AND @a = 30100, 1, 0), CONCAT('err=', @err, ' rc=', @rc, ' balance=', @a));

EXEC dbo.usp_AddGuarantor @LoanNo = @LoanNo, @GuarantorMemberNo = 'LT004', @Amount = 10000, @PledgedOn = '2026-03-02';

SET @err = NULL;
BEGIN TRY EXEC dbo.usp_ApproveLoan @LoanNo = @LoanNo, @ApprovedBy = 'officer.a', @ApprovedOn = '2026-03-10'; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'Whoever captured the application cannot approve it', IIF(@err = 50072, 1, 0), CONCAT('err=', @err));

SET @err = NULL;
EXECUTE AS USER = 'test_teller';
BEGIN TRY EXEC dbo.usp_ApproveLoan @LoanNo = @LoanNo, @ApprovedBy = 'teller.c', @ApprovedOn = '2026-03-10'; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
INSERT #Results VALUES (N'App role cannot approve loans', IIF(@err = 229, 1, 0), CONCAT('err=', @err));

EXEC dbo.usp_ApproveLoan @LoanNo = @LoanNo, @ApprovedBy = 'committee.b', @ApprovedOn = '2026-03-10';

/* ---------- Disbursement ---------- */

EXEC dbo.usp_DisburseLoan @LoanNo = @LoanNo, @DisbursedOn = '2026-03-15', @JournalEntryId = @id OUTPUT;
SELECT @n = COUNT(*), @a = SUM(Debit), @b = SUM(Credit) FROM dbo.JournalLine WHERE JournalEntryId = @id;
SELECT @c = Balance FROM dbo.vw_AccountBalance WHERE AccountNo = 'SAV-LT001';
SELECT @d = FirstDueDate, @s = Status FROM dbo.Loan WHERE LoanNo = @LoanNo;
INSERT #Results VALUES (N'Disbursement posts 3 lines, savings get principal less the 1% fee',
    IIF(@n = 3 AND @a = 40000 AND @b = 40000 AND @c = 59600 AND @s = 'ACTIVE' AND @d = '2026-04-15', 1, 0),
    CONCAT('lines=', @n, ' savings=', @c, ' status=', @s, ' firstDue=', @d));

SELECT @n = COUNT(*), @a = SUM(PrincipalDue) FROM dbo.LoanSchedule AS s JOIN dbo.Loan AS l ON l.LoanId = s.LoanId WHERE l.LoanNo = @LoanNo;
INSERT #Results VALUES (N'Schedule written with 12 installments adding up to 40,000', IIF(@n = 12 AND @a = 40000, 1, 0),
    CONCAT('rows=', @n, ' principal=', @a));

EXEC @rc = dbo.usp_DisburseLoan @LoanNo = @LoanNo, @DisbursedOn = '2026-03-15', @JournalEntryId = @id2 OUTPUT;
SET @n = (SELECT COUNT(*) FROM dbo.JournalEntry WHERE Reference = CONCAT('DSB-', @LoanNo));
INSERT #Results VALUES (N'Disbursing twice pays out once', IIF(@rc = 1 AND @id2 = @id AND @n = 1, 1, 0), CONCAT('rc=', @rc, ' entries=', @n));

SET @err = NULL;
BEGIN TRY UPDATE dbo.LoanSchedule SET InterestDue = 0 WHERE LoanId = (SELECT LoanId FROM dbo.Loan WHERE LoanNo = @LoanNo); END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'Schedule cannot be edited after disbursement', IIF(@err = 50003, 1, 0), CONCAT('err=', @err));

/* ---------- Interest and repayments ---------- */

DECLARE @Int1 decimal(19,2) = (SELECT InterestDue FROM dbo.LoanSchedule AS s JOIN dbo.Loan AS l ON l.LoanId = s.LoanId
                               WHERE l.LoanNo = @LoanNo AND s.InstallmentNo = 1);
EXEC dbo.usp_AccrueLoanInterest @AsOfDate = '2026-04-15';
EXEC dbo.usp_AccrueLoanInterest @AsOfDate = '2026-04-15';
SET @n = (SELECT COUNT(*) FROM dbo.JournalEntry WHERE Reference LIKE CONCAT('ACR-', @LoanNo, '-%'));
SELECT @a = InterestOutstanding FROM dbo.vw_LoanBalance WHERE LoanNo = @LoanNo;
INSERT #Results VALUES (N'Running the accrual job twice charges interest once', IIF(@n = 1 AND @a = @Int1 AND @a = 400, 1, 0),
    CONCAT('entries=', @n, ' interest=', @a));

EXEC dbo.usp_RepayLoan @LoanNo = @LoanNo, @Amount = 1000, @Reference = 'LTEST-RPY-1', @TxnDate = '2026-04-15';
SELECT @a = PrincipalOutstanding, @b = InterestOutstanding FROM dbo.vw_LoanBalance WHERE LoanNo = @LoanNo;
INSERT #Results VALUES (N'Repayment pays interest due first, then principal', IIF(@a = 39400 AND @b = 0, 1, 0),
    CONCAT('principal=', @a, ' interest=', @b));

EXEC @rc = dbo.usp_RepayLoan @LoanNo = @LoanNo, @Amount = 1000, @Reference = 'LTEST-RPY-1', @TxnDate = '2026-04-15';
SELECT @a = PrincipalOutstanding FROM dbo.vw_LoanBalance WHERE LoanNo = @LoanNo;
INSERT #Results VALUES (N'Duplicate repayment callback is ignored', IIF(@rc = 1 AND @a = 39400, 1, 0), CONCAT('rc=', @rc, ' principal=', @a));

SELECT @a = e.Exposure FROM dbo.vw_GuarantorExposure AS e JOIN dbo.Member AS m ON m.MemberId = e.GuarantorMemberId WHERE m.MemberNo = 'LT002';
INSERT #Results VALUES (N'Guarantor exposure shrinks as the loan is repaid (30,000 x 39,400 / 40,000)',
    IIF(@a = 29550, 1, 0), CONCAT('exposure=', @a));

SELECT @n = DaysPastDue, @cls = Classification, @a = ArrearsAmount
FROM   dbo.fn_LoanArrears('2026-05-31') WHERE LoanNo = @LoanNo;
SELECT @b = SUM(TotalDue) - 1000 FROM dbo.LoanSchedule AS s JOIN dbo.Loan AS l ON l.LoanId = s.LoanId
WHERE  l.LoanNo = @LoanNo AND s.DueDate < '2026-05-31';
INSERT #Results VALUES (N'Short payment on 15 Apr is 46 days past due on 31 May (Substandard)',
    IIF(@n = 46 AND @cls = 'Substandard' AND @a = @b, 1, 0), CONCAT('dpd=', @n, ' class=', @cls, ' arrears=', @a));

SET @err = NULL;
DELETE @L;
INSERT @L VALUES (1, '1010', NULL, 50000, 0), (2, '1100', CONCAT(@LoanNo, '-P'), 0, 50000);
BEGIN TRY EXEC dbo.usp_PostJournal @Reference = 'LTEST-HACK-1', @TxnDate = '2026-04-20', @Narration = N'Too much',
               @Channel = 'SYSTEM', @BranchCode = 'HQ', @Lines = @L; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'A loan account cannot be credited below zero', IIF(@err = 50022, 1, 0), CONCAT('err=', @err));

/* Pay everything off with 500 extra. */
EXEC dbo.usp_AccrueLoanInterest @AsOfDate = '2026-05-15';
SELECT @a = PrincipalOutstanding + InterestOutstanding + 500 FROM dbo.vw_LoanBalance WHERE LoanNo = @LoanNo;
SELECT @b = Balance FROM dbo.vw_AccountBalance WHERE AccountNo = 'SAV-LT001';
EXEC dbo.usp_RepayLoan @LoanNo = @LoanNo, @Amount = @a, @Reference = 'LTEST-RPY-2', @TxnDate = '2026-05-15';
SELECT @s = Status FROM dbo.Loan WHERE LoanNo = @LoanNo;
SELECT @c = Balance FROM dbo.vw_AccountBalance WHERE AccountNo = 'SAV-LT001';
SET @n = (SELECT COUNT(*) FROM dbo.vw_GuarantorExposure AS e JOIN dbo.Member AS m ON m.MemberId = e.GuarantorMemberId
          WHERE m.MemberNo IN ('LT002', 'LT004') AND e.Exposure > 0);
INSERT #Results VALUES (N'Paying off closes the loan, overpayment goes to savings, guarantors released',
    IIF(@s = 'CLOSED' AND @c = @b + 500 AND @n = 0, 1, 0), CONCAT('status=', @s, ' savings+', @c - @b, ' exposed=', @n));

SET @err = NULL;
BEGIN TRY EXEC dbo.usp_RepayLoan @LoanNo = @LoanNo, @Amount = 100, @Reference = 'LTEST-RPY-3', @TxnDate = '2026-05-20'; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'Closed loans take no more repayments', IIF(@err = 50077, 1, 0), CONCAT('err=', @err));

/* ---------- Whole-ledger invariants (includes all generated loans) ---------- */

SET @n = (SELECT COUNT(*) FROM dbo.vw_UnbalancedEntries);
INSERT #Results VALUES (N'Every journal entry balances', IIF(@n = 0, 1, 0), CONCAT('unbalanced=', @n));

SELECT @a = SUM(DebitBalance), @b = SUM(CreditBalance) FROM dbo.vw_TrialBalance;
INSERT #Results VALUES (N'Trial balance: total debits = total credits', IIF(@a = @b, 1, 0), CONCAT('Dr=', @a, ' Cr=', @b));

SELECT @n = COUNT(*)
FROM   dbo.GLAccount AS g
CROSS APPLY (SELECT ISNULL(SUM(Debit - Credit), 0) AS GLBal FROM dbo.JournalLine WHERE GLAccountId = g.GLAccountId) AS gl
CROSS APPLY (SELECT ISNULL(SUM(v.Balance), 0) AS SubBal
             FROM dbo.vw_AccountBalance AS v JOIN dbo.Account AS a ON a.AccountId = v.AccountId
             WHERE a.ControlGLAccountId = g.GLAccountId) AS sub
WHERE  g.GLCode IN ('1100', '1110') AND gl.GLBal <> sub.SubBal;
INSERT #Results VALUES (N'Loan and interest control GLs equal the sum of member loan accounts', IIF(@n = 0, 1, 0), CONCAT('out of balance=', @n));

SET @n = (SELECT COUNT(*) FROM dbo.vw_LoanBalance WHERE PrincipalOutstanding < 0 OR InterestOutstanding < 0);
INSERT #Results VALUES (N'No loan or interest account is negative', IIF(@n = 0, 1, 0), CONCAT('negative=', @n));

SET @n = (SELECT COUNT(*) FROM dbo.Loan AS l
          WHERE l.Status IN ('ACTIVE', 'CLOSED')
            AND l.Principal <> (SELECT SUM(PrincipalDue) FROM dbo.LoanSchedule AS s WHERE s.LoanId = l.LoanId));
INSERT #Results VALUES (N'Every disbursed loan has a schedule that adds up to its principal', IIF(@n = 0, 1, 0), CONCAT('bad=', @n));

SET @n = (SELECT COUNT(*) FROM dbo.vw_LoanBalance WHERE Status = 'CLOSED' AND PrincipalOutstanding + InterestOutstanding <> 0);
INSERT #Results VALUES (N'Closed loans owe nothing', IIF(@n = 0, 1, 0), CONCAT('bad=', @n));

SET @n = (SELECT COUNT(*) FROM dbo.Loan AS l
          WHERE l.Status IN ('ACTIVE', 'CLOSED')
            AND NOT EXISTS (SELECT 1 FROM dbo.JournalLine AS jl WHERE jl.JournalEntryId = l.DisbursementEntryId
                            AND jl.AccountId = l.PrincipalAccountId AND jl.Debit = l.Principal));
INSERT #Results VALUES (N'Every disbursed loan points at the entry that paid it out', IIF(@n = 0, 1, 0), CONCAT('bad=', @n));

DECLARE @LastProv date = (SELECT MAX(TxnDate) FROM dbo.JournalEntry WHERE Reference LIKE 'PROV-%');
SELECT @a = SUM(ProvisionAmount) FROM dbo.fn_LoanArrears(@LastProv);
SELECT @b = SUM(jl.Credit - jl.Debit) FROM dbo.JournalLine AS jl JOIN dbo.GLAccount AS g ON g.GLAccountId = jl.GLAccountId
WHERE  g.GLCode = '1190';
INSERT #Results VALUES (N'Provision GL matches the ageing report on the last provision date', IIF(@a = @b, 1, 0),
    CONCAT('asOf=', @LastProv, ' ageing=', @a, ' GL=', @b));

/* ---------- Report ---------- */
SELECT TestNo, IIF(Passed = 1, 'PASS', 'FAIL') AS Result, TestName, Detail FROM #Results ORDER BY TestNo;

DECLARE @Failed int = (SELECT COUNT(*) FROM #Results WHERE Passed = 0),
        @Total  int = (SELECT COUNT(*) FROM #Results);
IF @Failed > 0
    RAISERROR('%d of %d loan tests FAILED.', 16, 1, @Failed, @Total);
ELSE
    PRINT CONCAT('All ', @Total, ' loan tests passed.');
GO
