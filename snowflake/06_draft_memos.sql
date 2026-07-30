-- ============================================================================
-- LeakGuard — Milestone 3, Step 6: Draft the correction memo (CORTEX)
-- ============================================================================
--   snow sql -f snowflake/06_draft_memos.sql -c default
--
-- WHY THIS FILE EXISTS
-- --------------------
-- Everything up to 05 makes LeakGuard an ANALYST: it finds leaks and proves it
-- found them. This file is what makes it an AGENT -- it takes an action a human
-- would otherwise take, writing a reviewable artefact back into Snowflake.
-- LEAKAGE_FINDINGS.draft_memo has existed since 01_setup.sql and been empty
-- ever since. This fills it.
--
-- WHY THIS IS THE RIGHT PLACE FOR AI (and 04 was not)
-- --------------------------------------------------
-- 04 deliberately keeps detection in deterministic SQL, because arithmetic
-- should be arithmetic and nobody trusts "the LLM says $185k is missing".
-- Drafting is the opposite kind of problem: there is no correct answer to
-- compute, the output is prose, and a human reviews it before it goes anywhere.
-- That is exactly where a model earns its place.
--
-- MODEL: claude-sonnet-4-5 -- the newest Claude this account serves. If it
-- starts returning 400, re-run the probe in 00_enable_cortex.sql rather than
-- guessing a name; note that 'claude-4-5-sonnet' is NOT a valid alias.
--
-- COST + IDEMPOTENCE: one inference call per finding (35 today). The WHERE
-- clause only touches rows where draft_memo IS NULL, so re-running this file is
-- free and will not re-bill or overwrite a memo a human has already edited.
-- To deliberately regenerate, run the reset statement at the bottom first.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE LEAKGUARD_WH;
USE DATABASE LEAKGUARD;
USE SCHEMA CORE;

-- ============================================================================
-- 1. DRAFT. One memo per un-drafted finding.
--
--    Three things the prompt does deliberately:
--
--    a) It states the DIRECTION of the error. Revenue leakage means WE
--       under-billed, so the action is to recover -- not to refund. A model
--       given only "discrepancy of $X" will sometimes draft an apology for
--       overcharging, which is exactly backwards and reads terribly in a demo.
--
--    b) It is an INTERNAL memo to the account owner, not a letter to the
--       customer. The agent should not draft outbound customer claims off an
--       unreviewed finding, and for missing_charge the dollar figure is an
--       estimate (see 05, section 5) -- so the memo has to say so rather than
--       assert a precise number at a customer.
--
--    c) It bans the preamble. Without this you get "Here is a draft memo:"
--       glued to the front of every row, which then has to be stripped
--       downstream. Cheaper to just ask for the artefact.
-- ============================================================================
UPDATE LEAKAGE_FINDINGS
SET draft_memo = SNOWFLAKE.CORTEX.COMPLETE(
    'claude-sonnet-4-5',
    'You are a revenue-assurance analyst. Our own billing system UNDER-CHARGED '
      || 'a customer against the terms of their signed contract. We are recovering '
      || 'revenue we failed to invoice -- this is NOT a refund and NOT an apology '
      || 'for overcharging.'
      || '\n\nWrite a short INTERNAL memo to the account owner so they can review '
      || 'and decide whether to raise a corrected invoice. Do not address the '
      || 'customer directly.'
      || '\n\nFINDING'
      || '\nCustomer: '        || customer_name
      || '\nBilling period: '  || month
      || '\nProduct: '         || product
      || '\nLeak type: '       || leak_type
      || '\nAmount under-billed: $' || TO_VARCHAR(ROUND(estimated_recovery, 2))
      || '\nEvidence: '        || evidence
      || '\n\nWHAT THIS LEAK TYPE MEANS: '
      || CASE leak_type
           WHEN 'rate_leak' THEN
             'We invoiced a lower unit rate than the contract entitles us to. '
             || 'The shortfall is the rate difference times the units billed, and '
             || 'is exact.'
           WHEN 'stale_discount' THEN
             'A promotional discount kept being applied after its contractual '
             || 'expiry date. The customer was not entitled to it in this period.'
           WHEN 'missing_charge' THEN
             'A product the contract prices was never invoiced at all this period. '
             || 'IMPORTANT: because the invoice line is absent, the units are '
             || 'unknown and the amount is an ESTIMATE from this customer''s '
             || 'monthly average. Say clearly in the memo that the figure must be '
             || 'confirmed against usage records before any invoice is raised.'
           WHEN 'minimum_commitment_leak' THEN
             'The month total fell below the contracted monthly minimum and no '
             || 'true-up was charged. The recoverable amount is the shortfall '
             || 'against the committed floor, not a usage charge.'
           ELSE 'Reconcile the invoice against the contract terms.'
         END
      || '\n\nREQUIREMENTS'
      || '\n- Start immediately with "MEMO:" and a one-line subject. No preamble, '
      || 'no "Here is", no restating these instructions.'
      || '\n- Under 130 words.'
      || '\n- Cite the specific contract term and the specific invoice evidence.'
      || '\n- End with one line beginning "Recommended action:".'
      || '\n- Neutral professional tone. No apology. Do not invent contract '
      || 'clauses, dates, invoice numbers, or names beyond those given above.'
)
WHERE detected_by = 'sql_baseline'
  AND draft_memo IS NULL;

-- ============================================================================
-- VERIFICATION
-- ============================================================================
-- Coverage: expect drafted = 35, still_empty = 0.
SELECT
    COUNT(*)                                                     AS findings,
    COUNT(draft_memo)                                            AS drafted,
    COUNT(*) - COUNT(draft_memo)                                 AS still_empty,
    ROUND(AVG(LENGTH(draft_memo)), 0)                            AS avg_memo_chars
FROM LEAKAGE_FINDINGS
WHERE detected_by = 'sql_baseline';

-- Guardrail 1: no memo should have leaked the banned preamble. Expect 0 rows.
SELECT customer_name, month, product, LEFT(draft_memo, 80) AS starts_with
FROM LEAKAGE_FINDINGS
WHERE detected_by = 'sql_baseline'
  AND draft_memo IS NOT NULL
  AND NOT draft_memo ILIKE 'MEMO:%';

-- Guardrail 2: every missing_charge memo must flag that its figure is an
-- estimate. This is the one place the agent could mislead a human into
-- invoicing a number we cannot actually support. Expect 0 rows.
SELECT customer_name, month, product, estimated_recovery
FROM LEAKAGE_FINDINGS
WHERE detected_by = 'sql_baseline'
  AND leak_type   = 'missing_charge'
  AND draft_memo IS NOT NULL
  AND NOT (draft_memo ILIKE '%estimat%' OR draft_memo ILIKE '%confirm%'
           OR draft_memo ILIKE '%verify%' OR draft_memo ILIKE '%unknown%');

-- Eyeball the two most valuable memos, one exact and one estimated.
SELECT leak_type, customer_name, month, product, estimated_recovery, draft_memo
FROM LEAKAGE_FINDINGS
WHERE detected_by = 'sql_baseline'
QUALIFY ROW_NUMBER() OVER (PARTITION BY leak_type ORDER BY estimated_recovery DESC) = 1
ORDER BY estimated_recovery DESC;

-- ============================================================================
-- RESET -- run this ALONE and on purpose when you want fresh drafts (e.g. after
-- editing the prompt above). It re-bills one inference call per finding.
--   UPDATE LEAKAGE_FINDINGS SET draft_memo = NULL WHERE detected_by = 'sql_baseline';
-- ============================================================================
