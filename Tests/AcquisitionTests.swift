// Run independently from the repository root:
// swiftc -swift-version 5 -default-isolation MainActor \
//   Qcicada/Models/SerialPort.swift Qcicada/Models/QCCProtocol.swift \
//   Qcicada/Models/RandomTestEngine.swift Tests/AcquisitionTests.swift \
//   -o /tmp/qcicada-acquisition-tests
// /tmp/qcicada-acquisition-tests

import Foundation

nonisolated private final class AcquisitionTransport: SerialTransport, @unchecked Sendable {
    struct ReadStep {
        let data: Data
        var gated = false
    }
    struct Stream {
        let steps: [ReadStep]
        var failWhenExhausted = false
        var rejectStop = false
    }

    private let lock = NSLock()
    private let readGate = DispatchSemaphore(value: 0)
    private var streams: [Stream]
    private var steps: [ReadStep] = []
    private var response = Data()
    private var streaming = false
    private var failWhenExhausted = false
    private var rejectStop = false
    private var error: (any Error)?
    private var blocked = false
    private var activeOperations = 0
    private var maximumOperations = 0
    private var starts = 0
    private var closes = 0

    init(streams: [Stream]) { self.streams = streams }
    var lastError: (any Error)? { lock.withLock { error } }
    var isReadBlocked: Bool { lock.withLock { blocked } }
    var startCount: Int { lock.withLock { starts } }
    var closeCount: Int { lock.withLock { closes } }
    var maxConcurrentOperations: Int { lock.withLock { maximumOperations } }
    func releaseRead() { readGate.signal() }

    private func operation<T>(_ body: () throws -> T) rethrows -> T {
        lock.withLock {
            activeOperations += 1
            maximumOperations = max(maximumOperations, activeOperations)
        }
        defer { lock.withLock { activeOperations -= 1 } }
        return try body()
    }

    func write(_ data: Data) throws {
        operation {
            lock.withLock {
                switch data.first {
                case QCCDevice.CMD_STOP:
                    let rejected = streaming && rejectStop
                    streaming = false
                    rejectStop = false
                    response = rejected ? Data([QCCDevice.RESP_NACK]) : Data([QCCDevice.RESP_ACK, 0, 0, 0, 0, 0])
                case QCCDevice.CMD_GET_STATUS:
                    response = Data([QCCDevice.RESP_ACK, 0, 0x34, 0x12, 0, 0])
                case QCCDevice.CMD_INFO:
                    response = Data([QCCDevice.RESP_INFO])
                    response.append(Data(repeating: 0, count: 8))
                    response.append(Data("SIM-DEVICE".utf8))
                    response.append(Data(repeating: 0, count: 48 - "SIM-DEVICE".utf8.count))
                case QCCDevice.CMD_START:
                    starts += 1
                    let stream = streams.isEmpty ? Stream(steps: []) : streams.removeFirst()
                    steps = stream.steps
                    failWhenExhausted = stream.failWhenExhausted
                    rejectStop = stream.rejectStop
                    streaming = true
                    response = Data([QCCDevice.RESP_ACK, 1, 0, 0, 0, 0])
                default:
                    response = Data([QCCDevice.RESP_NACK])
                }
            }
        }
    }

    func read(count: Int, timeout: Double) -> Data {
        operation {
            let step: ReadStep = lock.withLock {
                error = nil
                if !response.isEmpty {
                    let data = Data(response.prefix(count))
                    response.removeFirst(data.count)
                    return ReadStep(data: data)
                }
                guard streaming else { return ReadStep(data: Data()) }
                if steps.isEmpty {
                    if failWhenExhausted {
                        error = SerialError.readFailed(errno: EIO)
                        return ReadStep(data: Data())
                    }
                    blocked = true
                    return ReadStep(data: Data(), gated: true)
                }
                let next = steps.removeFirst()
                if next.data.count > count {
                    steps.insert(ReadStep(data: Data(next.data.dropFirst(count))), at: 0)
                }
                if next.gated { blocked = true }
                return ReadStep(data: Data(next.data.prefix(count)), gated: next.gated)
            }
            if step.gated {
                readGate.wait()
                lock.withLock { blocked = false }
            }
            return step.data
        }
    }

    func setTimeout(seconds: Double) -> Bool { operation { true } }
    func flush() { operation { lock.withLock { response.removeAll() } } }
    func flushInput() { operation { lock.withLock { response.removeAll() } } }
    func close() {
        operation {
            lock.withLock {
                closes += 1
                streaming = false
            }
        }
    }
}

