-- ============================================================================
-- NovaCare Insurance — Claims & Benefits Reporting Solution
-- File:    04-implementation/sql/data/run_full_load.sql   (FULL-LOAD v1.1)
-- Purpose: One-shot rebuild: synthetic legacy source + ETL + self-verification.
--          Same entry point the CI pipeline (GitHub Actions) will use.
--
-- v1.1 ROOT-CAUSE FIX:
--   random() inside an UNCORRELATED subquery in FROM is evaluated ONCE for
--   the whole query (the subquery is an independent derived table; LATERAL
--   alone does not force per-row evaluation when no outer column is
--   referenced). v1.0 therefore drew ONE value per query for LOB, SLA,
--   status, amounts and corruption -> degenerate data: all-Health claims,
--   100% SLA compliance, zero corruption.
--   Fix: every random-draw subquery now correlates to its driving row
--   (WHERE <outer>.<key> IS NOT NULL), forcing per-row evaluation.
--
-- READING THE OUTPUT: a banner '<n>/14: ...' prints after every section.
--   Last banner seen          = how far execution got
--   '14/14: COMPLETE' visible  = everything ran; results follow the banner
--
-- Prerequisite: schema.sql applied. Run as ONE batch in ONE session.
-- All data is synthetic — GDPR-safe.
-- ============================================================================

SELECT '1/14: FULL-LOAD v1.1 starts — destroying all old data' AS step;

-- ── Reset ──────────────────────────────────────────────────────────────────
SELECT setseed(0.42);

TRUNCATE dim_benefit, dim_handler, dim_policy, dim_claimant,
         dim_claim, dq_audit_log RESTART IDENTITY CASCADE;

DROP TABLE IF EXISTS stg_raw_claims;
CREATE TABLE stg_raw_claims (
    clm_id        VARCHAR(20),
    clm_stat      VARCHAR(2),
    clm_dat_fnol  VARCHAR(10),
    clm_dat_dec   VARCHAR(10),
    clm_dat_close VARCHAR(10),
    pol_id        VARCHAR(20),
    clmt_id       VARCHAR(20),
    handl         VARCHAR(12),
    chanl         VARCHAR(12),
    clm_reason    VARCHAR(30),
    rwn_cnt       INT,
    clamd_amt     BIGINT,
    apprd_amt     BIGINT
);

-- ── Benefits ───────────────────────────────────────────────────────────────
INSERT INTO dim_benefit (benefit_type, payment_form) VALUES
    ('Hospital Daily Allowance',    'One-time'),
    ('Outpatient Reimbursement',    'One-time'),
    ('Dental Reimbursement',        'One-time'),
    ('Physiotherapy Reimbursement', 'One-time'),
    ('Medication Reimbursement',    'One-time'),
    ('Accident Medical Sum',        'One-time'),
    ('Accident Lump Sum',           'One-time'),
    ('Disability Income Monthly',   'Recurring'),
    ('Disability Lump Sum',         'One-time');
SELECT '2/14: benefits loaded=' || COUNT(*)::text AS step FROM dim_benefit;

-- ── Handlers (55 in 4 teams + H999 UNKNOWN) ───────────────────────────────
INSERT INTO dim_handler (handler_id, team, experience_level)
SELECT 'H' || lpad(g::text, 3, '0'),
       CASE WHEN g <= 20 THEN 'Team Alpha'
            WHEN g <= 35 THEN 'Team Bravo'
            WHEN g <= 47 THEN 'Team Charlie'
            ELSE 'Team Delta' END,
       CASE WHEN x.r < 0.25 THEN 'Junior'
            WHEN x.r < 0.70 THEN 'Intermediate'
            ELSE 'Senior' END
FROM generate_series(1, 55) AS g
CROSS JOIN LATERAL (SELECT random() AS r
                    WHERE g IS NOT NULL) AS x;              -- v1.1: correlated
INSERT INTO dim_handler (handler_id, team, experience_level)
VALUES ('H999', 'Unassigned', 'N/A');
SELECT '3/14: handlers loaded=' || COUNT(*)::text AS step FROM dim_handler;

-- ── Policies (weighted product mix, SLA by product) ────────────────────────
INSERT INTO dim_policy (policy_id, product, line_of_business,
                        coverage_start, coverage_end, sla_days)
SELECT 'POL-' || lpad(g::text, 5, '0'),
       pr.product,
       pr.line_of_business,
       cs.coverage_start,
       GREATEST(cs.coverage_start + (1460 + floor(random() * 2190)::int),
                DATE '2025-12-31'),
       pr.sla_days
FROM generate_series(1, 10000) AS g
CROSS JOIN LATERAL (SELECT random() AS rw
                    WHERE g IS NOT NULL) AS rr              -- v1.1: correlated
