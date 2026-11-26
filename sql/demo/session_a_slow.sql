-- Session A: a teller deposit that takes 8 seconds to commit (slow network, a lock wait, a long trigger...)
SET NOCOUNT ON;
DECLARE @id bigint, @ref varchar(50) = CONCAT('DEMO-A-', FORMAT(SYSDATETIME(), 'HHmmss'));
BEGIN TRANSACTION;
EXEC dbo.usp_Deposit @AccountNo = 'SAV-M00010', @Amount = 500, @Reference = @ref,
                     @Channel = 'TELLER', @TxnDate = '2026-11-25', @JournalEntryId = @id OUTPUT;
PRINT CONCAT(CONVERT(char(12), SYSDATETIME(), 114), '  A  inserted JournalEntryId ', @id, ', not committed yet');
WAITFOR DELAY '00:00:08';
COMMIT;
PRINT CONCAT(CONVERT(char(12), SYSDATETIME(), 114), '  A  committed ', @id);
