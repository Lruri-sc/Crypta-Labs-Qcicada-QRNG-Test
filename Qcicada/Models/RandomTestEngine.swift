// RandomTestEngine.swift
// Qcicada
//
// Data acquisition engine with real-time 随机数测试 statistics.
// Runs collection on a background thread, publishes to SwiftUI via @Observable.

import Foundation
import Observation

/// A sealed session. Values and file locations cannot change when another session starts.
nonisolated struct CompletedSessionSnapshot: Sendable, Identifiable {
    let id: UUID
    let fileID: String?
    let directory: String
    let port: String
    let direction: Int
    let chunkSize: Int
    let rawFilePath: String?
    let csvFilePath: String?
    let sampleCount: Int
    let totalBits: Int
    let totalOnes: Int
    let cumulativeZ: Double
    let instantZ: Double
    let izMean: Double
    let izVariance: Double
    let peakInstHi: Double
    let peakInstLo: Double
    let peakCumHi: Double
    let peakCumLo: Double
    let iz: [Double]
    let cz: [Double]
    let variance: [Double]
    let failure: String?
}

@MainActor
@Observable
final class RandomTestEngine {
    
    /// Synced from the UI so `connectionError` matches the chosen app language (including explicit English).
    static var uiLocale: Locale? = nil
    
    // MARK: - Configuration
    var portPath: String = ""
    var chunkSize: Int = 8192
    var direction: Int = 1  // 1 = more 1s, 0 = more 0s
    var historySize: Int = 600
    var saveRaw: Bool = true
    
    // MARK: - State
    var isConnected = false
    var isRunning = false
    var connectionError: String?
    var deviceSerial: String = "—"
    var readyBytes: UInt32 = 0
    
    // MARK: - Realtime Stats
    var sampleCount: Int = 0
    var totalBits: Int = 0
    var totalOnes: Int = 0
    var cumulativeZ: Double = 0
    var instantZ: Double = 0
    var peakInstHi: Double = -999
    var peakInstLo: Double = 999
    var peakCumHi: Double = -999
    var peakCumLo: Double = 999
    var izMean: Double = 0
    var izVariance: Double = 1.0
    var varianceZScore: Double = 0
    
    // MARK: - Chart Data
    var izHistory: [Double] = []
    var czHistory: [Double] = []
    var varHistory: [Double] = []
    
    // MARK: - Full History (for export)
    var izFull: [Double] = []
    var czFull: [Double] = []
    var varFull: [Double] = []
    
    // MARK: - File Paths (public for audit/export)
    var currentRawFilePath: String?
    var currentCsvFilePath: String?
    private(set) var sessionID: String?
    private(set) var sessionDirectory: String?
    private(set) var sessionPort: String = ""
    private(set) var sessionDirection = 1
    private(set) var sessionChunkSize = 8192
    private(set) var isBusy = false
    private(set) var completedSession: CompletedSessionSnapshot?
    @ObservationIgnored var onSessionFinished: (@MainActor (CompletedSessionSnapshot) -> Void)?
    var exportDirectory: String = NSHomeDirectory() + "/Documents"
    
