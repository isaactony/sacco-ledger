-- Session C: the nightly (here: every few seconds) incremental load runs while A is still open
SET NOCOUNT ON;
DECLARE @n int, @m int, @last bigint, @next varchar(20);
WAITFOR DELAY '00:00:04';
EXEC dw.usp_NaiveLoad @RowsLoaded = @m OUTPUT;
SET @last = (SELECT LastId FROM dw.NaiveWatermark);
PRINT CONCAT(CONVERT(char(12), SYSDATETIME(), 114), '  C  naive load: ', @m, ' lines, watermark moved to id ', @last);
EXEC dw.usp_LoadFactJournalLine @RowsLoaded = @n OUTPUT;
SET @next = CONVERT(varchar(20), (SELECT NextRowVer FROM dw.LoadWatermark), 1);
PRINT CONCAT(CONVERT(char(12), SYSDATETIME(), 114), '  C  rowversion load: ', @n, ' lines, next run starts at ', @next);