private struct SessionSnapshot {
    let n: Int
    let bits: Int
    let ones: Int
    let iz: [Double]
    let cz: [Double]
    let variance: [Double]
    let historyCount: Int
    let rawPath: String?
    let csvPath: String?
    let directory: String?

    @MainActor init(_ engine: RandomTestEngine) {
        n = engine.sampleCount; bits = engine.totalBits; ones = engine.totalOnes
        iz = engine.izFull; cz = engine.czFull; variance = engine.varFull
        historyCount = engine.izHistory.count
        rawPath = engine.currentRawFilePath; csvPath = engine.currentCsvFilePath
        directory = engine.sessionDirectory
    }
}

private enum AcquisitionTestFailure: Error { case failed(String) }

@main
struct AcquisitionTests {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qcicada-acquisition-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFolder = root.appendingPathComponent("first")
        let secondFolder = root.appendingPathComponent("second")
        let collisionFolder = root.appendingPathComponent("collisions")
        for folder in [firstFolder, secondFolder, collisionFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let firstSamples = [Data([0, 255, 85, 170]), Data([15, 240, 51, 204]), Data([255, 255, 0, 255])]
        let transport = AcquisitionTransport(streams: [
            .init(steps: [
                .init(data: firstSamples[0]),
                .init(data: Data(firstSamples[1].prefix(2))),
                .init(data: Data()), // A timeout between the two halves must not lose bytes.
                .init(data: Data(firstSamples[1].suffix(2))),
                .init(data: firstSamples[2], gated: true),
            ]),
            .init(steps: [.init(data: Data([255, 255, 255, 255]))]),
            .init(steps: [.init(data: Data([90, 165, 240, 15])), .init(data: Data([12, 34]))], failWhenExhausted: true),
            .init(steps: [.init(data: Data([1, 2, 3, 4]))]),
        ])
        defer { transport.releaseRead() }
        let engine = RandomTestEngine(makeDevice: { _ in QCCDevice(serial: transport) })
        var sealed: [CompletedSessionSnapshot] = []
        engine.onSessionFinished = { sealed.append($0) }
        engine.portPath = "simulated-port"
        engine.chunkSize = 4
        engine.historySize = 2
        engine.exportDirectory = firstFolder.path
        engine.connect()
        try await waitUntil("connection") { engine.isConnected && !engine.isBusy }
        try require(engine.deviceSerial == "SIM-DEVICE" && engine.readyBytes == 0x1234, "Connection metadata")

        engine.start()
        engine.start() // The second start must not enqueue another session or reset the first.
        engine.exportDirectory = secondFolder.path
        try await waitUntil("blocked final sample") { engine.sampleCount == 2 && transport.isReadBlocked }
        try require(transport.startCount == 1, "Repeated start entered twice")
        try require(engine.sessionDirectory == firstFolder.path, "Running session changed its output directory")

        var firstSnapshot: SessionSnapshot?
        var completionCount = 0
        var restartClearedRawPath = false
        engine.stop {
            precondition(sealed.count == 1 && sealed[0].sampleCount == 3,
                         "Session notification must precede the stop completion and include the final sample")
            firstSnapshot = SessionSnapshot(engine)
            completionCount += 1
            engine.saveRaw = false
            engine.start() // Restart in the completion itself to catch stale queued publications.
            restartClearedRawPath = engine.currentRawFilePath == nil
        }
        try require(completionCount == 0 && engine.isRunning, "Stop completed before the blocked read finished")
        transport.releaseRead()
        try await waitUntil("second session") { completionCount == 1 && engine.sampleCount == 1 && transport.isReadBlocked }
        try require(restartClearedRawPath, "Restart retained the old raw path")
        try require(transport.startCount == 2, "Immediate restart did not start exactly once")
        try require(engine.currentRawFilePath == nil, "saveRaw=false retained a raw file path")

        var secondSnapshot: SessionSnapshot?
        engine.stop { secondSnapshot = SessionSnapshot(engine) }
        transport.releaseRead()
        try await waitUntil("second stop") { !engine.isRunning && secondSnapshot != nil }
        try verify(firstSnapshot!, samples: firstSamples, folder: firstFolder, expectRaw: true)
        try require(firstSnapshot!.historyCount == 2, "Sliding history limit was not preserved")
        try verify(secondSnapshot!, samples: [Data([255, 255, 255, 255])], folder: secondFolder, expectRaw: false)
        for _ in 0..<10 { await Task.yield() }
        try require(engine.sampleCount == 1 && engine.totalBits == 32 && engine.totalOnes == 32, "Stale sample arrived after stop")
        try require(engine.izFull.count == 1, "Previous session polluted the next full history")
        try require(sealed.count == 2 && sealed[0].id != sealed[1].id, "Sessions were not sealed exactly once with unique IDs")
        try require(sealed[0].sampleCount == 3 && sealed[0].iz.count == 3 && sealed[0].failure == nil,
                    "Starting another session changed the sealed first session")
        try require(sealed[0].directory == firstFolder.path && sealed[0].chunkSize == 4 && sealed[0].port == "simulated-port",
                    "Sealed session lost its original configuration")
        try require(sealed[1].rawFilePath == nil && sealed[1].sampleCount == 1, "Sealed no-raw session paths or count")

        engine.saveRaw = true
        engine.start()
        try await waitUntil("transport failure") { !engine.isRunning && engine.connectionError != nil }
        try require(engine.sampleCount == 1 && engine.totalBits == 32, "Incomplete failing sample was published")
        try require(try Data(contentsOf: URL(fileURLWithPath: engine.currentRawFilePath!)) == SessionOutput.rawText(Data([90, 165, 240, 15])),
                    "Fault sealing changed accepted raw data or included the partial sample")
        try require(try csvRows(engine.currentCsvFilePath!).count == 1, "Fault sealing CSV count")
        try require(sealed.count == 3 && sealed[2].sampleCount == 1 && sealed[2].failure != nil,
                    "A fault did not notify the completed-sample snapshot exactly once")
        let faultSnapshot = sealed[2]
        try require(!engine.isConnected && transport.closeCount == 1, "Transport failure did not close the broken connection")
        engine.connect()
        try await waitUntil("reconnection") { engine.isConnected && !engine.isBusy }
        try require(engine.connectionError == nil && faultSnapshot.failure != nil,
                    "Reconnection erased the sealed failure annotation")

        let invalidFolder = root.appendingPathComponent("a-file")
        try Data("not a directory".utf8).write(to: invalidFolder)
        engine.exportDirectory = invalidFolder.path
        engine.start()
        try await waitUntil("invalid output folder") { !engine.isRunning && engine.connectionError != nil }
        try require(engine.currentRawFilePath == nil && engine.currentCsvFilePath == nil, "Invalid folder advertised output files")
        try require(transport.startCount == 3, "Invalid output folder started the device")
        try require(sealed.count == 4 && sealed[3].sampleCount == 0 && sealed[3].fileID == nil && sealed[3].failure != nil,
                    "Failure before file creation did not produce a zero-sample notification")

        engine.exportDirectory = secondFolder.path
        engine.start()
        try await waitUntil("disconnect during read") { engine.sampleCount == 1 && transport.isReadBlocked }
        var disconnected = false
        engine.disconnect { disconnected = true }
        try require(!disconnected && transport.closeCount == 1, "Device closed while its read was active")
        transport.releaseRead()
        try await waitUntil("disconnect completion") { disconnected }
        try require(!engine.isConnected && !engine.isRunning && !engine.isBusy, "Disconnect state did not settle")
        try require(transport.closeCount == 2 && transport.maxConcurrentOperations == 1, "Serial operations overlapped or close count was wrong")
        engine.releaseMemory()
        for _ in 0..<10 { await Task.yield() }
        try require(engine.sampleCount == 0 && engine.izFull.isEmpty && engine.currentRawFilePath == nil, "Released state was repopulated")

        try await testStopFailureAndEmptyCancellation(in: secondFolder)
        try testOutputCollisions(in: collisionFolder)
        try benchmarkRawEncoding()
        print("PASS: connection, repeated start, partial reads, stop during read, immediate restart, output consistency, fixed session directory, unplug error, invalid directory, serialized disconnect, collisions")
    }

