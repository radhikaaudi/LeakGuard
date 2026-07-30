-- ============================================================================
-- LeakGuard — Milestone 2, Step 5: Score the detector against the answer key
-- ============================================================================
--   snow sql -f snowflake/05_evaluate.sql -c default
--
-- WHY THIS FILE EXISTS
-- --------------------
-- 04 produces findings. Nothing so far says whether they are RIGHT. Without a
-- score, "LeakGuard found 35 leaks worth $162,724" is an unfalsifiable claim --
-- and an auditor's first question is "how do you know you didn't miss any?"
-- This file answers that in SQL, against the planted-leak answer key.
--
-- THE SCORING KEY is (customer_id, month, product, leak_type) -- the leak's
-- IDENTITY, deliberately not its dollar amount. Two reasons:
--   1. missing_charge recovery is ESTIMATED (04 averages the months that do
--      exist, because the true unit count vanished with the row). Scoring on
--      dollars would mark a correctly-identified leak wrong over rounding.
--   2. "which leaks exist" is the business question. Dollars are reported
--      separately below as an accuracy check, not as a pass/fail gate.
--
-- WHY IT PARTITIONS BY detected_by: LEAKAGE_FINDINGS holds rows from the regex
-- baseline today and from the Cortex agent later. Scoring per source means the
-- demo can say "AI found N leaks regex missed, here they are" with one query
-- instead of a hand-comparison. This file needs no edit when Cortex comes
-- online -- it picks up any new detected_by value automatically.
--
-- DEFINITIONS
--   TP  detector found a leak that is in the answer key
--   FP  detector reported a leak that is NOT in the answer key (false alarm)
--   FN  answer key has a leak the detector did not report (missed it)
--   precision = TP / (TP + FP)   "when it speaks, is it right?"
--   recall    = TP / (TP + FN)   "does it catch everything?"
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE LEAKGUARD_WH;
USE DATABASE LEAKGUARD;
USE SCHEMA CORE;

-- ============================================================================
-- The per-leak verdict. One row per (source, leak identity), labelled TP/FP/FN.
-- Everything below is an aggregate over this view.
-- ============================================================================
CREATE OR REPLACE VIEW V_EVALUATION AS
WITH
-- Every detector that has written findings. Drives the cross join below.
sources AS (
    SELECT DISTINCT detected_by
    FROM   LEAKAGE_FINDINGS
    WHERE  detected_by IS NOT NULL
),

-- DISTINCT because a re-run could double-insert; a leak found twice is still
-- one leak, and counting it twice would inflate TP.
found AS (
    SELECT DISTINCT detected_by, customer_id, month, product, leak_type
    FROM   LEAKAGE_FINDINGS
    WHERE  detected_by IS NOT NULL
),

-- The answer key, replicated once per detector. This is what makes a MISS
-- attributable: without the cross join, a leak that no detector found would
-- have no detected_by to hang the FN on, and would vanish from the score.
truth AS (
    SELECT s.detected_by, g.customer_id, g.month, g.product, g.leak_type
    FROM   GROUND_TRUTH_LEAKS g
    CROSS JOIN sources s
)

SELECT
    COALESCE(f.detected_by,  t.detected_by)  AS detected_by,
    COALESCE(f.customer_id,  t.customer_id)  AS customer_id,
    COALESCE(f.month,        t.month)        AS month,
    COALESCE(f.product,      t.product)      AS product,
    COALESCE(f.leak_type,    t.leak_type)    AS leak_type,
    CASE
        WHEN f.customer_id IS NOT NULL AND t.customer_id IS NOT NULL THEN 'TP'
        WHEN f.customer_id IS NOT NULL                               THEN 'FP'
        ELSE                                                              'FN'
    END                                      AS outcome
FROM        found f
FULL OUTER JOIN truth t
       ON   t.detected_by = f.detected_by
      AND   t.customer_id = f.customer_id
      AND   t.month       = f.month
      AND   t.product     = f.product
      AND   t.leak_type   = f.leak_type;

-- ============================================================================
-- 1. HEADLINE SCORECARD — one row per detector. This is the demo slide.
--    Expect the regex baseline at precision 1.0000 / recall 1.0000 once the
--    minimum-commitment branch in 04 is in place.
-- ============================================================================
SELECT
    detected_by,
    COUNT_IF(outcome = 'TP')                                     AS true_positives,
    COUNT_IF(outcome = 'FP')                                     AS false_positives,
    COUNT_IF(outcome = 'FN')                                     AS false_negatives,
    COUNT_IF(outcome IN ('TP', 'FP'))                            AS total_reported,
    COUNT_IF(outcome IN ('TP', 'FN'))                            AS total_actual,
    ROUND(COUNT_IF(outcome = 'TP')
          / NULLIF(COUNT_IF(outcome IN ('TP', 'FP')), 0), 4)     AS precision,
    ROUND(COUNT_IF(outcome = 'TP')
          / NULLIF(COUNT_IF(outcome IN ('TP', 'FN')), 0), 4)     AS recall,
    -- F1 = harmonic mean. Guards against a detector that games one metric:
    -- report everything (recall 1.0, precision awful) or report one certain
    -- leak (precision 1.0, recall awful). Both score badly here.
    ROUND(2 * COUNT_IF(outcome = 'TP')
          / NULLIF(2 * COUNT_IF(outcome = 'TP')
                   + COUNT_IF(outcome = 'FP')
                   + COUNT_IF(outcome = 'FN'), 0), 4)            AS f1
FROM V_EVALUATION
GROUP BY detected_by
ORDER BY f1 DESC;

