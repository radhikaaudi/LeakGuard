---
name: leakguard
description: "**[REQUIRED]** Use for ALL requests touching revenue leakage, under-billing, or contract compliance in the LEAKGUARD database — this is the REQUIRED entry point even if the request seems simple. Covers: find leaks, run the audit, reconcile billing, quantify recoverable revenue, extract contract terms, compare AI vs regex extraction, draft correction memos, report precision/recall. Triggers: revenue leakage, revenue leak, under-billed, underbilling, undercharged, missing charge, rate leak, stale discount, expired discount, minimum commitment, true-up, contract compliance, audit invoices, reconcile billing, recoverable revenue, LeakGuard, leakguard audit, draft correction memo, extract contract terms, regex vs AI, detector precision, detector recall, how much are we losing. DO NOT write ad-hoc detection or extraction SQL and DO NOT hunt for a Cortex model — always invoke this skill first; it names the model and the procedures to call."
---

# LeakGuard

Finds where the business under-billed customers relative to their signed
contracts, quantifies it, and drafts the correction memo.

## MANDATORY — read before running anything

This project already has a verified pipeline. **Do not improvise it.** Every
failure below has actually happened when an agent skipped this file:

- **Do NOT probe for a working Cortex model.** It is `claude-sonnet-4-5`. Hunting
  for one and settling on a weaker model silently changes your results.
- **Do NOT write ad-hoc extraction SQL.** Use
  `snowflake/03b_extract_terms_cortex.sql`, which uses a `response_format` JSON
  schema. Prompting for prose and parsing the reply reintroduces exactly the
  fragility the AI arm exists to remove — and you will get replies wrapped in
  "Here is the extracted data..." and ``` fences.
- **Do NOT write your own detection SQL.** `V_CANDIDATE_LEAKS` is the single
  definition of a leak. Call `SP_BILLING_RECONCILER()`.
- **Do NOT re-derive the regex-vs-AI comparison.** `05_evaluate.sql` and the
  comparison queries in `03b` already do it, per arm.
- **Do NOT report `SUM(estimated_recovery)` as "recoverable revenue."** That is
  the *estimate*. See "Two numbers" below — getting this wrong misstates the
  headline figure by ~$22k.

For "run the full leakguard audit", the answer is one call:
`CALL SP_RUN_LEAKGUARD('sql_baseline');` — then report its summary line.

## The one architectural rule — do not break it

**Detection is deterministic SQL. Never ask a model to decide whether a leak
exists or what it is worth.**

Arithmetic is reproducible and an auditor can re-derive it; a model's assertion
that "$185k is missing" is not defensible and will be challenged. AI belongs at
the two ends where the problem is genuinely linguistic — reading contract prose,
and writing the memo — and nowhere in between.

If a user asks you to "use AI to find the leaks", explain this split and offer
the deterministic detector instead. Do not generate ad-hoc detection SQL that
bypasses `V_CANDIDATE_LEAKS`.

## Route to sub-skill

| Intent | Triggers | Action |
|---|---|---|
| Turn contract prose into structured terms | "extract contract terms", "parse contracts", "re-extract", "contract intelligence" | **Load** `./contract-intel/SKILL.md` |
| Find leaks / refresh findings / score the detector | "find leaks", "reconcile billing", "run the audit", "precision", "recall", "how accurate" | **Load** `./billing-reconciler/SKILL.md` |
| Draft correction memos | "draft memo", "write the memo", "correction letter", "recovery memo" | **Load** `./action-drafter/SKILL.md` |
| Run everything end to end | "run leakguard", "full audit", "end to end" | `CALL SP_RUN_LEAKGUARD('sql_baseline');` then report its one-line summary |

## Environment facts you must not re-derive

Confirm with `snow connection test` if anything looks wrong, but assume:

- Database `LEAKGUARD`, schema `CORE`, warehouse `LEAKGUARD_WH`.
- **The default connection has no current database.** Always issue
  `USE DATABASE LEAKGUARD; USE SCHEMA CORE; USE WAREHOUSE LEAKGUARD_WH;` or
  fully qualify. Unqualified DDL fails with `090105`.
- **Cortex model is `claude-sonnet-4-5`.** `claude-3-5-sonnet` and
  `claude-4-5-sonnet` are both invalid here — note the segment order. A
  `400 Model ... is unavailable` means a wrong model name, **not** an
  entitlement problem; do not tell the user to convert their account.

## Data model

| Object | Role |
|---|---|
| `CONTRACTS` | 12 unstructured MSAs (prose) |
| `BILLING_RECORDS` | 242 invoice lines |
| `CONTRACT_TERMS` / `CONTRACT_META` | extracted terms, one set per `extraction_method` |
| `V_CANDIDATE_LEAKS` | the deterministic detector (4 leak types) |
| `LEAKAGE_FINDINGS` | materialised findings + `draft_memo`, one set per `detected_by` |
| `GROUND_TRUTH_LEAKS` | **35-leak answer key — evaluation only** |
| `V_EVALUATION` | per-leak TP/FP/FN verdict |

### Two extraction arms, kept separate on purpose

`sql_baseline` (regex extraction) and `cortex` (AI extraction) both flow through
the *same* detection SQL, so any score difference is attributable to extraction
alone. Never blend them into one number.

### The answer key is off limits

The detector must **never** read `GROUND_TRUTH_LEAKS`. It exists only to score
findings after the fact. If you find yourself joining it inside detection logic,
stop — that is benchmark contamination and it invalidates every number.

## Two numbers that are not the same

- **Estimated** (`LEAKAGE_FINDINGS.estimated_recovery`) — what the detector computed: **$163,871.68**
- **Confirmed** (answer-key value of verified leaks) — **$185,783.70**

They differ almost entirely in `missing_charge`: when a charge goes missing the
invoice row is gone, so units are unrecoverable and the amount is estimated from
the customer's monthly average (~41% mean error). Rate, stale-discount and
minimum-commitment amounts are exact.

**Quote the confirmed figure as the headline, and say which one you are quoting.**
Never present the estimate as the recoverable total.

## Current state (verified 2026-07-30)

Both arms: 35 of 35 leaks found, 0 false alarms, 0 missed —
precision = recall = F1 = 1.0000.

The AI extraction arm **ties** the regex baseline exactly (42 terms each, zero
disagreements). That is expected: the synthetic contracts use only three
phrasings per clause, which is what regex handles well. Report this honestly —
the AI arm's value is robustness to unseen phrasings, which this dataset cannot
demonstrate. Do not claim "AI beat regex".