JOIN LATERAL (
    SELECT product, line_of_business, sla_days
    FROM (VALUES
        (0.30, 'Health Basic',        'Health',     10),
        (0.50, 'Health Premium',      'Health',      7),
        (0.58, 'Health Dental',       'Health',     14),
        (0.70, 'Accident Personal',   'Accident',    5),
        (0.78, 'Accident Family',     'Accident',    5),
        (0.93, 'Disability Income',   'Disability', 21),
        (1.00, 'Disability Lump Sum', 'Disability', 30)
    ) AS w(cum, product, line_of_business, sla_days)
    WHERE rr.rw < w.cum
    ORDER BY w.cum
    LIMIT 1
) AS pr ON TRUE
CROSS JOIN LATERAL (SELECT (DATE '2015-01-01'
                            + floor(random() * 2000)::int)::date
                    AS coverage_start
                    WHERE g IS NOT NULL) AS cs;             -- v1.1: correlated
SELECT '4/14: policies loaded=' || COUNT(*)::text AS step FROM dim_policy;

-- ── Claimants ──────────────────────────────────────────────────────────────
INSERT INTO dim_claimant (claimant_id, age_band, region, customer_segment)
SELECT 'CLT-' || lpad(g::text, 5, '0'),
       CASE WHEN x.r1 < 0.18 THEN '18-29'
            WHEN x.r1 < 0.45 THEN '30-44'
            WHEN x.r1 < 0.70 THEN '45-59'
            WHEN x.r1 < 0.88 THEN '60-74'
            ELSE '75+' END,
       (ARRAY['North','South','East','West','Central'])[1 + floor(x.r2 * 5)::int],
       CASE WHEN x.r3 < 0.40 THEN 'Bronze'
            WHEN x.r3 < 0.75 THEN 'Silver'
            WHEN x.r3 < 0.93 THEN 'Gold'
            ELSE 'Platinum' END
FROM generate_series(1, 40000) AS g
CROSS JOIN LATERAL (SELECT random() AS r1, random() AS r2, random() AS r3
                    WHERE g IS NOT NULL) AS x;              -- v1.1: correlated
SELECT '5/14: claimants loaded=' || COUNT(*)::text AS step FROM dim_claimant;

-- ── Daily volumes + lookup arrays ──────────────────────────────────────────
CREATE TEMP TABLE tmp_daily_volume AS
SELECT d::date AS fnol_date,
       GREATEST(1, ROUND((
           115
           * CASE EXTRACT(MONTH FROM d)::int
                 WHEN 1 THEN 1.20 WHEN 2 THEN 1.08 WHEN 3 THEN 1.02
                 WHEN 4 THEN 0.95 WHEN 5 THEN 0.98 WHEN 6 THEN 1.05
                 WHEN 7 THEN 1.12 WHEN 8 THEN 1.06 WHEN 9 THEN 0.94
                 WHEN 10 THEN 1.00 WHEN 11 THEN 1.04 ELSE 1.18 END
           * CASE EXTRACT(YEAR FROM d)::int
                 WHEN 2022 THEN 1.00 WHEN 2023 THEN 1.12 ELSE 1.25 END
           * (0.85 + random() * 0.30)
       )::numeric)::int) AS n_claims
FROM generate_series(DATE '2022-01-01', DATE '2024-12-31', INTERVAL '1 day') AS d;

CREATE TEMP TABLE tmp_pol_by_lob AS
SELECT line_of_business, array_agg(policy_id ORDER BY policy_id) AS pol_ids
FROM dim_policy GROUP BY line_of_business;

CREATE TEMP TABLE tmp_claimants AS
SELECT array_agg(claimant_id ORDER BY claimant_id) AS clt_ids
FROM dim_claimant;
SELECT '6/14: daily volumes built, days=' || COUNT(*)::text AS step
FROM tmp_daily_volume;

