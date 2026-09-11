-- Final fingerprint — V1–V5 plus D2:
SELECT sla_met, COUNT(*) FROM fct_claim GROUP BY sla_met;

-- 1) All 10 tables created (expect exactly these)
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;

-- 2) Date dimension loaded (expect 1826 rows, 2021-01-01 → 2025-12-31)
SELECT COUNT(*) AS date_rows, MIN(full_date) AS first_date, MAX(full_date) AS last_date
FROM dim_date;

-- 3) Constraint smoke test — this MUST fail:
INSERT INTO dim_policy (policy_id, product, line_of_business,
                        coverage_start, coverage_end, sla_days)
VALUES ('POL-TEST-001', 'Health Basic', 'Health', '2023-01-01', '2025-12-31', 0);

-- V1: row counts. Expect ~149K source / ~149K claims / ~185-195K payments /
--     ~600-800K snapshots / ~300 DQ log entries
SELECT 'stg_raw_claims' AS tbl, COUNT(*) AS n FROM stg_raw_claims
UNION ALL SELECT 'dim_claim', COUNT(*) FROM dim_claim
UNION ALL SELECT 'fct_claim', COUNT(*) FROM fct_claim
UNION ALL SELECT 'fct_payment', COUNT(*) FROM fct_payment
UNION ALL SELECT 'fct_claim_status_snapshot', COUNT(*) FROM fct_claim_status_snapshot
UNION ALL SELECT 'dq_audit_log', COUNT(*) FROM dq_audit_log;

-- V2: lineage identity — MUST hold exactly: source = loaded + critical + duplicates
SELECT (SELECT COUNT(*) FROM stg_raw_claims) AS source_rows,
       (SELECT COUNT(*) FROM fct_claim) AS claims_loaded,
       (SELECT COUNT(*) FROM dq_audit_log WHERE severity = 'Critical') AS critical_rejected,
       (SELECT COUNT(*) FROM dq_audit_log WHERE check_name = 'E2_duplicate_detection') AS duplicates_removed;


-- V3: DQ audit summary — expect E1 Critical ~40, E2 Warning ~40, E3 Warning ~220
SELECT check_name, severity, COUNT(*) AS violations
FROM dq_audit_log GROUP BY check_name, severity ORDER BY check_name;

-- V4: the story your dashboard will tell — SLA compliance by LOB and year
SELECT dp.line_of_business, dd.year, COUNT(*) AS decided_claims,
       ROUND(100.0 * AVG(CASE WHEN fc.sla_met THEN 1 ELSE 0 END), 1) AS sla_pct
FROM fct_claim fc
JOIN dim_policy dp ON dp.policy_sk = fc.policy_sk
JOIN dim_date dd ON dd.date_key = fc.decision_date_key
GROUP BY dp.line_of_business, dd.year
ORDER BY dp.line_of_business, dd.year;

-- V5: leakage preview (KPI-06) — expect ~330-340 claims paid above approved
SELECT COUNT(*) AS claims_with_overpayment
FROM fct_claim fc
JOIN (SELECT claim_sk, SUM(payment_amount) AS paid
      FROM fct_payment GROUP BY claim_sk) pay ON pay.claim_sk = fc.claim_sk
WHERE fc.approved_benefit_amount IS NOT NULL
  AND pay.paid > fc.approved_benefit_amount;


-- T1: Does the staging table exist? (NULL = never created)
SELECT to_regclass('public.stg_raw_claims') AS stg_raw_claims;


-- T2: Did the generator run? (Expected if it did: 9 / 56 / 10000 / 40000 / 0)
SELECT 'dim_benefit'  AS tbl, COUNT(*) AS n FROM dim_benefit
UNION ALL SELECT 'dim_handler',  COUNT(*) FROM dim_handler
UNION ALL SELECT 'dim_policy',   COUNT(*) FROM dim_policy
UNION ALL SELECT 'dim_claimant', COUNT(*) FROM dim_claimant
UNION ALL SELECT 'dim_claim',    COUNT(*) FROM dim_claim;

-- T3: Was the Step 3.1 edit ('N/A') applied to the schema?
SELECT check_clause FROM information_schema.check_constraints
WHERE constraint_name = 'dim_handler_experience_level_check';


-- X1 — Which ETL version has ever run? (my ETL creates this function; an old variant doesn't)
SELECT COUNT(*) AS new_etl_ran FROM pg_proc WHERE proname = 'fn_safe_to_date';

-- X2 — Which generator version produced the source? (v2 assigns handlers by line of business: H001–035 Health, H036–047 Accident, H048–055 Disability)
SELECT
    CASE WHEN UPPER(TRIM(handl)) BETWEEN 'H001' AND 'H035' THEN 'Health-range'
         WHEN UPPER(TRIM(handl)) BETWEEN 'H036' AND 'H047' THEN 'Accident-range'
         WHEN UPPER(TRIM(handl)) BETWEEN 'H048' AND 'H055' THEN 'Disability-range'
         WHEN UPPER(TRIM(handl)) BETWEEN 'H090' AND 'H098' THEN 'Corrupt (expected!)'
         ELSE 'Other' END AS handler_group,
    COUNT(*) AS claims
FROM stg_raw_claims
GROUP BY 1
ORDER BY 1;

-- X3 — Corruption injection present?
SELECT COUNT(*) AS bad_fnol_dates
FROM stg_raw_claims
WHERE clm_dat_fnol !~ '^\d{2}\.\d{2}\.\d{4}$'
   OR clm_dat_fnol IN ('31.02.2024', '00.01.2022');


-- S1: expect ~30 (25–35)
SELECT COUNT(*) AS bad_fnol_dates FROM stg_raw_claims
WHERE clm_dat_fnol !~ '^\d{2}\.\d{2}\.\d{4}$'
   OR clm_dat_fnol IN ('31.02.2024', '00.01.2022');

-- S2: expect roughly 89,600 / 37,300 / 22,400 / ~220
SELECT CASE WHEN UPPER(TRIM(handl)) BETWEEN 'H001' AND 'H035' THEN 'Health-range'
            WHEN UPPER(TRIM(handl)) BETWEEN 'H036' AND 'H047' THEN 'Accident-range'
            WHEN UPPER(TRIM(handl)) BETWEEN 'H048' AND 'H055' THEN 'Disability-range'
            WHEN UPPER(TRIM(handl)) BETWEEN 'H090' AND 'H098' THEN 'Corrupt'
            ELSE 'Other' END AS handler_group,
       COUNT(*) AS claims
FROM stg_raw_claims GROUP BY 1 ORDER BY 1;