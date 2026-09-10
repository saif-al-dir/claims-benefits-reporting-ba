-- ============================================================================
-- NovaCare Insurance — Claims & Benefits Reporting Solution
-- File:    04-implementation/sql/data/etl_load.sql
-- Purpose: ETL from the simulated legacy extract into the star schema,
--          implementing the source-to-target mapping:
--
--   Legacy status codes   : 1=Registered, 2=In Assessment, 3=Decided,
--                           4=Rejected, 9=Closed
--   Dates 'DD.MM.YYYY'    -> DATE via safe parser; invalid -> rejection (E1)
--   Amounts in cents      -> / 100.00 -> NUMERIC(12,2)
--   Channel free text     -> normalized catalogue (Phone/Portal/Email/Broker)
--   Handler code          -> lookup; unknown -> H999 + DQ warning (E3)
--   Line of business      -> derived from the policy (dim_policy)
--   Reserve amount        -> derived: 80% of claimed while open, else 0
--
--   DQ gate (FR-03): every rejection is logged to dq_audit_log with
--   severity and evidence. Load is idempotent (truncate + reload).
--
-- Run as ONE batch in a single session. Runtime ~1-3 minutes
-- (the status-snapshot insert is the largest part).
-- ============================================================================

SELECT setseed(0.77);

-- 0. Helper: SAFE legacy date parser — returns NULL instead of raising an
--    error on malformed or impossible dates (e.g. '31.02.2024')
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

-- 1. Reset load targets (dimensions from the generator stay untouched)
TRUNCATE dim_claim, dq_audit_log RESTART IDENTITY CASCADE;

-- 2. Deduplication gate (E2): log exact duplicates before dropping them
INSERT INTO dq_audit_log (check_name, severity, source_table, source_row, violation)
SELECT 'E2_duplicate_detection', 'Warning', 'stg_raw_claims', t.clm_id,
       'Exact duplicate source row removed during deduplication'
FROM (SELECT clm_id,
             ROW_NUMBER() OVER (PARTITION BY clm_id ORDER BY clm_stat) AS rn
      FROM stg_raw_claims) t
WHERE t.rn > 1;

-- 3. Parse + validate (E1) into a staging work table
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

-- Rejection log (E1) — Critical: row NOT loaded
INSERT INTO dq_audit_log (check_name, severity, source_table, source_row, violation)
SELECT 'E1_source_validation', 'Critical', 'stg_raw_claims', clm_id, reject_reason
FROM tmp_etl_claims
WHERE reject_reason IS NOT NULL;

-- Handler mapping (E3) — Warning: row loaded, handler defaulted to H999
INSERT INTO dq_audit_log (check_name, severity, source_table, source_row, violation)
SELECT 'E3_handler_lookup', 'Warning', 'stg_raw_claims', clm_id,
       'Unknown handler code ''' || handl_norm || ''' defaulted to H999 (Unassigned)'
FROM tmp_etl_claims
WHERE reject_reason IS NULL
  AND handl_norm NOT IN (SELECT handler_id FROM dim_handler);

-- 4. dim_claim — conformed claim dimension (valid rows only)
INSERT INTO dim_claim (claim_id, line_of_business, intake_channel,
                       claim_reason, current_status, reopen_count)
SELECT e.clm_id,
       dp.line_of_business,                       -- derived via policy
       CASE e.chanl_norm WHEN 'PHONE'  THEN 'Phone'
                         WHEN 'PORTAL' THEN 'Portal'
                         WHEN 'E-MAIL' THEN 'Email'
                         WHEN 'EMAIL'  THEN 'Email'
                         WHEN 'BROKER' THEN 'Broker'
                         ELSE 'Phone' END,        -- defensive default
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

-- 5. fct_claim — grain: one row per claim
--    (invalid rows drop out naturally via INNER JOIN on dim_claim)
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

-- 6. fct_payment — grain: one row per payment transaction
--    One-time benefits: single payment 2-8 days after decision.
--    Recurring benefits: monthly installments, final installment adjusted
--    so the total always equals the approved amount (no rounding leakage).
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
WHERE e.clm_stat IN ('3','9')          -- Decided or Closed with approval
  AND e.apprd_amt > 0
  AND e.decision_date IS NOT NULL;

-- 7. Controlled payment-leakage injection (~0.2% of payments) so the DQ
--    audit in the next step has something real to detect (KPI-06):
--      a) 220 duplicate payments (same amount re-issued the next day)
--      b) 120 erroneous partial re-issues (40% of approved, +14 days)
--    Selection is hash-based (md5) -> stable across re-runs.
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

-- 8. fct_claim_status_snapshot — backlog/aging history:
--    month-end snapshots 2022-2024 + daily snapshots for Q4-2024.
--    Status timeline: Registered (first 3 days) -> In Assessment ->
--    Decided -> Closed; Rejected is terminal at decision date.
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