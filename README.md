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
Scored by `snowflake/05_evaluate.sql` against the planted-leak answer key, on the
identity key `(customer_id, month, product, leak_type)` — deliberately not on
dollar amount, so a correctly-identified leak is not marked wrong over an
estimation rounding difference.

| Metric | Value |
|---|---|
| Precision | **1.0000** (0 false alarms) |
| Recall | **1.0000** (0 missed leaks) |
| F1 | **1.0000** |
| Confirmed recoverable | **$185,783.70** across 12 customers / 6 months |

### Validated on datasets the detector has never seen

A perfect score on one fixed seed is weak evidence: the detector was written by
someone who knew how `generate_data.py` plants leaks, and the answer key comes
from that same script. So `seed_sweep.py` regenerates the corpus under other
seeds and re-runs the whole pipeline — generate → load → extract → detect → score
— against each.

```bash
python seed_sweep.py                 # seeds 7 13 99 2024 31337, then restores seed 42
python seed_sweep.py 1 2 3           # explicit seeds
```

| Seed | Leaks planted | FP | FN | Precision | Recall |
|---|---|---|---|---|---|
| 7 | 42 | 0 | 0 | 1.0000 | 1.0000 |
| 13 | 34 | 0 | 0 | 1.0000 | 1.0000 |
| 99 | 37 | 0 | 0 | 1.0000 | 1.0000 |
| 2024 | 24 | 0 | 0 | 1.0000 | 1.0000 |
| 31337 | 34 | 0 | 0 | 1.0000 | 1.0000 |

**5/5 unseen datasets at precision = recall = 1.0000.** Leak counts range 24–42,
so these are genuinely different corpora, not reruns.

### The sweep found a bug — in the benchmark, not the detector

On its first run, seed 7 scored **precision 0.9592 with 2 false positives**, both
`minimum_commitment_leak`. The detector turned out to be right and the answer key
wrong.

`generate_data.py` planted a below-minimum month as a leak only half the time
(`random.random() < 0.5`) while **never** adding a true-up line for the other
half — yet the contract text it generates states that any shortfall *"shall be
invoiced as a 'true-up' charge."* Those unplanted months were real breaches the
key had omitted, and the detector was being penalised for finding them.

Seed 42 concealed this completely: it produces **exactly one** below-minimum
month and the coin flip landed on "plant it." One month, one flip. A single fixed
seed didn't just make the 1.0 weak evidence — it made it *wrong* evidence.

The coin flip is gone; the generator now agrees with its own contract text.

**Known gap, deliberately recorded:** with every shortfall now a leak, no
compliant-true-up month exists, so the minimum-commitment branch has no negative
case. Emitting a real true-up line for some months and asserting the detector
stays silent is the next improvement to the generator.

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

### Dual-extractor cross-validation

The two extraction arms are scored independently and **agree on all 42 product
rates and all 12 account-term sets**, each reaching 35/35 at
precision = recall = 1.0.

Two independent extractors converging on the same answer is a validation signal
for the extraction layer: a disagreement would mean one of them is wrong, and
`05_evaluate.sql` reports which arm lost which leak. The AI arm is the path that
generalises to contract phrasings no pattern was written for — the property that
matters on real MSAs.

*Scope note for anyone extending this:* the 12 generated contracts use a small
set of clause phrasings, so this corpus validates agreement rather than stressing
that generalisation. Adding adversarially-phrased contracts is how you exercise
it.

**Cortex is live — no blockers.** Account `BATAFLC-FIB35362`, model
`claude-sonnet-4-5`, verified 2026-07-30. `snowflake/00_enable_cortex.sql` holds
the available-model list and a `TRY_COMPLETE` probe for re-checking when the
catalogue changes. Mind the naming trap: `claude-sonnet-4-5` is valid,
`claude-4-5-sonnet` is not.

*Built for the Snowflake CoCo CLI Hackathon 2026.*