    // The queue owns all serial I/O. The main actor owns all observable state.
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "Qcicada.acquisition", qos: .userInitiated)
    @ObservationIgnored private var device: QCCDevice?
    @ObservationIgnored private let makeDevice: @Sendable (String) throws -> QCCDevice

    init(makeDevice: @escaping @Sendable (String) throws -> QCCDevice = { path in
        let serial = SerialPort(path: path)
        try serial.open()
        return QCCDevice(serial: serial)
    }) {
        self.makeDevice = makeDevice
    }
    @ObservationIgnored private var activeSession: AcquisitionSession?
    @ObservationIgnored private var stopCompletions: [() -> Void] = []

    func connect() {
        guard !isBusy, !isConnected, !isRunning else { return }
        connectionError = nil
        guard !portPath.isEmpty else {
            connectionError = String(localized: "error.no_port", locale: Self.uiLocale ?? .current)
            return
        }
        isBusy = true
        let path = portPath
        let locale = Self.uiLocale
        let makeDevice = makeDevice
        ioQueue.async { [weak self] in
            var openedDevice: QCCDevice?
            do {
                let device = try makeDevice(path)
                openedDevice = device
                _ = device.stop()
                Thread.sleep(forTimeInterval: 0.3)
                device.flushBuffers()
                Thread.sleep(forTimeInterval: 0.2)
                guard let status = device.getStatus() else {
                    throw AcquisitionError.message(String(localized: "error.device_not_responding", locale: locale ?? .current))
                }
                let serialNumber = device.getInfo()?.serial ?? "connected"
                device.flushBuffers()
                DispatchQueue.main.async {
                    guard let self else { device.closeComm(); return }
                    self.device = device
                    self.sessionPort = path
                    self.deviceSerial = serialNumber
                    self.readyBytes = status.readyBytes
                    self.isConnected = true
                    self.isBusy = false
                }
            } catch {
                openedDevice?.closeComm()
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self?.isBusy = false
                    self?.connectionError = message
                }
            }
        }
    }

    func disconnect(completion: (() -> Void)? = nil) {
        // A connection attempt is allowed to finish before its queued close.
        if isBusy && !isRunning {
            ioQueue.async { [weak self] in
                DispatchQueue.main.async { self?.disconnect(completion: completion) }
            }
            return
        }
        stop { [weak self] in
            guard let self else { completion?(); return }
            let device = self.device
            self.device = nil
            self.isConnected = false
            self.deviceSerial = "—"
            self.readyBytes = 0
            self.isBusy = true
            self.ioQueue.async {
                device?.closeComm()
                DispatchQueue.main.async {
                    self.isBusy = false
                    completion?()
                }
            }
        }
    }

    /// Drop buffers only after collection has finished publishing its last sample.
    func releaseMemory() {
        guard !isRunning, !isBusy else { return }
        resetStatistics()
        currentRawFilePath = nil
        currentCsvFilePath = nil
        sessionID = nil
        sessionDirectory = nil
        completedSession = nil
        connectionError = nil
        readyBytes = 0
    }

    private func resetStatistics() {
        izHistory = []; czHistory = []; varHistory = []
        izFull = []; czFull = []; varFull = []
        sampleCount = 0; totalBits = 0; totalOnes = 0
        cumulativeZ = 0; instantZ = 0
        peakInstHi = -999; peakInstLo = 999
        peakCumHi = -999; peakCumLo = 999
        izMean = 0; izVariance = 1; varianceZScore = 0
    }

    func start() {
        guard let device, isConnected, !isBusy, !isRunning else { return }
        guard chunkSize > 0, historySize > 0 else { return }
        resetStatistics()
        connectionError = nil
        currentRawFilePath = nil
        currentCsvFilePath = nil
        sessionID = nil
        completedSession = nil
        sessionDirectory = exportDirectory
        sessionDirection = direction
        sessionChunkSize = chunkSize
        let session = AcquisitionSession()
        activeSession = session
        isRunning = true
        let directory = exportDirectory
        let chunk = chunkSize
        let direction = direction
        let historyLimit = historySize
        let saveRaw = saveRaw
        let locale = Self.uiLocale
        ioQueue.async { [weak self] in
            var failure: String?
            var connectionLost = false
            do {
                try Self.collect(device: device, session: session, directory: directory,
                                 chunkSize: chunk, direction: direction, saveRaw: saveRaw, locale: locale,
                                 prepared: { id, rawPath, csvPath in
                    DispatchQueue.main.async {
                        guard let self, self.activeSession === session else { return }
                        self.sessionID = id
                        self.currentRawFilePath = rawPath
                        self.currentCsvFilePath = csvPath
                    }
                }, publish: { sample in
                    DispatchQueue.main.async {
                        guard let self, self.activeSession === session else { return }
                        self.publish(sample, historyLimit: historyLimit)
                    }
                })
            } catch {
                failure = error.localizedDescription
                connectionLost = error is SerialError || (error as? CollectionFailure)?.connectionLost == true
                if connectionLost { device.closeComm() }
            }
            let finalError = failure
            let disconnected = connectionLost
            // FIFO delivery puts all accepted samples before completion/audit.
            DispatchQueue.main.async {
                guard let self, self.activeSession === session else { return }
                self.activeSession = nil
                self.isRunning = false
                if disconnected {
                    self.device = nil
                    self.isConnected = false
                    self.deviceSerial = "—"
                    self.readyBytes = 0
                }
                if let finalError { self.connectionError = finalError }
                let snapshot = CompletedSessionSnapshot(
                    id: session.id, fileID: self.sessionID,
                    directory: directory, port: self.sessionPort,
                    direction: direction, chunkSize: chunk,
                    rawFilePath: self.currentRawFilePath, csvFilePath: self.currentCsvFilePath,
                    sampleCount: self.sampleCount, totalBits: self.totalBits, totalOnes: self.totalOnes,
                    cumulativeZ: self.cumulativeZ, instantZ: self.instantZ,
                    izMean: self.izMean, izVariance: self.izVariance,
                    peakInstHi: self.peakInstHi, peakInstLo: self.peakInstLo,
                    peakCumHi: self.peakCumHi, peakCumLo: self.peakCumLo,
                    iz: self.izFull, cz: self.czFull, variance: self.varFull,
                    failure: finalError
                )
                self.completedSession = snapshot
                let completions = self.stopCompletions
                self.stopCompletions.removeAll()
                self.onSessionFinished?(snapshot)
                completions.forEach { $0() }
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        guard let session = activeSession else { completion?(); return }
        if let completion { stopCompletions.append(completion) }
        session.cancel()
    }

    private func publish(_ sample: AcquisitionSample, historyLimit: Int) {
        sampleCount = sample.n; totalBits = sample.bits; totalOnes = sample.ones
        instantZ = sample.iz; cumulativeZ = sample.cz
        izMean = sample.mean; izVariance = sample.variance
        peakInstHi = max(peakInstHi, sample.iz); peakInstLo = min(peakInstLo, sample.iz)
        peakCumHi = max(peakCumHi, sample.cz); peakCumLo = min(peakCumLo, sample.cz)
        if sample.n > 30 {
            // The displayed variance uses M2/n; chi-square therefore uses n*variance.
            varianceZScore = sqrt(2 * Double(sample.n) * sample.variance) - sqrt(2 * Double(sample.n - 1) - 1)
        }
        izFull.append(sample.iz); czFull.append(sample.cz); varFull.append(sample.variance)
        izHistory.append(sample.iz); czHistory.append(sample.cz); varHistory.append(sample.variance)
        if izHistory.count > historyLimit { izHistory.removeFirst(izHistory.count - historyLimit) }
        if czHistory.count > historyLimit { czHistory.removeFirst(czHistory.count - historyLimit) }
        if varHistory.count > historyLimit { varHistory.removeFirst(varHistory.count - historyLimit) }
    }

    nonisolated private static func collect(
        device: QCCDevice, session: AcquisitionSession, directory: String,
        chunkSize: Int, direction: Int, saveRaw: Bool, locale: Locale?,
        prepared: (String, String?, String) -> Void,
        publish: (AcquisitionSample) -> Void
    ) throws {
        let output = try SessionOutput(directory: directory, saveRaw: saveRaw)
        defer { output.close() }
        prepared(output.id, output.rawPath, output.csvPath)
        var failures: [String] = []
        var connectionLost = false
        var shouldStopDevice = false
        do {
            if !session.isCancelled {
                device.flushBuffers()
                Thread.sleep(forTimeInterval: 0.2)
                if !session.isCancelled {
                    // A failed START reply can still mean that the device started streaming.
                    shouldStopDevice = true
                    guard device.startContinuous() else {
                        if let error = device.lastTransportError { throw error }
                        throw AcquisitionError.message(String(localized: "error.start_continuous_failed", locale: locale ?? .current))
                    }
                    var n = 0, totalBits = 0, totalOnes = 0
                    var mean = 0.0, m2 = 0.0
                    while !session.isCancelled {
                        guard let data = device.readContinuous(count: chunkSize) else {
                            if let error = device.lastTransportError { throw error }
                            continue
                        }
                        let ones = data.reduce(0) { $0 + $1.nonzeroBitCount }
                        let bits = data.count * 8
                        n += 1; totalBits += bits; totalOnes += ones
                        let iz = zScore(ones: ones, total: bits, direction: direction)
                        let cz = zScore(ones: totalOnes, total: totalBits, direction: direction)
                        let delta = iz - mean
                        mean += delta / Double(n)
                        m2 += delta * (iz - mean)
                        let variance = n > 1 ? m2 / Double(n) : 1.0
                        // Publish only after both writes succeed; all I/O stays on this queue.
                        try output.write(data: data, n: n, iz: iz, cz: cz, variance: variance,
                                         ones: ones, bits: bits, totalOnes: totalOnes, totalBits: totalBits)
                        publish(AcquisitionSample(n: n, bits: totalBits, ones: totalOnes,
                                                  iz: iz, cz: cz, mean: mean, variance: variance))
                    }
                }
            }
        } catch {
            failures.append(error.localizedDescription)
            connectionLost = error is SerialError
        }

        // Seal every file even after a transport/write error. The final callback must never
        // race an open output handle or omit a synchronization/close failure.
        if shouldStopDevice && !device.stop() {
            let failure = device.lastTransportError?.localizedDescription
                ?? "The device did not acknowledge the stop command."
            if !failures.contains(failure) { failures.append(failure) }
            connectionLost = true
        }
        do {
            try output.finish()
        } catch {
            failures.append(error.localizedDescription)
        }
        if !failures.isEmpty {
            throw CollectionFailure(messages: failures, connectionLost: connectionLost)
        }
    }

    // MARK: - Helpers
    
    nonisolated static func zScore(ones: Int, total: Int, direction: Int) -> Double {
        guard total >= 8 else { return 0 }
        let z = (Double(ones) - Double(total) * 0.5) / sqrt(Double(total) * 0.25)
        return direction == 1 ? z : -z
    }
    
    nonisolated static func popcount(_ byte: UInt8) -> Int {
        byte.nonzeroBitCount
    }
    
    nonisolated static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
    
    nonisolated static func pValue(_ z: Double) -> Double {
        return 0.5 * erfc(z / sqrt(2.0))
    }
    
    nonisolated static func interpret(_ z: Double) -> String {
        let az = abs(z)
        if az >= 3.29 { return "EXTREME" }
        if az >= 2.58 { return "VERY SIG" }
        if az >= 1.96 { return "SIGNIF" }
        if az >= 1.645 { return "MARGINAL" }
        if az >= 1.0 { return "trend" }
        return ""
    }
    
    // MARK: - Available Ports
    
    nonisolated static func availablePorts() -> [String] {
        SerialPort.availablePorts()
    }
}


nonisolated private struct AcquisitionSample: Sendable {
    let n: Int, bits: Int, ones: Int
    let iz: Double, cz: Double, mean: Double, variance: Double
}

nonisolated private final class AcquisitionSession: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

nonisolated private struct CollectionFailure: LocalizedError {
    let messages: [String]
    let connectionLost: Bool
    var errorDescription: String? { messages.joined(separator: "\n") }
}

nonisolated private enum AcquisitionError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

/// Owns file handles for one collection. Created, written, and closed on the I/O queue.
nonisolated final class SessionOutput {
    let id: String
    let rawPath: String?
    let csvPath: String
    private var raw: FileHandle?
    private var csv: FileHandle?
    private static let bitText: [UInt8] = (0...255).flatMap { value in
        (0..<8).reversed().map { bit in ((value >> bit) & 1) == 1 ? 0x31 : 0x30 }
    }

    init(directory: String, saveRaw: Bool) throws {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: directory])
        }
        let reserved = try Self.reserveFiles(in: folder, saveRaw: saveRaw)
        id = reserved.id
        rawPath = reserved.rawPath
        csvPath = reserved.csvPath
        raw = reserved.raw
        csv = reserved.csv
        do {
            try csv?.write(contentsOf: Data("n,iz,cz,var,ones,bits,cum_ones,cum_bits\n".utf8))
        } catch {
            close()
            throw error
        }
    }

    private static func reserveFiles(in folder: URL, saveRaw: Bool) throws
        -> (id: String, rawPath: String?, csvPath: String, raw: FileHandle?, csv: FileHandle) {
        let base = RandomTestEngine.timestamp()
        var candidate = base
        while true {
            let urls = ["raw", "stats", "audit", "session"].map { name in
                folder.appendingPathComponent("rng_\(name)_\(candidate).\(name == "stats" ? "csv" : name == "session" ? "png" : "txt")")
            }
            if urls.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                candidate = base + "_" + UUID().uuidString
                continue
            }
            do {
                let csvHandle = try createFile(at: urls[1])
                do {
                    let rawHandle = saveRaw ? try createFile(at: urls[0]) : nil
                    return (candidate, saveRaw ? urls[0].path : nil, urls[1].path, rawHandle, csvHandle)
                } catch {
                    try? csvHandle.close()
                    throw error
                }
            } catch let error as POSIXError where error.code == .EEXIST {
                candidate = base + "_" + UUID().uuidString
            }
        }
    }

    private static func createFile(at url: URL) throws -> FileHandle {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func rawText(_ data: Data) -> Data {
        var result = Data(count: data.count * 8)
        // Fill one allocation instead of appending to Data once for every input byte.
        // Unsafe buffer indices start at zero even when data is a nonzero-index slice.
        result.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                bitText.withUnsafeBytes { lookup in
                    for index in input.indices {
                        output.baseAddress!.advanced(by: index * 8).copyMemory(
                            from: lookup.baseAddress!.advanced(by: Int(input[index]) * 8),
                            byteCount: 8
                        )
                    }
                }
            }
        }
        return result
    }

    func write(data: Data, n: Int, iz: Double, cz: Double, variance: Double,
               ones: Int, bits: Int, totalOnes: Int, totalBits: Int) throws {
        // Roll back this sample on a partial write so raw/CSV/counts stay aligned.
        let rawOffset = try raw?.offset()
        let csvOffset = try csv?.offset()
        do {
            try raw?.write(contentsOf: Self.rawText(data))
            let line = "\(n),\(String(format: "%.6f", iz)),\(String(format: "%.6f", cz)),\(String(format: "%.6f", variance)),\(ones),\(bits),\(totalOnes),\(totalBits)\n"
            try csv?.write(contentsOf: Data(line.utf8))
        } catch {
            var failures = [error.localizedDescription]
            if let rawOffset {
                do { try raw?.truncate(atOffset: rawOffset) }
                catch { failures.append(error.localizedDescription) }
            }
            if let csvOffset {
                do { try csv?.truncate(atOffset: csvOffset) }
                catch { failures.append(error.localizedDescription) }
            }
            throw CollectionFailure(messages: failures, connectionLost: false)
        }
    }

    func finish() throws {
        var failures: [String] = []
        // One failed sync/close must not skip closing the other output.
        for handle in [raw, csv].compactMap({ $0 }) {
            do { try handle.synchronize() }
            catch { failures.append(error.localizedDescription) }
            do { try handle.close() }
            catch { failures.append(error.localizedDescription) }
        }
        raw = nil
        csv = nil
        if !failures.isEmpty {
            throw CollectionFailure(messages: failures, connectionLost: false)
        }
    }

    func close() {
        try? raw?.close(); raw = nil
        try? csv?.close(); csv = nil
    }
}
