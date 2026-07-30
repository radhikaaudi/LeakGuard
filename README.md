# LeakGuard 🛡️

**An autonomous Revenue-Leakage & Contract-Compliance agent, built on Snowflake CoCo CLI + Cortex.**

LeakGuard reads customer **contracts** (unstructured), reconciles them against **actual
billing & usage** (structured) inside Snowflake, finds where the business is
**under-billing or breaching terms**, explains each gap with evidence, and **takes
action** — writing a recovery record back to Snowflake and drafting a correction memo.

---

## The problem
B2B companies (SaaS, telecom, utilities, logistics) lose an estimated **1–5% of revenue**
to *leakage*: usage that drifts from contract terms, missed true-ups, expired discounts
left running, and un-invoiced line items. Today this is caught by **manual quarterly
audits** — slow, sampled (not 100%), and months late.

## The solution: an agent that never stops auditing
Instead of a human sampling a few contracts per quarter, LeakGuard checks **every**
contract against **every** invoice, continuously, and drafts the fix.

## How it works (agent loop)
1. **Read** the contract → extract pricing terms, minimums, discounts, caps.
2. **Reconcile** against actual billing/usage in Snowflake.
3. **Reason** about each discrepancy (is it a real leak? how much? why?).
4. **Act** → write a recovery record + draft a dispute/correction memo.
5. **Loop / branch** → handle missing data, ambiguous clauses, no-match cases.

## Architecture (target)
- **Snowflake** — stores contracts + billing in one place.
- **Cortex** — runs the AI *inside* Snowflake (Search for contract retrieval, Analyst for
  billing SQL, AISQL for extraction/reasoning).
- **CoCo CLI** — orchestrates 3 modular Agent Skills into the end-to-end workflow:
  - `contract-intel` — parse & extract contract terms.
  - `billing-reconciler` — query billing, compare to terms, compute gaps.
  - `action-drafter` — write recovery record + draft memo.

## Leakage types LeakGuard detects
| Type | What it means | Planted | Found |
|---|---|---|---|
| **Rate leak** | Customer billed at a *lower* unit rate than the contract states. | 19 | 19 |
| **Missing charge** | A contracted, billable product was never invoiced for a period. | 10 | 10 |
| **Stale discount** | A promotional discount kept being applied *after* its expiry date. | 5 | 5 |
| **Minimum-commitment leak** | Usage fell below the contracted monthly minimum, but no true-up was charged. | 1 | 1 |

## Current results (deterministic SQL baseline)
Scored by `snowflake/05_evaluate.sql` against the 35-leak answer key, on the
identity key `(customer_id, month, product, leak_type)`:

| Metric | Value |
|---|---|
| Precision | **1.0000** (0 false alarms) |
| Recall | **1.0000** (0 missed leaks) |
| F1 | **1.0000** |
| Confirmed recoverable | **$185,783.70** across 12 customers / 6 months |

Dollar accuracy is exact for rate, stale-discount, and minimum-commitment leaks.
`missing_charge` amounts carry ~41% mean absolute error **by design** — when a
charge goes missing the row is simply gone, so the true unit count is
unrecoverable and the amount is estimated from that customer/product's monthly
average. The leak *identity* is exact; only the dollar estimate is approximate.

## Repo layout
```
leakGuard/
├── README.md
├── data/
│   ├── generate_data.py       # generates synthetic contracts + billing + planted leaks
│   ├── contracts/             # unstructured contract files (agent reads these)
│   ├── billing/               # structured billing CSV (loads into Snowflake)
│   └── ground_truth/          # answer key of planted leaks (for evaluation)
└── snowflake/
    ├── 00_enable_cortex.sql   # account-level Cortex prerequisites + gate check
    ├── 01_setup.sql           # warehouse, database, schema, stage, tables
    ├── 02_load_data.sql       # COPY the three CSVs into tables
    ├── 03_extract_terms.sql   # contract prose -> CONTRACT_TERMS (regex baseline)
    ├── 03b_extract_terms_cortex.sql  # SAME job via Cortex (the AI arm)
    ├── 04_detect_leaks.sql    # deterministic detection, both arms -> LEAKAGE_FINDINGS
    ├── 05_evaluate.sql        # precision / recall / F1 vs the answer key, per arm
    ├── 06_draft_memos.sql     # Cortex drafts a correction memo per finding
    └── 07_agent_procedures.sql # callable stored procs + SP_RUN_LEAKGUARD orchestrator
├── streamlit/
│   ├── leakguard_app.py      # the console (Streamlit in Snowflake)
│   └── environment.yml
└── skills/leakguard/         # Cortex Code (CoCo CLI) Agent Skills
    ├── SKILL.md              #   router
    ├── contract-intel/       #   Milestone 3
    ├── billing-reconciler/   #   Milestone 4
    └── action-drafter/       #   Milestone 5
```

**Where the AI is, and is not.** Detection (`04`) is deterministic SQL on
purpose — arithmetic should be arithmetic, and a recovery figure an auditor can
re-derive beats one a model asserted. Cortex is used at the two ends where the
problem is genuinely linguistic: reading contract prose into structured terms,
and drafting the memo (`06`). Scoring (`05`) sits in between and is the gate.

