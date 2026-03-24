// RandomTestEngine.swift
// Qcicada
//
// Data acquisition engine with real-time 随机数测试 statistics.
// Runs collection on a background thread, publishes to SwiftUI via @Observable.

import Foundation
import Observation

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
    var exportDirectory: String = NSHomeDirectory() + "/Documents"
    
    // MARK: - Internals
    private var device: QCCDevice?
    private var serial: SerialPort?
    private var collectionThread: Thread?
    private var welfordM2: Double = 0
    private var rawFileHandle: FileHandle?
    private var csvFileHandle: FileHandle?
    
    // MARK: - Connect
    
    func connect() {
        connectionError = nil
        
        guard !portPath.isEmpty else {
            connectionError = String(localized: "error.no_port", locale: Self.uiLocale ?? .current)
            return
        }
        
        let sp = SerialPort(path: portPath)
        
        // Try to connect with cleanup
        do {
            try sp.open()
        } catch {
            connectionError = error.localizedDescription
            return
        }
        
        let dev = QCCDevice(serial: sp)
        
        // Try stop (cleanup from previous session)
        _ = dev.stop()
        Thread.sleep(forTimeInterval: 0.3)
        dev.flushBuffers()
        Thread.sleep(forTimeInterval: 0.2)
        
        // Verify device
        if let status = dev.getStatus() {
            readyBytes = status.readyBytes
            isConnected = true
            
            // Try to get device info (may fail on some FW)
            if let info = dev.getInfo() {
                deviceSerial = info.serial
            } else {
                deviceSerial = "connected"
            }
        } else {
            connectionError = String(localized: "error.device_not_responding", locale: Self.uiLocale ?? .current)
            sp.close()
            return
        }
        
        dev.flushBuffers()
        self.serial = sp
        self.device = dev
    }
    
    func disconnect() {
        stop()
        device?.closeComm()
        serial = nil
        device = nil
        isConnected = false
        deviceSerial = "—"
    }
    
    /// Drop large in-memory buffers and reset stats to minimize memory usage.
    func releaseMemory() {
        izHistory.removeAll(keepingCapacity: false)
        czHistory.removeAll(keepingCapacity: false)
        varHistory.removeAll(keepingCapacity: false)
        izFull.removeAll(keepingCapacity: false)
        czFull.removeAll(keepingCapacity: false)
        varFull.removeAll(keepingCapacity: false)
        
        sampleCount = 0
        totalBits = 0
        totalOnes = 0
        cumulativeZ = 0
        instantZ = 0
        peakInstHi = -999
        peakInstLo = 999
        peakCumHi = -999
        peakCumLo = 999
        izMean = 0
        izVariance = 1.0
        varianceZScore = 0
        welfordM2 = 0
        
        currentRawFilePath = nil
        currentCsvFilePath = nil
        connectionError = nil
        readyBytes = 0
    }
    
    // MARK: - Start / Stop Collection
    
    func start() {
        guard let device = device, isConnected else { return }
        
        // Reset stats
        sampleCount = 0
        totalBits = 0
        totalOnes = 0
        cumulativeZ = 0
        instantZ = 0
        peakInstHi = -999
        peakInstLo = 999
        peakCumHi = -999
        peakCumLo = 999
        izMean = 0
        izVariance = 1.0
        varianceZScore = 0
        welfordM2 = 0
        izHistory = []
        czHistory = []
        varHistory = []
        izFull = []
        czFull = []
        varFull = []
        
        let ts = Self.timestamp()
        
        // Setup raw file
        if saveRaw {
            let rawPath = (exportDirectory as NSString).appendingPathComponent("rng_raw_\(ts).txt")
            FileManager.default.createFile(atPath: rawPath, contents: nil)
            rawFileHandle = FileHandle(forWritingAtPath: rawPath)
            currentRawFilePath = rawPath
        }
        
        // Setup stats CSV
        let csvPath = (exportDirectory as NSString).appendingPathComponent("rng_stats_\(ts).csv")
        let csvHeader = "n,iz,cz,var,ones,bits,cum_ones,cum_bits\n"
        FileManager.default.createFile(atPath: csvPath, contents: csvHeader.data(using: .utf8))
        csvFileHandle = FileHandle(forWritingAtPath: csvPath)
        csvFileHandle?.seekToEndOfFile()
        currentCsvFilePath = csvPath
        
        device.flushBuffers()
        Thread.sleep(forTimeInterval: 0.2)
        
        guard device.startContinuous() else {
            connectionError = String(localized: "error.start_continuous_failed", locale: Self.uiLocale ?? .current)
            return
        }
        
        isRunning = true
        
        // Background collection
        collectionThread = Thread {
            self.collectionLoop(device: device)
        }
        collectionThread?.qualityOfService = .userInitiated
        collectionThread?.name = "PKCollection"
        collectionThread?.start()
    }
    
    func stop() {
        isRunning = false
        collectionThread?.cancel()
        collectionThread = nil
        
        _ = device?.stop()
        
        rawFileHandle?.closeFile()
        rawFileHandle = nil
        csvFileHandle?.closeFile()
        csvFileHandle = nil
    }
    
    // MARK: - Collection Loop (runs on background thread)
    
    private func collectionLoop(device: QCCDevice) {
        while isRunning && !(Thread.current.isCancelled) {
            guard let data = device.readContinuous(count: chunkSize) else {
                continue
            }
            
            // Write raw 01 string to file
            if let fh = rawFileHandle {
                // Convert bytes to bit string efficiently
                var bitString = ""
                bitString.reserveCapacity(data.count * 8)
                for byte in data {
                    for i in (0..<8).reversed() {
                        bitString.append((byte >> i) & 1 == 1 ? "1" : "0")
                    }
                }
                if let strData = bitString.data(using: .ascii) {
                    fh.write(strData)
                }
            }
            
            // Count ones
            var ones = 0
            for byte in data {
                ones += Self.popcount(byte)
            }
            let bits = data.count * 8
            
            // Instant Z
            let iz = Self.zScore(ones: ones, total: bits, direction: direction)
            
            // Cumulative
            let newTotalOnes = totalOnes + ones
            let newTotalBits = totalBits + bits
            let cz = Self.zScore(ones: newTotalOnes, total: newTotalBits, direction: direction)
            
            let newSampleCount = sampleCount + 1
            
            // Welford online variance
            let delta = iz - izMean
            let newMean = izMean + delta / Double(newSampleCount)
            let delta2 = iz - newMean
            let newM2 = welfordM2 + delta * delta2
            let newVar = newSampleCount > 1 ? newM2 / Double(newSampleCount) : 1.0
            
            // Publish to main thread
            let finalIz = iz
            let finalCz = cz
            let finalVar = newVar
            let finalMean = newMean
            let finalN = newSampleCount
            let finalOnes = newTotalOnes
            let finalBits = newTotalBits
            let finalM2 = newM2
            let histSize = historySize
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.sampleCount = finalN
                self.totalOnes = finalOnes
                self.totalBits = finalBits
                self.instantZ = finalIz
                self.cumulativeZ = finalCz
                self.izMean = finalMean
                self.izVariance = finalVar
                self.welfordM2 = finalM2
                
                if finalIz > self.peakInstHi { self.peakInstHi = finalIz }
                if finalIz < self.peakInstLo { self.peakInstLo = finalIz }
                if finalCz > self.peakCumHi { self.peakCumHi = finalCz }
                if finalCz < self.peakCumLo { self.peakCumLo = finalCz }
                
                // Variance Z-score (chi-square approximation)
                if finalN > 30 {
                    let chi2 = Double(finalN - 1) * finalVar
                    let df = Double(finalN - 1)
                    self.varianceZScore = sqrt(2.0 * chi2) - sqrt(2.0 * df - 1.0)
                }
                
                // Full history (for export)
                self.izFull.append(finalIz)
                self.czFull.append(finalCz)
                self.varFull.append(finalVar)
                
                // Sliding window history (for chart)
                self.izHistory.append(finalIz)
                self.czHistory.append(finalCz)
                self.varHistory.append(finalVar)
                
                if self.izHistory.count > histSize {
                    self.izHistory.removeFirst(self.izHistory.count - histSize)
                }
                if self.czHistory.count > histSize {
                    self.czHistory.removeFirst(self.czHistory.count - histSize)
                }
                if self.varHistory.count > histSize {
                    self.varHistory.removeFirst(self.varHistory.count - histSize)
                }
            }
            
            // Write CSV (on background thread, non-blocking)
            if let fh = csvFileHandle {
                let line = "\(newSampleCount),\(String(format: "%.6f", iz)),\(String(format: "%.6f", cz)),\(String(format: "%.6f", newVar)),\(ones),\(bits),\(newTotalOnes),\(newTotalBits)\n"
                if let data = line.data(using: .utf8) {
                    fh.write(data)
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    static func zScore(ones: Int, total: Int, direction: Int) -> Double {
        guard total >= 8 else { return 0 }
        let z = (Double(ones) - Double(total) * 0.5) / sqrt(Double(total) * 0.25)
        return direction == 1 ? z : -z
    }
    
    static func popcount(_ byte: UInt8) -> Int {
        var n = byte
        var count = 0
        while n != 0 {
            count += Int(n & 1)
            n >>= 1
        }
        return count
    }
    
    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
    
    static func pValue(_ z: Double) -> Double {
        return 0.5 * erfc(z / sqrt(2.0))
    }
    
    static func interpret(_ z: Double) -> String {
        let az = abs(z)
        if az >= 3.29 { return "EXTREME" }
        if az >= 2.58 { return "VERY SIG" }
        if az >= 1.96 { return "SIGNIF" }
        if az >= 1.645 { return "MARGINAL" }
        if az >= 1.0 { return "trend" }
        return ""
    }
    
    // MARK: - Available Ports
    
    static func availablePorts() -> [String] {
        SerialPort.availablePorts()
    }
}
