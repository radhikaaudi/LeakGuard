---
name: leakguard-contract-intel
description: "Extract structured commercial terms from unstructured LeakGuard contract prose using Cortex. Use when: the user wants to extract or re-extract contract terms, parse contracts, compare AI extraction against the regex baseline, or investigate a term the detector seems to be missing. Triggers: extract contract terms, re-extract, parse contracts, contract intelligence, contract extraction, regex vs AI extraction, missing contract term, wrong contract rate."
---

# contract-intel

Turns contract prose into rows. `BILLING_RECORDS` says what we charged; the
contract says what we were *allowed* to charge, and you cannot compare those
until the contract stops being prose.

## Two arms, both live

| Arm | Script | `extraction_method` |
|---|---|---|
| Regex baseline (control) | `snowflake/03_extract_terms.sql` | `regex_baseline` |
| Cortex (treatment) | `snowflake/03b_extract_terms_cortex.sql` | `cortex` |

Both write into the **same** `CONTRACT_TERMS` / `CONTRACT_META` tables. Each
script deletes only its own `extraction_method` rows before reloading, so
running one never disturbs the other. Preserve that property in any change you
make — it is what keeps the comparison valid.

## Running it

```bash
snow sql -f snowflake/03b_extract_terms_cortex.sql -c default
```

Costs one inference call per contract (12). The raw JSON lands in
`CORTEX_EXTRACTION_RAW` first so both INSERTs read one inference pass — inspect
that table when an extraction looks wrong rather than re-running blind.

## Verify — all three, every time

```sql
-- 1. Coverage: expect 12 customers / 42 terms on BOTH arms.
SELECT extraction_method, COUNT(DISTINCT customer_id) AS customers, COUNT(*) AS terms
FROM CONTRACT_TERMS GROUP BY extraction_method;

-- 2. Every billed (customer, product) MUST have a term. Expect zero rows.
--    A row here means the model transcribed a product name differently from the
--    billing data, and 04's rate check will SILENTLY SKIP those invoices --
--    recall drops with no error anywhere.
SELECT DISTINCT b.customer_id, b.product
FROM BILLING_RECORDS b
LEFT JOIN CONTRACT_TERMS t
       ON t.customer_id = b.customer_id AND t.product = b.product
      AND t.extraction_method = 'cortex'
WHERE t.product IS NULL;

-- 3. No term may be NULL or non-positive. Expect zero rows.
SELECT * FROM CONTRACT_TERMS
WHERE extraction_method = 'cortex'
  AND (product IS NULL OR contract_rate IS NULL OR contract_rate <= 0);
```

Then re-run detection and scoring — extraction changes are meaningless until
scored:

```sql
CALL SP_BILLING_RECONCILER();
SELECT detected_by, COUNT_IF(outcome='TP') tp, COUNT_IF(outcome='FP') fp, COUNT_IF(outcome='FN') fn
FROM V_EVALUATION GROUP BY detected_by;
```

## Reporting the comparison honestly

Current measured result: the two arms produce **identical** output — 42 terms
each, zero rate disagreements, zero account-term disagreements, both scoring
35/35.

Say so plainly. The generated contracts use three phrasings per clause, which is
exactly the case regex handles well, so a tie is the expected and correct
outcome. The AI arm earns its place on *unseen* phrasings — a property this
corpus cannot demonstrate.

**Do not** report the tie as an AI win, and do not quietly omit it. If the user
wants to actually demonstrate the difference, the honest path is to add contracts
with adversarial phrasings (rate stated in words, table layout, unusual clause
order) and re-score — the regex arm should lose terms while the Cortex arm holds.

## Structured output, not prose parsing

`03b` passes a `response_format` JSON schema so Cortex returns a validated
object. Do not switch this to free-text-plus-regex — that would reintroduce the
exact fragility the AI arm exists to remove.

Response shape, if you need to touch the extraction path:

```
{ "structured_output": [ { "raw_message": {...}, "type": "json" } ], "usage": {...} }
```

Hence `...:structured_output[0]:raw_message`. **Do not wrap the messages-array
form of `COMPLETE` in `PARSE_JSON`** — that form already returns an OBJECT and
you get `Invalid argument types for function 'PARSE_JSON': (OBJECT)`.
