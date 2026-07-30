"""
LeakGuard — revenue-leakage console (Streamlit in Snowflake).

WHY STREAMLIT IN SNOWFLAKE rather than a separate web app: the data never
leaves Snowflake, there is no second service to host, no connection string to
manage, and no credentials to hand out. get_active_session() runs as the
viewing user, so row access is governed by Snowflake's own grants.

This app is READ-ONLY by design. Detection lives in 04, scoring in 05, drafting
in 06 -- all reproducible SQL. A dashboard that recomputed any of that would be
a second source of truth, and the two would drift. Everything here is a SELECT.
"""

import decimal

import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="LeakGuard", page_icon="🛡️", layout="wide")

session = get_active_session()


@st.cache_data(ttl=300)
def q(sql: str) -> pd.DataFrame:
    """Run a query and hand back a pandas frame with numerics as real floats.

    WHY THE COERCION: Snowpark's to_pandas() maps Snowflake NUMBER / INTEGER /
    DECIMAL -- which is what COUNT(), ROUND() and any INTEGER column return -- to
    Python decimal.Decimal objects inside an object-dtype column, not to a numeric
    dtype. Decimal is not JSON-serialisable, so Altair fails on it, and several
    Streamlit widgets raise the extremely unhelpful

        TypeError: bad argument type for built-in operation

    with no line number. Casting Decimal columns to float here fixes every one of
    those call sites at once, instead of scattering float() casts through the page.

    Cached for 5 minutes: the underlying tables only change when the pipeline is
    re-run, so re-querying on each widget interaction would burn warehouse credits
    for no new information. Clear it with the sidebar button.
    """
    df = session.sql(sql).to_pandas()
    for col in df.columns:
        if df[col].dtype == object:
            non_null = df[col].dropna()
            if len(non_null) and isinstance(non_null.iloc[0], decimal.Decimal):
                df[col] = pd.to_numeric(df[col], errors="coerce")
    return df


# ---------------------------------------------------------------------------
# Sidebar — which detector arm are we looking at?
#
# LEAKAGE_FINDINGS holds one set of findings per extraction arm ('sql_baseline'
# from the regex extractor, 'cortex' from the AI extractor). Everything on the
# page is scoped to the selected arm, so the two can be compared honestly rather
# than silently blended into one number.
# ---------------------------------------------------------------------------
st.sidebar.title("🛡️ LeakGuard")
st.sidebar.caption("Autonomous revenue-leakage & contract-compliance agent")

arms = q(
    "SELECT DISTINCT detected_by FROM LEAKAGE_FINDINGS "
    "WHERE detected_by IS NOT NULL ORDER BY detected_by"
)["DETECTED_BY"].tolist()

if not arms:
    st.error(
        "No findings in LEAKAGE_FINDINGS. Run the pipeline first:\n\n"
        "`snow sql -f snowflake/04_detect_leaks.sql -c default`"
    )
    st.stop()

arm = st.sidebar.selectbox(
    "Detector arm",
    arms,
    index=arms.index("sql_baseline") if "sql_baseline" in arms else 0,
    help="sql_baseline = regex contract extraction · cortex = AI contract extraction. "
         "Detection logic is identical for both, so any score difference is "
         "attributable to extraction.",
)

if st.sidebar.button("↻ Refresh data"):
    st.cache_data.clear()
    st.rerun()

# ---------------------------------------------------------------------------
# Headline KPIs.
#
# Two different dollar figures exist and conflating them would be misleading:
#   detected_total  -- what the detector estimated
#   confirmed_total -- what the confirmed leaks are actually worth
# They differ because missing_charge amounts are estimated from a monthly
# average (the true unit count vanished with the deleted invoice row). We show
# the confirmed figure as the headline and the delta underneath it.
# ---------------------------------------------------------------------------
score = q(
    f"""
    SELECT
        COUNT_IF(outcome = 'TP')                                   AS tp,
        COUNT_IF(outcome = 'FP')                                   AS fp,
        COUNT_IF(outcome = 'FN')                                   AS fn,
        ROUND(COUNT_IF(outcome = 'TP')
              / NULLIF(COUNT_IF(outcome IN ('TP','FP')), 0), 4)    AS precision,
        ROUND(COUNT_IF(outcome = 'TP')
              / NULLIF(COUNT_IF(outcome IN ('TP','FN')), 0), 4)    AS recall
    FROM V_EVALUATION
    WHERE detected_by = '{arm}'
    """
).iloc[0]

