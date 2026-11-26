-- Session B: a mobile share purchase that starts later and commits straight away
SET NOCOUNT ON;
DECLARE @id bigint, @ref varchar(50) = CONCAT('DEMO-B-', FORMAT(SYSDATETIME(), 'HHmmss'));
WAITFOR DELAY '00:00:02';
EXEC dbo.usp_Deposit @AccountNo = 'SHR-M00020', @Amount = 700, @Reference = @ref,
                     @Channel = 'MOBILE', @TxnDate = '2026-11-25', @JournalEntryId = @id OUTPUT;
PRINT CONCAT(CONVERT(char(12), SYSDATETIME(), 114), '  B  inserted and committed JournalEntryId ', @id);
