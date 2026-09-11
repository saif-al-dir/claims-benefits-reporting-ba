-- ============================================================================
-- NovaCare Insurance — Claims & Benefits Reporting Solution
-- File:    04-implementation/sql/tests/dq_test_suite.sql   (DQ TESTS v1.0)
-- Purpose: Automated data quality assertions over the loaded warehouse.
--
-- Design:
--   * Each test records PASS/FAIL + evidence in a results table
--   * A final gate RAISES an EXCEPTION if any test failed
--   * Run:  psql "$DB_URL" -v ON_ERROR_STOP=1 -f dq_test_suite.sql
--     -> exit code 0 = all green; exit code 3 = failure (CI-detectable)
--
-- Categories:
--   A structure · B volume · C lineage · D distribution
--   E dq_gates · F business_rule · G story
--
-- Note: tests T08/T10/T12 encode a real incident (v1.0 degenerate-data bug:
-- random() in an uncorrelated FROM-subquery evaluated once per query).
-- ============================================================================

DROP TABLE IF EXISTS dq_test_results;
CREATE TEMP TABLE dq_test_results (
    test_id  TEXT,
    category TEXT,
    status   TEXT,
    detail   TEXT
);

-- ── A. Structure ───────────────────────────────────────────────────────────
DO $$ DECLARE v int;
BEGIN
    SELECT COUNT(*) INTO v FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name IN ('dim_date','dim_policy','dim_claimant','dim_handler',
                         'dim_claim','dim_benefit','fct_claim','fct_payment',
                         'fct_claim_status_snapshot','dq_audit_log','stg_raw_claims');
    INSERT INTO dq_test_results
    SELECT 'T01','structure', CASE WHEN v = 11 THEN 'PASS' ELSE 'FAIL' END,
           'expected 11 tables, found ' || v;
END $$;

DO $$ DECLARE v int; d1 date; d2 date;
BEGIN
    SELECT COUNT(*), MIN(full_date), MAX(full_date) INTO v, d1, d2 FROM dim_date;
    INSERT INTO dq_test_results
    SELECT 'T02','structure',
           CASE WHEN v = 1826 AND d1 = DATE '2021-01-01'
                     AND d2 = DATE '2025-12-31' THEN 'PASS' ELSE 'FAIL' END,
           format('dim_date rows=%s range=%s..%s', v, d1, d2);
END $$;

-- ── B. Volume (generous bounds — stable under seed/version drift) ─────────
DO $$ DECLARE v bigint;
BEGIN
    SELECT COUNT(*) INTO v FROM stg_raw_claims;
    INSERT INTO dq_test_results
    SELECT 'T03','volume',
           CASE WHEN v BETWEEN 140000 AND 160000 THEN 'PASS' ELSE 'FAIL' END,
           'stg_raw_claims rows=' || v;
END $$;

DO $$ DECLARE a bigint; b bigint;
BEGIN
    SELECT COUNT(*) INTO a FROM fct_claim;
    SELECT COUNT(*) INTO b FROM dim_claim;
    INSERT INTO dq_test_results
    SELECT 'T04','volume',
           CASE WHEN a BETWEEN 140000 AND 160000 AND a = b
                THEN 'PASS' ELSE 'FAIL' END,
           format('fct_claim=%s dim_claim=%s (must be equal)', a, b);
END $$;

DO $$ DECLARE v bigint;
BEGIN
    SELECT COUNT(*) INTO v FROM fct_payment;
    INSERT INTO dq_test_results
    SELECT 'T05','volume',
           CASE WHEN v BETWEEN 150000 AND 210000 THEN 'PASS' ELSE 'FAIL' END,
           'fct_payment rows=' || v || ' (recurring installments expected)';
END $$;

DO $$ DECLARE v bigint;
BEGIN
    SELECT COUNT(*) INTO v FROM fct_claim_status_snapshot;
    INSERT INTO dq_test_results
    SELECT 'T06','volume',
           CASE WHEN v BETWEEN 300000 AND 900000 THEN 'PASS' ELSE 'FAIL' END,
           'snapshot rows=' || v;
END $$;

