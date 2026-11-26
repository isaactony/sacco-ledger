/* 06_tests.sql
   Proves the ledger rules hold. Run on a freshly built database (scripts/run-all.sh does this).
   Ends with an error if any test fails, so `sqlcmd -b` returns a non-zero exit code. */
USE SaccoLedger;
GO
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
CREATE TABLE #Results (TestNo int IDENTITY(1,1), TestName nvarchar(200), Passed bit, Detail nvarchar(400));

-- Two test members with known starting balances of zero.
INSERT dbo.Member (MemberNo, FirstName, LastName, NationalId, BranchId, JoinedOn)
VALUES ('T00001', N'Test', N'Alpha', 'TEST-0001', 1, '2026-01-01'),
       ('T00002', N'Test', N'Beta',  'TEST-0002', 1, '2026-01-01');
EXEC dbo.usp_OpenAccount @MemberNo = 'T00001', @ProductCode = 'SAV', @OpenedOn = '2026-01-01';
EXEC dbo.usp_OpenAccount @MemberNo = 'T00001', @ProductCode = 'SHR', @OpenedOn = '2026-01-01';
EXEC dbo.usp_OpenAccount @MemberNo = 'T00002', @ProductCode = 'SAV', @OpenedOn = '2026-01-01';

-- A database user with no login, in the app role, to test permissions.
CREATE USER test_teller WITHOUT LOGIN;
ALTER ROLE ledger_app ADD MEMBER test_teller;
GO

DECLARE @id bigint, @id2 bigint, @rc int, @err int, @n int,
        @bal1 decimal(19,2), @bal2 decimal(19,2), @d decimal(19,4), @c decimal(19,4);
DECLARE @L dbo.JournalLineInput;

/* 1. Deposit */
EXEC dbo.usp_Deposit @AccountNo = 'SAV-T00001', @Amount = 1000, @Reference = 'TEST-DEP-1',
                     @TxnDate = '2026-11-01', @JournalEntryId = @id OUTPUT;
SELECT @bal1 = Balance FROM dbo.vw_AccountBalance WHERE AccountNo = 'SAV-T00001';
INSERT #Results VALUES (N'Deposit credits the member account', IIF(@bal1 = 1000, 1, 0), CONCAT('balance=', @bal1));

/* 2. Idempotent retry */
EXEC @rc = dbo.usp_Deposit @AccountNo = 'SAV-T00001', @Amount = 1000, @Reference = 'TEST-DEP-1',
                           @TxnDate = '2026-11-01', @JournalEntryId = @id2 OUTPUT;
SELECT @bal1 = Balance FROM dbo.vw_AccountBalance WHERE AccountNo = 'SAV-T00001';
INSERT #Results VALUES (N'Retrying the same reference does not post twice',
    IIF(@rc = 1 AND @id2 = @id AND @bal1 = 1000, 1, 0), CONCAT('rc=', @rc, ' sameId=', IIF(@id2 = @id, 'yes', 'no'), ' balance=', @bal1));

/* 3. Overdraft rejected, nothing left behind */
SET @err = NULL;
BEGIN TRY
    EXEC dbo.usp_Withdraw @AccountNo = 'SAV-T00001', @Amount = 5000, @Reference = 'TEST-WDL-BIG', @TxnDate = '2026-11-02';
END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
SELECT @bal1 = Balance FROM dbo.vw_AccountBalance WHERE AccountNo = 'SAV-T00001';
SET @n = (SELECT COUNT(*) FROM dbo.JournalEntry WHERE Reference = 'TEST-WDL-BIG');
INSERT #Results VALUES (N'Withdrawal above balance is rejected and fully rolled back',
    IIF(@err = 50021 AND @bal1 = 1000 AND @n = 0, 1, 0), CONCAT('err=', @err, ' balance=', @bal1, ' entries=', @n));

/* 4. Withdrawal with fee: three-line entry */
EXEC dbo.usp_Withdraw @AccountNo = 'SAV-T00001', @Amount = 400, @Fee = 30, @Channel = 'MOBILE',
                      @Reference = 'TEST-WDL-1', @TxnDate = '2026-11-02', @JournalEntryId = @id OUTPUT;
