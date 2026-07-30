-- ============================================================================
-- LeakGuard — Milestone 2, Step 4: Detect revenue leaks
-- ============================================================================
--   snow sql -f snowflake/04_detect_leaks.sql -c default
--
-- WHY THIS FILE EXISTS
-- --------------------
-- Now that the contract is rows (CONTRACT_TERMS / CONTRACT_META) and the
-- invoices are rows (BILLING_RECORDS), "did we undercharge?" becomes a JOIN.
--
-- A DESIGN POINT WORTH DEFENDING IN THE DEMO: detection is deterministic SQL,
-- not AI. Judges and auditors both distrust "the LLM said $2.3M is missing".
-- Arithmetic should be arithmetic. The AI belongs on the two ends where
-- language actually lives:
--     reading the contract  ->  03 (Cortex extraction)
--     writing the memo      ->  06 (Cortex drafting)
-- Everything in between is reproducible, auditable, and cheap to re-run.
--
-- THE FOUR LEAK TYPES (all 35 planted leaks are one of these):
--   rate_leak                billed a lower unit rate than the contract allows
--   stale_discount           applied a promo discount after its expiry date
--   missing_charge           a contracted product has no invoice line for that month
--   minimum_commitment_leak  month's invoiced total fell below the contracted
--                            monthly minimum and no true-up was charged
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE LEAKGUARD_WH;
USE DATABASE LEAKGUARD;
USE SCHEMA CORE;

-- Tag findings with their source so the regex baseline and the future Cortex
-- agent can coexist in one table and be compared.
ALTER TABLE LEAKAGE_FINDINGS ADD COLUMN IF NOT EXISTS detected_by STRING;

-- ============================================================================
-- The reusable detector. Built as a VIEW so the Cortex agent in Milestone 3
-- can query candidates directly instead of re-deriving this logic in a prompt.
-- ============================================================================
CREATE OR REPLACE VIEW V_CANDIDATE_LEAKS AS

-- ----------------------------------------------------------------------------
-- 1. RATE LEAK — billed rate is below the contracted rate.
--    The 0.9999 factor is a float-noise guard: rates are FLOATs, and an exact
--    `<` would flag pennies of representation error as a leak.
--    Recovery = the per-unit shortfall, times the units actually billed.
-- ----------------------------------------------------------------------------
SELECT
    b.customer_id,
    b.customer_name,
    b.month,
    b.product,
    t.extraction_method                                           AS extraction_method,
    'rate_leak'                                                   AS leak_type,
    ROUND((t.contract_rate - b.unit_rate_billed) * b.units, 2)    AS estimated_recovery,
    'Invoice ' || b.invoice_id || ': billed $' || ROUND(b.unit_rate_billed, 4)
      || '/unit vs contracted $' || ROUND(t.contract_rate, 4)
      || '/unit on ' || b.units || ' units.'                      AS evidence
FROM BILLING_RECORDS b
JOIN CONTRACT_TERMS t
      ON  t.customer_id       = b.customer_id
      AND t.product           = b.product
WHERE b.unit_rate_billed < t.contract_rate * 0.9999

UNION ALL

-- ----------------------------------------------------------------------------
-- 2. STALE DISCOUNT — a promo discount applied to a month after it expired.
--    LAST_DAY() is the correct comparison, not the 1st of the month: a discount
--    valid through 2026-03-31 is legitimate for all of 2026-03. Comparing
--    '2026-03-01' > '2026-03-31' would wrongly clear March; comparing the
--    month's LAST day catches April onward and only April onward.
--    Recovery = the discount that should never have been granted.
-- ----------------------------------------------------------------------------
SELECT
    b.customer_id,
    b.customer_name,
    b.month,
    b.product,
    m.extraction_method                                           AS extraction_method,
    'stale_discount'                                              AS leak_type,
    ROUND(b.units * t.contract_rate * m.discount_pct / 100.0, 2)  AS estimated_recovery,
    'Invoice ' || b.invoice_id || ': ' || ROUND(m.discount_pct, 1)
      || '% discount applied in ' || b.month
      || ' but entitlement expired ' || TO_CHAR(m.discount_valid_through, 'YYYY-MM-DD') || '.'
                                                                  AS evidence
