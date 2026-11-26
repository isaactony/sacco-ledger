/* 12_loan_reports.sql
   The loan reports a SACCO credit committee and board look at every month. */
USE SaccoLedger;
GO
SET NOCOUNT ON;

DECLARE @AsOf date = '2026-11-25';

/* 1. Portfolio ageing and provisioning. */
SELECT  r.Classification,
        CONCAT(r.MinDaysPastDue, IIF(r.MaxDaysPastDue IS NULL, '+', CONCAT('-', r.MaxDaysPastDue))) AS DaysPastDue,
        COUNT(a.LoanId)                         AS Loans,
        ISNULL(SUM(a.PrincipalOutstanding), 0)  AS PrincipalOutstanding,
        ISNULL(SUM(a.ArrearsAmount), 0)         AS Arrears,
        r.ProvisionPct,
        ISNULL(SUM(a.ProvisionAmount), 0)       AS Provision
FROM    dbo.LoanProvisionRule AS r
LEFT JOIN dbo.fn_LoanArrears(@AsOf) AS a ON a.Classification = r.Classification
GROUP BY r.Classification, r.SortOrder, r.MinDaysPastDue, r.MaxDaysPastDue, r.ProvisionPct
ORDER BY r.SortOrder;

/* 2. Portfolio at risk: share of outstanding principal on loans more than 30 days late. */
SELECT  CAST(SUM(PrincipalOutstanding) AS decimal(19,2)) AS GrossPortfolio,
        CAST(SUM(IIF(DaysPastDue > 30, PrincipalOutstanding, 0)) AS decimal(19,2)) AS AtRisk30,
        CAST(100.0 * SUM(IIF(DaysPastDue > 30, PrincipalOutstanding, 0)) / SUM(PrincipalOutstanding) AS decimal(5,2)) AS PAR30Pct
FROM    dbo.fn_LoanArrears(@AsOf);

/* 3. One loan: what was due against what was paid, installment by installment.
      Payments are applied to the oldest installment first. */
DECLARE @LoanNo varchar(20) = (SELECT TOP (1) LoanNo FROM dbo.fn_LoanArrears(@AsOf)
                               WHERE Classification = 'Substandard' ORDER BY LoanNo);
WITH s AS (
    SELECT  s.InstallmentNo, s.DueDate, s.TotalDue,
            SUM(s.TotalDue) OVER (ORDER BY s.InstallmentNo ROWS UNBOUNDED PRECEDING) AS CumulativeDue
    FROM    dbo.LoanSchedule AS s JOIN dbo.Loan AS l ON l.LoanId = s.LoanId
    WHERE   l.LoanNo = @LoanNo AND s.DueDate < @AsOf
)
SELECT  @LoanNo AS LoanNo, s.InstallmentNo, s.DueDate, s.TotalDue,
        CAST(IIF(a.PaidToDate >= s.CumulativeDue, s.TotalDue,
                 IIF(a.PaidToDate > s.CumulativeDue - s.TotalDue, a.PaidToDate - (s.CumulativeDue - s.TotalDue), 0))
             AS decimal(19,2)) AS Covered,
        IIF(a.PaidToDate >= s.CumulativeDue, 'Paid', CONCAT(DATEDIFF(day, s.DueDate, @AsOf), ' days late')) AS State
FROM    s CROSS JOIN dbo.fn_LoanArrears(@AsOf) AS a
WHERE   a.LoanNo = @LoanNo
ORDER BY s.InstallmentNo;

/* 4. Members with the most savings tied up in guarantees. */
SELECT TOP (10) m.MemberNo, m.FirstName + N' ' + m.LastName AS MemberName,
        v.Balance AS Savings, e.Exposure AS Pledged,
        CAST(v.Balance - e.Exposure AS decimal(19,2)) AS Free
FROM    dbo.vw_GuarantorExposure AS e
JOIN    dbo.Member AS m ON m.MemberId = e.GuarantorMemberId
JOIN    dbo.vw_AccountBalance AS v ON v.MemberNo = m.MemberNo AND v.ProductCode = 'SAV'
ORDER BY e.Exposure DESC;

/* 5. Lending income and loss provisions by month. */
SELECT  FORMAT(je.TxnDate, 'yyyy-MM') AS Month,
        CAST(SUM(IIF(g.GLCode = '4020', jl.Credit - jl.Debit, 0)) AS decimal(19,2)) AS InterestIncome,
        CAST(SUM(IIF(g.GLCode = '4010' AND je.Reference LIKE 'DSB-%', jl.Credit, 0)) AS decimal(19,2)) AS ProcessingFees,
        CAST(SUM(IIF(g.GLCode = '5030', jl.Debit - jl.Credit, 0)) AS decimal(19,2)) AS ProvisionExpense
FROM    dbo.JournalLine  AS jl
JOIN    dbo.JournalEntry AS je ON je.JournalEntryId = jl.JournalEntryId
JOIN    dbo.GLAccount    AS g  ON g.GLAccountId     = jl.GLAccountId
WHERE   g.GLCode IN ('4020', '4010', '5030')
GROUP BY FORMAT(je.TxnDate, 'yyyy-MM')
ORDER BY Month;
GO