money = q(
    f"""
    SELECT
        ROUND(SUM(f.estimated_recovery), 2)                        AS detected_total,
        ROUND(SUM(g.estimated_recovery), 2)                        AS confirmed_total,
        COUNT(DISTINCT f.customer_id)                              AS customers
    FROM        LEAKAGE_FINDINGS f
    JOIN        GROUND_TRUTH_LEAKS g
           ON   g.customer_id = f.customer_id
          AND   g.month       = f.month
          AND   g.product     = f.product
          AND   g.leak_type   = f.leak_type
    WHERE f.detected_by = '{arm}'
    """
).iloc[0]

st.title("Revenue leakage detected")
st.caption(
    "Every contract checked against every invoice — continuously, not sampled quarterly."
)

k1, k2, k3, k4 = st.columns(4)
k1.metric(
    "Confirmed recoverable",
    f"${money['CONFIRMED_TOTAL']:,.0f}",
    delta=f"${money['DETECTED_TOTAL'] - money['CONFIRMED_TOTAL']:,.0f} vs estimate",
    delta_color="off",
    help="Value of leaks verified against the answer key. The delta is the "
         "detector's estimation error, which lives almost entirely in "
         "missing_charge — see the note below the table.",
)
k2.metric("Leaks confirmed", f"{int(score['TP'])}", help="True positives.")
k3.metric(
    "Precision / Recall",
    f"{score['PRECISION']:.2f} / {score['RECALL']:.2f}",
    help=f"{int(score['FP'])} false alarms · {int(score['FN'])} missed leaks.",
)
k4.metric("Customers affected", f"{int(money['CUSTOMERS'])}")

if int(score["FP"]) == 0 and int(score["FN"]) == 0:
    st.success(
        f"**Perfect detection on this dataset** — {int(score['TP'])} of "
        f"{int(score['TP'])} planted leaks found, zero false alarms. "
        "Detection is deterministic SQL, so this result is reproducible rather "
        "than a model's opinion."
    )
else:
    st.warning(
        f"{int(score['FN'])} leak(s) missed and {int(score['FP'])} false "
        "alarm(s) raised — see the Scoring tab."
    )

# ---------------------------------------------------------------------------
tab_leaks, tab_score, tab_memo, tab_ab = st.tabs(
    ["💧 Leaks", "🎯 Scoring", "✉️ Draft memos", "🧪 Regex vs AI"]
)

# ---------------------------------------------------------------------------
# LEAKS — the operational view. What was found, what it is worth, why.
# ---------------------------------------------------------------------------
with tab_leaks:
    findings = q(
        f"""
        SELECT customer_name, month, product, leak_type,
               estimated_recovery, evidence
        FROM   LEAKAGE_FINDINGS
        WHERE  detected_by = '{arm}'
        ORDER BY estimated_recovery DESC
        """
    )

    c1, c2 = st.columns([2, 3])
    with c1:
        by_type = (
            findings.groupby("LEAK_TYPE", as_index=False)
            .agg(DOLLARS=("ESTIMATED_RECOVERY", "sum"), LEAKS=("LEAK_TYPE", "size"))
            .sort_values("DOLLARS", ascending=False)
        )
        st.altair_chart(
            alt.Chart(by_type)
            .mark_bar(cornerRadiusEnd=3)
            .encode(
                x=alt.X("DOLLARS:Q", title="Estimated recovery ($)"),
                y=alt.Y("LEAK_TYPE:N", sort="-x", title=None),
                tooltip=["LEAK_TYPE", "LEAKS", alt.Tooltip("DOLLARS:Q", format="$,.2f")],
            )
            .properties(height=200, title="Where the money is"),
            use_container_width=True,
        )
    with c2:
        by_cust = (
            findings.groupby("CUSTOMER_NAME", as_index=False)
            .agg(DOLLARS=("ESTIMATED_RECOVERY", "sum"))
            .sort_values("DOLLARS", ascending=False)
            .head(8)
        )
        st.altair_chart(
            alt.Chart(by_cust)
            .mark_bar(cornerRadiusEnd=3)
            .encode(
                x=alt.X("DOLLARS:Q", title="Estimated recovery ($)"),
                y=alt.Y("CUSTOMER_NAME:N", sort="-x", title=None),
                tooltip=["CUSTOMER_NAME", alt.Tooltip("DOLLARS:Q", format="$,.2f")],
            )
            .properties(height=200, title="Most affected accounts"),
            use_container_width=True,
        )

    f1, f2 = st.columns(2)
    types = f1.multiselect(
        "Leak type", sorted(findings["LEAK_TYPE"].unique()),
        default=sorted(findings["LEAK_TYPE"].unique()),
    )
    custs = f2.multiselect("Customer", sorted(findings["CUSTOMER_NAME"].unique()))

    view = findings[findings["LEAK_TYPE"].isin(types)]
    if custs:
        view = view[view["CUSTOMER_NAME"].isin(custs)]

    st.dataframe(
        view,
        use_container_width=True,
        hide_index=True,
        column_config={
            "ESTIMATED_RECOVERY": st.column_config.NumberColumn(
                "Recovery", format="$%.2f"
            ),
            "EVIDENCE": st.column_config.TextColumn("Evidence", width="large"),
        },
    )
    st.caption(
        f"{len(view)} of {len(findings)} findings shown · "
        f"${view['ESTIMATED_RECOVERY'].sum():,.2f} estimated in this selection"
    )
    st.info(
        "**On the estimates.** rate_leak, stale_discount and "
        "minimum_commitment_leak amounts are exact — computed from real invoice "
        "rows. missing_charge amounts are *estimated* from the customer's monthly "
        "average, because when a charge goes missing the invoice row is simply "
        "gone and the true unit count is unrecoverable. The leak's identity is "
        "exact; only its dollar figure is approximate.",
        icon="ℹ️",
    )