FROM BILLING_RECORDS b
JOIN CONTRACT_META m
      ON  m.customer_id       = b.customer_id
JOIN CONTRACT_TERMS t
      ON  t.customer_id       = b.customer_id
      AND t.product           = b.product
      -- Terms and account-level clauses must come from the SAME extraction arm.
      -- Without this, a regex rate would be combined with a Cortex discount and
      -- the two arms would contaminate each other.
      AND t.extraction_method = m.extraction_method
WHERE b.discount_pct_applied  > 0
  AND m.discount_valid_through IS NOT NULL
  AND LAST_DAY(TO_DATE(b.month || '-01')) > m.discount_valid_through

UNION ALL

-- ----------------------------------------------------------------------------
-- 3. MISSING CHARGE — hardest of the three, because the evidence is an ABSENCE.
--
--    There is no usage feed in this dataset: when a charge goes missing the row
--    is simply gone, so nothing in BILLING_RECORDS points at it. We recover it
--    by reasoning about what SHOULD exist:
--        (every month the customer was invoiced at all)
--          x (every product their contract prices)
--        - (the invoice lines that actually exist)
--
--    Recovery must be ESTIMATED, since the true unit count vanished with the
--    row. We use that customer/product's average units across the months that
--    DO exist. Expect the amount to be approximate -- the leak identity
--    (customer, month, product) is what matters, and 05 scores on identity.
-- ----------------------------------------------------------------------------
SELECT
    e.customer_id,
    e.customer_name,
    e.month,
    e.product,
    e.extraction_method                                           AS extraction_method,
    'missing_charge'                                              AS leak_type,
    ROUND(e.avg_units * e.contract_rate, 2)                       AS estimated_recovery,
    'No invoice line for ' || e.product || ' in ' || e.month
      || ', though the contract prices it at $' || ROUND(e.contract_rate, 4)
      || '/unit and the customer averages ' || ROUND(e.avg_units, 0)
      || ' units/month. Estimated from ' || e.observed_months || ' other month(s).'
                                                                  AS evidence
FROM (
    SELECT
        cm.customer_id,
        t.customer_name,
        cm.month,
        t.product,
        t.contract_rate,
        t.extraction_method,
        COALESCE(u.avg_units, 0)      AS avg_units,
        COALESCE(u.n_months,  0)      AS observed_months
    FROM        (SELECT DISTINCT customer_id, month FROM BILLING_RECORDS) cm
    JOIN        CONTRACT_TERMS t
           ON   t.customer_id       = cm.customer_id
    LEFT JOIN   BILLING_RECORDS b
           ON   b.customer_id = cm.customer_id
          AND   b.month       = cm.month
          AND   b.product     = t.product
    LEFT JOIN   (SELECT customer_id, product,
                        AVG(units)  AS avg_units,
                        COUNT(*)    AS n_months
                 FROM BILLING_RECORDS GROUP BY 1, 2) u
           ON   u.customer_id = cm.customer_id
          AND   u.product     = t.product
    WHERE b.invoice_id IS NULL        -- the absence we are hunting
) e
WHERE e.avg_units > 0                 -- never invent a charge with no basis

UNION ALL