    @MainActor
    private static func testStopFailureAndEmptyCancellation(in folder: URL) async throws {
        let transport = AcquisitionTransport(streams: [
            .init(steps: [.init(data: Data([1, 2, 3, 4]))], rejectStop: true)
        ])
        defer { transport.releaseRead() }
        let engine = RandomTestEngine(makeDevice: { _ in QCCDevice(serial: transport) })
        var snapshots: [CompletedSessionSnapshot] = []
        engine.onSessionFinished = { snapshots.append($0) }
        engine.portPath = "stop-failure-simulator"
        engine.chunkSize = 4
        engine.exportDirectory = folder.path
        engine.connect()
        try await waitUntil("stop-failure connection") { engine.isConnected && !engine.isBusy }
        engine.start()
        try await waitUntil("stop-failure blocked read") { engine.sampleCount == 1 && transport.isReadBlocked }
        var completions = 0
        engine.stop { completions += 1 }
        engine.stop { completions += 1 }
        transport.releaseRead()
        try await waitUntil("stop-failure seal") { completions == 2 }
        try require(snapshots.count == 1 && snapshots[0].sampleCount == 1,
                    "Duplicate stops duplicated the seal or dropped completed data")
        try require(snapshots[0].failure?.contains("stop command") == true && !engine.isConnected,
                    "Rejected STOP did not mark the sealed session incomplete and close the device")
        try require(try csvRows(snapshots[0].csvFilePath!).count == 1,
                    "Rejected STOP prevented accepted output from closing")

        engine.connect()
        try await waitUntil("empty-cancel connection") { engine.isConnected && !engine.isBusy }
        engine.start()
        engine.stop { completions += 1 }
        try await waitUntil("empty-cancel seal") { completions == 3 }
        try require(snapshots.count == 2 && snapshots[1].sampleCount == 0 && snapshots[1].failure == nil,
                    "Immediate cancellation must emit one normal empty-session notification")
        try require(snapshots[1].id != snapshots[0].id && snapshots[1].iz.isEmpty,
                    "Immediate cancellation reused another session's identity/data")
        var disconnected = false
        engine.disconnect { disconnected = true }
        try await waitUntil("empty-cancel disconnect") { disconnected }
        print("PASS: fault snapshots preserve complete samples and failures, STOP rejection seals files, immediate cancellation notifies once")
    }

