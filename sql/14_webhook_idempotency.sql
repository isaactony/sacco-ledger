/* 14_webhook_idempotency.sql
   Handling a payment webhook that arrives more than once.

   Payment providers retry a webhook when they don't get a 2xx back in time, so the
   same event can reach you twice, sometimes a few hundred milliseconds apart. Three
   versions of the handler live here so demo/webhook_duplicates.sh can compare them.

   v1  check, then insert             two deliveries at once credit the member twice
   v2  check, then insert + UNIQUE    no double credit, but the second delivery errors
   v3  claim the event id first       one credit, and the retry gets the original result

   @WorkMs stands in for whatever the handler does between the check and the write
   (validation, a fraud rule, a slow lock wait). It makes the race easy to reproduce. */
USE SaccoLedger;
GO

CREATE SCHEMA hook;
GO

/* ---------- v1 and v2: a credits table and a "have I seen this?" check ---------- */
CREATE TABLE hook.NaiveCredit (
    CreditId   int IDENTITY PRIMARY KEY,
    EventId    varchar(64)   NOT NULL,          -- no unique constraint
    AccountNo  varchar(20)   NOT NULL,
    Amount     decimal(19,4) NOT NULL,
    CreatedAt  datetime2(3)  NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE TABLE hook.UniqueCredit (
    CreditId   int IDENTITY PRIMARY KEY,
    EventId    varchar(64)   NOT NULL CONSTRAINT UQ_UniqueCredit_EventId UNIQUE,
    AccountNo  varchar(20)   NOT NULL,
    Amount     decimal(19,4) NOT NULL,
    CreatedAt  datetime2(3)  NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

CREATE OR ALTER PROCEDURE hook.usp_HandleV1
    @EventId varchar(64), @AccountNo varchar(20), @Amount decimal(19,4), @WorkMs int = 0,
    @Outcome varchar(40) = NULL OUTPUT, @JournalEntryId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @wait char(12) = CONVERT(char(12), DATEADD(millisecond, @WorkMs, CAST('00:00' AS time)), 114);

    IF EXISTS (SELECT 1 FROM hook.NaiveCredit WHERE EventId = @EventId)
    BEGIN
        SET @Outcome = 'duplicate, ignored';
        RETURN;
    END;

    WAITFOR DELAY @wait;

    INSERT hook.NaiveCredit (EventId, AccountNo, Amount) VALUES (@EventId, @AccountNo, @Amount);
    SET @Outcome = 'credited';
END;
GO

CREATE OR ALTER PROCEDURE hook.usp_HandleV2
    @EventId varchar(64), @AccountNo varchar(20), @Amount decimal(19,4), @WorkMs int = 0,
    @Outcome varchar(40) = NULL OUTPUT, @JournalEntryId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @wait char(12) = CONVERT(char(12), DATEADD(millisecond, @WorkMs, CAST('00:00' AS time)), 114);

    IF EXISTS (SELECT 1 FROM hook.UniqueCredit WHERE EventId = @EventId)
    BEGIN
        SET @Outcome = 'duplicate, ignored';
        RETURN;
    END;

    WAITFOR DELAY @wait;

    INSERT hook.UniqueCredit (EventId, AccountNo, Amount) VALUES (@EventId, @AccountNo, @Amount);
    SET @Outcome = 'credited';
END;
GO

/* ---------- v3: an inbox table keyed on the provider's event id ---------- */
CREATE TABLE hook.WebhookEvent (
    EventId        varchar(64)  NOT NULL CONSTRAINT PK_WebhookEvent PRIMARY KEY,
    PayloadHash    binary(32)   NOT NULL,     -- same id must mean same payload
    ReceivedAt     datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    JournalEntryId bigint       NULL,         -- the result, returned to every retry
    DeliveryCount  int          NOT NULL DEFAULT 1
);
GO

CREATE OR ALTER PROCEDURE hook.usp_HandleV3
    @EventId varchar(64), @AccountNo varchar(20), @Amount decimal(19,4), @WorkMs int = 0,
    @Outcome varchar(40) = NULL OUTPUT, @JournalEntryId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @wait char(12) = CONVERT(char(12), DATEADD(millisecond, @WorkMs, CAST('00:00' AS time)), 114),
            @hash binary(32)  = HASHBYTES('SHA2_256', CONCAT(@AccountNo, '|', CONVERT(varchar(30), @Amount))),
            @entry bigint, @storedHash binary(32);

    BEGIN TRY
        BEGIN TRANSACTION;

        /* Claim the event first. A second delivery of the same id blocks here until
           this transaction ends, then fails with a duplicate key error. */
        INSERT hook.WebhookEvent (EventId, PayloadHash) VALUES (@EventId, @hash);

        WAITFOR DELAY @wait;

        DECLARE @ref varchar(50) = CONCAT('WH-', @EventId);
        EXEC dbo.usp_Deposit @AccountNo = @AccountNo, @Amount = @Amount, @Reference = @ref,
                             @Channel = 'MOBILE', @TxnDate = '2026-11-25', @JournalEntryId = @entry OUTPUT;

        UPDATE hook.WebhookEvent SET JournalEntryId = @entry WHERE EventId = @EventId;

        COMMIT TRANSACTION;
        SELECT @Outcome = 'credited', @JournalEntryId = @entry;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() NOT IN (2601, 2627) THROW;

        /* Seen before. Return what the first delivery got, unless the payload changed. */
        UPDATE hook.WebhookEvent
        SET    DeliveryCount = DeliveryCount + 1,
               @entry = JournalEntryId, @storedHash = PayloadHash
        WHERE  EventId = @EventId;

        IF @storedHash <> @hash
            THROW 50090, 'Event id reused with a different payload.', 1;

        SELECT @Outcome = 'duplicate, returned original', @JournalEntryId = @entry;
    END CATCH;
END;
GO

PRINT 'Webhook handler objects created.';
