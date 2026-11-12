#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/qcicada-tests.XXXXXX")
trap 'rm -rf "$test_build_dir"' EXIT HUP INT TERM

xcrun swiftc -swift-version 5 -default-isolation MainActor -O \
    Qcicada/Models/SerialPort.swift Qcicada/Models/QCCProtocol.swift \
    Tests/SerialProtocolTests.swift -o "$test_build_dir/serial"
"$test_build_dir/serial"

xcrun swiftc -swift-version 5 -default-isolation MainActor -O \
    Qcicada/Models/SerialPort.swift Qcicada/Models/QCCProtocol.swift \
    Qcicada/Models/RandomTestEngine.swift \
    Tests/AcquisitionTests.swift -o "$test_build_dir/acquisition"
"$test_build_dir/acquisition"

xcrun swiftc -swift-version 5 -default-isolation MainActor -O \
    Qcicada/Models/AuditEngine.swift Tests/AuditEngineTests.swift \
    -o "$test_build_dir/audit"
"$test_build_dir/audit"

xcrun swiftc -swift-version 5 -default-isolation MainActor -O \
    Qcicada/Models/StreamingPNGWriter.swift Qcicada/Models/PlotExporter.swift Tests/PlotExporterTests.swift \
    -o "$test_build_dir/plot"
"$test_build_dir/plot"

xcrun swiftc -swift-version 5 -default-isolation MainActor -O \
    Qcicada/Models/AppSettings.swift Tests/SettingsTests.swift \
    -o "$test_build_dir/settings"
"$test_build_dir/settings"

# Exercise the shared save/quit state machine using isolated simulated sessions.
xcrun swiftc -swift-version 5 -default-isolation MainActor -O \
    Qcicada/Models/*.swift Tests/SessionLifecycleTests.swift \
    -o "$test_build_dir/lifecycle"
"$test_build_dir/lifecycle"

xcrun swiftc -swift-version 5 -default-isolation MainActor -O \
    Qcicada/Models/AuditEngine.swift Tests/AuditWriteFailureTests.swift \
    -o "$test_build_dir/audit-write-failure"
"$test_build_dir/audit-write-failure"
