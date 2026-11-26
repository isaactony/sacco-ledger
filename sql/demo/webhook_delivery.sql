-- One webhook delivery. Called twice at once by demo/webhook_duplicates.sh.
-- Variables: Version (1, 2 or 3), EventId, Delivery (label), StartDelay (hh:mm:ss.mmm)
SET NOCOUNT ON;
WAITFOR DELAY '$(StartDelay)';
DECLARE @t char(12) = CONVERT(char(12), SYSDATETIME(), 114);
PRINT CONCAT(@t, '  v$(Version)  delivery $(Delivery) received $(EventId)');

DECLARE @outcome varchar(40), @entry bigint;
BEGIN TRY
    IF $(Version) = 3
        EXEC hook.usp_HandleV3 @EventId = '$(EventId)', @AccountNo = 'SAV-M00030', @Amount = 1500, @WorkMs = 2000,
                               @Outcome = @outcome OUTPUT, @JournalEntryId = @entry OUTPUT;
    ELSE IF $(Version) = 2
        EXEC hook.usp_HandleV2 @EventId = '$(EventId)', @AccountNo = 'SAV-M00030', @Amount = 1500, @WorkMs = 2000,
                               @Outcome = @outcome OUTPUT;
    ELSE
        EXEC hook.usp_HandleV1 @EventId = '$(EventId)', @AccountNo = 'SAV-M00030', @Amount = 1500, @WorkMs = 2000,
                               @Outcome = @outcome OUTPUT;

    SET @t = CONVERT(char(12), SYSDATETIME(), 114);
    DECLARE @msg varchar(200) = CONCAT(@outcome, IIF(@entry IS NULL, '', CONCAT(', entry ', @entry)));
    PRINT CONCAT(@t, '  v$(Version)  delivery $(Delivery) -> 200 ', @msg);
END TRY
BEGIN CATCH
    SET @t = CONVERT(char(12), SYSDATETIME(), 114);
    PRINT CONCAT(@t, '  v$(Version)  delivery $(Delivery) -> 500 error ', ERROR_NUMBER(), ': ', LEFT(ERROR_MESSAGE(), 70));
END CATCH;
