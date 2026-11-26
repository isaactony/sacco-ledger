/* 10_generate_fake_loans.sql
   A year of FAKE lending, run day by day from January to late November 2026.

   Each day, in this order:
     1. new applications are captured, guaranteed, approved and disbursed
     2. the interest accrual job runs
     3. members make the repayments their "behaviour" says they make
     4. on the last day of the month, the loan loss provision is updated

   Borrowers get a repayment behaviour from a hash of the loan number, so the data
   has a realistic mix of good payers, late payers, partial payers, defaulters and
   early settlers. Everything goes through the same procedures a real app would call. */
USE SaccoLedger;
GO
SET NOCOUNT ON;

DECLARE @Seed varchar(20) = 'loans-2026',
        @Start date = '2026-01-05',
        @End   date = '2026-11-25',
        @Applications int = 220,
        @LastAppDay int = 250;      -- applications stop in mid-September

DECLARE @Log TABLE (Kind varchar(20), ErrorNumber int NULL, Message nvarchar(400) NULL);

/* Application plan: who applies, when, for what. */
DECLARE @Plan TABLE (AppNo int PRIMARY KEY, AppDate date, MemberNo varchar(20), ProductCode varchar(10),
                     SizePct int, TermMonths smallint);
WITH n AS (SELECT TOP (@Applications) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects)
INSERT @Plan (AppNo, AppDate, MemberNo, ProductCode, SizePct, TermMonths)
SELECT  n.i,
        DATEADD(day, (n.i - 1) * @LastAppDay / @Applications, @Start),
        CONCAT('M', RIGHT(CONCAT('00000', m.Value + 1), 5)),
        IIF(pr.Value < 75, 'DEV', 'EMG'),
        40 + sz.Value,                                   -- 40% .. 119% of the member's loan limit
        IIF(pr.Value < 75, 6 + 6 * (tm.Value % 6), 3 + tm.Value % 10)   -- DEV 6..36, EMG 3..12
FROM    n
CROSS APPLY devtools.RandInt(CONCAT(@Seed, '-m-',  n.i), 500) AS m
CROSS APPLY devtools.RandInt(CONCAT(@Seed, '-p-',  n.i), 100) AS pr
CROSS APPLY devtools.RandInt(CONCAT(@Seed, '-sz-', n.i), 80)  AS sz
CROSS APPLY devtools.RandInt(CONCAT(@Seed, '-tm-', n.i), 60)  AS tm;

/* Repayment behaviour per loan, filled in at disbursement. */
DECLARE @Behaviour TABLE (LoanNo varchar(20) PRIMARY KEY, Behaviour varchar(10), StopAfter smallint);

DECLARE @Day date = @Start, @AppNo int, @MemberNo varchar(20), @ProductCode varchar(10), @SizePct int,
        @Term smallint, @Limit decimal(19,2), @Principal decimal(19,2), @LoanNo varchar(20),
        @Remaining decimal(19,2), @Try int, @GuarantorNo varchar(20), @Pledge decimal(19,2),
        @Free decimal(19,2), @Accrued int, @Ref varchar(50), @Amount decimal(19,2), @Channel varchar(10),
        @Installment smallint, @rc int, @Repayments int = 0, @Roll int, @Multiple decimal(5,2),
        @AppDate date;

