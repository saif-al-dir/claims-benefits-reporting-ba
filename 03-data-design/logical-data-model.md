# Logical Data Model — Claims & Benefits Star Schema

SQL implementation: [`04-implementation/sql/schema/schema.sql`](../04-implementation/sql/schema/schema.sql)

## Entity-Relationship Diagram

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

## Grain Statements

| Table | Grain |
|---|---|
| `fct_claim` | One row per claim (latest lifecycle state) |
| `fct_payment` | One row per payment transaction |
| `fct_claim_status_snapshot` | One row per open claim per day |

## Key Design Decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | Star schema with surrogate keys (`GENERATED ALWAYS AS IDENTITY`) | Decouples warehouse from legacy business keys; insulates against source key changes |
| 2 | No `paid_amount` in `fct_claim` | Payments live at transaction grain in `fct_payment`; total paid = `SUM()`. Payment accuracy (KPI-06) becomes a real cross-fact reconciliation check |
| 3 | `sla_days` in `dim_policy`, `sla_met` in `fct_claim` | SLA is a product attribute (dimension); compliance is determined at decision time (fact) |
| 4 | Daily status snapshot fact | Enables backlog/aging trend analysis — impossible with the current monthly Excel reports (OBJ-2) |
| 5 | `dq_audit_log` | Persistent evidence of data quality checks; implements the rejection log required by FR-03 |
| 6 | Smart date key `YYYYMMDD` | Human-readable, sortable, join-friendly conformed dimension |
| 7 | `dim_claim.current_status` as Type 1 attribute | Overwritten on change; history preserved in the snapshot fact |
| 8 | Status catalogue enforced by `CHECK` constraints | Directly fixes as-is pain point "no standard status codes → KPIs not comparable" |