-- ── Canonical claim universe — THE STORY ENGINE ────────────────────────────
-- v1.1: x, pp and cc are now CORRELATED to the claim row (s.seq), so every
-- claim draws its own random values. This is what restores the LOB mix,
-- the SLA breach model, varied amounts, channels and statuses.
CREATE TEMP TABLE tmp_claims_canonical AS
SELECT
    'CLM-' || to_char(v.fnol_date, 'YYYY') || '-' ||
    lpad((ROW_NUMBER() OVER (PARTITION BY EXTRACT(YEAR FROM v.fnol_date)::int
                             ORDER BY v.fnol_date, s.seq))::text, 6, '0') AS claim_id,
    v.fnol_date,
    l.lob,
    pp.policy_id,
    cc.claimant_id,
    'H' || lpad((CASE l.lob
                     WHEN 'Health'   THEN 1  + floor(random() * 35)::int
                     WHEN 'Accident' THEN 36 + floor(random() * 12)::int
                     ELSE                 48 + floor(random() * 8)::int
                 END)::text, 3, '0') AS handler_id,
    CASE WHEN x.r_chan < CASE l.yr WHEN 2022 THEN 0.25
                                      WHEN 2023 THEN 0.40
                                      ELSE 0.55 END THEN 'Portal'
         WHEN x.r_chan < 0.60 THEN 'Phone'
         WHEN x.r_chan < 0.75 THEN 'Email'
         ELSE 'Broker' END AS channel,
    CASE l.lob
        WHEN 'Health' THEN CASE WHEN x.r_reason < 0.25 THEN 'Inpatient Treatment'
                                WHEN x.r_reason < 0.55 THEN 'Outpatient Treatment'
                                WHEN x.r_reason < 0.70 THEN 'Dental Treatment'
                                WHEN x.r_reason < 0.85 THEN 'Physiotherapy'
                                ELSE 'Medication' END
        WHEN 'Accident' THEN CASE WHEN x.r_reason < 0.35 THEN 'Traffic Accident'
                                  WHEN x.r_reason < 0.65 THEN 'Work Accident'
                                  WHEN x.r_reason < 0.85 THEN 'Home Accident'
                                  ELSE 'Sports Injury' END
        ELSE CASE WHEN x.r_reason < 0.55 THEN 'Temporary Disability'
                  WHEN x.r_reason < 0.85 THEN 'Permanent Disability'
                  ELSE 'Rehabilitation Support' END
    END AS claim_reason,
    o2.status,
    o3.decision_date,
    o3.close_date,
    a.claimed_amount,
    o4.approved_amount,
    o4.reopen_count
FROM tmp_daily_volume v
CROSS JOIN LATERAL generate_series(1, v.n_claims) AS s(seq)
CROSS JOIN LATERAL (SELECT random() AS r_lob,  random() AS r_chan,
                           random() AS r_status, random() AS r_sla,
                           random() AS r_cycle, random() AS r_reason,
                           random() AS r_reopen, random() AS r_amt,
                           random() AS r_appr,  random() AS r_close
                    WHERE s.seq IS NOT NULL) AS x            -- v1.1: correlated
CROSS JOIN LATERAL (SELECT CASE WHEN x.r_lob < 0.60 THEN 'Health'
                                WHEN x.r_lob < 0.85 THEN 'Accident'
                                ELSE 'Disability' END AS lob,
                           EXTRACT(YEAR FROM v.fnol_date)::int AS yr) AS l
JOIN tmp_pol_by_lob p ON p.line_of_business = l.lob
CROSS JOIN LATERAL (SELECT p.pol_ids[1 + floor(random()
                    * array_length(p.pol_ids, 1))::int] AS policy_id
                    WHERE s.seq IS NOT NULL) AS pp           -- v1.1: correlated
JOIN dim_policy dp ON dp.policy_id = pp.policy_id
CROSS JOIN tmp_claimants tc
CROSS JOIN LATERAL (SELECT tc.clt_ids[1 + floor(random()
                    * array_length(tc.clt_ids, 1))::int] AS claimant_id
                    WHERE s.seq IS NOT NULL) AS cc           -- v1.1: correlated
CROSS JOIN LATERAL (
    SELECT CASE l.lob
        WHEN 'Health'   THEN CASE l.yr WHEN 2022 THEN 0.900
                                          WHEN 2023 THEN 0.930 ELSE 0.955 END
        WHEN 'Accident' THEN CASE l.yr WHEN 2022 THEN 0.940 ELSE 0.950 END
        ELSE                 CASE l.yr WHEN 2022 THEN 0.740
                                          WHEN 2023 THEN 0.760 ELSE 0.780 END
    END AS p_sla_met) AS o0
CROSS JOIN LATERAL (
    SELECT x.r_sla < o0.p_sla_met AS sla_met,
           CASE WHEN x.r_sla < o0.p_sla_met
                THEN 1 + floor(x.r_cycle * (dp.sla_days - 1))::int
                ELSE dp.sla_days + 1 + floor(x.r_cycle * dp.sla_days * 2)::int
           END AS cycle_days) AS o1
