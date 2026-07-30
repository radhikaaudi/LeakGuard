-- ============================================================================
-- LeakGuard — Milestone 3: contract-intel, the CORTEX term extractor
-- ============================================================================
--   snow sql -f snowflake/03b_extract_terms_cortex.sql -c default
--   (run 03_extract_terms.sql first -- this is the treatment arm, that is the control)
--
-- WHY THIS FILE EXISTS
-- --------------------
-- 03 turns contract prose into rows with regular expressions. That works here
-- only because our 12 generated contracts use three phrasings per clause. Real
-- MSAs do not cooperate, and every new phrasing is a new regex. This file does
-- the same job with Cortex, which is the version that would survive contact
-- with a real contract repository.
--
-- IT WRITES INTO THE SAME TABLES as the regex baseline, tagged
-- extraction_method = 'cortex'. That is what makes this an EXPERIMENT rather
-- than a replacement: identical downstream logic, two extraction arms, one
-- scoreboard (05). A demo that can say "AI recovered N terms regex missed, and
-- here is the precision/recall delta" is far stronger than one that only shows
-- the AI path and asks you to take its word for it.
--
-- WHY STRUCTURED OUTPUT, NOT PROSE PARSING
-- ----------------------------------------
-- COMPLETE is called with a response_format JSON schema, so Cortex returns a
-- validated object rather than a paragraph we would have to regex -- which
-- would reintroduce exactly the fragility this file exists to remove. The
-- response envelope is:
--     { "structured_output": [ { "raw_message": {...}, "type": "json" } ], ... }
-- hence the :structured_output[0]:raw_message path below.
--
-- COST: one inference call per contract (12). The raw extraction is landed in a
-- transient table first so both INSERTs read one inference pass rather than
-- billing the model twice, and so a bad extraction can be inspected after the
-- fact instead of being re-run blind.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE LEAKGUARD_WH;
USE DATABASE LEAKGUARD;
USE SCHEMA CORE;

-- ============================================================================
-- 1. ONE INFERENCE PASS over the contracts, landed as JSON.
--    TRANSIENT (not TEMPORARY) on purpose: it survives the session so you can
--    debug what the model actually returned without paying for a second pass.
-- ============================================================================
CREATE OR REPLACE TRANSIENT TABLE CORTEX_EXTRACTION_RAW AS
SELECT
    c.customer_id,
    c.customer_name,
    -- NOTE: no PARSE_JSON here. The single-prompt form of COMPLETE returns a
    -- STRING, but the messages-array + options form returns an OBJECT already,
    -- so wrapping it in PARSE_JSON is a compile error:
    --   Invalid argument types for function 'PARSE_JSON': (OBJECT)
    (
        SNOWFLAKE.CORTEX.COMPLETE(
            'claude-sonnet-4-5',
            [{'role': 'user', 'content':
                'You are a contract analyst. Extract the commercial terms from the '
             || 'master services agreement below. Rules: '
             || '(1) products: one entry per priced product line, using the product '
             || 'name EXACTLY as written in the contract, and its per-unit rate in '
             || 'dollars as a number. Do not invent products the contract does not '
             || 'price. (2) discount_pct: the promotional discount percentage as a '
             || 'number, or 0 if the contract grants none. (3) '
             || 'discount_valid_through: the discount expiry as YYYY-MM-DD, or null '
             || 'if there is no discount or no stated expiry. (4) '
             || 'min_monthly_commit: the minimum monthly spend commitment in dollars '
             || 'as a number, or 0 if there is no such clause. Report only what the '
             || 'contract states.'
             || '\n\n--- CONTRACT ---\n' || c.contract_text
            }],
            {'response_format': {
                'type': 'json',
                'schema': {
                    'type': 'object',
                    'properties': {
                        'products': {
                            'type': 'array',
                            'items': {
                                'type': 'object',
                                'properties': {
                                    'product':       {'type': 'string'},
                                    'contract_rate': {'type': 'number'}
                                },
                                'required': ['product', 'contract_rate']
                            }
                        },
                        'discount_pct':           {'type': 'number'},
                        'discount_valid_through': {'type': 'string'},
                        'min_monthly_commit':     {'type': 'number'}
                    },
                    'required': ['products', 'discount_pct', 'min_monthly_commit']
                }
            }}
        )
    ):structured_output[0]:raw_message AS terms
FROM CONTRACTS c;

-- Re-running replaces only the Cortex rows, never the regex control arm.
DELETE FROM CONTRACT_TERMS WHERE extraction_method = 'cortex';
DELETE FROM CONTRACT_META  WHERE extraction_method = 'cortex';

