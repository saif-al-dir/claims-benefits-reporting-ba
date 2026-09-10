-- ============================================================================
-- NovaCare Insurance — Claims & Benefits Reporting Solution
-- File:    04-implementation/sql/schema/schema.sql
-- Purpose: Star schema DDL (PostgreSQL 14+, tested on Neon)
--
-- Grain statements:
--   fct_claim                 one row per claim (latest lifecycle state)
--   fct_payment               one row per payment transaction
--   fct_claim_status_snapshot one row per open claim per day
--
-- Design rationale: 03-data-design/logical-data-model.md
-- ============================================================================

-- Idempotent: safe to re-run (drops then recreates everything)
DROP TABLE IF EXISTS fct_claim_status_snapshot CASCADE;
DROP TABLE IF EXISTS fct_payment              CASCADE;
DROP TABLE IF EXISTS fct_claim                CASCADE;
DROP TABLE IF EXISTS dq_audit_log             CASCADE;
DROP TABLE IF EXISTS dim_claim                CASCADE;
DROP TABLE IF EXISTS dim_policy               CASCADE;
DROP TABLE IF EXISTS dim_claimant             CASCADE;
DROP TABLE IF EXISTS dim_handler              CASCADE;
DROP TABLE IF EXISTS dim_benefit              CASCADE;
DROP TABLE IF EXISTS dim_date                 CASCADE;

-- ============================================================================
-- DIMENSIONS
-- ============================================================================

CREATE TABLE dim_date (
    date_key     INT          PRIMARY KEY,              -- smart key: YYYYMMDD
    full_date    DATE         NOT NULL UNIQUE,
    year         INT          NOT NULL,
    quarter      INT          NOT NULL CHECK (quarter BETWEEN 1 AND 4),
    month        INT          NOT NULL CHECK (month  BETWEEN 1 AND 12),
    day          INT          NOT NULL CHECK (day    BETWEEN 1 AND 31),
    month_name   VARCHAR(10)  NOT NULL,
    day_name     VARCHAR(10)  NOT NULL,
    iso_week     INT          NOT NULL,
    is_weekend   BOOLEAN      NOT NULL,
    is_month_end BOOLEAN      NOT NULL
);

CREATE TABLE dim_policy (
    policy_sk        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    policy_id        VARCHAR(20) NOT NULL UNIQUE,        -- business key
    product          VARCHAR(40) NOT NULL,
    line_of_business VARCHAR(20) NOT NULL
        CHECK (line_of_business IN ('Health', 'Accident', 'Disability')),
    coverage_start   DATE NOT NULL,
    coverage_end     DATE NOT NULL,
    sla_days         INT  NOT NULL CHECK (sla_days BETWEEN 1 AND 60),
    CHECK (coverage_end >= coverage_start)
);

CREATE TABLE dim_claimant (
    claimant_sk      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    claimant_id      VARCHAR(20) NOT NULL UNIQUE,        -- pseudonymized (GDPR)
    age_band         VARCHAR(10) NOT NULL
        CHECK (age_band IN ('18-29', '30-44', '45-59', '60-74', '75+')),
    region           VARCHAR(20) NOT NULL,
    customer_segment VARCHAR(10) NOT NULL
        CHECK (customer_segment IN ('Bronze', 'Silver', 'Gold', 'Platinum'))
);

CREATE TABLE dim_handler (
    handler_sk       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    handler_id       VARCHAR(10) NOT NULL UNIQUE,
    team             VARCHAR(20) NOT NULL,
    experience_level VARCHAR(12) NOT NULL
        CHECK (experience_level IN ('Junior', 'Intermediate', 'Senior', 'N/A'))
);

-- Fixes as-is pain point: no standard claim status model -> KPIs not comparable.
-- The CHECK constraint enforces the standard status catalogue at the DB level.
CREATE TABLE dim_claim (
    claim_sk         INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    claim_id         VARCHAR(20) NOT NULL UNIQUE,        -- source business key
    line_of_business VARCHAR(20) NOT NULL
        CHECK (line_of_business IN ('Health', 'Accident', 'Disability')),
    intake_channel   VARCHAR(10) NOT NULL
        CHECK (intake_channel IN ('Phone', 'Portal', 'Email', 'Broker')),
    claim_reason     VARCHAR(40) NOT NULL,
    current_status   VARCHAR(15) NOT NULL
        CHECK (current_status IN ('Registered', 'In Assessment', 'Decided',
                                   'Closed', 'Rejected')),
    reopen_count     INT NOT NULL DEFAULT 0 CHECK (reopen_count >= 0)
);

CREATE TABLE dim_benefit (
    benefit_sk   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    benefit_type VARCHAR(40) NOT NULL UNIQUE,
    payment_form VARCHAR(10) NOT NULL
        CHECK (payment_form IN ('One-time', 'Recurring'))
);

-- ============================================================================
-- FACTS
-- ============================================================================

