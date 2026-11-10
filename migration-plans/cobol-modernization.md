# COBOL modernization plan — bank estate, PCI DSS 4.0 throughout

## Target, and why
**Java 21 / Spring Boot** services on Cloud Run, **PostgreSQL (Cloud SQL)**
for data. Why Java: the deepest COBOL→Java transpiler ecosystem, the
largest bank-grade hiring pool to maintain the result, and the most mature
PCI tooling (scanners, WAF rules, audit frameworks) of any target.
(A .NET target is defensible; a Node/Go target for a bank core is not a
conversation worth having with an auditor.)

## The non-negotiables (PCI, before any code moves)
1. **Segmentation first.** The CDE subnet in workload 3 exists before the
   first program is copied. Data never leaves the CDE unencrypted; the
   migration pipeline runs *inside* it.
2. **No PAN in the pipeline's logs, ever.** CobolMigrator reads structure
   and counts, not cardholder values. Conversion jobs mask on read for any
   field the inventory flags as card-bearing; the flag list is a signed
   artifact, not a comment.
3. **Evidence at every gate.** Reconciliation (record counts + control
   totals, `CobolMigrator reconcile`) is signed off per file before the
   next stage opens. An unsigned gate stops the program, by rule.

## Phases
**Phase 0 — Inventory (2–4 wks).** CobolMigrator inventory: every program,
copybook, and data file, with call graph and data lineage. Dead programs
(banks typically find 20–40%) are retired, not migrated.

**Phase 1 — Rehost as-is (4–8 wks).** Recompile the surviving estate on
GnuCOBOL inside the CDE (workload 3 runtime). Zero functional change.
This buys the estate off the mainframe's clock and proves behavioral
equivalence with parallel-run output diffing — the baseline every later
phase is measured against.

**Phase 2 — Data migration (6–10 wks).** VSAM/sequential → Cloud SQL:
EBCDIC→UTF-8 conversion, packed-decimal (COMP-3) decoded with an explicit
rounding rule signed by Finance, dates normalized. Reconciliation gate
per file. Dual-write during transition; the COBOL estate stays the
system of record until the gate passes for every file.

**Phase 3 — Program transpilation (the long middle).** Automated
transpilation (COBOL→Java) for the mechanical majority; hand-rewrite for
the programs the transpiler mangles (expect 10–20%: heavy SORT/merge
logic, assembler exits, and anything touching CICS screens). Every
transpiled program passes the Phase 1 baseline diff suite before it
replaces its COBOL twin — strangler-fig, one program at a time, feature
flags at the router.

**Phase 4 — Cutover + decommission.** Final parallel run across a full
statement cycle, QSA walkthrough of the new CDE, then the COBOL runtime
is frozen read-only for the retention period and decommissioned.

## What will actually go wrong (plan for these)
- **COMP-3 rounding drift** — pennies that don't reconcile. The signed
  rounding rule in Phase 2 exists because this is a when, not an if.
- **Undocumented batch dependencies** — jobs triggered by files appearing,
  by operator habit, by the calendar in someone's head. Phase 0 interviews
  operators, not just code.
- **Transpiler output nobody can maintain** — budget the hand-rewrite
  honestly (Phase 3), or you have traded COBOL you can't staff for Java
  you can't read.
- **Scope creep toward "while we're in there"** — forbidden by the plan.
  Modernization first; improvements after cutover, in the new stack.

## Timeline honesty
For a mid-size bank estate (500–2,000 programs): 12–24 months end to end.
Anyone quoting a quarter is selling something.
