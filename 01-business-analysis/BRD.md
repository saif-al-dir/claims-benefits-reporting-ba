# Business Requirements Document

## Claims & Benefits Reporting Solution — "Project Claims Cockpit"

| | |
|---|---|
| **Document** | BRD v1.0 (baseline for implementation) |
| **Client** | NovaCare Insurance (fictional mid-size insurer, ~500K active policies) |
| **Author** | Saif — Business Analyst |
| **Related artifacts** | [Functional Specification](../02-functional-spec/FRS.md) · [Data Model](../03-data-design/logical-data-model.md) · [KPI Query Library](../04-implementation/sql/queries/kpi_queries.sql) · [DQ Test Suite](../04-implementation/sql/tests/dq_test_suite.sql) |

> ⚠️ Fictional case study. All figures derive from a synthetic, seeded dataset (~149,000 claims, 2022–2024) generated and quality-tested by this repository's own pipeline. No real customer data — GDPR-safe.

## 1. Executive Summary

NovaCare processes ~50,000 claims per year across three legacy claims systems plus manual Excel reporting. Baseline analysis — performed with the reporting pipeline built by this project — shows:

- **Disability SLA compliance is stuck** at 75–78% for three consecutive years while Health improved from 90.0% to 95.6% and Accident holds ~95%.
- **The Disability backlog problem is invisible in averages**: average cycle time (~20 days) sits at its 21-day SLA, but the 90th percentile is ~50 days — 1 in 10 claimants waits more than twice the promised turnaround.
- **Year-end 2024 backlog**: 6,814 open claims, of which 1,168 have been open for more than 180 days.
- **Payment leakage**: ≈340 claims were paid above the approved benefit amount (duplicate payments and erroneous re-issues).
- **Data quality is unmanaged today**: the reference load rejected 45 critical records and flagged 301 records (duplicates, unknown handler codes) — error classes the legacy process has never measured.

The solution delivers a conformed claims data warehouse with automated, tested data-quality gates and a KPI reporting layer — replacing 5 person-days of monthly manual reporting with daily transparency, regulatory TAT evidence, and continuous payment reconciliation.

## 2. Current-State Analysis (Quantified Baseline)

Produced by the implemented pipeline; reproducible via the commands in §11.

| Finding | Value | Source |
|---|---|---|
| Claims processed 2022–2024 | 149,237 source records → 149,152 loaded, 45 critical rejections, 40 duplicates removed | Load lineage |
| SLA compliance by LOB (2022 → 2024) | Health 90.0 → 95.6% · Accident 93.9 → 95.0% · **Disability 75.2 → 78.2%** | KPI-01/02 (Q1) |
| Cycle time avg / P90 (2024) | Health 5.4 / 9 d · Accident 2.9 / 4 d · **Disability 19.8 / 49 d (SLA 21 d)** | KPI-01 (Q1) |
| Backlog at 2024-12-31 | 6,814 open · 1,314 > 90 d · 1,168 > 180 d | KPI-03 (Q4) |
| First-pass ratio / reopen rate | 94.4–94.8% / 5.2–5.6% (target: ≥85% / ≤5%) | KPI-04/05 (Q5) |
| Payment leakage | ≈340 claims paid above approved amount | KPI-06 (Q6) |
| Handler performance | Team Delta (Disability): all 8 handlers at 76.0–77.4% SLA; all other handlers ≥ 91.8% | Q7 |
| Digital intake adoption | Portal share 24.5% → 39.9% → 55.0% | Q8 |
| Per-handler workload | Health ~2,560 · Accident ~3,100 · Disability ~2,800 claims per handler | Q7 |

**Key analytical conclusions:**

1. The Disability gap is **structural, not individual**: between-team variation dwarfs within-team variation, and per-handler workload is comparable (Accident carries *more* claims per handler at 95% SLA). Root cause candidates: SLA calibrated too tight for medical-assessment effort, or assessment-flow complexity — not handler capacity or skill.
2. **Averages mask the exposure**: any TAT commitment reported on means alone will understate the customer and regulatory risk by a factor of ~2.5 for Disability.
3. The backlog has a **bimodal age profile**: a healthy 0–30-day flow plus a parked 180+ tail that does not drain — indicating a missing escalation/cleanup process for legacy claims.

