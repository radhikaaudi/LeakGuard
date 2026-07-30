-- ============================================================================
-- LeakGuard — Milestones 4 & 6: the callable agent surface
-- ============================================================================
--   snow sql -f snowflake/07_agent_procedures.sql -c default
--
-- WHY THIS FILE EXISTS
-- --------------------
-- Milestones 1-5 and 7 are SCRIPTS -- a human runs them in order. An agent
-- needs something it can CALL. This file wraps the pipeline in stored
-- procedures so any orchestrator (CoCo CLI, a Snowflake TASK, a notebook, a
-- Cortex Agent tool definition, or a person with a SQL prompt) has one entry
-- point instead of a runbook.
--
-- A NOTE ON CoCo CLI, WRITTEN DELIBERATELY
-- ----------------------------------------
-- The CoCo CLI is NOT installed in this environment (there is no `coco` binary
-- and `snow` exposes no `coco`/`agent` subcommand as of 2026-07-30), so no CoCo
-- skill manifest in this repo has ever been executed. Rather than commit a
-- manifest whose schema is guessed and untested, the orchestration contract is
-- expressed here as procedures, which are real, callable, and verified.
--
-- Wiring this to CoCo later is then a thin mapping -- one skill per procedure:
--     contract-intel      -> 03b_extract_terms_cortex.sql   (see note below)
--     billing-reconciler  -> CALL SP_BILLING_RECONCILER()
--     action-drafter      -> CALL SP_ACTION_DRAFTER()
--     end-to-end          -> CALL SP_RUN_LEAKGUARD()
--
-- WHY contract-intel IS NOT A PROCEDURE HERE
-- ------------------------------------------
-- Its Cortex extraction prompt is ~40 lines and is the single most likely thing
-- to be tuned. Copying it into a procedure body would create two copies that
-- drift, and the wrong one would silently win. It stays in 03b, which is already
-- idempotent (it deletes only its own extraction_method rows before reloading).
-- If you later want it callable, move the prompt into a UDF and have both call
-- that -- one definition, two callers.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE LEAKGUARD_WH;
USE DATABASE LEAKGUARD;
USE SCHEMA CORE;

-- ============================================================================
-- SKILL 2: billing-reconciler
--   Re-derives findings for every extraction arm from V_CANDIDATE_LEAKS.
--   Deterministic -- no inference, no cost, safe to call as often as you like.
-- ============================================================================
CREATE OR REPLACE PROCEDURE SP_BILLING_RECONCILER()
RETURNS STRING
LANGUAGE SQL
COMMENT = 'Reconcile billing against contract terms; refresh LEAKAGE_FINDINGS. Deterministic, no AI.'
AS
$$
DECLARE
    n_found  INTEGER;
    n_kept   INTEGER;
BEGIN
    -- MEMO PRESERVATION. Findings are derived data and get rebuilt on every run,
    -- but draft_memo is NOT derived -- each one cost an inference call and may
    -- have been edited by a human. Deleting the rows would silently discard both,
    -- and because SP_ACTION_DRAFTER only fills memos that are NULL, the next call
    -- would happily re-bill all of them. So stash the memos, rebuild, re-attach.
    --
    -- Without this, one full orchestrator tick costs an inference call per
    -- finding, forever, for an unchanged answer.
    CREATE OR REPLACE TEMPORARY TABLE _memo_stash AS
    SELECT detected_by, customer_id, month, product, leak_type, draft_memo
    FROM   LEAKAGE_FINDINGS
    WHERE  draft_memo IS NOT NULL
      AND  detected_by IN ('sql_baseline', 'cortex');

    -- Clears only the arms it owns, so a future arm's rows are never collateral.
    DELETE FROM LEAKAGE_FINDINGS WHERE detected_by IN ('sql_baseline', 'cortex');

    INSERT INTO LEAKAGE_FINDINGS
           (customer_id, customer_name, month, product, leak_type,
            estimated_recovery, evidence, detected_by)
    SELECT  customer_id, customer_name, month, product, leak_type,
            estimated_recovery, evidence,
            CASE extraction_method
                WHEN 'regex_baseline' THEN 'sql_baseline'
                WHEN 'cortex'         THEN 'cortex'
                ELSE 'sql_' || extraction_method
            END
    FROM V_CANDIDATE_LEAKS;

    -- Re-attach on leak identity. A leak that no longer exists simply finds no
    -- row to attach to and its memo is dropped, which is correct.
    UPDATE LEAKAGE_FINDINGS f
    SET    draft_memo = s.draft_memo
    FROM   _memo_stash s
    WHERE  f.detected_by = s.detected_by
      AND  f.customer_id = s.customer_id
      AND  f.month       = s.month
      AND  f.product     = s.product
      AND  f.leak_type   = s.leak_type;

    n_kept := SQLROWCOUNT;

    SELECT COUNT(*) INTO n_found FROM LEAKAGE_FINDINGS WHERE detected_by IS NOT NULL;
    RETURN 'billing-reconciler: ' || n_found || ' findings across all arms ('
           || n_kept || ' existing memo(s) preserved).';
END;
$$;

