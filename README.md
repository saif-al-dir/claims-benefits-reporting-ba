# 🏥 Insurance Claims & Benefits — Business Analysis to Reporting Solution

CI — Data Pipeline | passing ✅

- [x] CI pipeline (GitHub Actions) — every push is automatically tested

End-to-end business analysis project: from business requirements analysis andBPMN process modeling, through functional specification and data warehousedesign, to a tested and automatically deployed KPI reporting solution.

⚠️ Fictional case study ("NovaCare Insurance"). All data is synthetic — GDPR-safe.

## Data Model

```mermaid
erDiagram
    DIM_DATE {
        int date_key PK
        date full_date UK
        int year
        int quarter
        int month
        int day
        varchar month_name
        varchar day_name
        int iso_week
        boolean is_weekend
        boolean is_month_end
    }
    DIM_POLICY {
        int policy_sk PK
        varchar policy_id UK
        varchar product
        varchar line_of_business
        date coverage_start
        date coverage_end
        int sla_days
    }
    DIM_CLAIMANT {
        int claimant_sk PK
        varchar claimant_id UK
        varchar age_band
        varchar region
        varchar customer_segment
    }
    DIM_HANDLER {
        int handler_sk PK
        varchar handler_id UK
        varchar team
        varchar experience_level
    }
    DIM_CLAIM {
        int claim_sk PK
        varchar claim_id UK
        varchar line_of_business
        varchar intake_channel
        varchar claim_reason
        varchar current_status
        int reopen_count
    }
    DIM_BENEFIT {
        int benefit_sk PK
        varchar benefit_type UK
        varchar payment_form
    }
    FCT_CLAIM {
        int claim_sk PK, FK
        int policy_sk FK
        int claimant_sk FK
        int handler_sk FK
        int fnol_date_key FK
        int decision_date_key FK
        int close_date_key FK
        numeric claimed_amount
        numeric approved_benefit_amount
        numeric reserve_amount
        int cycle_time_days
        boolean sla_met
        boolean first_pass_flag
    }
    FCT_PAYMENT {
        bigint payment_id PK
        int claim_sk FK
        int benefit_sk FK
        int payment_date_key FK
        numeric payment_amount
    }
    FCT_CLAIM_STATUS_SNAPSHOT {
        int snapshot_date_key PK, FK
        int claim_sk PK, FK
        varchar status
        int days_open
    }
    DQ_AUDIT_LOG {
        bigint dq_log_id PK
        varchar check_name
        varchar severity
        varchar source_table
        varchar source_row
        text violation
        timestamp detected_at
    }

    DIM_CLAIM    ||--|| FCT_CLAIM : ""
    DIM_POLICY   ||--o{ FCT_CLAIM : ""
    DIM_CLAIMANT ||--o{ FCT_CLAIM : ""
    DIM_HANDLER  ||--o{ FCT_CLAIM : ""
    DIM_DATE     ||--o{ FCT_CLAIM : "fnol / decision / close dates"
    DIM_CLAIM    ||--o{ FCT_PAYMENT : ""
    DIM_BENEFIT  ||--o{ FCT_PAYMENT : ""
    DIM_DATE     ||--o{ FCT_PAYMENT : "payment date"
    DIM_CLAIM    ||--o{ FCT_CLAIM_STATUS_SNAPSHOT : ""
    DIM_DATE     ||--o{ FCT_CLAIM_STATUS_SNAPSHOT : "snapshot date"
```


Business Case

A mid-size insurer processes claims across 3 legacy systems. Monthly reportingcosts 5 person-days, claim aging is invisible, and the regulator requires proofof claim-decision turnaround times. This project delivers the full analysis anddesign, plus a working, CI-tested implementation.

Objective	Target
Reporting effort	5 days → < 0.5 days (automation)
Backlog transparency	Daily aging dashboard
Claim cycle time	−20% within 12 months
Regulatory TAT evidence	100% traceable decisions
Payment accuracy	Paid ≤ approved, violations flagged


Deliverables
 Business Requirements Document (BRD) with prioritized requirements
 As-Is / To-Be process models (BPMN)
 Functional specification for the reporting solution
 KPI catalog & report specifications
 Logical data model (star schema)
 Source-to-target mapping & data quality rules
 SQL implementation: schema, seeded test data, DQ tests, KPI queries
 CI pipeline (GitHub Actions) — every push is automatically tested
 Live dashboard (GitHub Pages)


Tech Stack
PostgreSQL · GitHub Actions · GitHub Pages · Mermaid / BPMN · Chart.js


Quick Start

Requires PostgreSQL 14+ (e.g. a free Neon project) and psql.

export DB_URL='postgresql://user:password@host/dbname?sslmode=require'# 1. Create the schema (tables, constraints, indexes, dim_date)psql "$DB_URL" -f 04-implementation/sql/schema/schema.sql# 2. Generate the synthetic legacy source + run the ETL (self-verifying, ~3 min)psql "$DB_URL" -v ON_ERROR_STOP=1 -f 04-implementation/sql/data/run_full_load.sql# 3. Run the automated DQ test suite (24 assertions, CI-compatible)psql "$DB_URL" -v ON_ERROR_STOP=1 -f 04-implementation/sql/tests/dq_test_suite.sql
All data is synthetic and reproducible (seeded random) — GDPR-safe.