# ---------------------------------------------------------------------------
# SCORING — the credibility tab. An auditor's first question is "how do you
# know you didn't miss any?", and this is the answer.
# ---------------------------------------------------------------------------
with tab_score:
    st.subheader("Scored against a planted-leak answer key")
    st.caption(
        "The generator plants a known set of leaks and records them in "
        "GROUND_TRUTH_LEAKS. The detector never reads that table. Scoring is on "
        "leak *identity* — (customer, month, product, leak type) — not on dollar "
        "amount, so a correctly-identified leak is not marked wrong over an "
        "estimation rounding difference."
    )
    st.dataframe(
        q(
            f"""
            SELECT leak_type                                  AS "Leak type",
                   COUNT_IF(outcome = 'TP')                   AS "Found",
                   COUNT_IF(outcome = 'FN')                   AS "Missed",
                   COUNT_IF(outcome = 'FP')                   AS "False alarms",
                   ROUND(COUNT_IF(outcome = 'TP')
                         / NULLIF(COUNT_IF(outcome IN ('TP','FP')), 0), 4) AS "Precision",
                   ROUND(COUNT_IF(outcome = 'TP')
                         / NULLIF(COUNT_IF(outcome IN ('TP','FN')), 0), 4) AS "Recall"
            FROM V_EVALUATION
            WHERE detected_by = '{arm}'
            GROUP BY leak_type
            ORDER BY "Found" DESC
            """
        ),
        use_container_width=True,
        hide_index=True,
    )

    st.markdown("**Dollar accuracy on confirmed leaks**")
    st.dataframe(
        q(
            f"""
            SELECT e.leak_type                                    AS "Leak type",
                   ROUND(SUM(f.estimated_recovery), 2)            AS "Detected $",
                   ROUND(SUM(g.estimated_recovery), 2)            AS "Actual $",
                   ROUND(AVG(ABS(f.estimated_recovery - g.estimated_recovery)
                             / NULLIF(g.estimated_recovery, 0)) * 100, 1) AS "Mean error %"
            FROM        V_EVALUATION e
            JOIN        LEAKAGE_FINDINGS f
                   ON   f.detected_by = e.detected_by
                  AND   f.customer_id = e.customer_id AND f.month     = e.month
                  AND   f.product     = e.product     AND f.leak_type = e.leak_type
            JOIN        GROUND_TRUTH_LEAKS g
                   ON   g.customer_id = e.customer_id AND g.month     = e.month
                  AND   g.product     = e.product     AND g.leak_type = e.leak_type
            WHERE e.outcome = 'TP' AND e.detected_by = '{arm}'
            GROUP BY e.leak_type
            ORDER BY "Mean error %" DESC
            """
        ),
        use_container_width=True,
        hide_index=True,
    )

    # ---------------------------------------------------------------------
    # Generalisation evidence. A perfect score on one fixed seed is weak: the
    # detector was written by someone who knew how the generator plants leaks.
    # This is the answer to "you built the test to pass" -- and it is the
    # strongest claim on the page, so it sits above the per-type breakdown.
    # ---------------------------------------------------------------------
    st.divider()
    st.subheader("Does it hold on data it has never seen?")

    try:
        sweep = q(
            """
            SELECT seed          AS "Seed",
                   leaks_planted AS "Leaks planted",
                   fp            AS "False alarms",
                   fn            AS "Missed",
                   ROUND(tp / NULLIF(tp + fp, 0), 4) AS "Precision",
                   ROUND(tp / NULLIF(tp + fn, 0), 4) AS "Recall"
            FROM EVALUATION_SWEEP ORDER BY seed
            """
        )
    except Exception:
        sweep = pd.DataFrame()

    if sweep.empty:
        st.info(
            "No sweep results recorded. Run `python seed_sweep.py` to validate "
            "against unseen datasets.",
            icon="ℹ️",
        )
    else:
        clean = int((sweep["False alarms"] + sweep["Missed"]).eq(0).sum())
        st.caption(
            "`seed_sweep.py` regenerates the entire corpus under a different seed "
            "and re-runs the whole pipeline — generate → load → extract → detect → "
            "score — against each. The detector was never tuned on these datasets."
        )
        st.dataframe(sweep, use_container_width=True, hide_index=True)
        lo, hi = int(sweep["Leaks planted"].min()), int(sweep["Leaks planted"].max())
        if clean == len(sweep):
            st.success(
                f"**{clean}/{len(sweep)} unseen datasets at precision = recall = "
                f"1.0000.** Leaks planted ranges {lo}–{hi}, so these are genuinely "
                "different corpora rather than reruns of one test.",
                icon="✅",
            )
        else:
            st.warning(
                f"{len(sweep) - clean} of {len(sweep)} unseen datasets show errors — "
                "check whether the detector or the answer key is at fault before "
                "changing detection logic.",
                icon="⚠️",
            )

        with st.expander("This sweep already caught a real bug — in the benchmark"):
            st.markdown(
                """
On its first run, seed 7 scored **precision 0.9592 with 2 false positives**, both
`minimum_commitment_leak`. The detector was right and the answer key was wrong.

`generate_data.py` planted a below-minimum month as a leak only half the time
(`random.random() < 0.5`) while **never** adding a true-up line for the other
half — yet the contract text it generates states any shortfall *"shall be
invoiced as a 'true-up' charge."* Those unplanted months were real breaches the
key had omitted, and the detector was being penalised for finding them.

Seed 42 hid it completely: it produces **exactly one** below-minimum month, and
the coin flip landed on "plant it." A single fixed seed did not just make the
1.0 weak evidence — it made it *wrong* evidence.

**Known gap, recorded rather than hidden:** with every shortfall now a leak,
there is no compliant-true-up month, so the minimum-commitment branch has no
negative case — it has never been tested for staying silent when it should.
                """
            )

    st.divider()
    misses = q(
        f"""
        SELECT g.customer_name AS "Customer", e.month AS "Month",
               e.product AS "Product", e.leak_type AS "Leak type",
               g.estimated_recovery AS "Missed $", g.detail AS "What was planted"
        FROM        V_EVALUATION e
        JOIN        GROUND_TRUTH_LEAKS g
               ON   g.customer_id = e.customer_id AND g.month     = e.month
              AND   g.product     = e.product     AND g.leak_type = e.leak_type
        WHERE e.outcome = 'FN' AND e.detected_by = '{arm}'
        ORDER BY "Missed $" DESC
        """
    )
    st.markdown("**Missed leaks**")
    if misses.empty:
        st.success("None — every planted leak was detected.")
    else:
        st.dataframe(misses, use_container_width=True, hide_index=True)