CROSS JOIN LATERAL (
    SELECT CASE
        WHEN (DATE '2024-12-31' - v.fnol_date) < 7 THEN
             CASE WHEN x.r_status < 0.55 THEN 'Registered'
                  ELSE 'In Assessment' END
        WHEN (DATE '2024-12-31' - v.fnol_date) < 30 THEN
             CASE WHEN x.r_status < 0.05 THEN 'Registered'
                  WHEN x.r_status < 0.55 THEN 'In Assessment'
                  WHEN x.r_status < 0.61 THEN 'Decided'
                  WHEN x.r_status < 0.65 THEN 'Rejected'
                  ELSE 'Closed' END
        WHEN (DATE '2024-12-31' - v.fnol_date) < 90 THEN
             CASE WHEN x.r_status < 0.01 THEN 'Registered'
                  WHEN x.r_status < 0.12 THEN 'In Assessment'
                  WHEN x.r_status < 0.17 THEN 'Decided'
                  WHEN x.r_status < 0.25 THEN 'Rejected'
                  ELSE 'Closed' END
        ELSE
             CASE WHEN x.r_status < 0.001 THEN 'Registered'
                  WHEN x.r_status < 0.005 THEN 'In Assessment'
                  WHEN x.r_status < 0.010 THEN 'Decided'
                  WHEN x.r_status < 0.090 THEN 'Rejected'
                  ELSE 'Closed' END
    END AS status) AS o2
CROSS JOIN LATERAL (
    SELECT CASE WHEN o2.status IN ('Decided','Rejected','Closed')
                THEN v.fnol_date + o1.cycle_days END AS decision_date,
           CASE WHEN o2.status = 'Closed'
                THEN v.fnol_date + o1.cycle_days + 1 + floor(x.r_close * 10)::int
                WHEN o2.status = 'Rejected'
                THEN v.fnol_date + o1.cycle_days + 1 + floor(x.r_close * 5)::int
           END AS close_date) AS o3
CROSS JOIN LATERAL (
    SELECT CASE l.lob
        WHEN 'Health'   THEN ROUND((150.0  + x.r_amt * 3350 )::numeric, 2)
        WHEN 'Accident' THEN ROUND((300.0  + x.r_amt * 7700 )::numeric, 2)
        ELSE                 ROUND((1000.0 + x.r_amt * 19000)::numeric, 2)
    END AS claimed_amount) AS a
CROSS JOIN LATERAL (
    SELECT CASE WHEN o2.status IN ('Decided','Closed')
                THEN ROUND((a.claimed_amount * (0.55 + x.r_appr * 0.45))::numeric, 2)
           END AS approved_amount,
           CASE WHEN o2.status = 'Closed'
                THEN CASE WHEN x.r_reopen < 0.012 THEN 2
                          WHEN x.r_reopen < 0.058 THEN 1
                          ELSE 0 END
                ELSE 0 END AS reopen_count) AS o4;

SELECT '7/14: canonical built: total=' || COUNT(*)::text
       || ' | Health=' || COUNT(*) FILTER (WHERE lob = 'Health')::text
       || ' Accident=' || COUNT(*) FILTER (WHERE lob = 'Accident')::text
       || ' Disability=' || COUNT(*) FILTER (WHERE lob = 'Disability')::text
       || ' (expect ~149,346 | ~89,600 | ~37,300 | ~22,400)' AS step
FROM tmp_claims_canonical;

-- ── Legacy "export" WITH controlled corruption ─────────────────────────────
INSERT INTO stg_raw_claims (clm_id, clm_stat, clm_dat_fnol, clm_dat_dec,
                            clm_dat_close, pol_id, clmt_id, handl, chanl,
                            clm_reason, rwn_cnt, clamd_amt, apprd_amt)
SELECT
    c.claim_id,
    CASE c.status WHEN 'Registered'    THEN '1'
                  WHEN 'In Assessment' THEN '2'
                  WHEN 'Decided'       THEN '3'
                  WHEN 'Rejected'      THEN '4'
                  ELSE '9' END,
    CASE WHEN dg.r_b1 < 0.0002
         THEN (ARRAY['XX.XX.XXXX', '2023/07/14', ' .09.2023',
                     '00.01.2022', '1.2.2023', '31.02.2024'])[1 + floor(dg.r_b2 * 6)::int]
         ELSE to_char(c.fnol_date, 'DD.MM.YYYY') END,
    CASE WHEN dg.r_b3 < 0.0001 AND c.decision_date IS NOT NULL
         THEN to_char(c.fnol_date - 30, 'DD.MM.YYYY')
         ELSE to_char(c.decision_date, 'DD.MM.YYYY') END,
    to_char(c.close_date, 'DD.MM.YYYY'),
    c.policy_id,
    c.claimant_id,
    CASE WHEN dg.r_b4 < 0.0015
         THEN 'H' || lpad((90 + floor(dg.r_b4 * 6000)::int % 9)::text, 3, '0')
         WHEN dg.r_b4 < 0.0050 THEN lower(c.handler_id)
         WHEN dg.r_b4 < 0.0080 THEN ' ' || c.handler_id || ' '
         ELSE c.handler_id END,
    CASE c.channel
        WHEN 'Phone'  THEN (ARRAY['Phone','phone','PHONE',' Phone '])[1 + floor(dg.r_b5 * 4)::int]
        WHEN 'Portal' THEN (ARRAY['Portal','portal','PORTAL',' Portal '])[1 + floor(dg.r_b5 * 4)::int]
        WHEN 'Email'  THEN (ARRAY['Email','email','E-Mail','EMAIL'])[1 + floor(dg.r_b5 * 4)::int]
        ELSE (ARRAY['Broker','broker','BROKER',' Broker '])[1 + floor(dg.r_b5 * 4)::int]
    END,
    c.claim_reason,
    c.reopen_count,
    (c.claimed_amount * 100)::BIGINT,
    (c.approved_amount * 100)::BIGINT
