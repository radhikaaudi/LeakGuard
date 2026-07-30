"""
LeakGuard — synthetic data generator (Milestone 1)
==================================================

Generates a realistic-but-fake dataset for a SaaS/telecom biller called "CloudNova":

  1. contracts/   -> one human-readable CONTRACT per customer (UNSTRUCTURED input).
                     Written as prose/markdown on purpose, so the agent must *read*
                     and *extract* terms rather than reading tidy columns.
  2. billing/     -> billing_records.csv, the STRUCTURED input (loads into Snowflake).
  3. ground_truth/-> planted_leaks.csv, the ANSWER KEY of every leak we deliberately
                     injected. Used later to measure the agent's precision/recall.

Why synthetic + planted leaks?
  - We have no real private contracts (and shouldn't use any).
  - By planting KNOWN leaks, we can later PROVE the agent found them -> that's the
    "94% precision" number on your pitch slide, measured honestly, never faked.

Only uses the Python standard library. Seeded, so every run is identical (good demos).

Run it:
    python generate_data.py
"""

import csv
import os
import random

# --------------------------------------------------------------------------------------
# CONFIG
#
# SEED keeps the dataset (and the demo) reproducible run-to-run. It is overridable
# so the detector can be validated against datasets it has NEVER seen:
#
#     python data/generate_data.py            # seed 42 -- the committed demo dataset
#     python data/generate_data.py 7          # seed 7  -- an unseen dataset
#     LEAKGUARD_SEED=7 python data/generate_data.py
#
# WHY THIS MATTERS: scoring 1.0 on a single fixed seed is a weak claim, because the
# detector was written by someone who knew how this generator plants leaks. Holding
# 1.0 across seeds the detector has never been tuned against is a real claim. See
# snowflake/08_seed_sweep.md for the harness and the measured results.
# --------------------------------------------------------------------------------------
import sys

SEED = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("LEAKGUARD_SEED", 42))
random.seed(SEED)
print(f"[generate_data] seed = {SEED}")

NUM_CUSTOMERS = 12
MONTHS = ["2026-01", "2026-02", "2026-03", "2026-04", "2026-05", "2026-06"]

HERE = os.path.dirname(os.path.abspath(__file__))
CONTRACTS_DIR = os.path.join(HERE, "contracts")
BILLING_DIR = os.path.join(HERE, "billing")
GROUND_TRUTH_DIR = os.path.join(HERE, "ground_truth")

# The billable products CloudNova sells. Each has a "list" (catalog) unit price;
# each customer negotiates their own contracted rate around it.
PRODUCT_CATALOG = {
    "API Calls (per 1k)": 0.50,
    "Active Seats": 15.00,
    "Data Storage (GB)": 0.10,
    "Premium Support": 2500.00,
}

CUSTOMER_NAMES = [
    "Acme Retail", "Globex Logistics", "Initech Software", "Umbrella Health",
    "Wonka Foods", "Stark Manufacturing", "Wayne Freight", "Cyberdyne Robotics",
    "Soylent Grocers", "Hooli Media", "Pied Piper Data", "Vandelay Imports",
]

# --------------------------------------------------------------------------------------
# STEP 1 — Build each customer's CONTRACT (the "truth" the biller agreed to).
# --------------------------------------------------------------------------------------
def build_contract(cust_id, name):
    """Create a contract dict: negotiated rate, monthly minimum, and a discount."""
    products = {}
    # Every customer buys API Calls + Seats; some also buy Storage / Premium Support.
    chosen = ["API Calls (per 1k)", "Active Seats"]
    if random.random() < 0.7:
        chosen.append("Data Storage (GB)")
    if random.random() < 0.4:
        chosen.append("Premium Support")

    for p in chosen:
        list_price = PRODUCT_CATALOG[p]
        # Negotiated rate is a small discount off list (0%–20% cheaper).
        rate = round(list_price * random.uniform(0.80, 1.00), 4)
        products[p] = rate

    contract = {
        "customer_id": cust_id,
        "customer_name": name,
        "start_date": "2026-01-01",
        "end_date": "2026-12-31",
        "products": products,                              # product -> contracted unit rate
        "monthly_minimum": random.choice([0, 0, 2000, 5000]),  # $ true-up floor (0 = none)
        "discount_pct": random.choice([0, 0, 5, 10]),      # promotional % discount
        "discount_valid_until": "2026-03-31",              # discount expires after March
    }
    return contract


