/* 03_security.sql
   SQL Server has no "deferred" constraint that can check debits = credits across
   several rows at commit time. So the balancing rule lives in usp_PostJournal, and
   permissions make sure nobody can go around it: applications get EXECUTE on
   procedures and SELECT on views - never INSERT/UPDATE/DELETE on ledger tables.
   (Ownership chaining lets the procedures write to tables the caller cannot touch.) */
USE SaccoLedger;
GO

CREATE ROLE ledger_app;         -- teller screens and the mobile banking backend
CREATE ROLE ledger_supervisor;  -- back office: reversals and manual journals (maker/checker lives here)
CREATE ROLE ledger_reporting;   -- read-only: management reports, auditors
GO

GRANT EXECUTE ON OBJECT::dbo.usp_OpenAccount TO ledger_app;
GRANT EXECUTE ON OBJECT::dbo.usp_Deposit     TO ledger_app;
GRANT EXECUTE ON OBJECT::dbo.usp_Withdraw    TO ledger_app;
GRANT EXECUTE ON OBJECT::dbo.usp_Transfer    TO ledger_app;
GRANT SELECT  ON OBJECT::dbo.vw_AccountBalance TO ledger_app;

GRANT EXECUTE ON OBJECT::dbo.usp_ReverseEntry      TO ledger_supervisor;
GRANT EXECUTE ON OBJECT::dbo.usp_PostJournal       TO ledger_supervisor;
GRANT EXECUTE ON TYPE::dbo.JournalLineInput        TO ledger_supervisor;
GRANT SELECT  ON OBJECT::dbo.vw_AccountBalance     TO ledger_supervisor;
GRANT SELECT  ON OBJECT::dbo.vw_TrialBalance       TO ledger_supervisor;
GRANT SELECT  ON OBJECT::dbo.vw_UnbalancedEntries  TO ledger_supervisor;

GRANT SELECT ON SCHEMA::dbo TO ledger_reporting;   -- read everything, change nothing
GO

PRINT 'Roles and permissions created.';
