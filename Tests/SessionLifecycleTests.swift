// Run from the repository root:
// xcrun swiftc -swift-version 5 -default-isolation MainActor -O \
//   Qcicada/Models/*.swift Tests/SessionLifecycleTests.swift -o /tmp/qcicada-lifecycle-tests
// /tmp/qcicada-lifecycle-tests

import Foundation

nonisolated private final class GatedExporter: SessionExporting, @unchecked Sendable {
    private let lock = NSLock()
    private let gates: [DispatchSemaphore]
    private let results: [SessionExportResult]
    private var recorded: [SessionExportRequest] = []
    private var progressCallbacks: [@Sendable (String) -> Void] = []
    private var background = true

    init(_ results: [SessionExportResult]) {
        self.results = results
        gates = results.map { _ in DispatchSemaphore(value: 0) }
    }

    var requests: [SessionExportRequest] { lock.withLock { recorded } }
    var alwaysBackground: Bool { lock.withLock { background } }
    func release(_ index: Int) { gates[index].signal() }
    func releaseAll() { gates.forEach { $0.signal() } }
    func sendProgress(_ index: Int, _ message: String) {
        let callback = lock.withLock { progressCallbacks[index] }
        callback(message)
    }

    func export(_ request: SessionExportRequest, progress: @escaping @Sendable (String) -> Void) -> SessionExportResult {
        let index = lock.withLock {
            background = background && !Thread.isMainThread
            let index = recorded.count
            recorded.append(request)
            progressCallbacks.append(progress)
            return index
        }
        precondition(index < results.count, "Unexpected duplicate export attempt")
        progress("Export test in progress")
        gates[index].wait()
        return results[index]
    }
}

@MainActor
private final class ShutdownSpy: ShutdownParticipant {
    private(set) var prepareCount = 0
    private(set) var resumeCount = 0
    private var completions: [(Bool) -> Void] = []

    func prepareForShutdown(completion: @escaping (Bool) -> Void) {
        prepareCount += 1
        completions.append(completion)
    }
    func resumeAfterCancelledShutdown() { resumeCount += 1 }
    func finish(_ success: Bool) {
        let pending = completions
        completions.removeAll()
        pending.forEach { $0(success) }
    }
}

private enum LifecycleTestFailure: Error { case failed(String) }

