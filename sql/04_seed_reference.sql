/* 04_seed_reference.sql
   Branches, chart of accounts and products. */
USE SaccoLedger;
GO
SET NOCOUNT ON;

INSERT dbo.Branch (BranchCode, BranchName) VALUES
    ('HQ',  N'Head Office'),
    ('TWN', N'Town Branch'),
    ('AGT', N'Rural Agency');

INSERT dbo.GLAccount (GLCode, GLName, AccountClass, IsControlAccount) VALUES
    ('1010', N'Cash at Hand',                    'ASSET',     0),
    ('1020', N'Mobile Money Float',              'ASSET',     0),
    ('1030', N'Bank - Current Account',          'ASSET',     0),
    ('1100', N'Loans to Members',                'ASSET',     1),  -- used in project 2
    ('2010', N'Member Savings Deposits',         'LIABILITY', 1),
    ('3010', N'Member Share Capital',            'EQUITY',    1),
    ('3020', N'Retained Earnings',               'EQUITY',    0),
    ('4010', N'Fee Income',                      'INCOME',    0),
    ('4020', N'Interest Income on Loans',        'INCOME',    0),
    ('5010', N'Interest Expense on Savings',     'EXPENSE',   0),
    ('5020', N'Operating Expenses',              'EXPENSE',   0);

INSERT dbo.Product (ProductCode, ProductName, ProductType, ControlGLAccountId, IsWithdrawable, MinBalance)
SELECT v.ProductCode, v.ProductName, v.ProductType, g.GLAccountId, v.IsWithdrawable, v.MinBalance
FROM (VALUES
        ('SAV', N'Ordinary Savings', 'SAVINGS', '2010', 1, 100.00),
        ('SHR', N'Share Capital',    'SHARES',  '3010', 0,   0.00)
     ) AS v (ProductCode, ProductName, ProductType, GLCode, IsWithdrawable, MinBalance)
JOIN dbo.GLAccount AS g ON g.GLCode = v.GLCode;

PRINT 'Reference data loaded.';