# ---------------------------------------------------------------------------
# DRAFT MEMOS — the "agent takes action" tab. This is the artefact a human
# reviews and approves, which is why it is presented for review rather than
# shown as a finished document.
# ---------------------------------------------------------------------------
with tab_memo:
    st.subheader("Correction memos drafted by Cortex")
    st.caption(
        "Detection is deterministic SQL; drafting is where a language model "
        "earns its place. Each memo is an **internal** note to the account owner "
        "for review — not customer-facing correspondence — and ends with a "
        "recommended action for a human to approve."
    )

    memos = q(
        f"""
        SELECT customer_name, month, product, leak_type,
               estimated_recovery, evidence, draft_memo
        FROM   LEAKAGE_FINDINGS
        WHERE  detected_by = '{arm}' AND draft_memo IS NOT NULL
        ORDER BY estimated_recovery DESC
        """
    )

    if memos.empty:
        st.warning(
            f"No memos drafted for the `{arm}` arm yet. Run "
            "`snow sql -f snowflake/06_draft_memos.sql -c default`."
        )
    else:
        memos["LABEL"] = (
            memos["CUSTOMER_NAME"] + " · " + memos["MONTH"] + " · "
            + memos["PRODUCT"] + " · $"
            + memos["ESTIMATED_RECOVERY"].map("{:,.2f}".format)
        )
        pick = st.selectbox("Finding", memos["LABEL"].tolist())
        row = memos[memos["LABEL"] == pick].iloc[0]

        left, right = st.columns([2, 3])
        with left:
            st.metric("Estimated recovery", f"${row['ESTIMATED_RECOVERY']:,.2f}")
            st.markdown(f"**Leak type**  \n`{row['LEAK_TYPE']}`")
            st.markdown("**Evidence**")
            st.info(row["EVIDENCE"])
            if row["LEAK_TYPE"] == "missing_charge":
                st.warning(
                    "This amount is an estimate — confirm against usage records "
                    "before raising an invoice.",
                    icon="⚠️",
                )
        with right:
            st.markdown("**Draft memo**")
            # str() guard: st.markdown(None) raises, and a NULL draft_memo can slip
            # through if 04 rebuilt findings without 06 being re-run afterwards.
            memo_text = row["DRAFT_MEMO"]
            if memo_text is None or pd.isna(memo_text):
                st.warning(
                    "No memo stored for this finding. Run "
                    "`snow sql -f snowflake/06_draft_memos.sql -c default`.",
                    icon="⚠️",
                )
            else:
                st.markdown(str(memo_text))

        st.download_button(
            "⬇ Download all memos (CSV)",
            memos.drop(columns=["LABEL"]).to_csv(index=False).encode("utf-8"),
            file_name="leakguard_draft_memos.csv",
            mime="text/csv",
        )