-- ── C. Lineage (exact identity) ────────────────────────────────────────────
DO $$ DECLARE s bigint; l bigint; c bigint; d bigint; ok boolean;
BEGIN
    SELECT COUNT(*) INTO s FROM stg_raw_claims;
    SELECT COUNT(*) INTO l FROM fct_claim;
    SELECT COUNT(*) INTO c FROM dq_audit_log WHERE severity = 'Critical';
    SELECT COUNT(*) INTO d FROM dq_audit_log
    WHERE check_name = 'E2_duplicate_detection';
    ok := (s = l + c + d);
    INSERT INTO dq_test_results
    SELECT 'T07','lineage', CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END,
           format('source=%s = loaded=%s + critical=%s + duplicates=%s',
                  s, l, c, d);
END $$;

-- ── D. Distribution (the anti-degenerate class) ────────────────────────────
DO $$ DECLARE v int;
BEGIN
    SELECT COUNT(DISTINCT product) INTO v FROM dim_policy;
    INSERT INTO dq_test_results
    SELECT 'T08','distribution', CASE WHEN v >= 5 THEN 'PASS' ELSE 'FAIL' END,
           'distinct products=' || v || ' (v1.0 bug produced 1)';
END $$;

DO $$ DECLARE seg int; reg int;
BEGIN
    SELECT COUNT(DISTINCT customer_segment), COUNT(DISTINCT region)
    INTO seg, reg FROM dim_claimant;
    INSERT INTO dq_test_results
    SELECT 'T09','distribution',
           CASE WHEN seg = 4 AND reg = 5 THEN 'PASS' ELSE 'FAIL' END,
           format('claimant segments=%s regions=%s', seg, reg);
END $$;

DO $$ DECLARE v bigint;
BEGIN
    SELECT COUNT(DISTINCT claimant_sk) INTO v FROM fct_claim;
    INSERT INTO dq_test_results
    SELECT 'T10','distribution', CASE WHEN v >= 30000 THEN 'PASS' ELSE 'FAIL' END,
           'distinct claimants with claims=' || v || ' (v1.0 bug produced 1)';
END $$;

DO $$ DECLARE v int;
BEGIN
    SELECT COUNT(DISTINCT intake_channel) INTO v FROM dim_claim;
    INSERT INTO dq_test_results
    SELECT 'T11','distribution', CASE WHEN v = 4 THEN 'PASS' ELSE 'FAIL' END,
           'distinct intake channels=' || v;
END $$;

DO $$ DECLARE v bigint;
BEGIN
    SELECT COUNT(DISTINCT claimed_amount) INTO v FROM fct_claim;
    INSERT INTO dq_test_results
    SELECT 'T12','distribution', CASE WHEN v >= 50000 THEN 'PASS' ELSE 'FAIL' END,
           'distinct claimed amounts=' || v || ' (v1.0 bug produced 1)';
END $$;

DO $$ DECLARE total bigint; h bigint; a bigint; d bigint; ok boolean;
BEGIN
    SELECT COUNT(*) INTO total FROM fct_claim;
    SELECT COUNT(*) INTO h FROM fct_claim fc
    JOIN dim_policy dp ON dp.policy_sk = fc.policy_sk
    WHERE dp.line_of_business = 'Health';
    SELECT COUNT(*) INTO a FROM fct_claim fc
    JOIN dim_policy dp ON dp.policy_sk = fc.policy_sk
    WHERE dp.line_of_business = 'Accident';
    SELECT COUNT(*) INTO d FROM fct_claim fc
    JOIN dim_policy dp ON dp.policy_sk = fc.policy_sk
    WHERE dp.line_of_business = 'Disability';
    ok := h BETWEEN 0.50*total AND 0.70*total
       AND a BETWEEN 0.18*total AND 0.32*total
       AND d BETWEEN 0.10*total AND 0.20*total;
    INSERT INTO dq_test_results
    SELECT 'T13','distribution', CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END,
           format('LOB mix Health=%s Accident=%s Disability=%s of %s',
                  h, a, d, total);
END $$;