-- ============================================================================
-- 2. PER-LEAK-TYPE BREAKDOWN — where a detector is strong or weak.
--    A single aggregate number hides that (for example) missing_charge is the
--    hardest type because its evidence is an absence.
-- ============================================================================
SELECT
    detected_by,
    leak_type,
    COUNT_IF(outcome = 'TP')                                     AS tp,
    COUNT_IF(outcome = 'FP')                                     AS fp,
    COUNT_IF(outcome = 'FN')                                     AS fn,
    ROUND(COUNT_IF(outcome = 'TP')
          / NULLIF(COUNT_IF(outcome IN ('TP', 'FP')), 0), 4)     AS precision,
    ROUND(COUNT_IF(outcome = 'TP')
          / NULLIF(COUNT_IF(outcome IN ('TP', 'FN')), 0), 4)     AS recall
FROM V_EVALUATION
GROUP BY detected_by, leak_type
ORDER BY detected_by, fn DESC, leak_type;

-- ============================================================================
-- 3. EVERY MISS (FN) — the leaks that got away, with what they were worth.
--    Expect zero rows. Any row here is a detection-logic gap in 04, and the
--    ground-truth detail column tells you exactly what to go build.
-- ============================================================================
SELECT
    e.detected_by,
    e.leak_type,
    g.customer_name,
    e.month,
    e.product,
    g.estimated_recovery                                         AS missed_dollars,
    g.detail                                                     AS what_was_planted
FROM        V_EVALUATION e
JOIN        GROUND_TRUTH_LEAKS g
       ON   g.customer_id = e.customer_id
      AND   g.month       = e.month
      AND   g.product     = e.product
      AND   g.leak_type   = e.leak_type
WHERE  e.outcome = 'FN'
ORDER BY missed_dollars DESC;

-- ============================================================================
-- 4. EVERY FALSE ALARM (FP) — what the detector invented.
--    Expect zero rows. These are the expensive errors in production: a dispute
--    letter sent to a customer who was billed correctly costs goodwill, not
--    just time. The evidence string shows which rule misfired.
-- ============================================================================
SELECT
    e.detected_by,
    e.leak_type,
    f.customer_name,
    e.month,
    e.product,
    f.estimated_recovery                                         AS claimed_dollars,
    LEFT(f.evidence, 120)                                        AS claimed_evidence
FROM        V_EVALUATION e
JOIN        LEAKAGE_FINDINGS f
       ON   f.detected_by = e.detected_by
      AND   f.customer_id = e.customer_id
      AND   f.month       = e.month
      AND   f.product     = e.product
      AND   f.leak_type   = e.leak_type
WHERE  e.outcome = 'FP'
ORDER BY claimed_dollars DESC;

-- ============================================================================
-- 5. DOLLAR ACCURACY on correctly-identified leaks (TP only).
--
--    Reported SEPARATELY from precision/recall on purpose -- this is a
--    diagnostic, not a grade. rate_leak and stale_discount are computed from
--    real invoice rows and should land within pennies. missing_charge is
--    ESTIMATED from a customer/product monthly average (the true unit count
--    vanished with the deleted row), so expect visible error there and do not
--    read it as a bug. Saying this out loud is the honest framing in a demo.
-- ============================================================================
SELECT
    e.detected_by,
    e.leak_type,
    COUNT(*)                                                     AS leaks_scored,
    ROUND(SUM(f.estimated_recovery), 2)                          AS detected_total,
    ROUND(SUM(g.estimated_recovery), 2)                          AS actual_total,
    ROUND(SUM(f.estimated_recovery) - SUM(g.estimated_recovery), 2) AS dollar_error,
    -- Mean absolute percentage error, per leak, so one huge leak doesn't mask
    -- systematic error on the small ones.
    ROUND(AVG(ABS(f.estimated_recovery - g.estimated_recovery)
              / NULLIF(g.estimated_recovery, 0)) * 100, 1)       AS mean_abs_pct_error
FROM        V_EVALUATION e
JOIN        LEAKAGE_FINDINGS f
       ON   f.detected_by = e.detected_by
      AND   f.customer_id = e.customer_id
      AND   f.month       = e.month
      AND   f.product     = e.product
      AND   f.leak_type   = e.leak_type
JOIN        GROUND_TRUTH_LEAKS g
       ON   g.customer_id = e.customer_id
      AND   g.month       = e.month
      AND   g.product     = e.product
      AND   g.leak_type   = e.leak_type
WHERE  e.outcome = 'TP'
GROUP BY e.detected_by, e.leak_type
ORDER BY e.detected_by, ABS(ROUND(SUM(f.estimated_recovery) - SUM(g.estimated_recovery), 2)) DESC;

-- ============================================================================
-- 6. THE BUSINESS HEADLINE — total recoverable, by leak type.
--    The number that goes on the slide. Only counts CONFIRMED leaks (TP), so
--    it is a defensible figure rather than the detector's raw output.
-- ============================================================================
SELECT
    e.detected_by,
    e.leak_type,
    COUNT(*)                                                     AS confirmed_leaks,
    ROUND(SUM(g.estimated_recovery), 2)                          AS recoverable_dollars
FROM        V_EVALUATION e
JOIN        GROUND_TRUTH_LEAKS g
       ON   g.customer_id = e.customer_id
      AND   g.month       = e.month
      AND   g.product     = e.product
      AND   g.leak_type   = e.leak_type
WHERE  e.outcome = 'TP'
GROUP BY ROLLUP(e.detected_by, e.leak_type)
ORDER BY e.detected_by, recoverable_dollars DESC;