## 3. Problem Statement

Monthly reporting consumes 5 person-days of manual extraction and reconciliation; claim aging between month-ends is invisible; benefit amounts are calculated in uncontrolled spreadsheets; approvals leave no audit trail; and the regulator's new TAT-evidence requirement cannot be met from current systems.

## 4. Project Objectives

| ID | Objective | Target | Measured by |
|---|---|---|---|
| OBJ-1 | Reporting effort reduction | 5 days → < 0.5 days/month | Reporting runtime |
| OBJ-2 | Backlog transparency | Daily aging visibility by team | KPI-03 |
| OBJ-3 | Claim cycle time | −20% within 12 months (post go-live) | KPI-01 |
| OBJ-4 | Regulatory TAT evidence | 100% of decisions traceable with timestamps | KPI-02 |
| OBJ-5 | Payment accuracy | Overpayments flagged ≤ 24h after occurrence | KPI-06 |

## 5. Stakeholder Analysis

| Stakeholder | Interest | Influence | Engagement |
|---|---|---|---|
| Head of Claims Ops (Sponsor) | Cost, cycle time, KPIs | High | Kick-off, monthly review |
| Claims Team Leads | Aging, workload distribution | High | Interviews, workshops |
| Claims Handlers | Less manual work | Medium | Process walkthroughs |
| Payment Operations | Reconciliation accuracy | Medium | Document analysis |
| Actuarial / Finance | Loss ratio, reserves | Medium | Requirements review |
| Compliance / Regulator | TAT evidence, audit trail | High | Gap analysis |
| IT / Data Engineering | Feasibility, interfaces | High | Technical workshops |

## 6. Requirements Catalog

### 6.1 Business Requirements

| ID | Requirement | Priority | Status |
|---|---|---|---|
| BR-01 | Single source of truth for all claims KPIs | Must | ✅ Delivered (star schema + CI) |
| BR-02 | Daily backlog and aging visibility by team | Must | ✅ Delivered (Q3/Q4) |
| BR-03 | Automated monthly regulatory TAT report | Must | ✅ Delivered (Q2) |
| BR-04 | Payment reconciliation, paid vs approved | Must | ✅ Delivered (Q6) |
| BR-05 | Reporting effort < 0.5 person-days/month | Must | ✅ Queries; dashboard in progress |

### 6.2 Functional Requirements

| ID | Requirement | Priority | Status |
|---|---|---|---|
| FR-01 | Batch ingestion completed by 06:00 nightly | Must | ✅ Pipeline (CI-runnable) |
| FR-02 | Standard status/reason code mapping applied during load | Must | ✅ ETL mapping + DB CHECK constraints |
| FR-03 | Automated DQ checks with rejection log and alerting | Must | ✅ `dq_audit_log` + 24-assertion suite |
| FR-04 | Aging dashboard by team, drillable to claim | Must | 🔶 Query layer done (Q3); dashboard planned |
| FR-05 | Cycle time (avg + P90) and SLA compliance by product | Must | ✅ Delivered (Q1/Q2) |
| FR-06 | Report filters: period, product, team, channel | Must | 🔶 Dashboard planned |
| FR-07 | Paid-vs-approved reconciliation report with claim-level evidence | Must | ✅ Delivered (Q6) |
| FR-08 | Export to Excel/PDF with timestamp | Should | 🔶 Partial (CSV via psql) |
| FR-09 | Historical restatement when claims are reopened | Should | ⬜ Planned |

### 6.3 Non-Functional & Data-Quality Requirements

| ID | Requirement | Priority | Status |
|---|---|---|---|
| NFR-01 | Dashboard response < 5 s over 3 years of data | Should | ⬜ Pending dashboard |
| NFR-02 | Claimant data pseudonymized (GDPR) | Must | ✅ No PII in model |
| NFR-03 | Full audit trail of data changes, 10-year retention | Must | 🔶 `dq_audit_log` delivered; retention = ops |
| DQ-01 | Completeness of key fields ≥ 98% | Must | ✅ Tested (T18: zero NULL keys) |
| DQ-02 | Paid ≤ approved; violations flagged | Must | ✅ Tested (T21) |

