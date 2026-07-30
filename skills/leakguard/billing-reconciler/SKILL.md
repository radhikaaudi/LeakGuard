---
name: leakguard-billing-reconciler
description: "Reconcile LeakGuard billing records against contract terms to find revenue leaks, and score the detector against the answer key. Use when: the user wants to find leaks, run the audit, refresh findings, check how much revenue is recoverable, or ask how accurate the detector is. Triggers: find leaks, run the audit, reconcile billing, refresh findings, detect leaks, how much are we losing, recoverable revenue, precision, recall, F1, false positives, missed leaks, detector accuracy, rate leak, stale discount, missing charge, minimum commitment."
---

# billing-reconciler

Compares what we invoiced against what the contract entitled us to invoice.

## Run it

```sql
USE DATABASE LEAKGUARD; USE SCHEMA CORE; USE WAREHOUSE LEAKGUARD_WH;
CALL SP_BILLING_RECONCILER();
```

Deterministic — no inference, no cost, safe to call as often as you like. It
rebuilds findings for every extraction arm from `V_CANDIDATE_LEAKS` and preserves
existing `draft_memo` values across the rebuild.

**Do not write your own detection SQL.** `V_CANDIDATE_LEAKS` is the single
definition of what a leak is. A second definition would drift from it and the
wrong one would eventually win an argument.

## The four leak types

| Type | Rule | Amount |
|---|---|---|
| `rate_leak` | billed unit rate below the contracted rate | **exact** — rate delta × units billed |
| `stale_discount` | promo discount applied after its expiry | **exact** — discount that should not have been granted |
| `missing_charge` | a contracted product has no invoice line that month | **ESTIMATED** — see below |
| `minimum_commitment_leak` | month total below the contracted monthly minimum, no true-up | **exact** — the shortfall |

### `missing_charge` is estimated, and you must say so

Its evidence is an *absence*: the invoice row is gone, so the true unit count is
unrecoverable. The amount is derived from that customer/product's average across
the months that do exist — roughly **41% mean absolute error**. The leak's
*identity* (customer, month, product) is exact; only the dollar figure is not.

Never present a `missing_charge` amount as invoice-ready.

## Score it

Scoring is on leak **identity** — `(customer_id, month, product, leak_type)` —
deliberately not on dollar amount, so a correctly-identified leak is not marked
wrong over an estimation rounding difference.

```sql
SELECT detected_by,
       COUNT_IF(outcome='TP') AS found,
       COUNT_IF(outcome='FP') AS false_alarms,
       COUNT_IF(outcome='FN') AS missed,
       ROUND(COUNT_IF(outcome='TP')/NULLIF(COUNT_IF(outcome IN ('TP','FP')),0),4) AS precision,
       ROUND(COUNT_IF(outcome='TP')/NULLIF(COUNT_IF(outcome IN ('TP','FN')),0),4) AS recall
FROM V_EVALUATION GROUP BY detected_by ORDER BY detected_by;
```

For the full breakdown — per leak type, every miss with what was planted, every
false alarm with the evidence that misfired, dollar accuracy, business headline:

```bash
snow sql -f snowflake/05_evaluate.sql -c default
```

Expected today: both arms 35/35, 0 false alarms, 0 missed, precision = recall = 1.0000.

## When recall drops

Work in this order — the cause is almost never the detection SQL:

1. **A missing contract term.** Run the coverage check in `contract-intel`. A
   billed `(customer, product)` with no matching term is silently skipped by the
   rate check — no error, just a lower score.
2. **A leak type with no branch.** Check `GROUND_TRUTH_LEAKS.leak_type` against
   the four branches in `V_CANDIDATE_LEAKS`. This is exactly how
   `minimum_commitment_leak` was found missing.
3. **A sentinel-value mismatch.** `minimum_commitment_leak` has no product, so
   both the detector and the answer key use the literal string
   `'(account minimum)'`. If one side changes, every row of that type becomes a
   simultaneous false positive *and* false negative.

## When precision drops

A false positive is the expensive error in production — a dispute raised against
a customer who was billed correctly costs goodwill. Read the `evidence` string on
the offending row to see which rule misfired.

**Before adding a new detection branch, check how many rows it would flag against
the answer key's count for that type.** A branch that flags 30 months when one
leak was planted has just destroyed precision. Verify against the data first, not
after.

## A trap this pipeline has actually hit

A missing `WHERE` clause once made the rate-leak branch emit a row for every
billing record — 242 instead of 19 — and **the dollar total stayed identical**,
because a correctly-billed row yields a $0 shortfall. A sum will not reveal this.
Always check the *row count* per leak type, not just the total:

```sql
SELECT detected_by, leak_type, COUNT(*) AS found, ROUND(SUM(estimated_recovery),2) AS total
FROM LEAKAGE_FINDINGS WHERE detected_by IS NOT NULL
GROUP BY detected_by, leak_type ORDER BY detected_by, leak_type;
```

Expect per arm: rate_leak 19, missing_charge 10, stale_discount 5,
minimum_commitment_leak 1.