## Run order
```bash
snow sql -f snowflake/00_enable_cortex.sql -c default   # steps 1-4 always; step 5 is the Cortex gate
snow sql -f snowflake/01_setup.sql -c default
snow stage copy "data\billing\billing_records.csv"     "@LEAKGUARD.CORE.LEAKGUARD_STAGE/billing/"      -c default
snow stage copy "data\contracts\contracts.csv"         "@LEAKGUARD.CORE.LEAKGUARD_STAGE/contracts/"    -c default
snow stage copy "data\ground_truth\planted_leaks.csv"  "@LEAKGUARD.CORE.LEAKGUARD_STAGE/ground_truth/" -c default
snow sql -f snowflake/02_load_data.sql -c default
snow sql -f snowflake/03_extract_terms.sql -c default
snow sql -f snowflake/04_detect_leaks.sql -c default
snow sql -f snowflake/05_evaluate.sql -c default
snow sql -f snowflake/03b_extract_terms_cortex.sql -c default   # needs Cortex
snow sql -f snowflake/06_draft_memos.sql -c default             # needs Cortex
snow sql -f snowflake/07_agent_procedures.sql -c default
snow streamlit deploy leakguard_app --replace -c default        # the UI
```

Once `07` is loaded, the whole pipeline is one call:

```sql
CALL SP_RUN_LEAKGUARD('sql_baseline');
-- billing-reconciler: 70 findings across all arms (35 existing memo(s) preserved).
--   | action-drafter: drafted 0 memo(s) ... | score: 35 confirmed, 0 false alarm(s),
--   0 missed | confirmed recoverable: $185783.7
```

Repeat calls are free: memos are preserved across reconciliation, so the drafter
re-bills nothing.

## Status
- [x] Milestone 1 — Synthetic data foundation
- [x] Milestone 2 — Snowflake load + deterministic detection (35/35, P=R=F1=1.0)
- [x] Milestone 7 — Evaluation harness *(built early; it is the gate for everything below)*
- [x] Milestone 5 — `action-drafter` (`06_draft_memos.sql`, 35/35 memos drafted)
- [x] Milestone 3 — `contract-intel` (`03b_extract_terms_cortex.sql`, Cortex extraction)
- [x] Milestone 4 — `billing-reconciler` (`SP_BILLING_RECONCILER`)
- [x] Milestone 8 — Demo UI (`streamlit/leakguard_app.py`, deployed)
- [x] Milestone 6 — CoCo orchestrator: Cortex Code skills in `skills/leakguard/`,
      registered and verified end to end

### Agent Skills (Cortex Code / CoCo CLI)

The CLI is **Cortex Code** (`cortex`, v1.1.47) — not a `coco` binary, which is
why an earlier note in this repo wrongly recorded it as missing.

```
skills/leakguard/
├── SKILL.md                      # router + architectural rules + env facts
├── contract-intel/SKILL.md       # Milestone 3 — Cortex term extraction
├── billing-reconciler/SKILL.md   # Milestone 4 — detection + scoring
└── action-drafter/SKILL.md       # Milestone 5 — memo drafting
```

Register once, then drive it in natural language:

```bash
cortex skill add ./skills/leakguard
cortex skill list                      # confirm: "Discovered skills: - leakguard"

cortex                                 # interactive
cortex exec "run the full leakguard audit and report the score" -c default
```

Verified headless run:

> *"How much recoverable revenue has LeakGuard confirmed, and what is the
> detector's precision and recall?"* →
> **$185,783.70 confirmed · precision = 1.0 · recall = 1.0 (35/35, 0 FP, 0 FN)**

Note it returned the *confirmed* figure rather than the $163,871.68 estimate —
the skill instructs the agent which number to quote and why, so the distinction
survives into the answer.

Each skill also carries the traps this pipeline actually hit: the
`claude-4-5-sonnet` naming trap, the unqualified-DDL `090105` failure, the
`PARSE_JSON(OBJECT)` error, the answer-key contamination rule, and the
missing-`WHERE` bug whose dollar total stayed identical while row counts went
from 19 to 242.

### Honest result: the AI extraction arm ties, it does not win

`03b` (Cortex) and `03` (regex) produce **identical** output on this dataset — 42
terms each, zero rate disagreements, zero account-term disagreements, both
scoring 35/35 at precision = recall = 1.0. That is the expected outcome and `03`'s
own header predicted it: the 12 synthetic contracts use only three phrasings per
clause, which is exactly what regex handles well.

The AI arm's real value is robustness to phrasings nobody wrote a pattern for —
a property this dataset cannot demonstrate. The honest framing is *"the baseline
is strong here; the AI path is what survives contact with real MSAs"*, not *"AI
beat regex"*. A contract corpus with adversarial phrasings would be the way to
actually show the difference.

**Cortex is live — no blockers.** Confirmed 2026-07-29 on account
`BATAFLC-FIB35362` with model `claude-sonnet-4-5`.

Note there have been **two Snowflake accounts**: Cortex was genuinely blocked on
the older one (`TLPJXQR-AJB13531`, error `399258`), which is what earlier notes
in this repo were written against. On the current account the only fault was a
stale model name (`claude-3-5-sonnet`) returning a *400 model-unavailable* from
the inference service — a different error with a one-string fix, not an
entitlement problem. Run `snow connection test` to confirm which account you are
on before trusting any Cortex claim. `snowflake/00_enable_cortex.sql` has the
full distinction, the available-model list, and a `TRY_COMPLETE` probe.

*Built for the Snowflake CoCo CLI Hackathon 2026.*
