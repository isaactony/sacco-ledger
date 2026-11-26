/* 05_generate_fake_data.sql
   Generates FAKE members and a year of transactions. No real people or IDs.

   Every transaction goes through the same stored procedures a teller app would call,
   so the generator also exercises the business rules: some withdrawals are rejected
   for insufficient funds, some reversals are rejected because the money is gone, etc.

   The "random" numbers come from hashing a seed string, so every run produces exactly
   the same data - handy when you quote numbers in an article. */
USE SaccoLedger;
GO
CREATE SCHEMA devtools;   -- keeps test-only helpers away from the real schema
GO
CREATE FUNCTION devtools.RandInt (@Key varchar(200), @Max int)
RETURNS TABLE
AS
RETURN SELECT ABS(CAST(SUBSTRING(HASHBYTES('SHA2_256', @Key), 1, 4) AS int) % @Max) AS Value;
GO

SET NOCOUNT ON;

DECLARE @MemberCount int         = 500,
        @TxnCount    int         = 6000,
        @Seed        varchar(20) = 'sacco-2026';

/* ---------- Members ---------- */
DECLARE @FirstNames TABLE (Idx int IDENTITY(0,1) PRIMARY KEY, Name nvarchar(50));
INSERT @FirstNames (Name) VALUES
    (N'Amina'),(N'Brian'),(N'Chipo'),(N'David'),(N'Esther'),(N'Faith'),(N'George'),(N'Halima'),
    (N'Ivy'),(N'Joy'),(N'Kevin'),(N'Lindiwe'),(N'Moses'),(N'Naledi'),(N'Otieno'),(N'Precious'),
    (N'Rose'),(N'Sipho'),(N'Thandiwe'),(N'Wanjiru'),(N'Zanele'),(N'Peter'),(N'Grace'),(N'Samuel');

DECLARE @LastNames TABLE (Idx int IDENTITY(0,1) PRIMARY KEY, Name nvarchar(50));
INSERT @LastNames (Name) VALUES
    (N'Achieng'),(N'Banda'),(N'Chebet'),(N'Dlamini'),(N'Kamau'),(N'Kariuki'),(N'Khumalo'),(N'Mensah'),
    (N'Mokoena'),(N'Moyo'),(N'Mutua'),(N'Mwangi'),(N'Naidoo'),(N'Ndlovu'),(N'Nkosi'),(N'Odhiambo'),
    (N'Okafor'),(N'Phiri'),(N'Wambui'),(N'Zulu');

DECLARE @FnCount int = (SELECT COUNT(*) FROM @FirstNames),
        @LnCount int = (SELECT COUNT(*) FROM @LastNames),
        @BrCount int = (SELECT COUNT(*) FROM dbo.Branch);

WITH n AS (
    SELECT TOP (@MemberCount) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
)
INSERT dbo.Member (MemberNo, FirstName, LastName, NationalId, PhoneNumber, BranchId, JoinedOn)
SELECT  CONCAT('M', RIGHT(CONCAT('00000', n.i), 5)),
        fn.Name,
        ln.Name,
        CONCAT('FAKE', RIGHT(CONCAT('00000000', n.i), 8)),        -- obviously fake ID numbers
        CONCAT('07', RIGHT(CONCAT('00000000', ph.Value), 8)),
        br.BranchId,
        DATEADD(day, -jd.Value, '2025-12-31')                     -- joined in the last ~6 years
FROM    n
CROSS APPLY devtools.RandInt(CONCAT(@Seed, '-fn-', n.i), @FnCount)      AS rf
CROSS APPLY devtools.RandInt(CONCAT(@Seed, '-ln-', n.i), @LnCount)      AS rl
CROSS APPLY devtools.RandInt(CONCAT(@Seed, '-ph-', n.i), 100000000)     AS ph
CROSS APPLY devtools.RandInt(CONCAT(@Seed, '-br-', n.i), @BrCount)      AS rb
CROSS APPLY devtools.RandInt(CONCAT(@Seed, '-jd-', n.i), 2200)          AS jd
JOIN @FirstNames AS fn ON fn.Idx = rf.Value
JOIN @LastNames  AS ln ON ln.Idx = rl.Value
JOIN (SELECT BranchId, ROW_NUMBER() OVER (ORDER BY BranchId) - 1 AS Idx FROM dbo.Branch) AS br
     ON br.Idx = rb.Value;

