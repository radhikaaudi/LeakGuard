"""
Seed sweep — validate the detector against datasets it has never seen.

WHY THIS EXISTS
---------------
Scoring precision = recall = 1.0 on a single fixed seed is a weak claim. The
detector was written by someone who knew how generate_data.py plants leaks, and
the answer key comes from the same script, so a perfect score on seed 42 is
partly a statement about seed 42.

This harness regenerates the dataset under N different seeds, runs the full
pipeline against each, and scores every one. Holding 1.0 across seeds nobody
tuned against is a real claim about the detector. Any seed that drops is a real
bug, and worth more than the perfect score was.

WHAT IT RUNS PER SEED
---------------------
  generate -> stage upload -> 02 load -> 03 regex extract -> 04 detect -> score

The Cortex arm (03b) is deliberately SKIPPED: it costs 12 inference calls per
seed, and the arm under test here is the deterministic detector, which is what
the circularity objection is actually about. Cortex extraction is validated
separately against seed 42 in 03b's own comparison queries.

RESTORES SEED 42 AT THE END so the demo dataset and the deployed Streamlit app
are left exactly as they were. If the sweep dies midway, re-run the last block
manually -- the DB will otherwise hold whichever seed ran last.

USAGE
-----
    python seed_sweep.py                # seeds 7 13 99 2024 31337
    python seed_sweep.py 1 2 3          # explicit seeds
"""

import os
import re
import subprocess
import sys

HERE = r"C:\Users\Radhika Audichya\Documents\snowflake\LeakGuard"
CONN = "default"
DEMO_SEED = 42

SCORE_SQL = """
USE ROLE ACCOUNTADMIN; USE WAREHOUSE LEAKGUARD_WH;
USE DATABASE LEAKGUARD; USE SCHEMA CORE;
SELECT COUNT_IF(outcome='TP') AS tp, COUNT_IF(outcome='FP') AS fp,
       COUNT_IF(outcome='FN') AS fn, COUNT(*) AS total
FROM V_EVALUATION WHERE detected_by = 'sql_baseline';
"""

STAGE = "@LEAKGUARD.CORE.LEAKGUARD_STAGE"
UPLOADS = [
    (r"data\billing\billing_records.csv", f"{STAGE}/billing/"),
    (r"data\contracts\contracts.csv", f"{STAGE}/contracts/"),
    (r"data\ground_truth\planted_leaks.csv", f"{STAGE}/ground_truth/"),
]


def run(cmd, label):
    """Run a command, surface stderr on failure, never swallow a broken step."""
    r = subprocess.run(cmd, cwd=HERE, shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"    !! {label} FAILED (exit {r.returncode})")
        tail = (r.stdout or "")[-600:] + (r.stderr or "")[-600:]
        print("    " + tail.replace("\n", "\n    "))
        return None
    return r.stdout


def score_seed(seed):
    """Regenerate at `seed`, push it through the pipeline, return (tp, fp, fn, total)."""
    print(f"\n=== seed {seed} ===")

    if run(f"python data/generate_data.py {seed}", "generate") is None:
        return None

    for local, target in UPLOADS:
        # --overwrite matters: the stage keeps the previous seed's file otherwise,
        # and COPY would silently load stale data for the rest of the sweep.
        if run(f'snow stage copy "{local}" "{target}" --overwrite -c {CONN}', "upload") is None:
            return None

    for script in ["02_load_data.sql", "03_extract_terms.sql", "04_detect_leaks.sql"]:
        if run(f"snow sql -f snowflake/{script} -c {CONN}", script) is None:
            return None

    # Write the scoring SQL to a file rather than passing it via -q: multi-statement,
    # multi-line SQL gets mangled through the Windows shell and the query silently
    # returns nothing parseable.
    score_path = os.path.join(HERE, "_score_tmp.sql")
    with open(score_path, "w", encoding="utf-8") as f:
        f.write(SCORE_SQL)

    out = run(f'snow sql -f _score_tmp.sql -c {CONN}', "score")
    if out is None:
        return None

    # The scorecard is the last 4-integer row the CLI prints.
    rows = re.findall(r"\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|", out)
    if not rows:
        print("    !! could not parse a scorecard row")
        return None
    return tuple(int(v) for v in rows[-1])


def main():
    seeds = [int(a) for a in sys.argv[1:]] or [7, 13, 99, 2024, 31337]
    results = {}

    for seed in seeds:
        r = score_seed(seed)
        results[seed] = r
        if r:
            tp, fp, fn, total = r
            prec = tp / (tp + fp) if tp + fp else 0.0
            rec = tp / (tp + fn) if tp + fn else 0.0
            flag = "OK  " if fp == 0 and fn == 0 else "FAIL"
            print(f"    {flag} tp={tp} fp={fp} fn={fn}  precision={prec:.4f} recall={rec:.4f}")

    print("\n" + "=" * 62)
    print(f"{'seed':>8} {'TP':>4} {'FP':>4} {'FN':>4} {'precision':>10} {'recall':>8}")
    print("-" * 62)
    perfect = 0
    for seed, r in results.items():
        if not r:
            print(f"{seed:>8}  --   --   --      ERROR       ERROR")
            continue
        tp, fp, fn, _ = r
        prec = tp / (tp + fp) if tp + fp else 0.0
        rec = tp / (tp + fn) if tp + fn else 0.0
        print(f"{seed:>8} {tp:>4} {fp:>4} {fn:>4} {prec:>10.4f} {rec:>8.4f}")
        if fp == 0 and fn == 0:
            perfect += 1
    print("-" * 62)
    print(f"{perfect}/{len(results)} unseen datasets at precision = recall = 1.0000")

    print(f"\n=== restoring demo dataset (seed {DEMO_SEED}) ===")
    score_seed(DEMO_SEED)
    print("Demo dataset restored. Re-run 03b and 06 to refresh the Cortex arm and memos.")


if __name__ == "__main__":
    main()