def render_contract_text(contract):
    """Render the contract as UNSTRUCTURED prose the agent will have to parse.

    Returns the full text string, so we can BOTH write a .md file (for realism /
    Document AI story) AND load it into a Snowflake table column (for Cortex Search).
    """
    c = contract
    lines = []
    lines.append(f"# Master Services Agreement — {c['customer_name']}")
    lines.append("")
    lines.append(f"Contract ID: MSA-{c['customer_id']:03d}")
    lines.append(f"Customer: {c['customer_name']} (Account #{c['customer_id']:03d})")
    lines.append(f"Term: {c['start_date']} through {c['end_date']}.")
    lines.append("")
    lines.append("## 1. Pricing")
    lines.append(
        "CloudNova shall invoice the Customer monthly for actual usage of the "
        "following services, at the following agreed unit rates:"
    )
    lines.append("")
    for product, rate in c["products"].items():
        lines.append(f"- **{product}** — billed at ${rate:.4f} per unit.")
    lines.append("")

    lines.append("## 2. Minimum Commitment")
    if c["monthly_minimum"] > 0:
        lines.append(
            f"The Customer commits to a minimum monthly spend of "
            f"${c['monthly_minimum']:,} across all services. If actual usage in a given "
            f"month falls below this minimum, CloudNova shall invoice the difference as a "
            f"'true-up' charge so that the monthly total equals the minimum commitment."
        )
    else:
        lines.append("No minimum monthly commitment applies to this account.")
    lines.append("")

    lines.append("## 3. Discounts")
    if c["discount_pct"] > 0:
        lines.append(
            f"A promotional discount of {c['discount_pct']}% shall be applied to the "
            f"invoice total. This promotional discount is valid only through "
            f"{c['discount_valid_until']}; invoices for periods after this date shall be "
            f"billed at full contract rates with no promotional discount."
        )
    else:
        lines.append("No promotional discount applies to this account.")
    lines.append("")

    lines.append("## 4. Payment Terms")
    lines.append(
        "Invoices are due net-30. Late payments accrue interest at 1.5% per month. "
        "All amounts are stated in USD."
    )
    lines.append("")

    return "\n".join(lines)


# --------------------------------------------------------------------------------------
# STEP 2 — Generate BILLING records, injecting KNOWN leaks and logging them.
# --------------------------------------------------------------------------------------
def generate_billing(contract, billing_rows, leak_rows):
    """
    For each month and product, produce a billing line.

    Some lines are deliberately wrong (a "leak"). Every planted leak is recorded in
    leak_rows (the answer key), with an estimated recovery amount.
    """
    c = contract
    cust_id = c["customer_id"]

    for month in MONTHS:
        month_num = int(month.split("-")[1])
        discount_active_by_contract = month_num <= 3  # discount only valid Jan–Mar

        for product, contract_rate in c["products"].items():
            leak_type = None

            # --- decide whether to plant a leak on this line (~18% of lines) ---
            roll = random.random()

            # LEAK A — "missing charge": product simply not invoiced this month (~4%).
            if roll < 0.04:
                leak_type = "missing_charge"
                units = 1 if product == "Premium Support" else random.randint(500, 5000)
                # Estimate what SHOULD have been billed = the recovery amount.
                recovery = round(units * contract_rate, 2)
                leak_rows.append({
                    "customer_id": cust_id, "customer_name": c["customer_name"],
                    "month": month, "product": product, "leak_type": leak_type,
                    "estimated_recovery": recovery,
                    "detail": f"{units} units used but no invoice line was created.",
                })
                continue  # no billing row emitted -> that IS the leak

            units = 1 if product == "Premium Support" else random.randint(500, 5000)
            billed_rate = contract_rate

            # LEAK B — "rate leak": billed BELOW the contracted rate (~7%).
            if 0.04 <= roll < 0.11:
                leak_type = "rate_leak"
                billed_rate = round(contract_rate * random.uniform(0.60, 0.90), 4)
                recovery = round(units * (contract_rate - billed_rate), 2)
                leak_rows.append({
                    "customer_id": cust_id, "customer_name": c["customer_name"],
                    "month": month, "product": product, "leak_type": leak_type,
                    "estimated_recovery": recovery,
                    "detail": (f"Billed at ${billed_rate:.4f} vs contracted "
                               f"${contract_rate:.4f} per unit."),
                })

            amount = round(units * billed_rate, 2)

            # LEAK C — "stale discount": discount applied AFTER it expired (~7%).
            applied_discount = 0
            if c["discount_pct"] > 0:
                if discount_active_by_contract:
                    applied_discount = c["discount_pct"]  # correctly applied
                else:
                    # Should be 0 now, but sometimes the billing system leaves it on.
                    if 0.11 <= roll < 0.18:
                        leak_type = "stale_discount"
                        applied_discount = c["discount_pct"]  # WRONGLY still applied
                        recovery = round(amount * (applied_discount / 100.0), 2)
                        leak_rows.append({
                            "customer_id": cust_id, "customer_name": c["customer_name"],
                            "month": month, "product": product, "leak_type": leak_type,
                            "estimated_recovery": recovery,
                            "detail": (f"{applied_discount}% discount applied after "
                                       f"expiry ({c['discount_valid_until']})."),
                        })

            net_amount = round(amount * (1 - applied_discount / 100.0), 2)

            billing_rows.append({
                "invoice_id": f"INV-{cust_id:03d}-{month}-{product[:3].upper()}",
                "customer_id": cust_id,
                "customer_name": c["customer_name"],
                "month": month,
                "product": product,
                "units": units,
                "unit_rate_billed": billed_rate,
                "discount_pct_applied": applied_discount,
                "amount_billed": net_amount,
            })

        # LEAK D — "minimum-commitment leak": month total under minimum, no true-up.
        #
        # NO COIN FLIP HERE, AND THAT IS THE POINT. This previously read
        #     if month_total < minimum and random.random() < 0.5:
        # which recorded only HALF of the below-minimum months as leaks -- while never
        # adding a true-up line for the other half. But the contract this generator
        # writes (see build_contract_text) states:
        #
        #   "If actual usage in a given month falls below this minimum, CloudNova
        #    shall invoice the difference as a 'true-up' charge..."
        #
        # So a below-minimum month with no true-up line IS a breach, every time. The
        # coin flip made the answer key disagree with its own contract text, and the
        # detector -- which correctly flags all of them -- was scored as raising false
        # positives for finding real leaks the key had forgotten.
        #
        # Found by seed_sweep.py: seed 42 has exactly one below-minimum month and the
        # flip happened to land on "plant it", so the bug was invisible at 1.0. Seed 7
        # has three, and two went unplanted -> 2 spurious FPs, precision 0.9592.
        #
        # NOTE ON WHAT THIS DATASET STILL DOES NOT TEST: because every shortfall is now
        # a leak, there is no compliant-true-up month, so the minimum-commitment branch
        # has no negative case. Emitting an actual true-up line for some months (and
        # asserting the detector stays silent) is the next improvement to this generator.
        if c["monthly_minimum"] > 0:
            month_total = sum(
                r["amount_billed"] for r in billing_rows
                if r["customer_id"] == cust_id and r["month"] == month
            )
            if month_total < c["monthly_minimum"]:
                shortfall = round(c["monthly_minimum"] - month_total, 2)
                leak_rows.append({
                    "customer_id": cust_id, "customer_name": c["customer_name"],
                    "month": month, "product": "(account minimum)",
                    "leak_type": "minimum_commitment_leak",
                    "estimated_recovery": shortfall,
                    "detail": (f"Month total ${month_total:,.2f} below minimum "
                               f"${c['monthly_minimum']:,}; no true-up charged."),
                })


