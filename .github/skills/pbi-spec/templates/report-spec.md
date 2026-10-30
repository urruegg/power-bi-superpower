# <Report / model name> — design

**Issue:** #<n>
**Status:** Draft | In review | Approved (by <role>, <date>)
**Branch:** feat/<n>-<slug>
**Owner (business):** <role> · **Data owner:** <role> · **Tech lead:** <role>

## 1. Purpose
- Decision(s) supported:
- Audience and usage frequency:
- Success measure (how we know the report works):

## 2. Scope
- In scope:
- Out of scope:
- Assumptions:

## 3. KPI catalogue
| # | KPI (measure name) | Business definition | Formula in words | Grain / filters | Time logic | Format | Owner |
|---|---|---|---|---|---|---|---|
| K1 | | | | | | | |

## 4. Data
| Source | System / location | Owner | Tables / entities | Grain | Volume | Refresh | Access path (connector, gateway, OneLake) |
|---|---|---|---|---|---|---|---|

Storage mode decision (Import / Direct Lake / DirectQuery) and why:
Parameters needed per environment (become M parameters in `expressions.tmdl`):

## 5. Semantic model design
- Fact tables (grain, keys):
- Dimension tables (keys, attributes, hierarchies, sort-by columns):
- Date table and marked date column:
- Relationships (from → to, cardinality, direction, active):
- Calculation groups / field parameters (if any):
- Display folders and naming:

## 6. Report design
| Page | Decision answered | Visuals (kind → fields) | Filters / slicers | Drill-through / tooltips |
|---|---|---|---|---|

Blueprint: `src/<Project>/report-blueprint.json` · Theme: <base / custom> · Mobile layout: yes/no

## 7. Security and compliance
- RLS roles (name → rule → who) — membership is set in the service by humans:
- OLS / hidden objects:
- Sensitivity label:
- Personal data and retention:

## 8. Non-functional requirements
- Refresh window and SLA:
- Visual load time budget (default ≤ 3 s per page):
- Accessibility (alt text, contrast, keyboard order):
- Languages / cultures:

## 9. Acceptance tests (become DAX tests)
| Test | Filter context | Expected value | Source of expected value | Test file |
|---|---|---|---|---|
| K1 overall | none | | | `<Area>.ALL.Tests.dax` |
| K1 for <slice> | <column = value> | | | |

## 10. Risks and open questions
| # | Question / risk | Owner | Due |
|---|---|---|---|

## 11. Revision history
| Date | Change | Approved by |
|---|---|---|