SELECT @bal1 = Balance FROM dbo.vw_AccountBalance WHERE AccountNo = 'SAV-T00001';
SELECT @n = COUNT(*), @d = SUM(Debit), @c = SUM(Credit) FROM dbo.JournalLine WHERE JournalEntryId = @id;
INSERT #Results VALUES (N'Mobile withdrawal with fee posts 3 balanced lines',
    IIF(@bal1 = 570 AND @n = 3 AND @d = 430 AND @c = 430, 1, 0), CONCAT('balance=', @bal1, ' lines=', @n, ' Dr=', @d, ' Cr=', @c));

/* 5. Minimum balance */
SET @err = NULL;
BEGIN TRY
    EXEC dbo.usp_Withdraw @AccountNo = 'SAV-T00001', @Amount = 500, @Reference = 'TEST-WDL-MIN', @TxnDate = '2026-11-02';
END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'Withdrawal that breaks the product minimum balance (100) is rejected',
    IIF(@err = 50021, 1, 0), CONCAT('err=', @err));

/* 6. Share capital is not withdrawable */
EXEC dbo.usp_Deposit @AccountNo = 'SHR-T00001', @Amount = 2000, @Reference = 'TEST-SHR-1', @TxnDate = '2026-11-02';
SET @err = NULL;
BEGIN TRY
    EXEC dbo.usp_Withdraw @AccountNo = 'SHR-T00001', @Amount = 100, @Reference = 'TEST-SHR-WDL', @TxnDate = '2026-11-02';
END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'Share capital cannot be withdrawn', IIF(@err = 50034, 1, 0), CONCAT('err=', @err));

/* 7. Transfer */
EXEC dbo.usp_Transfer @FromAccountNo = 'SAV-T00001', @ToAccountNo = 'SAV-T00002', @Amount = 200,
                      @Reference = 'TEST-TRF-1', @TxnDate = '2026-11-03', @JournalEntryId = @id OUTPUT;
SELECT @bal1 = Balance FROM dbo.vw_AccountBalance WHERE AccountNo = 'SAV-T00001';
SELECT @bal2 = Balance FROM dbo.vw_AccountBalance WHERE AccountNo = 'SAV-T00002';
INSERT #Results VALUES (N'Transfer moves money between members',
    IIF(@bal1 = 370 AND @bal2 = 200, 1, 0), CONCAT('from=', @bal1, ' to=', @bal2));

/* 8. Reversal */
EXEC dbo.usp_ReverseEntry @JournalEntryId = @id, @Reason = N'Wrong recipient', @TxnDate = '2026-11-03',
                          @ReversalEntryId = @id2 OUTPUT;
SELECT @bal1 = Balance FROM dbo.vw_AccountBalance WHERE AccountNo = 'SAV-T00001';
SELECT @bal2 = Balance FROM dbo.vw_AccountBalance WHERE AccountNo = 'SAV-T00002';
SET @n = (SELECT COUNT(*) FROM dbo.JournalEntry WHERE JournalEntryId IN (@id, @id2));
INSERT #Results VALUES (N'Reversal restores balances and keeps the original entry',
    IIF(@bal1 = 570 AND @bal2 = 0 AND @n = 2, 1, 0), CONCAT('from=', @bal1, ' to=', @bal2, ' entries kept=', @n));

/* 9. Double reversal */
SET @err = NULL;
BEGIN TRY EXEC dbo.usp_ReverseEntry @JournalEntryId = @id, @Reason = N'Again'; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'An entry cannot be reversed twice', IIF(@err = 50042, 1, 0), CONCAT('err=', @err));

/* 10. Reversing a reversal */
SET @err = NULL;
BEGIN TRY EXEC dbo.usp_ReverseEntry @JournalEntryId = @id2, @Reason = N'Undo the undo'; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'A reversal cannot itself be reversed', IIF(@err = 50041, 1, 0), CONCAT('err=', @err));

