# dBase → SQL migration plan (the back-pocket plan for workload 1)

The dBase layer in workload 1 is life support, not a destination. This is
the exit, in the order it has to happen. Every step is reversible until
step 5.

## Step 0 — Freeze the truth
- Inventory every .DBF/.DBT/.MDX with `Tier3Manager` (record counts,
  field maps). The emitted DDL is the contract for the target schema.
- Identify the writers: dBase record locking is cooperative. Every VB6
  screen that writes must be catalogued — an unknown writer found later
  invalidates the cutover.

## Step 1 — Stand up the target
- PostgreSQL (RDS/Aurora PostgreSQL in the same VPC) or SQL Server if the
  VB6 data-access layer is ADO-to-SQL-shaped already. Decision rule: if
  the VB code speaks ODBC generically, PostgreSQL; if it leans on
  SQL Server idioms, SQL Server. Do not translate idioms mid-migration.
- Apply the Tier3Manager DDL; add surrogate keys — dBase has none worth
  trusting — and keep the legacy record number as a column for audit.

## Step 2 — Bulk load + prove it
- Convert with the DBF reader (memo fields from the .DBT in the same pass).
- Prove: row counts per table, control totals on every numeric column,
  and a 1% random sample eyeballed against the live app. No proof, no
  step 3.

## Step 3 — Dual-run
- Nightly sync dBase → SQL (changed-records via the replication watcher).
- Point READ-ONLY reporting at SQL first. The VB6 app still writes dBase.
- Run one full business cycle (month-end is the honest test) in dual-run.

## Step 4 — Flip the writes
- One maintenance window: final sync, switch the app's connection to SQL
  via the ODBC DSN (the only code change is the connection string and any
  dBase-ism SQL the catalogue from step 0 flagged).
- dBase share goes read-only the same night. It stays mounted, read-only,
  for one full quarter as the fallback.

## Step 5 — Retire
- After a clean quarter: snapshot the FSx share to S3 (already versioned
  by the workload-1 vault bucket), decommission the share, and shrink the
  WS2008 footprint to the tiers that still need it.

## Risks, plainly
- Memo-field corruption in old .DBT files is the classic failure — step 2's
  sample check exists because of it.
- Date fields: dBase stores YYYYMMDD as characters; dirty values
  ("  /  /  ") will fail DATE conversion. The loader quarantines them to
  an exceptions table rather than guessing. Never guess a date.
- The plan dies if a shadow writer exists. Step 0 is the whole ballgame.
