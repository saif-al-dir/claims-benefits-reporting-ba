🏥 Insurance Claims & Benefits — Business Analysis to Reporting Solution


End-to-end business analysis project: from business requirements analysis andBPMN process modeling, through functional specification and data warehousedesign, to a tested and automatically deployed KPI reporting solution.

⚠️ Fictional case study ("NovaCare Insurance"). All data is synthetic — GDPR-safe.


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
Setup instructions coming in Step 2.