CREATE TABLE fct_claim (
    claim_sk                INT PRIMARY KEY REFERENCES dim_claim(claim_sk),
    policy_sk               INT NOT NULL REFERENCES dim_policy(policy_sk),
    claimant_sk             INT NOT NULL REFERENCES dim_claimant(claimant_sk),
    handler_sk              INT NOT NULL REFERENCES dim_handler(handler_sk),
    fnol_date_key           INT NOT NULL REFERENCES dim_date(date_key),
    decision_date_key       INT          REFERENCES dim_date(date_key),   -- NULL while open
    close_date_key          INT          REFERENCES dim_date(date_key),   -- NULL until closed
    claimed_amount          NUMERIC(12,2) NOT NULL CHECK (claimed_amount >= 0),
    approved_benefit_amount NUMERIC(12,2)          CHECK (approved_benefit_amount >= 0),
    reserve_amount          NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (reserve_amount >= 0),
    cycle_time_days         INT                   CHECK (cycle_time_days >= 0),
    sla_met                 BOOLEAN,                                       -- NULL until decided
    first_pass_flag         BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE fct_payment (
    payment_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    claim_sk         INT NOT NULL REFERENCES dim_claim(claim_sk),
    benefit_sk       INT NOT NULL REFERENCES dim_benefit(benefit_sk),
    payment_date_key INT NOT NULL REFERENCES dim_date(date_key),
    payment_amount   NUMERIC(12,2) NOT NULL CHECK (payment_amount > 0)
);

CREATE TABLE fct_claim_status_snapshot (
    snapshot_date_key INT NOT NULL REFERENCES dim_date(date_key),
    claim_sk          INT NOT NULL REFERENCES dim_claim(claim_sk),
    status            VARCHAR(15) NOT NULL
        CHECK (status IN ('Registered', 'In Assessment', 'Decided',
                          'Closed', 'Rejected')),
    days_open         INT NOT NULL CHECK (days_open >= 0),
    PRIMARY KEY (snapshot_date_key, claim_sk)
);

-- Evidence of data quality checks (populated in Step 4) — feeds DQ reporting
-- and demonstrates the "rejection log + alerting" requirement (FR-03).
CREATE TABLE dq_audit_log (
    dq_log_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    check_name   VARCHAR(60) NOT NULL,
    severity     VARCHAR(10) NOT NULL CHECK (severity IN ('Critical', 'Warning')),
    source_table VARCHAR(60) NOT NULL,
    source_row   VARCHAR(60),
    violation    TEXT NOT NULL,
    detected_at  TIMESTAMP NOT NULL DEFAULT now()
);

-- ============================================================================
-- INDEXES (PostgreSQL does not auto-index foreign keys)
-- ============================================================================

CREATE INDEX ix_fct_claim_policy    ON fct_claim (policy_sk);
CREATE INDEX ix_fct_claim_claimant  ON fct_claim (claimant_sk);
CREATE INDEX ix_fct_claim_handler   ON fct_claim (handler_sk);
CREATE INDEX ix_fct_claim_fnol_date ON fct_claim (fnol_date_key);
CREATE INDEX ix_fct_payment_claim   ON fct_payment (claim_sk);
CREATE INDEX ix_fct_payment_benefit ON fct_payment (benefit_sk);
CREATE INDEX ix_fct_payment_date    ON fct_payment (payment_date_key);
CREATE INDEX ix_snapshot_claim      ON fct_claim_status_snapshot (claim_sk);
CREATE INDEX ix_dim_claim_status    ON dim_claim (current_status);

-- ============================================================================
-- REFERENCE DATA: populate dim_date (2021-2025, covers 3 claim years + buffer)
-- ============================================================================

INSERT INTO dim_date (date_key, full_date, year, quarter, month, day,
                      month_name, day_name, iso_week, is_weekend, is_month_end)
SELECT
    TO_CHAR(d, 'YYYYMMDD')::INT,
    d::date,
    EXTRACT(YEAR    FROM d)::INT,
    EXTRACT(QUARTER FROM d)::INT,
    EXTRACT(MONTH   FROM d)::INT,
    EXTRACT(DAY     FROM d)::INT,
    TRIM(TO_CHAR(d, 'Month')),
    TRIM(TO_CHAR(d, 'Day')),
    EXTRACT(WEEK    FROM d)::INT,
    EXTRACT(ISODOW  FROM d) IN (6, 7),
    d::date = (DATE_TRUNC('month', d) + INTERVAL '1 month - 1 day')::date
FROM generate_series(
        DATE '2021-01-01',
        DATE '2025-12-31',
        INTERVAL '1 day') AS d;

-- ============================================================================
-- DOCUMENTATION (visible to anyone inspecting the database)
-- ============================================================================

COMMENT ON TABLE  fct_claim                 IS 'Grain: one row per claim (latest lifecycle state). Paid amounts live in fct_payment; reconciliation is a DQ check.';
COMMENT ON TABLE  fct_payment               IS 'Grain: one row per payment transaction.';
COMMENT ON TABLE  fct_claim_status_snapshot IS 'Grain: one row per open claim per day — enables backlog/aging trend analysis.';
COMMENT ON TABLE  dq_audit_log              IS 'Data quality violations found during load/tests, with severity and evidence.';
COMMENT ON COLUMN fct_claim.sla_met         IS 'TRUE if decided within SLA (sla_days from dim_policy). NULL until decided.';