WHILE @Day <= @End
BEGIN
    /* ---------- 1. Applications ---------- */
    DECLARE apps CURSOR LOCAL FAST_FORWARD FOR
        SELECT AppNo, MemberNo, ProductCode, SizePct, TermMonths FROM @Plan WHERE AppDate = @Day ORDER BY AppNo;
    OPEN apps;
    FETCH NEXT FROM apps INTO @AppNo, @MemberNo, @ProductCode, @SizePct, @Term;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @LoanNo = NULL;
        BEGIN TRY
            -- Ask for a share of the member's limit. Above 100% the application is refused.
            SELECT @Multiple = SavingsMultiple FROM dbo.LoanProduct WHERE LoanProductCode = @ProductCode;
            SELECT @Limit = (v.Balance - dbo.fn_LockedAmount(v.AccountId)) * @Multiple
            FROM   dbo.vw_AccountBalance AS v WHERE v.AccountNo = CONCAT('SAV-', @MemberNo);
            SET @Principal = ROUND(ISNULL(@Limit, 0) * @SizePct / 100, -2);
            IF @Principal < 1000 SET @Principal = 1000;

            EXEC dbo.usp_ApplyForLoan @MemberNo = @MemberNo, @LoanProductCode = @ProductCode,
                 @Principal = @Principal, @TermMonths = @Term, @ApplicationDate = @Day,
                 @AppliedBy = 'loans.officer', @LoanNo = @LoanNo OUTPUT;
            INSERT @Log (Kind) VALUES ('APPLICATION');
        END TRY
        BEGIN CATCH
            INSERT @Log VALUES ('APPLICATION', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;

        IF @LoanNo IS NOT NULL
        BEGIN
            /* Find guarantors. Try up to eight random members. Each is asked for an
               equal share of what's left. Some won't have enough free savings. */
            SET @Remaining = @Principal;
            SET @Try = 1;
            WHILE @Remaining > 0 AND @Try <= 8
            BEGIN
                SELECT @GuarantorNo = CONCAT('M', RIGHT(CONCAT('00000', Value + 1), 5))
                FROM   devtools.RandInt(CONCAT(@Seed, '-g-', @AppNo, '-', @Try), 500);

                SET @Pledge = CEILING(@Remaining / IIF(@Try >= 4, 1, 4 - @Try + 1) * 100) / 100;
                BEGIN TRY
                    EXEC dbo.usp_AddGuarantor @LoanNo = @LoanNo, @GuarantorMemberNo = @GuarantorNo,
                         @Amount = @Pledge, @PledgedOn = @Day;
                    SET @Remaining -= @Pledge;
                    INSERT @Log (Kind) VALUES ('GUARANTEE');
                END TRY
                BEGIN CATCH
                    INSERT @Log VALUES ('GUARANTEE', ERROR_NUMBER(), ERROR_MESSAGE());
                END CATCH;
                SET @Try += 1;
            END;

            BEGIN TRY
                IF @Remaining > 0
                BEGIN
                    EXEC dbo.usp_RejectLoan @LoanNo = @LoanNo, @Reason = N'Not enough guarantors';
                    INSERT @Log VALUES ('APPROVAL', 50073, N'Rejected: not enough guarantors');
                END
                ELSE
                BEGIN
                    SET @AppDate = DATEADD(day, 2, @Day);
                    EXEC dbo.usp_ApproveLoan @LoanNo = @LoanNo, @ApprovedBy = 'credit.committee', @ApprovedOn = @AppDate;
                    INSERT @Log (Kind) VALUES ('APPROVAL');

                    SET @AppDate = DATEADD(day, 3, @Day);
                    EXEC dbo.usp_DisburseLoan @LoanNo = @LoanNo, @DisbursedOn = @AppDate;
                    INSERT @Log (Kind) VALUES ('DISBURSEMENT');

                    SELECT @Roll = Value FROM devtools.RandInt(CONCAT(@Seed, '-b-', @LoanNo), 100);
                    INSERT @Behaviour (LoanNo, Behaviour, StopAfter)
                    SELECT @LoanNo,
                           CASE WHEN @Roll < 62 THEN 'ONTIME' WHEN @Roll < 77 THEN 'LATE'
                                WHEN @Roll < 85 THEN 'PARTIAL' WHEN @Roll < 95 THEN 'STOPS' ELSE 'EARLY' END,
                           2 + s.Value
                    FROM   devtools.RandInt(CONCAT(@Seed, '-k-', @LoanNo), 4) AS s;
                END;
            END TRY
            BEGIN CATCH
                INSERT @Log VALUES ('APPROVAL', ERROR_NUMBER(), ERROR_MESSAGE());
            END CATCH;
        END;

        FETCH NEXT FROM apps INTO @AppNo, @MemberNo, @ProductCode, @SizePct, @Term;
    END;
    CLOSE apps;
    DEALLOCATE apps;

    /* ---------- 2. Interest accrual ---------- */
    EXEC dbo.usp_AccrueLoanInterest @AsOfDate = @Day, @EntriesPosted = @Accrued OUTPUT;
    IF @Accrued > 0 INSERT @Log (Kind) SELECT 'ACCRUAL' FROM GENERATE_SERIES(1, @Accrued);

    /* ---------- 3. Repayments ---------- */
    DECLARE pay CURSOR LOCAL FAST_FORWARD FOR
        SELECT  l.LoanNo, s.InstallmentNo,
                CASE b.Behaviour
                     WHEN 'PARTIAL' THEN ROUND(s.TotalDue * 0.6, 2)
                     WHEN 'EARLY'   THEN IIF(s.InstallmentNo = 3, lb.PrincipalOutstanding + lb.InterestOutstanding, s.TotalDue)
                     ELSE s.TotalDue END
        FROM    dbo.LoanSchedule AS s
        JOIN    dbo.Loan         AS l  ON l.LoanId = s.LoanId AND l.Status = 'ACTIVE'
        JOIN    @Behaviour       AS b  ON b.LoanNo = l.LoanNo
        JOIN    dbo.vw_LoanBalance AS lb ON lb.LoanId = l.LoanId
        WHERE   DATEADD(day, IIF(b.Behaviour = 'LATE', 20, 0), s.DueDate) = @Day
          AND   NOT (b.Behaviour = 'STOPS' AND s.InstallmentNo > b.StopAfter)
        ORDER BY l.LoanNo;
    OPEN pay;
    FETCH NEXT FROM pay INTO @LoanNo, @Installment, @Amount;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Repayments += 1;
        SET @Ref = CONCAT('RPY-', @LoanNo, '-', @Installment);
        SELECT @Channel = IIF(Value < 70, 'MOBILE', 'TELLER') FROM devtools.RandInt(CONCAT(@Seed, '-c-', @Ref), 100);
        BEGIN TRY
            EXEC dbo.usp_RepayLoan @LoanNo = @LoanNo, @Amount = @Amount, @Reference = @Ref,
                 @Channel = @Channel, @TxnDate = @Day;
            INSERT @Log (Kind) VALUES ('REPAYMENT');

            -- Every 25th payment, the mobile money callback arrives twice.
            IF @Repayments % 25 = 0
            BEGIN
                EXEC @rc = dbo.usp_RepayLoan @LoanNo = @LoanNo, @Amount = @Amount, @Reference = @Ref,
                     @Channel = @Channel, @TxnDate = @Day;
                INSERT @Log (Kind) VALUES (IIF(@rc = 1, 'RETRY-IGNORED', 'RETRY-POSTED!'));
            END;
        END TRY
        BEGIN CATCH
            INSERT @Log VALUES ('REPAYMENT', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
        FETCH NEXT FROM pay INTO @LoanNo, @Installment, @Amount;
    END;
    CLOSE pay;
    DEALLOCATE pay;

    /* ---------- 4. Month-end provision ---------- */
    IF @Day = EOMONTH(@Day) OR @Day = @End
    BEGIN
        EXEC @rc = dbo.usp_PostLoanProvision @AsOfDate = @Day;
        IF @rc = 0 INSERT @Log (Kind) VALUES ('PROVISION');
    END;

    SET @Day = DATEADD(day, 1, @Day);
END;

/* ---------- Summary ---------- */
SELECT  Kind,
        SUM(IIF(ErrorNumber IS NULL, 1, 0)) AS Succeeded,
        SUM(IIF(ErrorNumber IS NULL, 0, 1)) AS Refused
FROM    @Log
GROUP BY Kind
ORDER BY MIN(CASE Kind WHEN 'APPLICATION' THEN 1 WHEN 'GUARANTEE' THEN 2 WHEN 'APPROVAL' THEN 3
                       WHEN 'DISBURSEMENT' THEN 4 WHEN 'ACCRUAL' THEN 5 WHEN 'REPAYMENT' THEN 6 ELSE 7 END);

SELECT  ErrorNumber, COUNT(*) AS Times, MIN(Message) AS ExampleMessage
FROM    @Log WHERE ErrorNumber IS NOT NULL
GROUP BY ErrorNumber ORDER BY Times DESC;

SELECT  Status, COUNT(*) AS Loans, SUM(Principal) AS Principal
FROM    dbo.Loan GROUP BY Status ORDER BY Status;
GO