/* ---------- Accounts: every member gets savings + shares ---------- */
INSERT dbo.Account (AccountNo, MemberId, ProductId, ControlGLAccountId, OpenedOn)
SELECT CONCAT(p.ProductCode, '-', m.MemberNo), m.MemberId, p.ProductId, p.ControlGLAccountId, m.JoinedOn
FROM   dbo.Member AS m
CROSS JOIN dbo.Product AS p
WHERE  p.ProductCode IN ('SAV', 'SHR');

DECLARE @AccountCount int = (SELECT COUNT(*) FROM dbo.Account);
PRINT CONCAT('Members: ', @MemberCount, '   Accounts: ', @AccountCount);

/* ---------- Opening deposits on the joining date ----------
   (EXEC parameters must be variables or constants, so values are computed first.) */
DECLARE @i int = 1, @MemberNo varchar(20), @JoinedOn date, @Amt decimal(19,4), @Ref varchar(50),
        @Acct varchar(20), @Acct2 varchar(20);

WHILE @i <= @MemberCount
BEGIN
    SELECT @MemberNo = MemberNo, @JoinedOn = JoinedOn
    FROM   dbo.Member WHERE MemberNo = CONCAT('M', RIGHT(CONCAT('00000', @i), 5));

    SELECT @Amt = (Value + 1) * 500 FROM devtools.RandInt(CONCAT(@Seed, '-os-', @i), 10);  -- 500..5,000
    SELECT @Ref = CONCAT('OPEN-SHR-', @MemberNo), @Acct = CONCAT('SHR-', @MemberNo);
    EXEC dbo.usp_Deposit @AccountNo = @Acct, @Amount = @Amt, @Reference = @Ref,
                         @Channel = 'TELLER', @TxnDate = @JoinedOn, @Narration = N'Opening share capital';

    SELECT @Amt = (Value + 2) * 500 FROM devtools.RandInt(CONCAT(@Seed, '-ov-', @i), 10);  -- 1,000..5,500
    SELECT @Ref = CONCAT('OPEN-SAV-', @MemberNo), @Acct = CONCAT('SAV-', @MemberNo);
    EXEC dbo.usp_Deposit @AccountNo = @Acct, @Amount = @Amt, @Reference = @Ref,
                         @Channel = 'TELLER', @TxnDate = @JoinedOn, @Narration = N'Opening savings deposit';
    SET @i += 1;
END;

/* A handful of frozen accounts (e.g. a court order or a deceased member's estate) */
UPDATE a SET Status = 'FROZEN'
FROM   dbo.Account AS a
CROSS APPLY devtools.RandInt(CONCAT(@Seed, '-frz-', a.AccountNo), 100) AS r
WHERE  a.AccountNo LIKE 'SAV-%' AND r.Value = 0;

/* ---------- Day-to-day activity, 1 Jan - late Nov 2026 ---------- */
DECLARE @Outcome TABLE (TxnType varchar(20), ErrorNumber int NULL, ExampleMessage nvarchar(400) NULL);

DECLARE @TxnDate date, @Roll int, @Pick int, @Pick2 int, @AmtRoll int, @Channel varchar(10),
        @Fee decimal(19,4), @TxnType varchar(20), @EntryId bigint, @rc int;

