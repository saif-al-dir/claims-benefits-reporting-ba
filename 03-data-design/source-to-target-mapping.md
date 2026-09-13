# Source-to-Target Mapping & Data Quality Rules

Documents the ETL from the simulated legacy extract (`stg_raw_claims`) into the star schema. Implemented in [`run_full_load.sql`](../04-implementation/sql/data/run_full_load.sql).

## 1. Source Profile — Legacy Conventions

| Convention | Legacy behavior | Risk |
|---|---|---|
| Dates | `'DD.MM.YYYY'` strings, sometimes corrupted (`'31.02.2024'`, `'XX.XX.XXXX'`) | Silent parse failure |
| Amounts | Integer **cents** | Unit errors (÷100 required) |
| Status | Codes `1/2/3/4/9` | No catalogue documentation |
| Channel | Free text (`'Phone'`, `'phone'`, `' Phone '`) | Non-comparable KPIs |
| Handler | Codes, sometimes unknown/lowercase/padded | Broken attribution |
| Duplicates | No uniqueness constraint on claim ID | Double-counting |

## 2. Column Mapping

| Source | Transformation | Target | Rule / Gate |
|---|---|---|---|
| `clm_id` | Dedup: `ROW_NUMBER()`, keep first | `dim_claim.claim_id` | E2: duplicates logged & dropped |
| `clm_stat` | Code map: 1→Registered, 2→In Assessment, 3→Decided, 4→Rejected, 9→Closed | `dim_claim.current_status` | Invalid code → E1 Critical |
| `clm_dat_fnol` | `fn_safe_to_date()` — regex + calendar validation | `fct_claim.fnol_date_key` | Unparseable → E1 Critical |
| `clm_dat_dec` | Same parser | `decision_date_key` | `decision < fnol` → E1 Critical |
| `clm_dat_close` | Same parser | `close_date_key` | `close < decision`, closed w/o close → E1 |
| `pol_id` | Join `dim_policy` | `policy_sk` | Line of business **derived** from policy |
| `clmt_id` | Join `dim_claimant` | `claimant_sk` | Pseudonymized (no PII) |
| `handl` | `UPPER(TRIM())` → lookup | `handler_sk` | Unknown → default **H999** + E3 Warning |
| `chanl` | Normalize spelling → catalogue | `dim_claim.intake_channel` | Phone/Portal/Email/Broker |
| `clm_reason` | Direct (validated vocabulary) | `dim_claim.claim_reason` | Drives benefit mapping |
| `rwn_cnt` | `COALESCE(x,0)` | `dim_claim.reopen_count` | — |
| `clamd_amt` | `÷ 100.00` | `fct_claim.claimed_amount` | — |
| `apprd_amt` | `÷ 100.00`; NULL/negative → NULL | `approved_benefit_amount` | NULL = pending |

## 3. Derived Fields

| Target | Rule |
|---|---|
| `reserve_amount` | 80% of claimed while Registered/In Assessment, else 0 |
| `cycle_time_days` | `decision_date − fnol_date` (NULL until decided) |
| `sla_met` | `cycle_time ≤ dim_policy.sla_days` (NULL until decided) |
| `first_pass_flag` | `reopen_count = 0` |
| `fct_payment.benefit_sk` | Claim-reason → benefit mapping (e.g. Temporary Disability → Disability Income Monthly, *Recurring*) |
| Recurring installments | Monthly payments; final installment adjusted so total = approved exactly (no rounding leakage) |
| `fct_claim_status_snapshot` | Month-end 2022–2024 + daily Q4-2024; status timeline Registered → In Assessment → Decided/Rejected |

## 4. Data Quality Gates

| Gate | Severity | Action | Baseline |
|---|---|---|---|
| **E1** invalid status · unparseable dates · decision-before-FNOL · close-before-decision · missing lifecycle dates | Critical | Reject row (not loaded), log evidence | 45 |
| **E2** exact duplicate claim rows | Warning | Drop duplicate, log | 40 |
| **E3** handler code not in `dim_handler` | Warning | Default to H999 (Unassigned), log | 261 |
| **Reconciliation** `SUM(paid) > approved` | Report | Flag for recovery (KPI-06) — not a load rejection | 339 claims / €650,236.22 |

> Note: the ~340 leakage rows are **deliberately injected** in the synthetic generator (clearly labeled blocks) so the reconciliation control has realistic violations to detect — in production, KPI-06 output feeds the recovery workflow.

## 5. Balancing & Verification

**Lineage identity (must balance exactly):** `source rows = loaded + critical rejections + duplicates` → reference: **149,237 = 149,152 + 45 + 40**.

**Post-load test suite** (runs in CI on every push, fresh database): 24 assertions — structure (2) · volume (4) · lineage (1) · **distribution (6)** · DQ gates (4) · business rules (5) · story (2). Distribution guards encode the fixed `random()`-evaluation defect: a degenerate dataset now fails the build.

## 6. Known Limitations

1. Decided claims remain in snapshots until closure (payment-pending WIP) — hence the two backlog views (KPI-03).
2. Window-boundary artifacts (2022-01, post-cutoff 2025 decisions) — handled by FNOL-cohorting in trend queries.
3. Snapshot coverage is month-end before Q4-2024 and daily within Q4-2024 — a storage/insight trade-off.
