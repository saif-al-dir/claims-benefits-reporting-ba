# Functional Specification — Claims & Benefits Reporting Solution

| | |
|---|---|
| **Document** | FRS v1.0 (baseline implemented and CI-tested) |
| **Related** | [BRD](../01-business-analysis/BRD.md) · [KPI Catalog](kpi-catalog.md) · [Data Model](../03-data-design/logical-data-model.md) · [Source-to-Target Mapping](../03-data-design/source-to-target-mapping.md) |
| **Implementation** | [`04-implementation/sql/`](../04-implementation/sql/) — schema, load, tests, queries |

## 1. Purpose and Scope

This specification defines the functional behavior of the reporting solution: nightly batch ETL with data-quality gates, a conformed claims data warehouse, a KPI/reporting layer, and an automated verification framework. Claims intake systems, workflow engines, and role-based access management are out of scope (see BRD §8).

## 2. Solution Architecture

```mermaid
flowchart LR
    L["Legacy claims systems<br/>(3 systems + Excel)"] --> S[("stg_raw_claims<br/>legacy-format extract")]
    S --> E["ETL: parse, validate,<br/>map, deduplicate"]
    E -->|"E1 / E2 / E3 evidence"| DQ[("dq_audit_log")]
    E --> W[("Star schema DWH<br/>6 dimensions + 3 facts")]
    W --> K["KPI query library Q1-Q9"]
    K --> R["Reports R-01 to R-05"]
    W --> T["DQ test suite<br/>24 assertions"]
    T --> CI["GitHub Actions CI<br/>fresh PostgreSQL on every push"]
    CI -.->|"re-executes and verifies"| E
```

Batch pipeline: legacy-format extract → validation/mapping/deduplication with three DQ gates → star schema → KPI layer. Every gate writes evidence to `dq_audit_log`; a 24-assertion test suite verifies the loaded warehouse on every push in CI, on a freshly created database.

## 3. User Roles and Access Matrix

| Role | Primary reports | Access |
|---|---|---|
| Claims Team Lead | R-02 Aging Cockpit | Own team's claims |
| Compliance Officer | R-03 Regulatory TAT Report | Read-all, export |
| Payment Operations | R-04 Leakage Report | Payments + claims, read |
| Operations Manager / Sponsor | R-01 Claims Cockpit, R-05 Process Quality | Read-all |
| Data Engineer | Pipeline, DQ evidence, test suite | ETL admin |

## 4. Functional Requirements

| ID | Requirement | Acceptance criteria | Implementation | Status |
|---|---|---|---|---|
| FR-01 | Nightly batch completed by 06:00 | Reference load (~149K claims) completes < 10 min | `run_full_load.sql` (~3 min in CI) | ✅ |
| FR-02 | Standard status/code mapping at load | 100% of loaded claims carry catalogue values; enforced by DB CHECK constraints | ETL mapping + schema | ✅ |
| FR-03 | Automated DQ checks with rejection log | Every rejected row logged with severity + evidence; lineage identity balances: source = loaded + critical + duplicates | `dq_audit_log`, tests T07/T14–T17 | ✅ |
| FR-04 | Aging dashboard by team, drillable to claim | Aging buckets 0-30/31-60/61-90/91-180/180+ per team at latest snapshot | Query Q3 | 🔶 dashboard pending |
| FR-05 | Cycle time (avg + P90) and SLA by product | Per LOB/year (Q1) and monthly (Q2), FNOL-cohorted with cutoff filter | Queries Q1/Q2 | ✅ |
| FR-06 | Report filters: period, product, team, channel | Filterable report surface | Dashboard layer | 🔶 pending |
| FR-07 | Paid-vs-approved reconciliation, claim-level | Overpayment list (Q6) + totals (Q9): reference load → 339 claims, €650,236.22, avg ≈ €1,918 | Queries Q6/Q9, test T21 | ✅ |
| FR-08 | Export with timestamp | CSV export via psql `\copy`; formatted export with dashboard | Partial | 🔶 |
| FR-09 | Historical restatement on reopen | Restatement semantics defined and implemented | Open point O-01 (BRD) | ⬜ |

## 5. Data Quality Framework

**Load-time gates** (every decision logged to `dq_audit_log`):

| Gate | Severity | Action | Reference load |
|---|---|---|---|
| E1 source validation (invalid dates, decision-before-FNOL, missing lifecycle dates, invalid status) | Critical | Row rejected, not loaded | 45 rows |
| E2 duplicate detection | Warning | Exact duplicate removed | 40 rows |
| E3 handler lookup | Warning | Defaulted to UNKNOWN member H999 | 261 rows |