-- ── E. DQ gates (evidence of the ETL controls) ─────────────────────────────
DO $$ DECLARE v int;
BEGIN
    SELECT COUNT(*) INTO v FROM dq_audit_log
    WHERE check_name = 'E1_source_validation' AND severity = 'Critical';
    INSERT INTO dq_test_results
    SELECT 'T14','dq_gate',
           CASE WHEN v BETWEEN 20 AND 80 THEN 'PASS' ELSE 'FAIL' END,
           'E1 critical rejections=' || v;
END $$;

DO $$ DECLARE v int;
BEGIN
    SELECT COUNT(*) INTO v FROM dq_audit_log
    WHERE check_name = 'E2_duplicate_detection';
    INSERT INTO dq_test_results
    SELECT 'T15','dq_gate', CASE WHEN v = 40 THEN 'PASS' ELSE 'FAIL' END,
           'E2 duplicates removed=' || v;
END $$;

DO $$ DECLARE v int;
BEGIN
    SELECT COUNT(*) INTO v FROM dq_audit_log
    WHERE check_name = 'E3_handler_lookup';
    INSERT INTO dq_test_results
    SELECT 'T16','dq_gate',
           CASE WHEN v BETWEEN 100 AND 400 THEN 'PASS' ELSE 'FAIL' END,
           'E3 handler warnings=' || v;
END $$;

DO $$ DECLARE has999 int; claims999 bigint;
BEGIN
    SELECT COUNT(*) INTO has999 FROM dim_handler WHERE handler_id = 'H999';
    SELECT COUNT(*) INTO claims999 FROM fct_claim fc
    JOIN dim_handler dh ON dh.handler_sk = fc.handler_sk
    WHERE dh.handler_id = 'H999';
    INSERT INTO dq_test_results
    SELECT 'T17','dq_gate',
           CASE WHEN has999 = 1 AND claims999 BETWEEN 100 AND 400
                THEN 'PASS' ELSE 'FAIL' END,
           format('H999 exists=%s, claims defaulted to H999=%s',
                  has999, claims999);
END $$;

-- ── F. Business rules ──────────────────────────────────────────────────────
DO $$ DECLARE v bigint;
BEGIN
    SELECT COUNT(*) INTO v FROM fct_claim
    WHERE policy_sk IS NULL OR claimant_sk IS NULL
       OR handler_sk IS NULL OR fnol_date_key IS NULL;
    INSERT INTO dq_test_results
    SELECT 'T18','business_rule', CASE WHEN v = 0 THEN 'PASS' ELSE 'FAIL' END,
           'claims with NULL dimension keys=' || v;
END $$;

DO $$ DECLARE mn int; mx int;
BEGIN
    SELECT MIN(cycle_time_days), MAX(cycle_time_days) INTO mn, mx
    FROM fct_claim WHERE cycle_time_days IS NOT NULL;
    INSERT INTO dq_test_results
    SELECT 'T19','business_rule',
           CASE WHEN mn >= 0 AND mx <= 120 THEN 'PASS' ELSE 'FAIL' END,
           format('cycle time days min=%s max=%s', mn, mx);
END $$;

DO $$ DECLARE v bigint;
BEGIN
    SELECT COUNT(*) INTO v FROM fct_payment WHERE payment_amount <= 0;
    INSERT INTO dq_test_results
    SELECT 'T20','business_rule', CASE WHEN v = 0 THEN 'PASS' ELSE 'FAIL' END,
           'non-positive payments=' || v;
END $$;

DO $$ DECLARE v bigint;
BEGIN
    SELECT COUNT(*) INTO v
    FROM fct_claim fc
    JOIN (SELECT claim_sk, SUM(payment_amount) AS paid
          FROM fct_payment GROUP BY claim_sk) pay ON pay.claim_sk = fc.claim_sk
    WHERE fc.approved_benefit_amount IS NOT NULL
      AND pay.paid > fc.approved_benefit_amount;
    INSERT INTO dq_test_results
    SELECT 'T21','business_rule',
           CASE WHEN v BETWEEN 250 AND 450 THEN 'PASS' ELSE 'FAIL' END,
           'KPI-06 payment leakage claims=' || v;
END $$;

