-- ============================================================================
-- LeakGuard — Milestone 2, Step 0: ENABLE CORTEX (run BEFORE 01_setup.sql)
-- ============================================================================
-- STATUS: Cortex is LIVE on account BATAFLC-FIB35362 (verified 2026-07-30).
--   Statements 1-4 succeed and the step-5 smoke test returns a sentence.
--
-- TWO FAILURES THAT LOOK ALIKE. Read the error text, not the vibe:
--
--     399258 (0A000): AI function COMPLETE is not available for trial accounts.
--       -> a genuine entitlement block. The function never ran.
--
--     400 "Model \"claude-3-5-sonnet\" is unavailable"
--       -> NOT a block. COMPLETE ran, reached the inference service, and the
--          service rejected the MODEL NAME. Entitlement is fine; the argument
--          is wrong. The fix is one string, not a payment method.
--
--   Do not convert an account to paid on the strength of a 400 like the second.
--
-- CONNECTION NOTE: the `default` connection has no default database and points
--   at COMPUTE_WH, not LEAKGUARD_WH. That is fine -- every script here issues
--   its own USE DATABASE / USE WAREHOUSE, so they do not depend on it. Confirm
--   with `snow connection test`; expect account BATAFLC-FIB35362.
--
-- MODELS AVAILABLE TO THE CURRENT ACCOUNT (probed empirically 2026-07-29):
--     claude-sonnet-4-5   <-- newest Claude here; what LeakGuard uses
--     claude-4-sonnet
--     llama3.1-70b
--     llama3.1-8b
--     mistral-large2
--   Rejected as unavailable (TRY_COMPLETE returns NULL): claude-3-5-sonnet,
--   claude-3-7-sonnet, claude-4-opus, claude-4-5-sonnet, snowflake-arctic.
--
--   Verify with the probe in step 6 rather than trusting a one-off COMPLETE call
--   whose label you cannot see. TRY_COMPLETE returning NULL is the unambiguous
--   signal; a bare COMPLETE that appears to succeed may be a different model
--   than the one you think you tested.
--
--   The Cortex model catalogue changes over time and varies by region, so
--   re-probe rather than trusting this list if a model name starts 400-ing.
--   Note the naming trap: 'claude-sonnet-4-5' works, 'claude-4-5-sonnet' does
--   not -- the segment order is not interchangeable.
--
-- Statements 1-4 remain required prerequisites.
-- ============================================================================

USE ROLE ACCOUNTADMIN;

-- 1. Allow ALL Cortex models for this account.
--    (Necessary but NOT sufficient on a trial -- see header.)
ALTER ACCOUNT SET CORTEX_MODELS_ALLOWLIST = 'All';

-- 2. Let the account reach models hosted in other AWS US regions if a needed
--    model isn't local to us-west-2. (Options: 'AWS_US', 'ANY_REGION', 'DISABLED'.)
--    This account IS in AWS_US_WEST_2, so 'AWS_US' is the correct value here.
ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'AWS_US';

-- 3. Make sure your role can use Cortex + the agent surface CoCo needs.
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER       TO ROLE ACCOUNTADMIN;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE ACCOUNTADMIN;

-- 4. Verify the settings took effect. Expect 'All' and 'AWS_US'.
SHOW PARAMETERS LIKE 'CORTEX_MODELS_ALLOWLIST' IN ACCOUNT;
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;

-- 5. GATE CHECK -- the single query that tells you Cortex is live.
--    Expect a sentence back. Confirmed passing 2026-07-29.
--
SELECT SNOWFLAKE.CORTEX.COMPLETE('claude-sonnet-4-5',
       'Say hello in one short sentence.') AS cortex_test;

-- 6. MODEL PROBE -- run this when a model name starts returning a 400, or when
--    checking whether a newer Claude has landed in this region. Each row is
--    independent, so a model that is unavailable fails only its own row.
--    (TRY_COMPLETE returns NULL instead of erroring, which is what lets the
--    whole probe run in one statement.)
--
SELECT 'claude-sonnet-4-5' AS model, SNOWFLAKE.CORTEX.TRY_COMPLETE('claude-sonnet-4-5', 'hi') AS reply
UNION ALL SELECT 'claude-4-sonnet',   SNOWFLAKE.CORTEX.TRY_COMPLETE('claude-4-sonnet',   'hi')
UNION ALL SELECT 'claude-4-opus',     SNOWFLAKE.CORTEX.TRY_COMPLETE('claude-4-opus',     'hi')
UNION ALL SELECT 'llama3.1-70b',      SNOWFLAKE.CORTEX.TRY_COMPLETE('llama3.1-70b',      'hi')
UNION ALL SELECT 'mistral-large2',    SNOWFLAKE.CORTEX.TRY_COMPLETE('mistral-large2',    'hi');
