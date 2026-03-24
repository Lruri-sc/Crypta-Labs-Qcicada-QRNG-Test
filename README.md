# Qcicada

This project is a Swift rebuild of the uQcicada testing software used with Crypta Labs hardware.

The original workflow was unpacked from their Python library and then reimplemented with native Swift and native macOS UI components (SwiftUI/AppKit/Charts).

The app is focused on running QRNG test sessions and saving the session outputs locally.

After a test session, it generates:

- raw bit stream file: `rng_raw_YYYYMMDD_HHMMSS.txt`
- stats CSV file: `rng_stats_YYYYMMDD_HHMMSS.csv`
- summary/audit report: `rng_audit_YYYYMMDD_HHMMSS.txt`

It can also export a full-session plot image:

- plot image: `rng_session_YYYYMMDD_HHMMSS.png`

Exact naming is defined in code:

- `Qcicada/Models/RandomTestEngine.swift`
- `Qcicada/Models/AuditEngine.swift`
- `Qcicada/Models/PlotExporter.swift`