## 7. Use Cases

### UC-01 — Team Lead monitors aging and escalates overdue claims

| | |
|---|---|
| **Actor** | Claims Team Lead |
| **Trigger** | Daily dashboard review (09:00) |
| **Precondition** | Nightly load completed by 06:00 (FR-01), DQ checks green (FR-03) |
| **Main flow** | 1. Opens Claims Cockpit → 2. Filters own team (FR-06) → 3. Reviews aging buckets 0-30/31-60/61-90/91-180/180+ (FR-04) → 4. Opens 180+ bucket → 5. Reviews claim list sorted by days open → 6. Escalates/reassigns via workflow |
| **Alternate flow** | 3a. SLA-breach count exceeds threshold → automatic escalation notification |
| **Postcondition** | Escalation logged with timestamp (OBJ-4 evidence) |

### UC-02 — Compliance officer produces regulatory TAT evidence

| | |
|---|---|
| **Actor** | Compliance Officer |
| **Trigger** | Monthly regulatory submission |
| **Main flow** | 1. Opens TAT report → 2. Selects reporting month → 3. System presents decided claims with FNOL/decision timestamps, cycle time, SLA met flag by product (FR-05, Q2) → 4. Exports with timestamp stamp (FR-08) |
| **Business rules** | Cycle time = decision date − FNOL date; SLA per product from policy dimension |
| **Postcondition** | Submission archived; figures reproducible from warehouse |

### Further use cases (detailed in the FRS)

UC-03 Payment Operations works the leakage queue (Q6) · UC-04 Operations manager reviews handler workload balance (Q7) · UC-05 Sponsor tracks digital-intake adoption (Q8)

## 8. Scope

**In scope:** claims DWH (star schema), ETL with DQ gates, KPI/reporting layer, automated testing + CI, reporting dashboard. **Out of scope:** replacement of claim intake systems, workflow/engine implementation, role-based access management, source-system remediation.

## 9. Assumptions & Constraints

1. Nightly batch (not streaming) suffices for all KPIs; 06:00 completion SLA.
2. Reporting currency EUR; amounts in legacy source stored in cents.
3. Backlog history via status snapshots (month-end 2022–2024, daily for Q4-2024).
4. **Boundary effects**: months at the edge of the data window show artifacts (2022-01 SLA inflated; post-cutoff decisions fall into 2025) — trend reports cohort on FNOL year with a cutoff filter (see Q1).
5. Synthetic dataset: distributions are realistic by design; absolute figures are not market benchmarks.

## 10. Risks & Open Issues

| # | Risk / Issue | Impact | Mitigation / Owner |
|---|---|---|---|
| R-01 | Disability SLA may be mis-calibrated vs assessment effort | Wrong target drives wrong behavior | SLA recalibration study — Ops + Actuarial |
| R-02 | Leakage recovery process undefined (detection ≠ recovery) | Financial exposure persists after go-live | Payment Ops to define recovery workflow |
| R-03 | 180+ backlog has no owner/cleanup process | Aging tail never drains | Escalation rule in to-be process |
| O-01 | Restatement semantics for reopened claims (FR-09) undecided | Historical KPI drift | FRS workshop |

## 11. Reproducing the Baseline

```bash
export DB_URL='postgresql://user:password@host/dbname?sslmode=require'
psql "$DB_URL" -f 04-implementation/sql/schema/schema.sql
psql "$DB_URL" -v ON_ERROR_STOP=1 -f 04-implementation/sql/data/run_full_load.sql
psql "$DB_URL" -v ON_ERROR_STOP=1 -f 04-implementation/sql/queries/kpi_queries.sql
```

## 12. Sign-off

| Role | Name | Date |
|---|---|---|
| Sponsor — Head of Claims Ops | *(fictional)* | |
| Business Analyst | Saif | |
| Compliance | *(fictional)* | |