FROM tmp_claims_canonical c
CROSS JOIN LATERAL (SELECT random() AS r_b1, random() AS r_b2, random() AS r_b3,
                           random() AS r_b4, random() AS r_b5
                    WHERE c.claim_id IS NOT NULL) AS dg;    -- v1.1: correlated

SELECT '8/14: legacy export: rows=' || COUNT(*)::text
       || ' | bad FNOL dates=' || COUNT(*) FILTER (
             WHERE clm_dat_fnol !~ '^\d{2}\.\d{2}\.\d{4}$'
                OR clm_dat_fnol IN ('31.02.2024','00.01.2022'))::text
       || ' | unknown handlers=' || (SELECT COUNT(*) FROM stg_raw_claims s
             WHERE UPPER(TRIM(s.handl)) NOT IN
                   (SELECT handler_id FROM dim_handler))::text
       || ' (expect ~149,346 | ~25-35 | ~220)' AS step
FROM stg_raw_claims;

-- ── Inject 40 exact duplicates ─────────────────────────────────────────────
INSERT INTO stg_raw_claims (clm_id, clm_stat, clm_dat_fnol, clm_dat_dec,
                            clm_dat_close, pol_id, clmt_id, handl, chanl,
                            clm_reason, rwn_cnt, clamd_amt, apprd_amt)
SELECT clm_id, clm_stat, clm_dat_fnol, clm_dat_dec, clm_dat_close,
       pol_id, clmt_id, handl, chanl, clm_reason, rwn_cnt, clamd_amt, apprd_amt
FROM stg_raw_claims
ORDER BY clm_id
LIMIT 40 OFFSET 60000;

DROP TABLE IF EXISTS tmp_daily_volume, tmp_pol_by_lob, tmp_claimants,
                        tmp_claims_canonical;
SELECT '9/14: duplicates injected, source final rows=' || COUNT(*)::text
       || ' (expect ~149,386)' AS step
FROM stg_raw_claims;

-- ═════════════════════ ETL ════════════════════════════════════════════════

SELECT setseed(0.77);

CREATE OR REPLACE FUNCTION fn_safe_to_date(p_raw TEXT)
RETURNS DATE
LANGUAGE sql IMMUTABLE STRICT AS $$     SELECT CASE
        WHEN p_raw ~ '^\d{2}\.\d{2}\.\d{4}$'
        THEN CASE
            WHEN substring(p_raw, 4, 2)::int BETWEEN 1 AND 12
             AND substring(p_raw, 1, 2)::int BETWEEN 1 AND 31
             AND substring(p_raw, 1, 2)::int <= (CASE substring(p_raw, 4, 2)::int
                    WHEN 2  THEN CASE WHEN substring(p_raw, 7, 4)::int % 4 = 0
                                      THEN 29 ELSE 28 END
                    WHEN 4  THEN 30 WHEN 6 THEN 30
                    WHEN 9  THEN 30 WHEN 11 THEN 30
                    ELSE 31 END)
            THEN make_date(substring(p_raw, 7, 4)::int,
                           substring(p_raw, 4, 2)::int,
                           substring(p_raw, 1, 2)::int)
        END
    END
 $$;

TRUNCATE dim_claim, dq_audit_log RESTART IDENTITY CASCADE;

INSERT INTO dq_audit_log (check_name, severity, source_table, source_row, violation)
SELECT 'E2_duplicate_detection', 'Warning', 'stg_raw_claims', t.clm_id,
       'Exact duplicate source row removed during deduplication'
FROM (SELECT clm_id,
             ROW_NUMBER() OVER (PARTITION BY clm_id ORDER BY clm_stat) AS rn
      FROM stg_raw_claims) t
WHERE t.rn > 1;