-- ============================================================================
-- 2. Per-product pricing. FLATTEN turns the products array into rows.
--    The guards mirror 03's: a term with no name or a non-positive rate is
--    worse than no term at all, because 04 would silently join on it.
-- ============================================================================
INSERT INTO CONTRACT_TERMS (customer_id, customer_name, product, contract_rate, extraction_method)
SELECT
    r.customer_id,
    r.customer_name,
    p.value:product::STRING          AS product,
    p.value:contract_rate::FLOAT     AS contract_rate,
    'cortex'
FROM        CORTEX_EXTRACTION_RAW r,
LATERAL FLATTEN(input => r.terms:products) p
WHERE p.value:product        IS NOT NULL
  AND p.value:contract_rate  IS NOT NULL
  AND p.value:contract_rate::FLOAT > 0;

-- ============================================================================
-- 3. Account-level terms. COALESCE to the same neutral values 03 uses (0 / NULL
--    meaning "clause absent") so the two arms are compared like for like.
--    TRY_TO_DATE, not TO_DATE: a malformed date from the model must become NULL
--    rather than abort the load.
-- ============================================================================
INSERT INTO CONTRACT_META (customer_id, customer_name, discount_pct, discount_valid_through, min_monthly_commit, extraction_method)
SELECT
    r.customer_id,
    r.customer_name,
    COALESCE(r.terms:discount_pct::FLOAT, 0),
    TRY_TO_DATE(r.terms:discount_valid_through::STRING),
    COALESCE(r.terms:min_monthly_commit::FLOAT, 0),
    'cortex'
FROM CORTEX_EXTRACTION_RAW r;

-- ============================================================================
-- VERIFICATION -- the whole point is the COMPARISON, so every check is side by side.
-- ============================================================================
-- Coverage. Expect 12 customers on both arms; term counts should match closely.
SELECT extraction_method,
       COUNT(DISTINCT customer_id)  AS customers,
       COUNT(*)                     AS term_rows
FROM CONTRACT_TERMS
GROUP BY extraction_method
ORDER BY extraction_method;

-- Guardrail: every billed (customer, product) pair must have a Cortex term, or
-- 04's rate check silently skips those rows. Expect zero rows -- any row here is
-- a product name the model transcribed differently from the billing data.
SELECT DISTINCT b.customer_id, b.customer_name, b.product
FROM        BILLING_RECORDS b
LEFT JOIN   CONTRACT_TERMS t
       ON   t.customer_id       = b.customer_id
      AND   t.product           = b.product
      AND   t.extraction_method = 'cortex'
WHERE t.product IS NULL
ORDER BY b.customer_id, b.product;

-- Terms the two arms DISAGREE on. This is the interesting table: a rate present
-- on one arm and absent on the other, or the same product priced differently.
SELECT
    COALESCE(g.customer_id, x.customer_id)      AS customer_id,
    COALESCE(g.product, x.product)              AS product,
    g.contract_rate                             AS regex_rate,
    x.contract_rate                             AS cortex_rate,
    CASE
        WHEN g.product IS NULL THEN 'cortex only'
        WHEN x.product IS NULL THEN 'regex only'
        ELSE 'rate differs'
    END                                         AS disagreement
FROM            (SELECT * FROM CONTRACT_TERMS WHERE extraction_method = 'regex_baseline') g
FULL OUTER JOIN (SELECT * FROM CONTRACT_TERMS WHERE extraction_method = 'cortex')         x
           ON   x.customer_id = g.customer_id
          AND   x.product     = g.product
WHERE g.product IS NULL
   OR x.product IS NULL
   OR ABS(COALESCE(g.contract_rate, 0) - COALESCE(x.contract_rate, 0)) > 0.0001
ORDER BY customer_id, product;

-- Account-level terms, side by side. Expect the two arms to agree on all three.
SELECT
    g.customer_id,
    g.discount_pct           AS regex_disc,   x.discount_pct           AS cortex_disc,
    g.discount_valid_through AS regex_expiry, x.discount_valid_through AS cortex_expiry,
    g.min_monthly_commit     AS regex_min,    x.min_monthly_commit     AS cortex_min
FROM        (SELECT * FROM CONTRACT_META WHERE extraction_method = 'regex_baseline') g
JOIN        (SELECT * FROM CONTRACT_META WHERE extraction_method = 'cortex')         x
       ON   x.customer_id = g.customer_id
ORDER BY g.customer_id;