SET @i = 1;
WHILE @i <= @TxnCount
BEGIN
    SET @TxnDate = DATEADD(day, (@i - 1) * 327 / @TxnCount, '2026-01-01');

    SELECT @Roll    = Value     FROM devtools.RandInt(CONCAT(@Seed, '-t-',  @i), 100);
    SELECT @Pick    = Value + 1 FROM devtools.RandInt(CONCAT(@Seed, '-m-',  @i), @MemberCount);
    SELECT @Pick2   = Value + 1 FROM devtools.RandInt(CONCAT(@Seed, '-m2-', @i), @MemberCount);
    SELECT @AmtRoll = Value     FROM devtools.RandInt(CONCAT(@Seed, '-a-',  @i), 100);
    SELECT @Channel = IIF(Value < 60, 'MOBILE', 'TELLER') FROM devtools.RandInt(CONCAT(@Seed, '-c-', @i), 100);

    SET @MemberNo = CONCAT('M', RIGHT(CONCAT('00000', @Pick), 5));
    SET @Ref      = CONCAT('GEN-', RIGHT(CONCAT('000000', @i), 6));

    BEGIN TRY
        IF @Roll < 40
        BEGIN
            SELECT @TxnType = 'DEPOSIT', @Acct = CONCAT('SAV-', @MemberNo), @Amt = (@AmtRoll + 1) * 100;  -- 100..10,000
            EXEC dbo.usp_Deposit @AccountNo = @Acct, @Amount = @Amt, @Reference = @Ref,
                                 @Channel = @Channel, @TxnDate = @TxnDate;
            -- Every 200th transaction, simulate the phone app retrying a deposit after a timeout.
            IF @i % 200 = 0
            BEGIN
                EXEC @rc = dbo.usp_Deposit @AccountNo = @Acct, @Amount = @Amt, @Reference = @Ref,
                                           @Channel = @Channel, @TxnDate = @TxnDate;
                INSERT @Outcome (TxnType) VALUES (IIF(@rc = 1, 'RETRY-IGNORED', 'RETRY-POSTED!'));
            END;
        END
        ELSE IF @Roll < 72
        BEGIN
            SELECT @TxnType = 'WITHDRAWAL', @Acct = CONCAT('SAV-', @MemberNo),
                   @Amt = (@AmtRoll % 60 + 1) * 100, @Fee = IIF(@Channel = 'MOBILE', 30, 0);
            EXEC dbo.usp_Withdraw @AccountNo = @Acct, @Amount = @Amt, @Reference = @Ref,
                                  @Channel = @Channel, @Fee = @Fee, @TxnDate = @TxnDate;
        END
        ELSE IF @Roll < 84
        BEGIN
            SELECT @TxnType = 'TRANSFER', @Acct = CONCAT('SAV-', @MemberNo),
                   @Acct2 = CONCAT('SAV-M', RIGHT(CONCAT('00000', @Pick2), 5)), @Amt = (@AmtRoll % 30 + 1) * 100;
            EXEC dbo.usp_Transfer @FromAccountNo = @Acct, @ToAccountNo = @Acct2, @Amount = @Amt,
                                  @Reference = @Ref, @TxnDate = @TxnDate;
        END
        ELSE IF @Roll < 95
        BEGIN
            SELECT @TxnType = 'SHARE-PURCHASE', @Acct = CONCAT('SHR-', @MemberNo), @Amt = (@AmtRoll % 10 + 1) * 200;
            EXEC dbo.usp_Deposit @AccountNo = @Acct, @Amount = @Amt, @Reference = @Ref,
                                 @Channel = @Channel, @TxnDate = @TxnDate, @Narration = N'Share capital top-up';
        END
        ELSE IF @Roll < 97
        BEGIN
            -- Not allowed: share capital is not withdrawable. Should always be rejected.
            SELECT @TxnType = 'SHARE-WITHDRAWAL', @Acct = CONCAT('SHR-', @MemberNo);
            EXEC dbo.usp_Withdraw @AccountNo = @Acct, @Amount = 500, @Reference = @Ref,
                                  @Channel = 'TELLER', @TxnDate = @TxnDate;
        END
        ELSE
        BEGIN
            -- Reverse one of the ~300 most recent entries (some will already be reversed, or the money spent).
            -- Some ids won't exist: a rolled-back insert still uses up its IDENTITY value, so ids have gaps.
            -- (Never rely on IDENTITY values being consecutive - a good point for the article.)
            SET @TxnType = 'REVERSAL';
            SELECT @EntryId = (SELECT MAX(JournalEntryId) FROM dbo.JournalEntry) - Value
            FROM   devtools.RandInt(CONCAT(@Seed, '-rv-', @i), 300);
            EXEC dbo.usp_ReverseEntry @JournalEntryId = @EntryId, @Reason = N'Posted to wrong member (simulated)',
                                      @TxnDate = @TxnDate;
        END;

        INSERT @Outcome (TxnType) VALUES (@TxnType);
    END TRY
    BEGIN CATCH
        INSERT @Outcome (TxnType, ErrorNumber, ExampleMessage) VALUES (@TxnType, ERROR_NUMBER(), ERROR_MESSAGE());
    END CATCH;

    SET @i += 1;
END;

/* ---------- Summary ---------- */
SELECT  TxnType,
        SUM(IIF(ErrorNumber IS NULL, 1, 0)) AS Posted,
        SUM(IIF(ErrorNumber IS NULL, 0, 1)) AS Rejected
FROM    @Outcome
GROUP BY TxnType
ORDER BY TxnType;

SELECT  ErrorNumber, COUNT(*) AS Times, MIN(ExampleMessage) AS ExampleMessage
FROM    @Outcome
WHERE   ErrorNumber IS NOT NULL
GROUP BY ErrorNumber
ORDER BY Times DESC;

SELECT  (SELECT COUNT(*) FROM dbo.JournalEntry) AS JournalEntries,
        (SELECT COUNT(*) FROM dbo.JournalLine)  AS JournalLines;
GO