DROP TABLE IF EXISTS tmp_etl_claims;
CREATE TEMP TABLE tmp_etl_claims AS
WITH deduped AS (
    SELECT s.*,
           ROW_NUMBER() OVER (PARTITION BY s.clm_id ORDER BY s.clm_stat) AS rn
    FROM stg_raw_claims s
),
parsed AS (
    SELECT d.clm_id, d.clm_stat, d.clm_dat_fnol, d.clm_dat_dec, d.clm_dat_close,
           d.pol_id, d.clmt_id, d.handl, d.chanl, d.clm_reason, d.rwn_cnt,
           d.clamd_amt, d.apprd_amt,
           fn_safe_to_date(d.clm_dat_fnol)  AS fnol_date,
           fn_safe_to_date(d.clm_dat_dec)   AS decision_date,
           fn_safe_to_date(d.clm_dat_close) AS close_date,
           UPPER(TRIM(d.chanl)) AS chanl_norm,
           UPPER(TRIM(d.handl)) AS handl_norm
    FROM deduped d
    WHERE d.rn = 1
),
validated AS (
    SELECT p.*,
           CASE
               WHEN p.clm_stat NOT IN ('1','2','3','4','9')
                   THEN 'Invalid status code: ' || p.clm_stat
               WHEN p.fnol_date IS NULL
                   THEN 'Invalid FNOL date: ' || COALESCE(p.clm_dat_fnol, '(empty)')
               WHEN p.decision_date IS NOT NULL AND p.decision_date < p.fnol_date
                   THEN 'Decision date before FNOL date'
               WHEN p.close_date IS NOT NULL AND p.close_date < p.decision_date
                   THEN 'Close date before decision date'
               WHEN p.clm_stat IN ('3','4','9') AND p.decision_date IS NULL
                   THEN 'Decided/Rejected/Closed without decision date'
               WHEN p.clm_stat = '9' AND p.close_date IS NULL
                   THEN 'Closed without close date'
           END AS reject_reason
    FROM parsed p
)
SELECT * FROM validated;

INSERT INTO dq_audit_log (check_name, severity, source_table, source_row, violation)
SELECT 'E1_source_validation', 'Critical', 'stg_raw_claims', clm_id, reject_reason
FROM tmp_etl_claims
WHERE reject_reason IS NOT NULL;

