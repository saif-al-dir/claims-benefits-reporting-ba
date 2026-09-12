-- ============================================================================
-- NovaCare Insurance — Claims & Benefits Reporting Solution
-- File:    04-implementation/sql/queries/kpi_queries.sql   (KPI LIBRARY v1.0)
-- Purpose: Reporting & analysis layer. All queries are read-only SELECTs.
--
-- Traceability: each query references the KPI catalog (KPI-01..07) and the
-- functional requirements (FR-04..07) it satisfies.
-- Run:  psql "$DB_URL" -f 04-implementation/sql/queries/kpi_queries.sql
-- ============================================================================

-- ───────────────────────────────────────────────────────────────────────────
-- Q1 | KPI-01 · Claim cycle time (avg + P90) + SLA compliance
--    by line of business and FNOL year (intake cohort).
--    Analytical choice: cohorting by FNOL year (not decision year) avoids
--    the end-of-period selection artifact where only slow claims remain.
--    Expected: 9 rows. Health avg ~5-7d, P90 ~9-14d, improving;
--    Disability avg ~20d with P90 far above its 21-30d SLA — the headline.
-- ───────────────────────────────────────────────────────────────────────────
SELECT
    dp.line_of_business,
    dd.year,
    COUNT(*)                                                        AS decided_claims,
    ROUND(AVG(fc.cycle_time_days), 1)                               AS avg_cycle_days,
    PERCENTILE_CONT(0.9) WITHIN GROUP
        (ORDER BY fc.cycle_time_days)                               AS p90_cycle_days,
    MIN(dp.sla_days)                                                AS typical_sla_days,
    ROUND(100.0 * AVG(CASE WHEN fc.sla_met THEN 1 ELSE 0 END), 1)   AS sla_pct
FROM fct_claim fc
JOIN dim_policy dp ON dp.policy_sk = fc.policy_sk
JOIN dim_date   dd ON dd.date_key   = fc.fnol_date_key
WHERE fc.cycle_time_days IS NOT NULL
  AND dd.full_date <= DATE '2024-12-31'
GROUP BY dp.line_of_business, dd.year
ORDER BY dp.line_of_business, dd.year;

-- ───────────────────────────────────────────────────────────────────────────
-- Q2 | KPI-02 · SLA compliance, monthly by line of business (FR-03:
--    regulatory TAT evidence — the report the regulator asks for).
--    Expected: 108 rows (36 months x 3 LOB).
-- ───────────────────────────────────────────────────────────────────────────
SELECT
    dd.year || '-' || LPAD(dd.month::text, 2, '0')               AS month_id,
    dp.line_of_business,
    COUNT(*)                                                      AS decided_claims,
    ROUND(100.0 * AVG(CASE WHEN fc.sla_met THEN 1 ELSE 0 END), 1) AS sla_pct
FROM fct_claim fc
JOIN dim_policy dp ON dp.policy_sk = fc.policy_sk
JOIN dim_date   dd ON dd.date_key   = fc.decision_date_key
WHERE fc.sla_met IS NOT NULL
  AND dd.full_date BETWEEN DATE '2022-01-01' AND DATE '2024-12-31'
GROUP BY 1, 2
ORDER BY 1, 2;

-- ───────────────────────────────────────────────────────────────────────────
-- Q3 | KPI-03 · Current backlog by team and aging bucket (FR-04:
--    daily aging visibility — replaces the monthly Excel report).
--    Work-in-progress = Registered + In Assessment at latest snapshot.
-- ───────────────────────────────────────────────────────────────────────────
WITH latest AS (
    SELECT MAX(snapshot_date_key) AS snap
    FROM fct_claim_status_snapshot
)
SELECT
    h.team,
    CASE
        WHEN s.days_open <= 30  THEN '0-30'
        WHEN s.days_open <= 60  THEN '31-60'
        WHEN s.days_open <= 90  THEN '61-90'
        WHEN s.days_open <= 180 THEN '91-180'
        ELSE '180+'
    END                                                           AS aging_bucket,
    COUNT(*)                                                      AS open_claims
FROM fct_claim_status_snapshot s
JOIN fct_claim  fc ON fc.claim_sk = s.claim_sk
JOIN dim_handler h ON h.handler_sk = fc.handler_sk
CROSS JOIN latest l
WHERE s.snapshot_date_key = l.snap
  AND s.status IN ('Registered', 'In Assessment')
GROUP BY h.team, aging_bucket
ORDER BY h.team, aging_bucket;

-- ───────────────────────────────────────────────────────────────────────────
-- Q4 | KPI-03 · Backlog trend at month-ends, with 90+ highlight (OBJ-2:
--    the trend analysis the legacy monthly Excel could never deliver).
--    Expected: 36 rows, backlog growing with intake volume.
-- ───────────────────────────────────────────────────────────────────────────
SELECT
    dd.full_date                                                  AS month_end,
    COUNT(*)                                                      AS open_claims,
    COUNT(*) FILTER (WHERE s.days_open > 90)                      AS open_over_90,
    COUNT(*) FILTER (WHERE s.days_open > 180)                     AS open_over_180
