# Qcicada

This project is a Swift rebuild of the uQcicada testing software used with Crypta Labs hardware.

The original workflow was unpacked from their Python library and then reimplemented with native Swift and native macOS UI components (SwiftUI/AppKit/Charts).

The app is focused on running QRNG test sessions and saving the session outputs locally.

Currently, only the Apple Music theme is effective.

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

## Saving results

Choose a folder with **Settings → Export → Choose…**.
The app remembers this folder when reopened. Changing the choice during a test
applies to the next test; all files from the current session stay in its original
folder and share the same session identifier. A filename collision adds a unique
suffix to the new session instead of replacing previous results. Unavailable or
unwritable folders fail explicitly; collection does not silently fall back to a
different folder.

Stopping waits for the current read and file writes to finish before taking the
export snapshot. Serial operations and file writes run off the main thread.
Reports distinguish missing/insufficient raw data from completed statistical tests
and disclose the sample limits.

## Regression checks

With Xcode's Swift toolchain selected, run `sh Tests/run-tests.sh` from this folder.
The standalone checks cover simulated serial responses and interrupted collection,
file consistency and collision protection, statistics, background PNG export, and
save-folder persistence. They create isolated temporary test data and do not
connect to QRNG hardware or alter the application's saved preferences.

## Long sessions, faults, and Quit

Full-session PNG output keeps its layout, colors, fonts, three logical pixels per
sample, and display backing scale however long the session is. Export renders
narrow strips into a temporary on-disk raster and streams the PNG, so the
full-width bitmap is never held in memory. Temporary raster/PNG files are removed
on completion or error; free-space checks run before rendering. This trades
temporary disk space for lower memory use and does not impose a smaller output
size or downsample the plot. Strips are rendered on up to four threads and the PNG
is compressed in independent pieces on every core; the pixels are identical to a
single-threaded export. Working memory stays bounded (about 0.75 GB at a 2x
backing scale) for any session length.

Stop, device failures, window close, and application Quit share one save workflow.
A fault saves the accepted samples according to the automatic-save options
and marks the report as interrupted. Raw analysis only reads the accepted bit count;
missing or truncated raw data produces an explicitly marked summary instead of
pretending the raw-bit tests passed.

Quit waits for every open session to stop, save, and disconnect. If an output fails,
Quit is cancelled and the frozen session remains available for retry through the
Start, window-close, or Quit actions. A retry skips outputs already saved
successfully. Reports and plots are published only after the temporary output is
complete, without replacing existing files.

Connecting, collection at every chunk size, Stop and save, reconnecting, Quit while
connected, and reconnecting after a killed session have been checked on a QCicada
device (CICADA-QRNG-1.1). Unplugging the device during a session has only been
simulated. A system force-quit or power loss cannot use the normal application's
save-and-exit handshake.
