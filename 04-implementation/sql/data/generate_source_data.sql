-- ============================================================================
-- NovaCare Insurance — Claims & Benefits Reporting Solution
-- File:    04-implementation/sql/data/generate_source_data.sql
-- Purpose: Generates reproducible SYNTHETIC test data.
--          Part 1: reference dimensions (except dim_date / dim_claim)
--          Part 2: stg_raw_claims — simulated LEGACY extract ("dirty" source)
--
-- Run as ONE batch in a single session (required for seed reproducibility).
-- Expected runtime: ~30-60 seconds.
-- All data is fictional — no real customer data (GDPR-safe).
-- ============================================================================

SELECT setseed(0.42);   -- master seed: same seed + same script = same data

-- 0. Reset (idempotent re-run). dim_date is untouched (loaded by schema.sql).
--    CASCADE also clears all fact tables referencing these dimensions.
TRUNCATE dim_benefit, dim_handler, dim_policy, dim_claimant,
         dim_claim, dq_audit_log RESTART IDENTITY CASCADE;

DROP TABLE IF EXISTS stg_raw_claims;
CREATE TABLE stg_raw_claims (
    clm_id        VARCHAR(20),
    clm_stat      VARCHAR(2),   -- legacy status code (mapping in ETL)
    clm_dat_fnol  VARCHAR(10),  -- 'DD.MM.YYYY' — sometimes corrupted
    clm_dat_dec   VARCHAR(10),
    clm_dat_close VARCHAR(10),
    pol_id        VARCHAR(20),
    clmt_id       VARCHAR(20),
    handl         VARCHAR(12),  -- handler code — sometimes corrupted
    chanl         VARCHAR(12),  -- channel free text — inconsistent spelling
    clm_reason    VARCHAR(30),
    rwn_cnt       INT,          -- reopen counter
    clamd_amt     BIGINT,       -- claimed amount in CENTS (legacy convention)
    apprd_amt     BIGINT        -- approved amount in CENTS, NULL = pending
);

-- 1. Benefit catalogue (fixed reference data)
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

-- 2. Handlers: 55 in 4 teams + 1 UNKNOWN member (target of mapping rule E3)
INSERT INTO dim_handler (handler_id, team, experience_level)
SELECT
    'H' || lpad(g::text, 3, '0'),
    CASE WHEN g <= 20 THEN 'Team Alpha'    -- Health
         WHEN g <= 35 THEN 'Team Bravo'    -- Health
         WHEN g <= 47 THEN 'Team Charlie'  -- Accident
         ELSE 'Team Delta' END,            -- Disability
    CASE WHEN x.r < 0.25 THEN 'Junior'
         WHEN x.r < 0.70 THEN 'Intermediate'
         ELSE 'Senior' END
FROM generate_series(1, 55) AS g
CROSS JOIN LATERAL (SELECT random() AS r) AS x;

INSERT INTO dim_handler (handler_id, team, experience_level)
VALUES ('H999', 'Unassigned', 'N/A');

-- 3. Policies: 10,000, weighted product mix, product-specific SLA days
INSERT INTO dim_policy (policy_id, product, line_of_business,
                        coverage_start, coverage_end, sla_days)
SELECT
    'POL-' || lpad(g::text, 5, '0'),
    pr.product,
    pr.line_of_business,
    cs.coverage_start,
    GREATEST(cs.coverage_start + (1460 + floor(random() * 2190)::int),
             DATE '2025-12-31'),
    pr.sla_days
FROM generate_series(1, 10000) AS g
CROSS JOIN LATERAL (SELECT random() AS rw) AS rr
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
                    AS coverage_start) AS cs;

-- 4. Claimants: 40,000 pseudonymized (GDPR)
INSERT INTO dim_claimant (claimant_id, age_band, region, customer_segment)
SELECT
    'CLT-' || lpad(g::text, 5, '0'),
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
CROSS JOIN LATERAL (SELECT random() AS r1, random() AS r2, random() AS r3) AS x;

-- 5. Daily claim volume 2022-2024 (~149,000 claims):
--    winter peak, summer accident bump, +12%/+25% year-over-year growth
CREATE TEMP TABLE tmp_daily_volume AS
SELECT
    d::date AS fnol_date,
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

-- Fast lookup arrays for random FK assignment
CREATE TEMP TABLE tmp_pol_by_lob AS
SELECT line_of_business, array_agg(policy_id ORDER BY policy_id) AS pol_ids
FROM dim_policy GROUP BY line_of_business;

CREATE TEMP TABLE tmp_claimants AS
SELECT array_agg(claimant_id ORDER BY claimant_id) AS clt_ids
FROM dim_claimant;

