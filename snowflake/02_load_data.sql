-- ============================================================================
-- LeakGuard — Milestone 2, Step 2: Load the seed data
-- ============================================================================
-- PREREQUISITE: the three CSVs must already be uploaded to the stage. From the
-- project root, run these once (they are local-file ops, so they can't live in
-- a .sql file that runs server-side):
--
--   snow stage copy "data\billing\billing_records.csv"      "@LEAKGUARD.CORE.LEAKGUARD_STAGE/billing/"      -c default
--   snow stage copy "data\contracts\contracts.csv"          "@LEAKGUARD.CORE.LEAKGUARD_STAGE/contracts/"    -c default
--   snow stage copy "data\ground_truth\planted_leaks.csv"   "@LEAKGUARD.CORE.LEAKGUARD_STAGE/ground_truth/" -c default
--
-- Then:
--   snow sql -f snowflake/02_load_data.sql -c default
--
-- This file is idempotent: it TRUNCATEs before each COPY, so re-running gives
-- you exactly one clean copy of the data rather than duplicates. (COPY INTO on
-- its own would skip already-loaded files, which silently hides regenerated data.)
--
-- Nothing here needs Cortex. Runs fine on a trial account.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE LEAKGUARD_WH;
USE DATABASE LEAKGUARD;
USE SCHEMA CORE;

-- ----------------------------------------------------------------------------
-- 1. Billing: 242 invoice lines. Straightforward single-line-per-row CSV.
-- ----------------------------------------------------------------------------
TRUNCATE TABLE IF EXISTS BILLING_RECORDS;

COPY INTO BILLING_RECORDS
    FROM @LEAKGUARD_STAGE/billing/
    FILE_FORMAT = (FORMAT_NAME = LEAKGUARD_CSV)
    PATTERN = '.*billing_records[.]csv'
    ON_ERROR = ABORT_STATEMENT
    FORCE = TRUE;

-- ----------------------------------------------------------------------------
-- 2. Contracts: 12 rows, but the file is ~267 physical lines because each
--    contract_text is multi-line prose inside one quoted CSV field. The
--    FIELD_OPTIONALLY_ENCLOSED_BY '"' in LEAKGUARD_CSV is what makes this work.
--    If you ever see ~266 rows here, that setting got lost.
-- ----------------------------------------------------------------------------
TRUNCATE TABLE IF EXISTS CONTRACTS;

COPY INTO CONTRACTS
    FROM @LEAKGUARD_STAGE/contracts/
    FILE_FORMAT = (FORMAT_NAME = LEAKGUARD_CSV)
    PATTERN = '.*contracts[.]csv'
    ON_ERROR = ABORT_STATEMENT
    FORCE = TRUE;

-- ----------------------------------------------------------------------------
-- 3. Ground truth: 35 planted leaks. EVALUATION ONLY -- the agent must never
--    read this table, or the whole benchmark is meaningless.
-- ----------------------------------------------------------------------------
TRUNCATE TABLE IF EXISTS GROUND_TRUTH_LEAKS;

COPY INTO GROUND_TRUTH_LEAKS
    FROM @LEAKGUARD_STAGE/ground_truth/
    FILE_FORMAT = (FORMAT_NAME = LEAKGUARD_CSV)
    PATTERN = '.*planted_leaks[.]csv'
    ON_ERROR = ABORT_STATEMENT
    FORCE = TRUE;

-- ============================================================================
-- VERIFICATION -- expected: 242 billing / 12 contracts / 35 leaks
--
-- These expected values track data/generate_data.py. If you change the
-- generator's customer count, month range, or leak rate, re-run it and update
-- the three numbers below -- otherwise a correct load reads as a mismatch.
-- ============================================================================
SELECT 'BILLING_RECORDS'    AS table_name, COUNT(*) AS row_count, 242 AS expected FROM BILLING_RECORDS
UNION ALL
SELECT 'CONTRACTS',                        COUNT(*),              12         FROM CONTRACTS
UNION ALL
SELECT 'GROUND_TRUTH_LEAKS',               COUNT(*),              35         FROM GROUND_TRUTH_LEAKS
ORDER BY table_name;

-- Contracts must be 12 whole documents, not shredded lines.
-- Expect avg_chars in the high hundreds and n_contracts = 12.
SELECT COUNT(*)                    AS n_contracts,
       AVG(LENGTH(contract_text))  AS avg_chars,
       MIN(LENGTH(contract_text))  AS min_chars
FROM CONTRACTS;

-- Eyeball one row end-to-end.
SELECT customer_id, customer_name, LEFT(contract_text, 120) AS contract_head
FROM CONTRACTS
ORDER BY customer_id
LIMIT 3;