# --------------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------------
def main():
    for d in (CONTRACTS_DIR, BILLING_DIR, GROUND_TRUTH_DIR):
        os.makedirs(d, exist_ok=True)

    billing_rows = []
    leak_rows = []
    contract_rows = []  # for contracts.csv (loads into Snowflake for Cortex Search)

    for cust_id in range(1, NUM_CUSTOMERS + 1):
        name = CUSTOMER_NAMES[cust_id - 1]
        contract = build_contract(cust_id, name)

        # Render the contract text once, then use it twice:
        text = render_contract_text(contract)
        # 1) write the human-readable .md file (realism / Document AI story)
        md_path = os.path.join(CONTRACTS_DIR, f"contract_{cust_id:03d}.md")
        with open(md_path, "w", encoding="utf-8") as f:
            f.write(text)
        # 2) collect a row for the loadable CSV (Cortex Search indexes this text column)
        contract_rows.append({
            "customer_id": cust_id,
            "customer_name": name,
            "contract_text": text,
        })

        generate_billing(contract, billing_rows, leak_rows)

    # Write structured billing CSV (this is what loads into Snowflake).
    billing_path = os.path.join(BILLING_DIR, "billing_records.csv")
    with open(billing_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "invoice_id", "customer_id", "customer_name", "month", "product",
            "units", "unit_rate_billed", "discount_pct_applied", "amount_billed",
        ])
        writer.writeheader()
        writer.writerows(billing_rows)

    # Write contracts CSV (the loadable copy of the unstructured contract text).
    contracts_path = os.path.join(CONTRACTS_DIR, "contracts.csv")
    with open(contracts_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "customer_id", "customer_name", "contract_text",
        ])
        writer.writeheader()
        writer.writerows(contract_rows)

    # Write the ground-truth answer key.
    truth_path = os.path.join(GROUND_TRUTH_DIR, "planted_leaks.csv")
    with open(truth_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "customer_id", "customer_name", "month", "product",
            "leak_type", "estimated_recovery", "detail",
        ])
        writer.writeheader()
        writer.writerows(leak_rows)

    # Summary for the console.
    total_recovery = sum(r["estimated_recovery"] for r in leak_rows)
    by_type = {}
    for r in leak_rows:
        by_type[r["leak_type"]] = by_type.get(r["leak_type"], 0) + 1

    print("=" * 60)
    print("LeakGuard synthetic data generated [OK]")
    print("=" * 60)
    print(f"Customers          : {NUM_CUSTOMERS}")
    print(f"Contract files     : {NUM_CUSTOMERS}  -> {CONTRACTS_DIR}")
    print(f"Contracts CSV      : 1  -> {contracts_path}")
    print(f"Billing rows       : {len(billing_rows)}  -> {billing_path}")
    print(f"Planted leaks      : {len(leak_rows)}  -> {truth_path}")
    print("-" * 60)
    for t, n in sorted(by_type.items()):
        print(f"  {t:<26}: {n}")
    print("-" * 60)
    print(f"Total recoverable  : ${total_recovery:,.2f}")
    print("=" * 60)


if __name__ == "__main__":
    main()