**Post-load verification:** 24 assertions in 7 categories (structure 2 · volume 4 · lineage 1 · distribution 6 · DQ gates 4 · business rules 5 · story 2). Includes distribution guards (T08/T10/T12) that encode a real defect fixed during development — `random()` in an uncorrelated FROM-subquery is evaluated once per query, silently degenerating all distributions; the suite now fails the build if that class of error returns.

**Reconciliation:** paid-vs-approved per claim (KPI-06). Detected violations are *reported*, not rejected — detection feeds the recovery process (BRD risk R-02).

## 6. Reports and KPI Specifications

| Report | Audience | KPIs | Refresh |
|---|---|---|---|
| R-01 Claims Cockpit | Ops Manager, Sponsor | KPI-01, 02, 07, 08 | Daily |
| R-02 Aging Cockpit | Team Leads | KPI-03 | Daily |
| R-03 Regulatory TAT Report | Compliance | KPI-02 | Monthly |
| R-04 Leakage Report | Payment Operations | KPI-06 | Daily |
| R-05 Process Quality | Operations | KPI-04, 05 | Monthly |

Authoritative definitions, targets, RAG thresholds, and baselines: [KPI Catalog](kpi-catalog.md).

## 7. Interfaces and Dependencies

- **Input:** legacy extract format — conventions and full column mapping in the [mapping document](../03-data-design/source-to-target-mapping.md)
- **Conformed calendar:** `dim_date` 2021–2025 (smart key YYYYMMDD)
- **Output:** KPI query layer consumed by the reporting dashboard (GitHub Pages, planned)
- **CI:** GitHub Actions runner with ephemeral PostgreSQL 15 service container

## 8. Non-Functional Requirements

| ID | Requirement | Status |
|---|---|---|
| NFR-01 | Dashboard response < 5 s over 3 years of data | Spot checks sub-second on indexed schema; formal measurement with dashboard |
| NFR-02 | Claimant data pseudonymized (GDPR) — no PII in model | ✅ |
| NFR-03 | Audit trail of data-quality decisions, 10-year retention | ✅ `dq_audit_log`; retention is an ops policy |

## 9. Traceability Matrix

| Requirement | KPI | Query | Data model element | Test |
|---|---|---|---|---|
| BR-01 | all | Q1–Q9 | star schema | T01–T02 |
| BR-02 / FR-04 | KPI-03 | Q3, Q4 | `fct_claim_status_snapshot` | T06 |
| BR-03 / FR-05 | KPI-01, 02 | Q1, Q2 | `fct_claim`, `dim_policy.sla_days` | T19, T22–T24 |
| BR-04 / FR-07 | KPI-06 | Q6, Q9 | `fct_claim` × `fct_payment` | T20, T21 |
| FR-02 | — | ETL | `dim_claim.current_status` + CHECKs | T11 |
| FR-03 | — | ETL | `dq_audit_log` | T07, T14–T17 |
| DQ-01 | — | — | NOT NULL keys | T18 |
| DQ-02 | KPI-06 | Q6 | reconciliation | T21 |
| Data integrity | — | — | dimensions/facts | T08, T10, T12, T13 |

## 10. Assumptions, Constraints, Open Points

1. **Boundary effects:** window-edge periods show artifacts (2022-01 SLA inflated; post-cutoff decisions land in 2025). Trend reports cohort on FNOL year with a cutoff filter (Q1).
2. **Two backlog views (by design):** assessment WIP (Registered + In Assessment — Q3) vs. total open pipeline including decided-awaiting-closure (Q4). See KPI catalog notes.
3. FR-09 restatement semantics open (BRD O-01).
4. Reference figures derive from the seeded synthetic dataset; distributions are realistic, absolute values are not market benchmarks.

## 11. Reproducing the Reference Results

```bash
export DB_URL='postgresql://user:password@host/dbname?sslmode=require'
psql "$DB_URL" -f 04-implementation/sql/schema/schema.sql
psql "$DB_URL" -v ON_ERROR_STOP=1 -f 04-implementation/sql/data/run_full_load.sql
psql "$DB_URL" -v ON_ERROR_STOP=1 -f 04-implementation/sql/tests/dq_test_suite.sql
psql "$DB_URL" -v ON_ERROR_STOP=1 -f 04-implementation/sql/queries/kpi_queries.sql
```