-- 6. Canonical claim universe — the "business reality" behind the data.
--    Embedded patterns the analysis will later discover:
--      * portal adoption grows 25% -> 55% (digitalization trend)
--      * SLA compliance: Health improves 90->95.5%; Disability stuck ~74-78%
--      * ~5.8% of closed claims are reopened (first-pass target is 85%)
--      * a small share of old claims is stuck open -> 180+ day backlog
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
                           random() AS r_appr,  random() AS r_close) AS x
CROSS JOIN LATERAL (SELECT CASE WHEN x.r_lob < 0.60 THEN 'Health'
                                WHEN x.r_lob < 0.85 THEN 'Accident'
                                ELSE 'Disability' END AS lob,
                           EXTRACT(YEAR FROM v.fnol_date)::int AS yr) AS l
JOIN tmp_pol_by_lob p ON p.line_of_business = l.lob
CROSS JOIN LATERAL (SELECT p.pol_ids[1 + floor(random()
                    * array_length(p.pol_ids, 1))::int] AS policy_id) AS pp
JOIN dim_policy dp ON dp.policy_id = pp.policy_id
CROSS JOIN tmp_claimants tc
CROSS JOIN LATERAL (SELECT tc.clt_ids[1 + floor(random()
                    * array_length(tc.clt_ids, 1))::int] AS claimant_id) AS cc
CROSS JOIN LATERAL (           -- SLA-met probability: the embedded story
    SELECT CASE l.lob
        WHEN 'Health'   THEN CASE l.yr WHEN 2022 THEN 0.900
                                          WHEN 2023 THEN 0.930 ELSE 0.955 END
        WHEN 'Accident' THEN CASE l.yr WHEN 2022 THEN 0.940 ELSE 0.950 END
        ELSE                 CASE l.yr WHEN 2022 THEN 0.740
                                          WHEN 2023 THEN 0.760 ELSE 0.780 END
    END AS p_sla_met) AS o0
CROSS JOIN LATERAL (           -- cycle time: within SLA, or overrun up to 3x SLA
    SELECT x.r_sla < o0.p_sla_met AS sla_met,
           CASE WHEN x.r_sla < o0.p_sla_met
                THEN 1 + floor(x.r_cycle * (dp.sla_days - 1))::int
                ELSE dp.sla_days + 1 + floor(x.r_cycle * dp.sla_days * 2)::int
           END AS cycle_days) AS o1
CROSS JOIN LATERAL (           -- lifecycle status by claim age at data cutoff
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
CROSS JOIN LATERAL (           -- lifecycle dates
    SELECT CASE WHEN o2.status IN ('Decided','Rejected','Closed')
                THEN v.fnol_date + o1.cycle_days END AS decision_date,
           CASE WHEN o2.status = 'Closed'
                THEN v.fnol_date + o1.cycle_days + 1 + floor(x.r_close * 10)::int
                WHEN o2.status = 'Rejected'
                THEN v.fnol_date + o1.cycle_days + 1 + floor(x.r_close * 5)::int
           END AS close_date) AS o3
CROSS JOIN LATERAL (           -- claimed amount by line of business
    SELECT CASE l.lob
        WHEN 'Health'   THEN ROUND((150.0  + x.r_amt * 3350 )::numeric, 2)
        WHEN 'Accident' THEN ROUND((300.0  + x.r_amt * 7700 )::numeric, 2)
        ELSE                 ROUND((1000.0 + x.r_amt * 19000)::numeric, 2)
    END AS claimed_amount) AS a
CROSS JOIN LATERAL (           -- approval ratio 55-100%, reopens
    SELECT CASE WHEN o2.status IN ('Decided','Closed')
                THEN ROUND((a.claimed_amount * (0.55 + x.r_appr * 0.45))::numeric, 2)
           END AS approved_amount,
           CASE WHEN o2.status = 'Closed'
                THEN CASE WHEN x.r_reopen < 0.012 THEN 2
                          WHEN x.r_reopen < 0.058 THEN 1
                          ELSE 0 END
                ELSE 0 END AS reopen_count) AS o4;

-- 7. "Export" the canonical universe into the LEGACY extract format,
--    including controlled corruption for the DQ gates to catch:
--      ~0.02% invalid FNOL date strings  -> Critical rejection (E1)
--      ~0.01% decision date before FNOL  -> Critical rejection (E1)
--      ~0.15% non-existent handler codes -> Warning, defaulted to H999 (E3)
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
         THEN to_char(c.fnol_date - 30, 'DD.MM.YYYY')     -- decision BEFORE fnol
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
                           random() AS r_b4, random() AS r_b5) AS dg;

-- 8. Inject ~40 exact duplicate rows (deduplication check E2)
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