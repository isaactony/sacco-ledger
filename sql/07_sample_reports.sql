/* 07_sample_reports.sql
   Everyday questions a SACCO / co-op asks of its ledger. */
USE SaccoLedger;
GO
SET NOCOUNT ON;

/* 1. Member statement with a running balance (window function). */
DECLARE @AccountNo varchar(20) = 'SAV-M00042';

SELECT  je.TxnDate,
        je.Reference,
        je.Narration,
        je.Channel,
        CAST(jl.Debit  AS decimal(19,2)) AS Withdrawal,
        CAST(jl.Credit AS decimal(19,2)) AS Deposit,
        CAST(SUM(jl.Credit - jl.Debit) OVER (ORDER BY je.TxnDate, je.JournalEntryId
                                             ROWS UNBOUNDED PRECEDING) AS decimal(19,2)) AS RunningBalance
FROM    dbo.JournalLine  AS jl
JOIN    dbo.JournalEntry AS je ON je.JournalEntryId = jl.JournalEntryId
JOIN    dbo.Account      AS a  ON a.AccountId       = jl.AccountId
WHERE   a.AccountNo = @AccountNo
ORDER BY je.TxnDate, je.JournalEntryId;

/* 2. Trial balance with totals row. */
SELECT  ISNULL(GLCode, 'TOTAL') AS GLCode,
        IIF(GROUPING(GLCode) = 1, N'', MAX(GLName)) AS GLName,
        SUM(DebitBalance)       AS Debit,
        SUM(CreditBalance)      AS Credit
FROM    dbo.vw_TrialBalance
GROUP BY ROLLUP (GLCode)
ORDER BY GROUPING(GLCode), GLCode;

/* 3. Control account reconciliation: GL vs sum of member sub-ledger. */
SELECT  g.GLCode, g.GLName,
        CAST(gl.GLBal  AS decimal(19,2)) AS GLBalance,
        CAST(sub.SubBal AS decimal(19,2)) AS MemberAccountsTotal,
        CAST(gl.GLBal - sub.SubBal AS decimal(19,2)) AS Difference
FROM    dbo.GLAccount AS g
CROSS APPLY (SELECT ISNULL(SUM(Credit - Debit), 0) AS GLBal FROM dbo.JournalLine WHERE GLAccountId = g.GLAccountId) AS gl
CROSS APPLY (SELECT ISNULL(SUM(v.Balance), 0) AS SubBal
             FROM dbo.vw_AccountBalance AS v JOIN dbo.Account AS a ON a.AccountId = v.AccountId
             WHERE a.ControlGLAccountId = g.GLAccountId) AS sub
WHERE   g.IsControlAccount = 1 AND g.AccountClass IN ('LIABILITY', 'EQUITY');

/* 4. Monthly cash flow by channel: money in vs money out. */
SELECT  FORMAT(je.TxnDate, 'yyyy-MM') AS Month,
        g.GLName                      AS CashAccount,
        CAST(SUM(jl.Debit)  AS decimal(19,2)) AS MoneyIn,
        CAST(SUM(jl.Credit) AS decimal(19,2)) AS MoneyOut,
        CAST(SUM(jl.Debit - jl.Credit) AS decimal(19,2)) AS Net
FROM    dbo.JournalLine  AS jl
JOIN    dbo.JournalEntry AS je ON je.JournalEntryId = jl.JournalEntryId
JOIN    dbo.GLAccount    AS g  ON g.GLAccountId     = jl.GLAccountId
WHERE   g.GLCode IN ('1010', '1020') AND je.TxnDate >= '2026-01-01'
GROUP BY FORMAT(je.TxnDate, 'yyyy-MM'), g.GLName
ORDER BY Month, CashAccount;

/* 5. Top 10 savers. */
SELECT TOP (10) AccountNo, MemberName, Balance
FROM   dbo.vw_AccountBalance
WHERE  ProductCode = 'SAV'
ORDER BY Balance DESC;

/* 6. Audit: every reversal, who posted it and why. */
SELECT  r.TxnDate, r.Reference AS ReversalRef, o.Reference AS OriginalRef,
        r.Narration, r.PostedBy, r.PostedAt
FROM    dbo.JournalEntry AS r
JOIN    dbo.JournalEntry AS o ON o.JournalEntryId = r.ReversalOfEntryId
ORDER BY r.JournalEntryId DESC
OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY;
GO
