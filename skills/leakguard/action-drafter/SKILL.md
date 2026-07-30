---
name: leakguard-action-drafter
description: "Draft internal correction memos for confirmed LeakGuard revenue leaks using Cortex. Use when: the user wants to draft memos, write up a finding, produce a recovery memo, generate correction letters, or review what the agent would send. Triggers: draft memo, draft memos, write the memo, correction memo, recovery memo, correction letter, dispute letter, write up the finding, memo for the account owner, what would we send."
---

# action-drafter

Writes the artefact a human reviews. This is the step that makes LeakGuard an
agent rather than a report: it takes an action a person would otherwise take.

## Run it

```sql
CALL LEAKGUARD.CORE.SP_ACTION_DRAFTER('sql_baseline');
```

Fully qualify — `USE DATABASE` from a previous tool call does not persist.

Or the fuller, guard-railed version:

```bash
snow sql -f snowflake/06_draft_memos.sql -c default
```

Both fill `LEAKAGE_FINDINGS.draft_memo` and **only** where it is `NULL`.

## Cost — the `IS NULL` guard is load-bearing

One inference call per memo drafted. The guard means re-running is free and will
never overwrite a memo a human has edited. **Do not remove it**, and do not add a
blanket `SET draft_memo = ...` without a `WHERE draft_memo IS NULL`.

To deliberately regenerate (e.g. after changing the prompt), null the column
first — on purpose, knowing it re-bills:

```sql
UPDATE LEAKAGE_FINDINGS SET draft_memo = NULL WHERE detected_by = 'sql_baseline';
```

`SP_BILLING_RECONCILER` stashes and re-attaches memos across its rebuild, so a
full `SP_RUN_LEAKGUARD` tick does **not** silently re-bill. If you change the
reconciler, preserve that.

## Three things the prompt must keep doing

**1. State the direction of the error.** Revenue leakage means *we under-billed*.
Given only "a discrepancy of $X", a model will sometimes draft an apology for
*over*charging — exactly backwards, and it reads terribly in front of judges.

**2. Keep it internal.** The memo addresses the **account owner**, not the
customer, and ends with a `Recommended action:` line for a human to approve. The
agent must not draft outbound customer claims off an unreviewed finding —
especially not for `missing_charge`, where the amount is an estimate.

**3. Force the `missing_charge` caveat.** Those memos must state the figure is an
estimate requiring confirmation against usage records. This is the one place the
agent could mislead a human into invoicing a number the pipeline cannot support.

## Verify — both guardrails, expect zero rows each

```sql
-- Coverage: expect drafted = findings, still_empty = 0.
SELECT COUNT(*) AS findings, COUNT(draft_memo) AS drafted,
       COUNT(*) - COUNT(draft_memo) AS still_empty
FROM LEAKAGE_FINDINGS WHERE detected_by = 'sql_baseline';

-- Guardrail 1: no preamble leakage ("Here is a draft memo:").
SELECT customer_name, month, LEFT(draft_memo, 80)
FROM LEAKAGE_FINDINGS
WHERE detected_by = 'sql_baseline' AND draft_memo IS NOT NULL
  AND NOT draft_memo ILIKE 'MEMO:%';

-- Guardrail 2: every missing_charge memo flags its own uncertainty.
SELECT customer_name, month, product, estimated_recovery
FROM LEAKAGE_FINDINGS
WHERE detected_by = 'sql_baseline' AND leak_type = 'missing_charge'
  AND draft_memo IS NOT NULL
  AND NOT (draft_memo ILIKE '%estimat%' OR draft_memo ILIKE '%confirm%'
           OR draft_memo ILIKE '%verify%' OR draft_memo ILIKE '%unknown%');
```

If guardrail 2 returns rows, **do not hand those memos to anyone.** Strengthen
the prompt's caveat instruction and re-draft just the affected rows.

## Reading memos back

```sql
SELECT customer_name, month, product, leak_type, estimated_recovery, draft_memo
FROM LEAKAGE_FINDINGS
WHERE detected_by = 'sql_baseline'
ORDER BY estimated_recovery DESC LIMIT 5;
```

The Streamlit console (`LEAKGUARD.CORE.LEAKGUARD_CONSOLE`, "Draft memos" tab) is
the better surface for a human review pass — it pairs each memo with its evidence
and flags the estimated ones.

## Model

`claude-sonnet-4-5`. If it starts returning `400 ... is unavailable`, re-probe
with the `TRY_COMPLETE` block in `snowflake/00_enable_cortex.sql` rather than
guessing a name — and note `claude-4-5-sonnet` is **not** a valid alias.