    @MainActor
    private static func waitUntil(_ label: String, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !condition() {
            try require(ProcessInfo.processInfo.systemUptime < deadline, "Timed out waiting for " + label)
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw AcquisitionTestFailure.failed(message) }
    }

    private static func csvRows(_ path: String) throws -> [[String]] {
        try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").dropFirst().map { $0.split(separator: ",").map(String.init) }
    }

    private static func verify(_ snapshot: SessionSnapshot, samples: [Data], folder: URL, expectRaw: Bool) throws {
        let input = samples.reduce(into: Data()) { $0.append($1) }
        try require(snapshot.n == samples.count && snapshot.bits == input.count * 8, "Sample count/bit count mismatch")
        try require(snapshot.ones == input.reduce(0) { $0 + $1.nonzeroBitCount }, "Ones count mismatch")
        try require(snapshot.iz.count == samples.count && snapshot.cz.count == samples.count && snapshot.variance.count == samples.count, "Full history mismatch")
        try require(snapshot.directory == folder.path, "Session directory mismatch")
        try require(URL(fileURLWithPath: snapshot.csvPath!).deletingLastPathComponent().path == folder.path, "CSV moved to a new folder")
        if expectRaw {
            try require(try Data(contentsOf: URL(fileURLWithPath: snapshot.rawPath!)) == SessionOutput.rawText(input), "Raw output differs from accepted samples")
        } else {
            try require(snapshot.rawPath == nil, "Unexpected raw file")
        }
        let rows = try csvRows(snapshot.csvPath!)
        try require(rows.count == samples.count, "CSV row count mismatch")
        var totalOnes = 0
        var totalBits = 0
        for (index, row) in rows.enumerated() {
            let ones = samples[index].reduce(0) { $0 + $1.nonzeroBitCount }
            let bits = samples[index].count * 8
            totalOnes += ones; totalBits += bits
            try require(row.count == 8, "CSV column count")
            try require(Int(row[0]) == index + 1 && Int(row[4]) == ones && Int(row[5]) == bits, "CSV sample data mismatch")
            try require(Int(row[6]) == totalOnes && Int(row[7]) == totalBits, "CSV cumulative totals mismatch")
            try require(abs(Double(row[1])! - snapshot.iz[index]) < 0.000001, "CSV instant Z mismatch")
            try require(abs(Double(row[2])! - snapshot.cz[index]) < 0.000001, "CSV cumulative Z mismatch")
            try require(abs(Double(row[3])! - snapshot.variance[index]) < 0.000001, "CSV variance mismatch")
        }
    }