INSERT INTO dq_audit_log (check_name, severity, source_table, source_row, violation)
SELECT 'E3_handler_lookup', 'Warning', 'stg_raw_claims', clm_id,
       'Unknown handler code ''' || handl_norm || ''' defaulted to H999 (Unassigned)'
FROM tmp_etl_claims
WHERE reject_reason IS NULL
  AND handl_norm NOT IN (SELECT handler_id FROM dim_handler);

INSERT INTO dim_claim (claim_id, line_of_business, intake_channel,
                       claim_reason, current_status, reopen_count)
SELECT e.clm_id,
       dp.line_of_business,
       CASE e.chanl_norm WHEN 'PHONE'  THEN 'Phone'
                         WHEN 'PORTAL' THEN 'Portal'
                         WHEN 'E-MAIL' THEN 'Email'
                         WHEN 'EMAIL'  THEN 'Email'
                         WHEN 'BROKER' THEN 'Broker'
                         ELSE 'Phone' END,
       e.clm_reason,
       CASE e.clm_stat WHEN '1' THEN 'Registered'
                       WHEN '2' THEN 'In Assessment'
                       WHEN '3' THEN 'Decided'
                       WHEN '4' THEN 'Rejected'
                       ELSE 'Closed' END,
       COALESCE(e.rwn_cnt, 0)
FROM tmp_etl_claims e
JOIN dim_policy dp ON dp.policy_id = e.pol_id
WHERE e.reject_reason IS NULL;

INSERT INTO fct_claim (claim_sk, policy_sk, claimant_sk, handler_sk,
                       fnol_date_key, decision_date_key, close_date_key,
                       claimed_amount, approved_benefit_amount, reserve_amount,
                       cycle_time_days, sla_met, first_pass_flag)
SELECT dc.claim_sk,
       dp.policy_sk,
       dct.claimant_sk,
       COALESCE(dh.handler_sk, dh999.handler_sk),
       dfn.date_key,
       dcd.date_key,
       dcl.date_key,
       e.clamd_amt / 100.00,
       CASE WHEN e.apprd_amt IS NULL OR e.apprd_amt <= 0
            THEN NULL ELSE e.apprd_amt / 100.00 END,
       CASE WHEN e.clm_stat IN ('1','2')
            THEN ROUND((e.clamd_amt / 100.00) * 0.8, 2) ELSE 0 END,
       CASE WHEN e.decision_date IS NOT NULL
            THEN (e.decision_date - e.fnol_date) END,
       CASE WHEN e.decision_date IS NOT NULL
            THEN (e.decision_date - e.fnol_date) <= dp.sla_days END,
       COALESCE(e.rwn_cnt, 0) = 0
FROM tmp_etl_claims e
JOIN dim_claim    dc    ON dc.claim_id     = e.clm_id
JOIN dim_policy   dp    ON dp.policy_id    = e.pol_id
JOIN dim_claimant dct   ON dct.claimant_id = e.clmt_id
LEFT JOIN dim_handler dh ON dh.handler_id  = e.handl_norm
JOIN dim_handler  dh999 ON dh999.handler_id = 'H999'
JOIN dim_date     dfn   ON dfn.full_date   = e.fnol_date
LEFT JOIN dim_date dcd  ON dcd.full_date   = e.decision_date
LEFT JOIN dim_date dcl  ON dcl.full_date   = e.close_date;

SELECT '10/14: ETL claims loaded=' || COUNT(*)::text
       || ' | critical rejected=' || (SELECT COUNT(*) FROM dq_audit_log
             WHERE severity = 'Critical')::text
       || ' (expect ~149,300 | ~40-50)' AS step
FROM fct_claim;

-- ── Payments (one-time + recurring installments) ───────────────────────────
INSERT INTO fct_payment (claim_sk, benefit_sk, payment_date_key, payment_amount)
SELECT dc.claim_sk, db.benefit_sk, dpay.date_key, pa.pay_amt
FROM tmp_etl_claims e
JOIN dim_claim dc ON dc.claim_id = e.clm_id
CROSS JOIN LATERAL (
    SELECT CASE e.clm_reason
               WHEN 'Inpatient Treatment'    THEN 'Hospital Daily Allowance'
               WHEN 'Outpatient Treatment'   THEN 'Outpatient Reimbursement'
               WHEN 'Dental Treatment'       THEN 'Dental Reimbursement'
               WHEN 'Physiotherapy'          THEN 'Physiotherapy Reimbursement'
               WHEN 'Medication'             THEN 'Medication Reimbursement'
               WHEN 'Permanent Disability'   THEN 'Disability Lump Sum'
               WHEN 'Temporary Disability'   THEN 'Disability Income Monthly'
               WHEN 'Rehabilitation Support' THEN 'Disability Income Monthly'
               ELSE 'Accident Medical Sum'
           END AS benefit_type,
           CASE WHEN e.clm_reason IN ('Temporary Disability','Rehabilitation Support')
                THEN 'Recurring' ELSE 'One-time' END AS payment_form
) AS bm
JOIN dim_benefit db ON db.benefit_type = bm.benefit_type
CROSS JOIN LATERAL (
    SELECT CASE WHEN bm.payment_form = 'Recurring'
                THEN LEAST(3 + floor(random() * 6)::int,
                           GREATEST(1, (DATE '2024-12-31' - e.decision_date) / 30))
                ELSE 1 END::int AS n_inst
) AS ni
CROSS JOIN LATERAL generate_series(1, ni.n_inst) AS inst(i)
CROSS JOIN LATERAL (
    SELECT CASE WHEN inst.i < ni.n_inst
                THEN ROUND(e.apprd_amt / 100.00 / ni.n_inst, 2)
                ELSE e.apprd_amt / 100.00
                     - ROUND(e.apprd_amt / 100.00 / ni.n_inst, 2) * (ni.n_inst - 1)
           END AS pay_amt,
           LEAST(CASE WHEN bm.payment_form = 'Recurring'
                      THEN e.decision_date + (5 + 30 * (inst.i - 1))
                      ELSE e.decision_date + (2 + floor(random() * 7)::int)
                 END,
                 DATE '2024-12-31') AS pay_date
) AS pa
JOIN dim_date dpay ON dpay.full_date = pa.pay_date
WHERE e.clm_stat IN ('3','9')
  AND e.apprd_amt > 0
  AND e.decision_date IS NOT NULL;

-- ── Controlled payment leakage (detectable by KPI-06) ─────────────────────
CREATE TEMP TABLE tmp_leak_dup AS
SELECT claim_sk, MIN(payment_id) AS dup_payment_id
FROM fct_payment
GROUP BY claim_sk
ORDER BY md5(MIN(payment_id)::text)
LIMIT 220;

INSERT INTO fct_payment (claim_sk, benefit_sk, payment_date_key, payment_amount)
SELECT fp.claim_sk, fp.benefit_sk, d2.date_key, fp.payment_amount
FROM tmp_leak_dup t
JOIN fct_payment fp ON fp.payment_id = t.dup_payment_id
JOIN dim_date d1 ON d1.date_key = fp.payment_date_key
JOIN dim_date d2 ON d2.full_date = d1.full_date + 1;

CREATE TEMP TABLE tmp_leak_reissue AS
SELECT claim_sk, approved_benefit_amount
FROM fct_claim
WHERE approved_benefit_amount IS NOT NULL
ORDER BY md5(claim_sk::text)
LIMIT 120;

INSERT INTO fct_payment (claim_sk, benefit_sk, payment_date_key, payment_amount)
SELECT t.claim_sk, fp.benefit_sk, d2.date_key,
       ROUND(t.approved_benefit_amount * 0.4, 2)
FROM tmp_leak_reissue t
JOIN fct_payment fp
  ON fp.payment_id = (SELECT MIN(payment_id) FROM fct_payment
                      WHERE claim_sk = t.claim_sk)
JOIN dim_date d1 ON d1.date_key = fp.payment_date_key
JOIN dim_date d2 ON d2.full_date = LEAST(d1.full_date + 14, DATE '2024-12-31');

SELECT '11/14: payments=' || COUNT(*)::text
       || ' (expect ~160,000-190,000 — recurring benefits included)' AS step
FROM fct_payment;

-- ── Status snapshots (backlog/aging history) ───────────────────────────────
INSERT INTO fct_claim_status_snapshot (snapshot_date_key, claim_sk, status, days_open)
SELECT ts.date_key,
       dc.claim_sk,
       CASE WHEN e.decision_date IS NOT NULL AND ts.full_date >= e.decision_date
            THEN CASE WHEN e.clm_stat = '4' THEN 'Rejected' ELSE 'Decided' END
            WHEN ts.full_date < e.fnol_date + 3 THEN 'Registered'
            ELSE 'In Assessment'
       END,
       ts.full_date - e.fnol_date
FROM (SELECT date_key, full_date
      FROM dim_date
      WHERE (is_month_end AND full_date BETWEEN DATE '2022-01-31'
                                            AND DATE '2024-12-31')
         OR full_date BETWEEN DATE '2024-10-01' AND DATE '2024-12-31') AS ts
JOIN tmp_etl_claims e
     ON e.reject_reason IS NULL
    AND e.fnol_date <= ts.full_date
    AND (e.close_date IS NULL OR ts.full_date < e.close_date)
JOIN dim_claim dc ON dc.claim_id = e.clm_id;

DROP TABLE IF EXISTS tmp_etl_claims, tmp_leak_dup, tmp_leak_reissue;
SELECT '12/14: snapshots=' || COUNT(*)::text
       || ' (expect several hundred thousand)' AS step
FROM fct_claim_status_snapshot;

-- ═══════════════ SELF-VERIFICATION ════════════════════════════════════════

SELECT '13/14: LINEAGE IDENTITY: ' ||
       CASE WHEN (SELECT COUNT(*) FROM stg_raw_claims) =
                 (SELECT COUNT(*) FROM fct_claim)
                 + (SELECT COUNT(*) FROM dq_audit_log WHERE severity = 'Critical')
                 + (SELECT COUNT(*) FROM dq_audit_log
                    WHERE check_name = 'E2_duplicate_detection')
            THEN 'PASS — source = loaded + critical + duplicates'
            ELSE 'FAIL — counts do not balance, do not trust this load'
       END AS step;

SELECT '14/14: FULL-LOAD COMPLETE — results follow, copy them into your reply'
       AS step;

-- Result 1: DQ audit summary (expect E1 Critical ~40-50, E2 Warning 40, E3 Warning ~220)
SELECT check_name, severity, COUNT(*) AS violations
FROM dq_audit_log
GROUP BY check_name, severity
ORDER BY check_name;

-- Result 2: THE BUSINESS STORY — SLA compliance (expect 9 rows;
-- Health ~90->95.5 improving, Accident ~94-95 flat, Disability stuck ~74-78)
SELECT dp.line_of_business, dd.year, COUNT(*) AS decided_claims,
       ROUND(100.0 * AVG(CASE WHEN fc.sla_met THEN 1 ELSE 0 END), 1) AS sla_pct
FROM fct_claim fc
JOIN dim_policy dp ON dp.policy_sk = fc.policy_sk
JOIN dim_date dd ON dd.date_key = fc.decision_date_key
GROUP BY dp.line_of_business, dd.year
ORDER BY dp.line_of_business, dd.year;

-- Result 3: payment leakage, KPI-06 (expect ~330-340)
SELECT COUNT(*) AS claims_with_overpayment
FROM fct_claim fc
JOIN (SELECT claim_sk, SUM(payment_amount) AS paid
      FROM fct_payment GROUP BY claim_sk) pay ON pay.claim_sk = fc.claim_sk
WHERE fc.approved_benefit_amount IS NOT NULL
  AND pay.paid > fc.approved_benefit_amount;

-- [FULL-LOAD v1.1 — END OF FILE]