-- ----------------------------------------------------------------------------
-- 4. MINIMUM-COMMITMENT LEAK — the month's invoiced total fell below the
--    contracted monthly minimum, and no true-up line was ever charged.
--
--    This is the only leak type that is a property of the MONTH rather than of
--    a single invoice line, so it aggregates first and joins second. There is
--    no product involved, but V_CANDIDATE_LEAKS is a UNION and the scoring key
--    in 05 is (customer, month, product, leak_type) -- so we emit the sentinel
--    '(account minimum)', which is exactly the string the generator writes into
--    GROUND_TRUTH_LEAKS.product. Change one and you must change the other.
--
--    The -0.01 is a float-noise guard, same idea as the 0.9999 factor above: a
--    month landing exactly on the minimum must not be flagged over a fraction
--    of a cent. Recovery = the un-charged true-up.
--
--    Verified against this dataset: exactly one customer-month sits below its
--    minimum (customer 12, 2026-01, $3,852.96 vs $5,000.00), which is the one
--    planted leak -- so this branch adds recall without costing precision.
-- ----------------------------------------------------------------------------
SELECT
    m.customer_id,
    m.customer_name,
    t.month,
    '(account minimum)'                                           AS product,
    m.extraction_method                                           AS extraction_method,
    'minimum_commitment_leak'                                     AS leak_type,
    ROUND(m.min_monthly_commit - t.month_total, 2)                AS estimated_recovery,
    'Invoiced $' || ROUND(t.month_total, 2) || ' in ' || t.month
      || ' against a contracted monthly minimum of $' || ROUND(m.min_monthly_commit, 2)
      || '. No true-up was charged, so the $'
      || ROUND(m.min_monthly_commit - t.month_total, 2)
      || ' shortfall was never invoiced.'                         AS evidence
FROM (
    SELECT customer_id, month, SUM(amount_billed) AS month_total
    FROM BILLING_RECORDS
    GROUP BY 1, 2
) t
JOIN CONTRACT_META m
      ON  m.customer_id       = t.customer_id
WHERE m.min_monthly_commit > 0                    -- 0 means "clause absent"
  AND t.month_total < m.min_monthly_commit - 0.01;

-- ============================================================================
-- Materialise the findings. This is the table the agent will later write into
-- too; we clear only our own rows so the two sources never clobber each other.
-- ============================================================================
-- One findings row per (leak, extraction arm). The detector logic is identical
-- for both arms -- that is the whole point of the experiment. Any difference in
-- the 05 scorecard is therefore attributable to the EXTRACTION, not to
-- detection, which is what makes the comparison meaningful.
--
--   regex_baseline terms -> detected_by = 'sql_baseline'
--   cortex terms         -> detected_by = 'cortex'
--
-- 'sql_baseline' is kept rather than renamed to 'sql_regex_baseline' because
-- 05, 06 and the Streamlit app already reference it.
DELETE FROM LEAKAGE_FINDINGS WHERE detected_by IN ('sql_baseline', 'cortex');

INSERT INTO LEAKAGE_FINDINGS
       (customer_id, customer_name, month, product, leak_type,
        estimated_recovery, evidence, detected_by)
SELECT  customer_id, customer_name, month, product, leak_type,
        estimated_recovery, evidence,
        CASE extraction_method
            WHEN 'regex_baseline' THEN 'sql_baseline'
            WHEN 'cortex'         THEN 'cortex'
            ELSE 'sql_' || extraction_method   -- future arms get a label, not a NULL
        END
FROM V_CANDIDATE_LEAKS;

-- ============================================================================
-- VERIFICATION
-- ============================================================================
SELECT detected_by,
       leak_type,
       COUNT(*)                          AS found,
       ROUND(SUM(estimated_recovery), 2) AS total_recovery
FROM LEAKAGE_FINDINGS
WHERE detected_by IS NOT NULL
GROUP BY detected_by, leak_type
ORDER BY detected_by, total_recovery DESC;

SELECT leak_type, customer_name, month, product,
       estimated_recovery, LEFT(evidence, 90) AS evidence
FROM LEAKAGE_FINDINGS
WHERE detected_by = 'sql_baseline'
QUALIFY ROW_NUMBER() OVER (PARTITION BY leak_type ORDER BY estimated_recovery DESC) <= 2
ORDER BY leak_type;