    private static func testOutputCollisions(in folder: URL) throws {
        var ids = Set<String>()
        var recorded: [(String, Data)] = []
        var usedCollisionSuffix = false
        for index in 0..<8 {
            let output = try SessionOutput(directory: folder.path, saveRaw: true)
            try require(ids.insert(output.id).inserted, "Duplicate session ID")
            usedCollisionSuffix = usedCollisionSuffix || output.id.split(separator: "_").count > 2
            try output.write(data: Data([UInt8(index)]), n: 1, iz: 0, cz: 0, variance: 1,
                             ones: UInt8(index).nonzeroBitCount, bits: 8,
                             totalOnes: UInt8(index).nonzeroBitCount, totalBits: 8)
            try output.finish()
            recorded.append((output.rawPath!, try Data(contentsOf: URL(fileURLWithPath: output.rawPath!))))
            recorded.append((output.csvPath, try Data(contentsOf: URL(fileURLWithPath: output.csvPath))))
        }
        try require(usedCollisionSuffix, "Collision scenario was not exercised")
        for (path, expected) in recorded {
            try require(try Data(contentsOf: URL(fileURLWithPath: path)) == expected, "A later session overwrote an existing output")
        }
    }

    private static func benchmarkRawEncoding() throws {
        func original(_ data: Data) -> Data {
            var text = ""
            text.reserveCapacity(data.count * 8)
            for byte in data {
                for bit in (0..<8).reversed() {
                    text.append((byte >> bit) & 1 == 1 ? "1" : "0")
                }
            }
            return text.data(using: .ascii)!
        }
        let allBytes = Data((0...255).map(UInt8.init))
        try require(SessionOutput.rawText(allBytes) == original(allBytes), "Raw encoder changed bit order/content")
        try require(SessionOutput.rawText(Data()).isEmpty, "Empty raw encoding")
        let slicedBytes = allBytes[17..<241]
        try require(slicedBytes.startIndex != 0, "Nonzero-index Data slice fixture was lost")
        try require(SessionOutput.rawText(slicedBytes) == original(slicedBytes), "Raw encoder changed a Data slice")
        try require(SessionOutput.rawText(allBytes[17..<17]).isEmpty, "Empty Data slice encoding")
        for length in 1...25 {
            let slice = allBytes[11..<(11 + length)]
            try require(SessionOutput.rawText(slice) == original(slice), "Raw encoder changed short input of length \(length)")
        }
        let input = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0) })
        let expected = original(input)
        for (label, encode) in [("character append", original), ("buffer lookup", SessionOutput.rawText)] {
            let started = ProcessInfo.processInfo.systemUptime
            for _ in 0..<100 {
                try require(encode(input) == expected, "Benchmark byte mismatch")
            }
            print(String(format: "Raw encoding %@, 100 x 8192 bytes: %.4f s", label, ProcessInfo.processInfo.systemUptime - started))
        }
    }
}
