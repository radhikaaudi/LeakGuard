-- ============================================================================
-- LeakGuard — Milestone 2, Step 3: Turn contract PROSE into structured TERMS
-- ============================================================================
--   snow sql -f snowflake/03_extract_terms.sql -c default
--
-- WHY THIS FILE EXISTS
-- --------------------
-- BILLING_RECORDS says what we *charged*. The contract says what we were
-- *allowed* to charge. You cannot compare those two until the contract stops
-- being prose and becomes rows. That conversion is this file's whole job.
--
-- This is the step that is normally done by AI (Cortex extraction over the
-- unstructured MSA). Cortex is blocked on this trial account, so this file
-- implements a DETERMINISTIC REGEX BASELINE instead. It is not a throwaway:
--
--   1. It unblocks steps 04 and 05 today, so the full pipeline runs end-to-end.
--   2. It is the control arm. When Cortex comes online, the AI extractor writes
--      into the SAME tables with extraction_method = 'cortex', and you can
--      measure AI vs regex on identical downstream logic. A demo that can say
--      "AI found N more terms than regex, here they are" is far stronger than
--      one that only shows the AI path.
--
-- WHY REGEX IS ENOUGH *HERE* (and why it wouldn't be in the real world):
-- our 12 generated contracts use only 3 phrasings per clause. Real MSAs don't
-- -- that is exactly the gap the Cortex version is meant to close. Say this
-- out loud in the demo; it's the honest framing and it makes the AI necessary
-- rather than decorative.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE LEAKGUARD_WH;
USE DATABASE LEAKGUARD;
USE SCHEMA CORE;

-- ----------------------------------------------------------------------------
-- 1. Per-product pricing: one row per (customer, product).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CONTRACT_TERMS (
    customer_id        INTEGER,
    customer_name      STRING,
    product            STRING,
    contract_rate      FLOAT,        -- the rate we are ENTITLED to charge
    extraction_method  STRING,       -- 'regex_baseline' | 'cortex'
    extracted_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ----------------------------------------------------------------------------
-- 2. Account-level terms: one row per customer.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CONTRACT_META (
    customer_id            INTEGER,
    customer_name          STRING,
    discount_pct           FLOAT,    -- 0 if none
    discount_valid_through DATE,     -- NULL if no discount
    min_monthly_commit     FLOAT,    -- 0 if none
    extraction_method      STRING,
    extracted_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Re-running replaces only the baseline rows, never the Cortex ones.
DELETE FROM CONTRACT_TERMS WHERE extraction_method = 'regex_baseline';
DELETE FROM CONTRACT_META  WHERE extraction_method = 'regex_baseline';

-- ----------------------------------------------------------------------------
-- 3. Pricing lines look like:
--      - **API Calls (per 1k)** — billed at $0.4275 per unit.
--
--    SPLIT_TO_TABLE explodes the contract into one row per physical line, then
--    two REGEXP_SUBSTRs pull the bolded product name and the dollar amount.
--    The 'e' flag means "return capture group 1", not the whole match.
--    We deliberately do NOT match the em-dash — it is an encoding landmine and
--    matching around it buys nothing.
-- ----------------------------------------------------------------------------
INSERT INTO CONTRACT_TERMS (customer_id, customer_name, product, contract_rate, extraction_method)
WITH lines AS (
    SELECT c.customer_id, c.customer_name, l.value::STRING AS ln
    FROM CONTRACTS c, LATERAL SPLIT_TO_TABLE(c.contract_text, '\n') l
)
SELECT customer_id,
       customer_name,
       REGEXP_SUBSTR(ln, '\\*\\*(.+?)\\*\\*',        1, 1, 'e', 1)         AS product,
       REGEXP_SUBSTR(ln, 'billed at \\$([0-9.]+)', 1, 1, 'e', 1)::FLOAT    AS contract_rate,
       'regex_baseline'
FROM lines
WHERE ln LIKE '- **%billed at%';

-- ----------------------------------------------------------------------------
-- 4. Account-level clauses. All three are optional in the prose, so each falls
--    back to a neutral value (0 / NULL) meaning "clause absent".
-- ----------------------------------------------------------------------------
INSERT INTO CONTRACT_META (customer_id, customer_name, discount_pct, discount_valid_through, min_monthly_commit, extraction_method)
SELECT
    customer_id,
    customer_name,
    COALESCE(REGEXP_SUBSTR(contract_text, 'promotional discount of ([0-9.]+)%', 1, 1, 'e', 1)::FLOAT, 0),
    TRY_TO_DATE(REGEXP_SUBSTR(contract_text, 'valid only through ([0-9]{4}-[0-9]{2}-[0-9]{2})', 1, 1, 'e', 1)),
    COALESCE(REPLACE(REGEXP_SUBSTR(contract_text, 'minimum monthly spend of \\$([0-9,]+)', 1, 1, 'e', 1), ',', '')::FLOAT, 0),
    'regex_baseline'
FROM CONTRACTS;

-- ============================================================================
-- VERIFICATION
-- ============================================================================
-- Expect 12 customers and 40 product-rate rows (not every customer buys all 4).
SELECT COUNT(DISTINCT customer_id) AS customers, COUNT(*) AS term_rows
FROM CONTRACT_TERMS WHERE extraction_method = 'regex_baseline';

-- Guardrail: no term may be NULL or non-positive. Expect zero rows back.
SELECT * FROM CONTRACT_TERMS
WHERE extraction_method = 'regex_baseline'
  AND (product IS NULL OR contract_rate IS NULL OR contract_rate <= 0);

-- Every billed (customer, product) pair MUST have a contract term, or the
-- rate check in 04 silently skips those rows. Expect zero rows back.
SELECT DISTINCT b.customer_id, b.product
FROM BILLING_RECORDS b
LEFT JOIN CONTRACT_TERMS t
       ON t.customer_id = b.customer_id
      AND t.product     = b.product
      AND t.extraction_method = 'regex_baseline'
WHERE t.product IS NULL;

SELECT * FROM CONTRACT_META WHERE extraction_method = 'regex_baseline' ORDER BY customer_id;