/* 11-12. Append-only ledger */
SET @err = NULL;
BEGIN TRY UPDATE dbo.JournalLine SET Credit = Credit + 1000000 WHERE JournalEntryId = @id; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'Journal lines cannot be edited (even by dbo)', IIF(@err = 50002, 1, 0), CONCAT('err=', @err));

SET @err = NULL;
BEGIN TRY DELETE dbo.JournalEntry WHERE JournalEntryId = @id; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'Journal entries cannot be deleted (even by dbo)', IIF(@err = 50001, 1, 0), CONCAT('err=', @err));

/* 13. Unbalanced manual journal */
DELETE @L;
INSERT @L (LineNum, GLCode, AccountNo, Debit, Credit) VALUES (1, '5020', NULL, 100, 0), (2, '1010', NULL, 0, 90);
SET @err = NULL;
BEGIN TRY
    EXEC dbo.usp_PostJournal @Reference = 'TEST-JNL-UNBAL', @TxnDate = '2026-11-04', @Narration = N'Office supplies',
                             @Channel = 'SYSTEM', @BranchCode = 'HQ', @Lines = @L;
END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'Unbalanced journal is rejected', IIF(@err = 50015, 1, 0), CONCAT('err=', @err));

/* 14. Control account needs a member account */
DELETE @L;
INSERT @L (LineNum, GLCode, AccountNo, Debit, Credit) VALUES (1, '1010', NULL, 100, 0), (2, '2010', NULL, 0, 100);
SET @err = NULL;
BEGIN TRY
    EXEC dbo.usp_PostJournal @Reference = 'TEST-JNL-CTRL', @TxnDate = '2026-11-04', @Narration = N'Mystery savings',
                             @Channel = 'SYSTEM', @BranchCode = 'HQ', @Lines = @L;
END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT #Results VALUES (N'Posting to a control GL without a member account is rejected', IIF(@err = 50018, 1, 0), CONCAT('err=', @err));

/* 15. Composite foreign key catches a direct insert that bypasses the procedure */
SET @err = NULL;
BEGIN TRANSACTION;
BEGIN TRY
    INSERT dbo.JournalEntry (Reference, TxnDate, Narration, Channel, BranchId)
    VALUES ('TEST-DIRECT', '2026-11-04', N'Direct insert', 'SYSTEM', 1);
    INSERT dbo.JournalLine (JournalEntryId, GLAccountId, AccountId, Debit, Credit)
    SELECT CAST(SCOPE_IDENTITY() AS bigint),
           (SELECT GLAccountId FROM dbo.GLAccount WHERE GLCode = '3010'),          -- share capital GL...
           (SELECT AccountId   FROM dbo.Account   WHERE AccountNo = 'SAV-T00001'), -- ...but a savings account
           0, 50;
END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT #Results VALUES (N'Member account + wrong GL is blocked by a foreign key', IIF(@err = 547, 1, 0), CONCAT('err=', @err));

/* 16. Frozen account */
UPDATE dbo.Account SET Status = 'FROZEN' WHERE AccountNo = 'SAV-T00002';
SET @err = NULL;
BEGIN TRY
    EXEC dbo.usp_Deposit @AccountNo = 'SAV-T00002', @Amount = 100, @Reference = 'TEST-FRZ', @TxnDate = '2026-11-05';
END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
UPDATE dbo.Account SET Status = 'ACTIVE' WHERE AccountNo = 'SAV-T00002';
INSERT #Results VALUES (N'Frozen accounts cannot transact', IIF(@err = 50020, 1, 0), CONCAT('err=', @err));

/* 17-19. Permissions: the app can call procedures but cannot touch tables or reverse entries */
SET @err = NULL;
EXECUTE AS USER = 'test_teller';
BEGIN TRY
    INSERT dbo.JournalEntry (Reference, TxnDate, Narration, Channel, BranchId)
    VALUES ('TEST-HACK', '2026-11-05', N'Free money', 'SYSTEM', 1);
END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
INSERT #Results VALUES (N'App role cannot write to ledger tables directly', IIF(@err = 229, 1, 0), CONCAT('err=', @err));

