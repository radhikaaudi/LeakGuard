-- ============================================================================
-- LeakGuard — Milestone 2, Step 1: Snowflake foundation
-- ============================================================================
-- Run with role ACCOUNTADMIN. Safe to re-run (idempotent).
--   snow sql -f snowflake/01_setup.sql -c default
--
-- NOTE: nothing in this file needs Cortex. It runs fine on a trial account.
-- Only 00_enable_cortex.sql's final smoke test is blocked. See that file.
--
-- Concepts:
--   WAREHOUSE   = the "engine/workers" that run queries. Costs credits only while ON.
--   DATABASE    = a labelled filing cabinet.
--   SCHEMA      = a drawer inside the cabinet.
--   TABLE       = a spreadsheet inside the drawer.
--   STAGE       = a landing area you upload local files into before loading them.
--   FILE FORMAT = a saved recipe telling Snowflake how to parse those files.
-- ============================================================================

-- 0. Use the admin role for setup.
USE ROLE ACCOUNTADMIN;

-- 1. A small, cheap engine that auto-suspends after 60s idle (saves your credits).
CREATE WAREHOUSE IF NOT EXISTS LEAKGUARD_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Compute for LeakGuard hackathon project';

-- 2. The filing cabinet + drawer for all LeakGuard data.
CREATE DATABASE IF NOT EXISTS LEAKGUARD;
CREATE SCHEMA IF NOT EXISTS LEAKGUARD.CORE;

-- Make these the "current" context so later commands don't need full paths.
USE WAREHOUSE LEAKGUARD_WH;
USE DATABASE LEAKGUARD;
USE SCHEMA CORE;

-- ----------------------------------------------------------------------------
-- 3. Parsing recipe for our CSVs.
--    FIELD_OPTIONALLY_ENCLOSED_BY '"' is the important one: contracts.csv holds
--    full multi-line contract prose inside a single quoted field, so without it
--    Snowflake would treat every newline in a contract as a new row. (The file
--    is 267 physical lines but only 12 logical records.)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT LEAKGUARD_CSV
    TYPE = CSV
    FIELD_DELIMITER = ','
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    ESCAPE_UNENCLOSED_FIELD = NONE
    TRIM_SPACE = FALSE
    EMPTY_FIELD_AS_NULL = TRUE
    NULL_IF = ('')
    ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE
    COMPRESSION = AUTO;

-- 4. Landing area for the local CSVs (02_load_data.sql PUTs files here).
CREATE STAGE IF NOT EXISTS LEAKGUARD_STAGE
    FILE_FORMAT = LEAKGUARD_CSV
    COMMENT = 'Upload target for LeakGuard seed CSVs';

-- ----------------------------------------------------------------------------
-- 5. STRUCTURED data: the billing table. Columns match billing_records.csv exactly.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS BILLING_RECORDS (
    invoice_id            STRING,
    customer_id           INTEGER,
    customer_name         STRING,
    month                 STRING,        -- 'YYYY-MM'
    product               STRING,
    units                 INTEGER,
    unit_rate_billed      FLOAT,
    discount_pct_applied  FLOAT,
    amount_billed         FLOAT
);

-- ----------------------------------------------------------------------------
-- 6. UNSTRUCTURED data (as text): the contracts table. Cortex Search will index
--    the contract_text column so the agent can retrieve relevant clauses.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CONTRACTS (
    customer_id    INTEGER,
    customer_name  STRING,
    contract_text  STRING          -- the full prose MSA; Cortex Search indexes this
);

-- ----------------------------------------------------------------------------
-- 7. A table the AGENT will WRITE its findings into (closing the loop = judge points).
--    Empty for now; the action-drafter skill inserts rows here.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS LEAKAGE_FINDINGS (
    finding_id          STRING DEFAULT UUID_STRING(),
    customer_id         INTEGER,
    customer_name       STRING,
    month               STRING,
    product             STRING,
    leak_type           STRING,
    estimated_recovery  FLOAT,
    evidence            STRING,       -- cited contract clause + billing row
    draft_memo          STRING,       -- the correction memo the agent drafts
    created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ----------------------------------------------------------------------------
-- 8. The ANSWER KEY (35 planted leaks). This is how we score the agent:
--    precision/recall of LEAKAGE_FINDINGS against GROUND_TRUTH_LEAKS.
--
--    The agent must NEVER read this table -- it is evaluation-only. Keeping it
--    in Snowflake (rather than a local CSV) means the scoring query is just SQL.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS GROUND_TRUTH_LEAKS (
    customer_id         INTEGER,
    customer_name       STRING,
    month               STRING,
    product             STRING,
    leak_type           STRING,
    estimated_recovery  FLOAT,
    detail              STRING
);

-- 9. Make sure your role can call Cortex AI functions + the agent surface.
--    (Also set in 00_enable_cortex.sql; repeated here so this file stands alone.)
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER       TO ROLE ACCOUNTADMIN;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE ACCOUNTADMIN;

-- Sanity check: expect BILLING_RECORDS, CONTRACTS, GROUND_TRUTH_LEAKS, LEAKAGE_FINDINGS.
SHOW TABLES IN SCHEMA LEAKGUARD.CORE;