FROM fct_claim_status_snapshot s
JOIN dim_date dd ON dd.date_key = s.snapshot_date_key
WHERE dd.is_month_end
GROUP BY dd.full_date
ORDER BY dd.full_date;

-- ───────────────────────────────────────────────────────────────────────────
-- Q5 | KPI-04/05 · First-pass ratio and reopen rate, by LOB and intake year
--    (process quality — target: first pass >= 85%, reopen <= 5%).
--    Expected: first_pass ~94-95% (reopens were injected only on closed
--    claims at ~5.8%).
-- ───────────────────────────────────────────────────────────────────────────
SELECT
    dp.line_of_business,
    dd.year,
    COUNT(*)                                                      AS closed_claims,
    ROUND(100.0 * AVG(CASE WHEN fc.first_pass_flag
             THEN 1 ELSE 0 END), 1)                               AS first_pass_pct,
    ROUND(100.0 * AVG(CASE WHEN dc.reopen_count > 0
             THEN 1 ELSE 0 END), 1)                               AS reopen_pct
FROM fct_claim fc
JOIN dim_claim  dc ON dc.claim_sk = fc.claim_sk
JOIN dim_policy dp ON dp.policy_sk = fc.policy_sk
JOIN dim_date   dd ON dd.date_key   = fc.fnol_date_key
WHERE fc.close_date_key IS NOT NULL
  AND dd.full_date <= DATE '2024-12-31'
GROUP BY 1, 2
ORDER BY 1, 2;

-- ───────────────────────────────────────────────────────────────────────────
-- Q6 | KPI-06 · Payment leakage report (FR-07: paid vs approved
--    reconciliation). Top 25 overpayments, largest first — the queue the
--    payment-operations team works through. Expected ~340 claims in total.
-- ───────────────────────────────────────────────────────────────────────────
WITH paid AS (
    SELECT claim_sk,
           SUM(payment_amount) AS total_paid,
           COUNT(*)            AS n_payments
    FROM fct_payment
    GROUP BY claim_sk
)
SELECT
    dc.claim_id,
    dc.line_of_business,
    fc.approved_benefit_amount,
    paid.total_paid,
    ROUND(paid.total_paid - fc.approved_benefit_amount, 2)        AS overpayment,
    paid.n_payments
FROM fct_claim fc
JOIN dim_claim dc  ON dc.claim_sk  = fc.claim_sk
JOIN paid          ON paid.claim_sk = fc.claim_sk
WHERE fc.approved_benefit_amount IS NOT NULL
  AND paid.total_paid > fc.approved_benefit_amount
ORDER BY overpayment DESC
LIMIT 25;

-- ───────────────────────────────────────────────────────────────────────────
-- Q7 | Operational management · Handler performance ranking (>= 100 decided
--    claims). Worst SLA compliance first — Team Delta (Disability) should
--    dominate the bottom, matching KPI-01's story.
-- ───────────────────────────────────────────────────────────────────────────
SELECT
    h.handler_id,
    h.team,
    h.experience_level,
    COUNT(*)                                                      AS decided_claims,
    ROUND(100.0 * AVG(CASE WHEN fc.sla_met THEN 1 ELSE 0 END), 1) AS sla_pct,
    ROUND(AVG(fc.cycle_time_days), 1)                             AS avg_cycle_days
FROM fct_claim fc
JOIN dim_handler h ON h.handler_sk = fc.handler_sk
WHERE fc.sla_met IS NOT NULL
GROUP BY h.handler_id, h.team, h.experience_level
HAVING COUNT(*) >= 100
ORDER BY sla_pct ASC, decided_claims DESC;

-- ───────────────────────────────────────────────────────────────────────────
-- Q8 | Strategic · Intake channel mix by year (digitalization trend).
--    Expected: Portal ~25% -> ~40% -> ~55% — the adoption success story.
-- ───────────────────────────────────────────────────────────────────────────
SELECT
    dd.year,
    dc.intake_channel,
    COUNT(*)                                                      AS claims,
    ROUND(100.0 * COUNT(*)
          / SUM(COUNT(*)) OVER (PARTITION BY dd.year), 1)         AS share_pct
FROM fct_claim fc
JOIN dim_claim dc ON dc.claim_sk = fc.claim_sk
JOIN dim_date  dd ON dd.date_key  = fc.fnol_date_key
GROUP BY dd.year, dc.intake_channel
ORDER BY dd.year, share_pct DESC;

-- [KPI LIBRARY v1.0 — END OF FILE]