# ---------------------------------------------------------------------------
# REGEX vs AI — the experiment. Reported as measured, including when the AI
# arm merely ties. A dashboard that only ever showed the AI winning would not
# be worth trusting on the occasions it did.
# ---------------------------------------------------------------------------
with tab_ab:
    st.subheader("Contract extraction: regex baseline vs Cortex")
    st.caption(
        "Both arms feed the *same* detection SQL, so any difference in score is "
        "attributable to contract extraction alone."
    )

    ab = q(
        """
        SELECT detected_by                                        AS "Arm",
               COUNT_IF(outcome = 'TP')                           AS "Found",
               COUNT_IF(outcome = 'FN')                           AS "Missed",
               COUNT_IF(outcome = 'FP')                           AS "False alarms",
               ROUND(COUNT_IF(outcome = 'TP')
                     / NULLIF(COUNT_IF(outcome IN ('TP','FP')), 0), 4) AS "Precision",
               ROUND(COUNT_IF(outcome = 'TP')
                     / NULLIF(COUNT_IF(outcome IN ('TP','FN')), 0), 4) AS "Recall"
        FROM V_EVALUATION
        GROUP BY detected_by
        ORDER BY detected_by
        """
    )
    st.dataframe(ab, use_container_width=True, hide_index=True)

    terms = q(
        """
        SELECT extraction_method AS "Arm",
               COUNT(DISTINCT customer_id) AS "Contracts",
               COUNT(*)                    AS "Terms extracted"
        FROM CONTRACT_TERMS
        GROUP BY extraction_method
        ORDER BY extraction_method
        """
    )
    st.dataframe(terms, use_container_width=True, hide_index=True)

    disagree = q(
        """
        SELECT COALESCE(g.customer_id, x.customer_id) AS "Customer",
               COALESCE(g.product, x.product)         AS "Product",
               g.contract_rate                        AS "Regex rate",
               x.contract_rate                        AS "Cortex rate"
        FROM            (SELECT * FROM CONTRACT_TERMS WHERE extraction_method = 'regex_baseline') g
        FULL OUTER JOIN (SELECT * FROM CONTRACT_TERMS WHERE extraction_method = 'cortex') x
                   ON   x.customer_id = g.customer_id AND x.product = g.product
        WHERE g.product IS NULL OR x.product IS NULL
           OR ABS(COALESCE(g.contract_rate,0) - COALESCE(x.contract_rate,0)) > 0.0001
        ORDER BY "Customer", "Product"
        """
    )
    st.markdown("**Terms the two arms disagree on**")
    if disagree.empty:
        st.info(
            "**No disagreements — the two arms tie exactly on this dataset.**\n\n"
            "This is the honest result, and it is expected: the 12 synthetic "
            "contracts use only three phrasings per clause, which is precisely "
            "the case regex handles well. The AI arm's value is robustness to "
            "phrasings nobody wrote a pattern for — a property this dataset "
            "cannot demonstrate. Treat the tie as the baseline being strong here, "
            "not as the extractor being interchangeable on real contracts.",
            icon="🤝",
        )
    else:
        st.dataframe(disagree, use_container_width=True, hide_index=True)

st.divider()
st.caption(
    "LeakGuard · Snowflake + Cortex · detection is deterministic SQL, "
    "extraction and drafting are AI · scored against a planted-leak answer key"
)