DO $$ DECLARE total bigint; breaches bigint; ratio numeric;
BEGIN
    SELECT COUNT(*), COUNT(*) FILTER (WHERE sla_met = false)
    INTO total, breaches
    FROM fct_claim WHERE sla_met IS NOT NULL;
    ratio := ROUND(100.0 * breaches / total, 1);
    INSERT INTO dq_test_results
    SELECT 'T22','business_rule',
           CASE WHEN ratio BETWEEN 5.0 AND 15.0 THEN 'PASS' ELSE 'FAIL' END,
           format('SLA breach rate=%s%% (breaches=%s of %s)',
                  ratio, breaches, total);
END $$;

-- ── G. The business story (the reason the project exists) ──────────────────
DO $$ DECLARE hlt numeric; dis numeric;
BEGIN
    SELECT ROUND(100.0*AVG(CASE WHEN fc.sla_met THEN 1 ELSE 0 END),1) INTO hlt
    FROM fct_claim fc
    JOIN dim_policy dp ON dp.policy_sk = fc.policy_sk
    WHERE fc.sla_met IS NOT NULL AND dp.line_of_business = 'Health';
    SELECT ROUND(100.0*AVG(CASE WHEN fc.sla_met THEN 1 ELSE 0 END),1) INTO dis
    FROM fct_claim fc
    JOIN dim_policy dp ON dp.policy_sk = fc.policy_sk
    WHERE fc.sla_met IS NOT NULL AND dp.line_of_business = 'Disability';
    INSERT INTO dq_test_results
    SELECT 'T23','story',
           CASE WHEN dis <= hlt - 10 THEN 'PASS' ELSE 'FAIL' END,
           format('Disability SLA=%s%% at least 10 pts below Health=%s%%',
                  dis, hlt);
END $$;

DO $$ DECLARE y22 numeric; y24 numeric;
BEGIN
    SELECT ROUND(100.0*AVG(CASE WHEN fc.sla_met THEN 1 ELSE 0 END),1) INTO y22
    FROM fct_claim fc
    JOIN dim_policy dp ON dp.policy_sk = fc.policy_sk
    JOIN dim_date dd ON dd.date_key = fc.decision_date_key
    WHERE fc.sla_met IS NOT NULL
      AND dp.line_of_business = 'Health' AND dd.year = 2022;
    SELECT ROUND(100.0*AVG(CASE WHEN fc.sla_met THEN 1 ELSE 0 END),1) INTO y24
    FROM fct_claim fc
    JOIN dim_policy dp ON dp.policy_sk = fc.policy_sk
    JOIN dim_date dd ON dd.date_key = fc.decision_date_key
    WHERE fc.sla_met IS NOT NULL
      AND dp.line_of_business = 'Health' AND dd.year = 2024;
    INSERT INTO dq_test_results
    SELECT 'T24','story',
           CASE WHEN y24 > y22 THEN 'PASS' ELSE 'FAIL' END,
           format('Health SLA improving: 2022=%s%% -> 2024=%s%%', y22, y24);
END $$;

-- ── Report ─────────────────────────────────────────────────────────────────
SELECT category, COUNT(*) AS tests,
       COUNT(*) FILTER (WHERE status = 'PASS') AS passed,
       COUNT(*) FILTER (WHERE status = 'FAIL') AS failed
FROM dq_test_results
GROUP BY category
ORDER BY category;

SELECT test_id, status, detail
FROM dq_test_results
WHERE status = 'FAIL'
ORDER BY test_id;

-- ── CI gate: nonzero psql exit if anything failed ──────────────────────────
DO $$ DECLARE n int;
BEGIN
    SELECT COUNT(*) INTO n FROM dq_test_results WHERE status = 'FAIL';
    IF n > 0 THEN
        RAISE EXCEPTION 'DQ SUITE FAILED — % test(s): %', n,
            (SELECT string_agg(test_id || ': ' || detail, ' | ')
             FROM dq_test_results WHERE status = 'FAIL');
    END IF;
    RAISE NOTICE 'DQ SUITE PASSED — all % tests green',
        (SELECT COUNT(*) FROM dq_test_results);
END $$;

-- [DQ TESTS v1.0 — END OF FILE]