SET @err = NULL;
EXECUTE AS USER = 'test_teller';
BEGIN TRY
    EXEC dbo.usp_Deposit @AccountNo = 'SAV-T00002', @Amount = 300, @Reference = 'TEST-TELLER-1', @TxnDate = '2026-11-05';
END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
SELECT @bal2 = Balance FROM dbo.vw_AccountBalance WHERE AccountNo = 'SAV-T00002';
INSERT #Results VALUES (N'App role can deposit through the procedure', IIF(@err IS NULL AND @bal2 = 300, 1, 0),
    CONCAT('err=', @err, ' balance=', @bal2));

SET @err = NULL;
EXECUTE AS USER = 'test_teller';
BEGIN TRY EXEC dbo.usp_ReverseEntry @JournalEntryId = 1, @Reason = N'Teller trying to reverse'; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
REVERT;
INSERT #Results VALUES (N'App role cannot post reversals (supervisor only)', IIF(@err = 229, 1, 0), CONCAT('err=', @err));

/* ---------- Whole-ledger invariants (covers all the generated data too) ---------- */

SET @n = (SELECT COUNT(*) FROM dbo.vw_UnbalancedEntries);
INSERT #Results VALUES (N'Every journal entry balances (debits = credits, 2+ lines)', IIF(@n = 0, 1, 0), CONCAT('unbalanced=', @n));

SELECT @d = SUM(DebitBalance), @c = SUM(CreditBalance) FROM dbo.vw_TrialBalance;
INSERT #Results VALUES (N'Trial balance: total debits = total credits', IIF(@d = @c, 1, 0), CONCAT('Dr=', @d, ' Cr=', @c));

SELECT @n = COUNT(*)
FROM   dbo.vw_AccountBalance AS v
LEFT JOIN (SELECT AccountId, SUM(Credit) - SUM(Debit) AS Recomputed
           FROM dbo.JournalLine WHERE AccountId IS NOT NULL GROUP BY AccountId) AS x ON x.AccountId = v.AccountId
WHERE  v.Balance <> ISNULL(x.Recomputed, 0);
INSERT #Results VALUES (N'Indexed-view balances match a full recalculation from journal lines', IIF(@n = 0, 1, 0), CONCAT('mismatches=', @n));

SELECT @n = COUNT(*)
FROM   dbo.GLAccount AS g
CROSS APPLY (SELECT ISNULL(SUM(Credit - Debit), 0) AS GLBal FROM dbo.JournalLine WHERE GLAccountId = g.GLAccountId) AS gl
CROSS APPLY (SELECT ISNULL(SUM(v.Balance), 0) AS SubBal
             FROM dbo.vw_AccountBalance AS v JOIN dbo.Account AS a ON a.AccountId = v.AccountId
             WHERE a.ControlGLAccountId = g.GLAccountId) AS sub
WHERE  g.IsControlAccount = 1 AND g.AccountClass IN ('LIABILITY', 'EQUITY') AND gl.GLBal <> sub.SubBal;
INSERT #Results VALUES (N'Each control GL equals the sum of its member accounts', IIF(@n = 0, 1, 0), CONCAT('out of balance=', @n));

SET @n = (SELECT COUNT(*) FROM dbo.vw_AccountBalance WHERE Balance < 0);
INSERT #Results VALUES (N'No member deposit or share account is negative', IIF(@n = 0, 1, 0), CONCAT('negative=', @n));

/* ---------- Report ---------- */
SELECT TestNo, IIF(Passed = 1, 'PASS', 'FAIL') AS Result, TestName, Detail FROM #Results ORDER BY TestNo;

DECLARE @Failed int = (SELECT COUNT(*) FROM #Results WHERE Passed = 0),
        @Total  int = (SELECT COUNT(*) FROM #Results);
IF @Failed > 0
    RAISERROR('%d of %d tests FAILED.', 16, 1, @Failed, @Total);
ELSE
    PRINT CONCAT('All ', @Total, ' tests passed.');
GO