@main
struct SessionLifecycleTests {
    @MainActor private static var preferenceSuites: [String] = []

    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Qcicada-LifecycleTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            for suite in preferenceSuites {
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            }
        }
        try await testFaultExportAndWaiters(in: directory)
        try await testPartialRetryAndStart(in: directory)
        try await testQuitWaitsForEveryWindow(in: directory)
        try await testEmptyQuitIsAsynchronous()
        try await testRegistrationAndDetachDuringQuit()
        try await testRealExporter(in: directory)
        print("PASS: all session lifecycle regression groups completed")
    }

    @MainActor private static func settings(directory: URL) -> AppSettings {
        let suite = "Qcicada.SessionLifecycleTests." + UUID().uuidString
        preferenceSuites.append(suite)
        let result = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        result.exportPath = directory.path
        return result
    }

    nonisolated private static func snapshot(
        directory: URL, fileID: String? = "simulated-session", rawPath: String? = nil,
        sampleCount: Int = 2, totalBits: Int = 128, failure: String? = nil
    ) -> CompletedSessionSnapshot {
        CompletedSessionSnapshot(
            id: UUID(), fileID: fileID, directory: directory.path,
            port: "simulated-device", direction: 0, chunkSize: 8,
            rawFilePath: rawPath, csvFilePath: directory.appendingPathComponent("rng_stats_\(fileID ?? "none").csv").path,
            sampleCount: sampleCount, totalBits: totalBits, totalOnes: totalBits / 2,
            cumulativeZ: 0, instantZ: 0, izMean: 0, izVariance: sampleCount > 1 ? 0 : 1,
            peakInstHi: 0, peakInstLo: 0, peakCumHi: 0, peakCumLo: 0,
            iz: Array(repeating: 0, count: sampleCount),
            cz: Array(repeating: 0, count: sampleCount),
            variance: sampleCount == 0 ? [] : [1] + Array(repeating: 0, count: sampleCount - 1),
            failure: failure
        )
    }

    @MainActor
    private static func testFaultExportAndWaiters(in directory: URL) async throws {
        let shutdown = ApplicationShutdownCoordinator()
        let engine = RandomTestEngine()
        let plot = directory.appendingPathComponent("fault.png").path
        let audit = directory.appendingPathComponent("fault.txt").path
        let exporter = GatedExporter([SessionExportResult(plotPath: plot, auditPath: audit)])
        defer { exporter.releaseAll() }
        let controller = SessionController(engine: engine, settings: settings(directory: directory),
                                           exporter: exporter, shutdown: shutdown)
        let sealed = snapshot(directory: directory, failure: "Simulated cable disconnect")
        engine.onSessionFinished?(sealed)
        try await waitUntil("automatic fault export") { exporter.requests.count == 1 }
        try require(controller.isSaving, "Fault did not automatically enter the saving lifecycle")
        try require(exporter.requests[0].snapshot.failure == sealed.failure,
                    "The exporter did not receive the original collection failure")
        var replies: [Bool] = []
        controller.stopAndSave { replies.append($0) }
        controller.stopAndSave { replies.append($0) }
        engine.onSessionFinished?(sealed) // Replaying the same completion must not duplicate files.
        try require(replies.isEmpty && exporter.requests.count == 1,
                    "Repeated Stop or a duplicate completion started another export")
        exporter.release(0)
        try await waitUntil("fault save completion") { replies.count == 2 }
        try require(replies == [true, true] && controller.auditComplete && !controller.isSaving,
                    "A collection fault incorrectly blocked saving accepted samples")
        try require(controller.lastAuditPath == audit && engine.connectionError == sealed.failure,
                    "Saved path or persistent collection-failure annotation was lost")
        try require(exporter.alwaysBackground, "Export work ran on the main thread")
        print("PASS: automatic fault export, failure annotation, duplicate stop waiters, completion deduplication")
    }

    @MainActor
    private static func testPartialRetryAndStart(in directory: URL) async throws {
        let shutdown = ApplicationShutdownCoordinator()
        let engine = RandomTestEngine()
        let selected = directory.appendingPathComponent("next-session-folder", isDirectory: true)
        let config = settings(directory: selected)
        let plot = directory.appendingPathComponent("already-saved.png").path
        let audit = directory.appendingPathComponent("retried-audit.txt").path
        let exporter = GatedExporter([
            SessionExportResult(plotPath: plot, auditPath: nil, errors: ["Simulated audit write failure"]),
            SessionExportResult(plotPath: plot, auditPath: audit)
        ])
        defer { exporter.releaseAll() }
        let controller = SessionController(engine: engine, settings: config, exporter: exporter, shutdown: shutdown)
        engine.exportDirectory = "/unchanged-until-retry-completes"
        engine.onSessionFinished?(snapshot(directory: directory, fileID: "partial", failure: "Acquisition interrupted"))
        try await waitUntil("partial first export") { exporter.requests.count == 1 }
        exporter.release(0)
        try await waitUntil("partial export failure") { !controller.isSaving }
        try require(!controller.auditComplete && engine.connectionError?.contains("Simulated audit write failure") == true,
                    "Partial output failure was reported as successful")
        controller.start()
        try await waitUntil("start retries pending export") { exporter.requests.count == 2 }
        try require(engine.exportDirectory == "/unchanged-until-retry-completes",
                    "Start changed session configuration before pending output was saved")
        let retry = exporter.requests[1]
        try require(retry.savedPlotPath == plot && retry.savedAuditPath == nil,
                    "Retry did not preserve the successfully exported plot")
        try require(retry.snapshot.id == exporter.requests[0].snapshot.id && retry.snapshot.directory == directory.path,
                    "Retry changed the sealed session identity or original directory")
        exporter.sendProgress(1, "Current retry progress")
        await mainQueueBarrier()
        exporter.sendProgress(0, "Stale attempt progress")
        await mainQueueBarrier()
        try require(controller.auditStatus == "Current retry progress",
                    "Late progress from a failed attempt overwrote its retry's progress")
        exporter.release(1)
        try await waitUntil("start follows successful retry") {
            !controller.isSaving && engine.exportDirectory == selected.path
        }
        try require(exporter.requests.count == 2, "Retry produced duplicate export work")
        print("PASS: partial outputs survive retries; Start waits for the pending session before proceeding")
    }

    @MainActor
    private static func testQuitWaitsForEveryWindow(in directory: URL) async throws {
        let shutdown = ApplicationShutdownCoordinator()
        let firstEngine = RandomTestEngine()
        let secondEngine = RandomTestEngine()
        let firstExporter = GatedExporter([
            SessionExportResult(plotPath: nil, auditPath: nil, errors: ["First window disk failure"]),
            SessionExportResult(plotPath: "/first.png", auditPath: "/first.txt")
        ])
        let secondExporter = GatedExporter([SessionExportResult(plotPath: "/second.png", auditPath: "/second.txt")])
        defer { firstExporter.releaseAll(); secondExporter.releaseAll() }
        let first = SessionController(engine: firstEngine, settings: settings(directory: directory),
                                      exporter: firstExporter, shutdown: shutdown)
        let second = SessionController(engine: secondEngine, settings: settings(directory: directory),
                                       exporter: secondExporter, shutdown: shutdown)
        firstEngine.onSessionFinished?(snapshot(directory: directory, fileID: "first-window"))
        secondEngine.onSessionFinished?(snapshot(directory: directory, fileID: "second-window"))
        try await waitUntil("two window exports") { firstExporter.requests.count == 1 && secondExporter.requests.count == 1 }
        var replies: [Bool] = []
        var duplicateReplies = 0
        shutdown.requestTermination { replies.append($0) }
        shutdown.requestTermination { _ in duplicateReplies += 1 }
        try require(replies.isEmpty, "Quit reply was delivered before terminateLater could return")
        try await waitUntil("both windows enter shutdown") { first.isShuttingDown && second.isShuttingDown }
        firstExporter.release(0)
        try await waitUntil("first window failure") { !first.isSaving }
        try require(replies.isEmpty && shutdown.isTerminating && second.isSaving,
                    "A failed window replied to Quit before the other window finished")

        // This window is no longer exporting, so these checks exercise shutdown guards.
        firstEngine.exportDirectory = "/shutdown-must-not-start"
        firstEngine.portPath = ""
        let savedError = firstEngine.connectionError
        first.start()
        first.connect()
        try require(firstEngine.exportDirectory == "/shutdown-must-not-start" && firstEngine.connectionError == savedError,
                    "Start or Connect was allowed during an unresolved application Quit")
        secondExporter.release(0)
        try await waitUntil("cancelled application Quit") { replies.count == 1 }
        try require(replies == [false] && duplicateReplies == 0 && !shutdown.isTerminating,
                    "Failed Quit did not produce exactly one cancellation reply")
        try require(!first.isShuttingDown && !second.isShuttingDown,
                    "Cancelled Quit left a window permanently blocked")

        shutdown.requestTermination { replies.append($0) }
        shutdown.requestTermination { _ in duplicateReplies += 1 }
        try await waitUntil("failed window retries on Quit") { firstExporter.requests.count == 2 }
        try await waitUntil("already saved window finishes first") { !secondEngine.isBusy && second.isShuttingDown }
        try require(replies.count == 1 && first.isSaving,
                    "Second Quit did not wait for the retried window")
        try require(secondExporter.requests.count == 1,
                    "Second Quit exported a successful window's session again")
        firstExporter.release(1)
        try await waitUntil("successful retried Quit") { replies.count == 2 }
        try require(replies == [false, true] && duplicateReplies == 0 && !firstEngine.isBusy && !secondEngine.isBusy,
                    "Retried Quit did not wait for both disconnections and reply exactly once")
        print("PASS: multiwindow Quit waits for all outcomes, cancels on failure, blocks actions, and retries only missing work")
    }

    @MainActor
    private static func testEmptyQuitIsAsynchronous() async throws {
        let shutdown = ApplicationShutdownCoordinator()
        var replies: [Bool] = []
        var returnedFromRequest = false
        shutdown.requestTermination {
            precondition(returnedFromRequest, "Empty Quit replied synchronously")
            replies.append($0)
        }
        shutdown.requestTermination { _ in preconditionFailure("Duplicate Quit reply") }
        returnedFromRequest = true
        try require(replies.isEmpty, "Empty Quit must wait for terminateLater")
        try await waitUntil("empty Quit") { replies.count == 1 }
        try require(replies == [true], "Empty Quit did not approve termination")
        print("PASS: empty and duplicate Quit requests obey asynchronous reply ordering")
    }

    @MainActor
    private static func testRegistrationAndDetachDuringQuit() async throws {
        let shutdown = ApplicationShutdownCoordinator()
        let remaining = ShutdownSpy()
        shutdown.register(remaining)
        var replies: [Bool] = []
        shutdown.requestTermination { replies.append($0) }
        // Register before the queued initial batch starts: preparation must still occur once.
        var detached: ShutdownSpy? = ShutdownSpy()
        weak let weakDetached = detached
        shutdown.register(detached!)
        try await waitUntil("registration during pending Quit batch") {
            remaining.prepareCount == 1 && detached?.prepareCount == 1
        }
        await mainQueueBarrier()
        try require(detached?.prepareCount == 1, "Registration and the initial Quit batch prepared one window twice")
        shutdown.unregister(detached!)
        detached!.finish(true)
        detached = nil
        try require(weakDetached != nil, "Quit released a participant before the batch settled")
        remaining.finish(false)
        try await waitUntil("cancelled Quit releases detached window") { replies.count == 1 }
        try require(replies == [false] && weakDetached == nil && remaining.resumeCount == 1,
                    "Cancelled Quit retained a successfully detached window or did not resume the remaining window")
        shutdown.requestTermination { replies.append($0) }
        try await waitUntil("remaining window retries Quit") { remaining.prepareCount == 2 }
        remaining.finish(true)
        try await waitUntil("remaining window completes Quit") { replies.count == 2 }
        try require(replies == [false, true], "Detached window interfered with subsequent Quit")
        print("PASS: registration before the Quit batch is prepared once; detached windows are released after cancellation")
    }

    @MainActor
    private static func mainQueueBarrier() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    private static func testRealExporter(in directory: URL) async throws {
        let raw = directory.appendingPathComponent("rng_raw_real-interrupted.txt")
        // Deliberately append an unaccepted tail. The audit must use only sealed totalBits.
        let accepted = Data((0..<128).map { $0.isMultiple(of: 2) ? UInt8(0x30) : UInt8(0x31) })
        try (accepted + Data(repeating: 0x31, count: 32)).write(to: raw)
        let sealed = snapshot(directory: directory, fileID: "real-interrupted", rawPath: raw.path,
                              failure: "Simulated disconnect after two complete samples")
        let request = SessionExportRequest(snapshot: sealed, savePlot: true, saveAudit: true, locale: Locale(identifier: "en"))
        let result = await Task.detached { SessionExporter().export(request) { _ in } }.value
        try require(result.succeeded, "Production exporter failed: " + result.errors.joined(separator: "; "))
        let plot = directory.appendingPathComponent("rng_session_real-interrupted.png")
        let report = directory.appendingPathComponent("rng_audit_real-interrupted.txt")
        try require(result.plotPath == plot.path && result.auditPath == report.path,
                    "Production output paths do not share the sealed directory/session ID")
        let plotBytes = try Data(contentsOf: plot)
        try require(Array(plotBytes.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10], "Production export was not a PNG")
        let reportBytes = try Data(contentsOf: report)
        let text = String(decoding: reportBytes, as: UTF8.self)
        try require(text.contains("Session status: INTERRUPTED") && text.contains(sealed.failure!) && text.contains("Samples:        2"),
                    "Fault report omitted the interruption or accepted-sample count")
        try require(text.contains("Raw bits read:  128"), "Audit included the unaccepted raw-data tail")

        let collision = await Task.detached { SessionExporter().export(request) { _ in } }.value
        try require(!collision.succeeded && !collision.errors.isEmpty,
                    "An output collision was falsely reported as a new successful export")
        try require(try Data(contentsOf: plot) == plotBytes && Data(contentsOf: report) == reportBytes,
                    "A collision changed the existing output bytes")

        var retry = request
        retry.savedPlotPath = result.plotPath
        retry.savedAuditPath = result.auditPath
        let retryResult = await Task.detached { SessionExporter().export(retry) { _ in } }.value
        try require(retryResult.succeeded, "Production retry rewrote already successful files")
        try require(try Data(contentsOf: plot) == plotBytes && Data(contentsOf: report) == reportBytes,
                    "Production retry changed successful output bytes")

        let missingRaw = snapshot(directory: directory, fileID: "raw-unavailable",
                                  rawPath: directory.appendingPathComponent("missing-raw.txt").path,
                                  failure: "Input became unavailable")
        let missingRequest = SessionExportRequest(snapshot: missingRaw, savePlot: false, saveAudit: true, locale: nil)
        let fallback = await Task.detached { SessionExporter().export(missingRequest) { _ in } }.value
        try require(fallback.succeeded && fallback.auditPath != nil, "Missing raw data discarded the usable fault summary")
        let fallbackText = try String(contentsOfFile: fallback.auditPath!, encoding: .utf8)
        try require(fallbackText.contains("Raw data unavailable:") && fallbackText.contains("Session status: INTERRUPTED"),
                    "Raw-input failure was not disclosed in the summary report")

        let shortRaw = directory.appendingPathComponent("short-raw.txt")
        try accepted.prefix(64).write(to: shortRaw)
        let shortSnapshot = snapshot(directory: directory, fileID: "raw-truncated", rawPath: shortRaw.path,
                                     failure: "Raw file truncated after acquisition")
        let shortRequest = SessionExportRequest(snapshot: shortSnapshot, savePlot: false, saveAudit: true, locale: nil)
        let shortResult = await Task.detached { SessionExporter().export(shortRequest) { _ in } }.value
        try require(shortResult.succeeded && shortResult.auditPath != nil, "A short raw file prevented the summary report")
        let shortText = try String(contentsOfFile: shortResult.auditPath!, encoding: .utf8)
        try require(shortText.contains("Raw data unavailable:") && shortText.contains("Raw-bit tests were not performed"),
                    "A short raw file was silently analysed as a complete session")

        let zeroRaw = directory.appendingPathComponent("zero-raw.txt")
        try Data().write(to: zeroRaw)
        let zeroSnapshot = snapshot(directory: directory, fileID: "zero-samples", rawPath: zeroRaw.path,
                                    sampleCount: 0, totalBits: 0, failure: "Interrupted before the first complete sample")
        let zeroRequest = SessionExportRequest(snapshot: zeroSnapshot, savePlot: true, saveAudit: true, locale: nil)
        let zeroResult = await Task.detached { SessionExporter().export(zeroRequest) { _ in } }.value
        try require(zeroResult.succeeded && zeroResult.plotPath == nil && zeroResult.auditPath != nil,
                    "An established zero-sample session must save its interruption report without creating a plot")
        let zeroText = try String(contentsOfFile: zeroResult.auditPath!, encoding: .utf8)
        try require(zeroText.contains("Not run (no collected samples)") && zeroText.contains(zeroSnapshot.failure!),
                    "Zero-sample report presented initialization values as measurements")

        let empty = snapshot(directory: directory, fileID: nil, sampleCount: 0, totalBits: 0,
                             failure: "Output directory could not be opened")
        let emptyRequest = SessionExportRequest(snapshot: empty, savePlot: true, saveAudit: true, locale: nil)
        let emptyResult = await Task.detached { SessionExporter().export(emptyRequest) { _ in } }.value
        try require(emptyResult.succeeded && emptyResult.plotPath == nil && emptyResult.auditPath == nil,
                    "A session without output files fabricated an export path")
        print("PASS: real interrupted PNG/report, accepted raw prefix, retained output paths, retry byte preservation, raw-input fallback")
    }

    @MainActor
    private static func waitUntil(_ label: String, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !condition() {
            try require(ProcessInfo.processInfo.systemUptime < deadline, "Timed out: " + label)
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw LifecycleTestFailure.failed(message) }
    }
}
