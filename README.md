# 🏥 Insurance Claims & Benefits — Business Analysis to Reporting Solution

[![CI — Data Pipeline](https://github.com/saif-al-dir/claims-benefits-reporting-ba/actions/workflows/ci.yml/badge.svg)](https://github.com/saif-al-dir/claims-benefits-reporting-ba/actions/workflows/ci.yml)

End-to-end business analysis project: from business requirements analysis and BPMN process modeling, through functional specification and data warehouse design, to a **tested and CI-verified KPI reporting solution**.

> ⚠️ Fictional case study ("NovaCare Insurance"). All data is synthetic and reproducible (seeded) — GDPR-safe.

## 📖 The Story in the Data

Three years of synthetic claims data (~149,000 claims, 2022–2024) were generated with embedded, realistic business problems that the analysis uncovers:

- **Disability claims are stuck:** SLA compliance has hovered at ~77% for three straight years (77.3 → 76.4 → 77.5), while Health improved from 90.4% to 95.3% and Accident holds stable at ~95%. The operations improvement program works everywhere except Disability.
- **Payment leakage exists:** ≈340 claims were paid more than the approved benefit amount (duplicate payments + erroneous re-issues) — every one flagged by automated reconciliation (KPI-06).
- **Data quality gates work:** the ETL rejected 45 critical rows (invalid dates, decision-before-FNOL), removed 40 exact duplicates, and defaulted 261 unknown handler codes to an explicit UNKNOWN member — each rejection logged with evidence.
- **Digital intake is growing:** portal adoption rose from 25% to 55% of new claims across the period.

## Business Case

A mid-size insurer processes claims across 3 legacy systems. Monthly reporting costs 5 person-days, claim aging is invisible, and the regulator requires proof of claim-decision turnaround times. This project delivers the full analysis and design, plus a working, CI-tested implementation.

| Objective | Target |
|---|---|
| Reporting effort | 5 days → < 0.5 days (automation) |
| Backlog transparency | Daily aging dashboard |
| Claim cycle time | −20% within 12 months |
| Regulatory TAT evidence | 100% traceable decisions |
| Payment accuracy | Paid ≤ approved, violations flagged |

## Deliverables

- [x] Business Requirements Document (BRD) with prioritized requirements
- [ ] As-Is / To-Be process models (BPMN)
- [ ] Functional specification for the reporting solution
- [ ] KPI catalog & report specifications
- [x] Logical data model (star schema)
- [ ] Source-to-target mapping & data quality rules
- [x] SQL implementation: schema, seeded test data, ETL with DQ gates
- [x] Automated test suite: 24 assertions across 7 categories
- [x] CI pipeline (GitHub Actions) — every push is tested
- [ ] Live dashboard (GitHub Pages)

## Data Quality & CI

Every push to this repository triggers GitHub Actions to spin up a **fresh PostgreSQL 15 container**, build the star schema, run the self-verifying data load (14 sections, each printing counts), and execute the **24-assertion DQ test suite** (structure, volume, lineage, distribution, DQ gates, business rules, and the business story itself). Any SQL error or failed assertion fails the build.

Among the assertions are distribution guards (T08/T10/T12) that encode a real defect found and fixed during development: PostgreSQL evaluates `random()` inside an *uncorrelated* subquery in `FROM` **once per query**, which silently degenerated every distribution in the first data version. The test suite now makes that class of failure impossible to miss.

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

## Quick Start

Requires PostgreSQL 14+ (e.g. a free [Neon](https://neon.tech) project) and `psql`.

```bash
export DB_URL='postgresql://user:password@host/dbname?sslmode=require'

# 1. Create the schema (tables, constraints, indexes, dim_date)
psql "$DB_URL" -f 04-implementation/sql/schema/schema.sql

# 2. Generate the synthetic legacy source + run the ETL (self-verifying, ~3 min)
psql "$DB_URL" -v ON_ERROR_STOP=1 -f 04-implementation/sql/data/run_full_load.sql

# 3. Run the automated DQ test suite (24 assertions, CI-compatible)
psql "$DB_URL" -v ON_ERROR_STOP=1 -f 04-implementation/sql/tests/dq_test_suite.sql
```

## Repository Structure

```
claims-benefits-reporting-ba/
├── .github/workflows/ci.yml           ← CI: fresh DB → schema → load → 24 tests
├── 01-business-analysis/              ← BRD, use cases (in progress)
├── 02-functional-spec/                ← FRS, KPI catalog (in progress)
├── 03-data-design/
│   └── logical-data-model.md          ← star schema + design decisions
└── 04-implementation/sql/
    ├── schema/schema.sql              ← DDL, constraints, indexes, dim_date
    ├── data/run_full_load.sql         ← seeded source + ETL, self-verifying
    └── tests/dq_test_suite.sql        ← 24 automated DQ assertions
```

## Tech Stack

`PostgreSQL` · `GitHub Actions` · `GitHub Pages` · `Mermaid / BPMN` · `Chart.js`
