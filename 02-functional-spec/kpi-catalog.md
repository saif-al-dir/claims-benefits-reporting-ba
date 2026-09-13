# KPI Catalog & Report Specifications

Authoritative KPI definitions for the Claims & Benefits reporting solution. Baselines are from the reference load (seeded, reproducible — see [FRS §11](FRS.md)).

**RAG convention:** Green = target met · Amber = within tolerance · Red = action required.

## KPI Summary

| ID | KPI | Target | Baseline (2024 / latest) | RAG | Query |
|---|---|---|---|---|---|
| KPI-01 | Claim cycle time (avg + P90) | P90 ≤ product SLA | Health 5.4/9 d · Accident 2.9/4 d · **Disability 19.8/49 d (SLA 21)** | 🔴 Disability (P90 = 2.3× SLA) | Q1 |
| KPI-02 | SLA compliance | ≥ 95% | Health 95.6% · Accident 95.0% · **Disability 78.2%** | 🟢🟢🔴 | Q2 |
| KPI-03 | Backlog & aging | Draining 90+/180+ tail | 6,814 open · 1,314 > 90 d · 1,168 > 180 d | 🔴 tail not draining | Q3/Q4 |
| KPI-04 | First-pass ratio | ≥ 85% | 94.4–94.8% | 🟢 | Q5 |
| KPI-05 | Reopen rate | ≤ 5% | 5.2–5.6% | 🟡 marginal | Q5 |
| KPI-06 | Payment leakage | 0 / flagged ≤ 24 h | **339 claims · €650,236.22 · avg €1,918** | 🔴 | Q6/Q9 |
| KPI-07 | Handler performance & workload | Informational | Team Delta 76.0–77.4% SLA; all others ≥ 91.8%; 2.5–3.1 K claims/handler | — | Q7 |
| KPI-08 | Digital intake share | Strategic growth | Portal 24.5% → 39.9% → 55.0% (2022–2024) | 🟢 | Q8 |

## Definitions & Measurement Notes

**KPI-01 — Claim cycle time.** `decision_date − fnol_date`, reported as mean **and** P90, cohorted on FNOL year with period-cutoff filter. *Why P90:* Disability's mean (~20 d) sits at its 21-day SLA while its P90 is ~49 d — the mean alone would certify compliance that the tail violates. RAG: Green P90 ≤ SLA · Amber ≤ 1.5× SLA · Red > 1.5× SLA.

**KPI-02 — SLA compliance.** Share of decided claims with `cycle_time ≤ sla_days` (product SLA from `dim_policy`). Monthly by LOB for the regulatory TAT report (R-03). Boundary months excluded from trend judgment (2022-01 is structurally inflated).

**KPI-03 — Backlog & aging.** Two views by design: (a) **assessment WIP** = Registered + In Assessment (Q3, drives team escalation); (b) **total open pipeline** = all claims not yet closed, including decided-awaiting-closure (Q4, drives capacity planning). Aging buckets 0-30 / 31-60 / 61-90 / 91-180 / 180+.

**KPI-04/05 — First-pass ratio / reopen rate.** Closed claims with `reopen_count = 0` / > 0. Baseline reopen marginally above the 5% target → Amber: monitor, no immediate action.

**KPI-06 — Payment leakage.** Claims where `SUM(payments) > approved_benefit_amount`, reported in **EUR, not count**: 339 claims is 0.23% of volume, but €650K is the exposure. Claim-level queue (Q6) for recovery; totals (Q9) for steering. Detection ≠ recovery (BRD R-02).

**KPI-07 — Handler performance & workload.** Per handler with ≥ 100 decided claims. Purpose: distinguish structural vs. individual performance — the baseline shows a *structural* Disability gap (all 8 Delta handlers in a 1.4-point band, comparable workload to 95%-SLA teams).

**KPI-08 — Digital intake share.** Channel mix of new claims per year; measures the digitalization initiative.

## Report Specifications

| Report | KPIs | Grain / views | Audience | Refresh |
|---|---|---|---|---|
| R-01 Claims Cockpit | 01, 02, 07, 08 | LOB × month; team ranking; channel trend | Ops Mgr, Sponsor | Daily |
| R-02 Aging Cockpit | 03 | Team × bucket, drill to claim | Team Leads | Daily |
| R-03 Regulatory TAT | 02 | Month × LOB, timestamped export | Compliance | Monthly |
| R-04 Leakage Report | 06 | Claim-level queue + totals | Payment Ops | Daily |
| R-05 Process Quality | 04, 05 | LOB × year | Operations | Monthly |
