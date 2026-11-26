-- After everything has committed: run both loads again and compare with the source.
SET NOCOUNT ON;
DECLARE @n int, @m int;
EXEC dw.usp_NaiveLoad @RowsLoaded = @m OUTPUT;
EXEC dw.usp_LoadFactJournalLine @RowsLoaded = @n OUTPUT;
PRINT CONCAT('Next run: naive load picked up ', @m, ' lines, rowversion load picked up ', @n, ' lines');
SELECT e.Reference, e.JournalEntryId,
       IIF(EXISTS (SELECT 1 FROM dw.NaiveFactJournalLine f WHERE f.JournalEntryId = e.JournalEntryId), 'yes', 'MISSING') AS InNaiveLoad,
       IIF(EXISTS (SELECT 1 FROM dw.FactJournalLine f WHERE f.JournalEntryId = e.JournalEntryId), 'yes', 'MISSING') AS InRowversionLoad
FROM dbo.JournalEntry e WHERE e.Reference LIKE 'DEMO-%' AND e.JournalEntryId > (SELECT MAX(JournalEntryId) - 2 FROM dbo.JournalEntry) ORDER BY e.JournalEntryId;
SELECT * FROM dw.vw_LoadReconciliation;