-- ============================================================================
-- SKILL 3: action-drafter
--   Drafts a correction memo per finding that lacks one. COSTS ONE INFERENCE
--   CALL PER UNDRAFTED FINDING, so the IS NULL guard is load-bearing, not
--   cosmetic: without it every orchestrator tick would re-bill the whole table
--   and overwrite memos a human had edited.
--
--   The prompt is intentionally shorter than 06_draft_memos.sql's. 06 is the
--   reviewed, guard-railed artefact; this is the callable path. If they diverge
--   in ways that matter, collapse them into one UDF -- see the header note.
-- ============================================================================
CREATE OR REPLACE PROCEDURE SP_ACTION_DRAFTER(TARGET_ARM STRING)
RETURNS STRING
LANGUAGE SQL
COMMENT = 'Draft an internal correction memo per undrafted finding, via Cortex. Bills one call per row drafted.'
AS
$$
DECLARE
    n_drafted INTEGER;
    n_left    INTEGER;
BEGIN
    UPDATE LEAKAGE_FINDINGS
    SET draft_memo = SNOWFLAKE.CORTEX.COMPLETE(
        'claude-sonnet-4-5',
        'You are a revenue-assurance analyst. Our billing system UNDER-CHARGED a '
          || 'customer against their signed contract. We are recovering revenue we '
          || 'failed to invoice -- this is NOT a refund and NOT an apology. Write a '
          || 'short INTERNAL memo to the account owner for review; do not address '
          || 'the customer. Start with "MEMO:" and a one-line subject, no preamble. '
          || 'Under 130 words. Cite the contract term and the invoice evidence. End '
          || 'with a line starting "Recommended action:". Do not invent clauses, '
          || 'dates or invoice numbers beyond those given.'
          || CASE WHEN leak_type = 'missing_charge'
                  THEN ' CRITICAL: the invoice line is absent so the units are '
                       || 'unknown and this amount is an ESTIMATE from a monthly '
                       || 'average -- say so explicitly and require confirmation '
                       || 'against usage records before any invoice is raised.'
                  ELSE '' END
          || '\n\nCustomer: '   || customer_name
          || '\nPeriod: '       || month
          || '\nProduct: '      || product
          || '\nLeak type: '    || leak_type
          || '\nUnder-billed: $' || TO_VARCHAR(ROUND(estimated_recovery, 2))
          || '\nEvidence: '     || evidence
    )
    WHERE detected_by = :TARGET_ARM
      AND draft_memo IS NULL;

    n_drafted := SQLROWCOUNT;

    SELECT COUNT(*) INTO n_left
    FROM LEAKAGE_FINDINGS
    WHERE detected_by = :TARGET_ARM AND draft_memo IS NULL;

    RETURN 'action-drafter: drafted ' || n_drafted || ' memo(s) for arm '''
           || :TARGET_ARM || '''; ' || n_left || ' still undrafted.';
END;
$$;

-- ============================================================================
-- ORCHESTRATOR: the single entry point.
--   reconcile -> draft -> score, returning a one-line report. This is what an
--   agent calls; everything above is a step it can also call individually.
--
--   Extraction is deliberately NOT re-run here. It is the only expensive,
--   rarely-changing step (one inference per contract), and contracts do not
--   change between reconciliation runs -- so re-extracting on every tick would
--   burn credits to recompute an identical answer. Run 03/03b when the contract
--   corpus changes, not when billing does.
-- ============================================================================
CREATE OR REPLACE PROCEDURE SP_RUN_LEAKGUARD(TARGET_ARM STRING)
RETURNS STRING
LANGUAGE SQL
COMMENT = 'End-to-end LeakGuard run: reconcile billing, draft memos, return the scorecard.'
AS
$$
DECLARE
    r_reconcile STRING;
    r_draft     STRING;
    tp INTEGER; fp INTEGER; fn INTEGER;
    recoverable FLOAT;
BEGIN
    CALL SP_BILLING_RECONCILER()            INTO :r_reconcile;
    CALL SP_ACTION_DRAFTER(:TARGET_ARM)     INTO :r_draft;

    SELECT COUNT_IF(outcome = 'TP'), COUNT_IF(outcome = 'FP'), COUNT_IF(outcome = 'FN')
      INTO :tp, :fp, :fn
    FROM V_EVALUATION
    WHERE detected_by = :TARGET_ARM;

    -- Confirmed value only: what the verified leaks are actually worth, not the
    -- detector's estimate. The two differ because missing_charge is estimated.
    SELECT COALESCE(ROUND(SUM(g.estimated_recovery), 2), 0)
      INTO :recoverable
    FROM        V_EVALUATION e
    JOIN        GROUND_TRUTH_LEAKS g
           ON   g.customer_id = e.customer_id AND g.month     = e.month
          AND   g.product     = e.product     AND g.leak_type = e.leak_type
    WHERE e.outcome = 'TP' AND e.detected_by = :TARGET_ARM;

    RETURN r_reconcile || ' | ' || r_draft
           || ' | score: ' || tp || ' confirmed, ' || fp || ' false alarm(s), '
           || fn || ' missed | confirmed recoverable: $' || recoverable;
END;
$$;

-- ============================================================================
-- VERIFICATION -- call the orchestrator end to end.
-- Expect: 70 findings across both arms, 0 memos newly drafted (06 already did
-- them), 35 confirmed / 0 false alarms / 0 missed, $185,783.70 recoverable.
-- ============================================================================
CALL SP_RUN_LEAKGUARD('sql_baseline');

SHOW PROCEDURES LIKE 'SP_%' IN SCHEMA LEAKGUARD.CORE;
