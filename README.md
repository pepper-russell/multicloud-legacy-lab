# Multicloud Legacy Lab — the drop

One multicloud environment (AWS + Azure + GCP) joined by a full-mesh,
BGP-routed site-to-site VPN, carrying three legacy workloads that should
not work in 2026 and do anyway — plus the Swift tooling that runs them.

## Layout
```
terraform/network/            The mesh: one hub + VPN gateway per cloud,
                              AWS<->Azure, AWS<->GCP, Azure<->GCP, BGP.
terraform/workload1-tier3/    AWS. 3-tier app: WS2008 + Classic VB,
                              autoscaling on every tier, dBase data layer
                              on FSx with a versioned S3 vault.
terraform/workload2-frontpage/ Azure. FrontPage 98 blog: private staging
                              VM over the mesh only, public static hosting
                              + CDN in front.
terraform/workload3-cobol/    GCP. Bank COBOL modernization env: PCI-shaped
                              CDE segment, CMEK everywhere, audit-log
                              retention lock, GnuCOBOL runtime, Cloud SQL
                              target, Cloud Run for the modernized API.
swift-apps/MeshController/    Validates the mesh design (CIDR overlap,
                              ASN collisions, missing legs).
swift-apps/Tier3Manager/      dBase replication check + migration DDL
                              generator (parses real DBF headers).
swift-apps/FrontPagePublisher/ Promotes an FP98 site from staging to
                              publish; skips _vti_*; dead-link + FrontPage
                              component report.
swift-apps/CobolMigrator/     Estate inventory, CP037->UTF-8 conversion,
                              reconciliation gate (the cutover evidence).
migration-plans/              dbase-to-sql.md, cobol-modernization.md.
```

## Address plan (no overlaps, ever)
AWS 10.10.0.0/16 · Azure 10.20.0.0/16 · GCP 10.30.0.0/16 · CDE 10.30.66.0/24

## Honest flags — read before applying anything
1. **Windows Server 2008 is end-of-life.** No patches since Jan 2023. The
   Terraform quarantines it (no internet egress, ALB-only inbound, RDP
   only over the mesh), but quarantine is mitigation, not safety. The AMI
   is bring-your-own via VM Import — no cloud sells this image.
2. **dBase has no HA.** The design gives it shared storage, replication
   checks, and snapshots — the most the format honestly supports. The
   exit is written: `migration-plans/dbase-to-sql.md`.
3. **FrontPage Server Extensions stay off the internet.** FP98 publishes
   to a private VM over the VPN; the public sees static files only. Hit
   counters and form handlers don't survive — the publisher reports them
   instead of pretending.
4. **PCI is a posture, not a checkbox.** Workload 3 builds the
   segmentation/encryption/logging skeleton; a QSA still has to bless the
   real thing, and the COBOL plan's reconciliation gates are the evidence
   trail.
5. **Secrets** (VPN PSKs, VM passwords) are Terraform variables — inject
   from a vault at apply time. Nothing real is committed here.

## Run order
1. `terraform -chdir=terraform/network apply` (needs the three PSK vars).
2. Each workload module, passing the hub IDs from the network outputs.
3. `swift run` inside any swift-apps/* package — they take paths, not
   cloud credentials, by design.

Built Nov 9, 2026 as a lab/POC drop in Charles's poc-lab.
