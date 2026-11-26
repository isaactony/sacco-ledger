/* 00_reset_database.sql
   Drops and recreates the SaccoLedger database. DEV ONLY - this destroys all data. */
USE master;
GO
IF DB_ID(N'SaccoLedger') IS NOT NULL
BEGIN
    ALTER DATABASE SaccoLedger SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE SaccoLedger;
END;
GO
CREATE DATABASE SaccoLedger;
GO
-- Readers (reports, statements) see the last committed version instead of
-- waiting on tellers' locks. Posting procedures take explicit locks where it matters.
ALTER DATABASE SaccoLedger SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO
PRINT 'SaccoLedger database created.';
