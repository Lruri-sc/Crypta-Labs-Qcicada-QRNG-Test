// AuditEngine.swift
// Qcicada
//
// Post-session statistical audit: chi-square, autocorrelation, runs test,
// approximate entropy, Hurst exponent, Levene's test.

import Foundation

nonisolated struct AuditReport {
    // Distribution Integrity
    var chi2: Double = 0
    var chi2P: Double = 1
    var runsZ: Double?
    var runsP: Double?
    var autocorrelation: [Int: Double] = [:]
    var maxACLag: Int = 0
    var maxACValue: Double = 0
    
    // Structural Measures
    var approxEntropy: Double = 0
    var hurstExponent: Double = 0.5
    var leveneF: Double?
    var leveneP: Double?
    var leveneVar1: Double = 0
    var leveneVar2: Double = 0
    
    // Summary
    var sessionFailure: String?
    var rawDataFailure: String?
    var cumulativeZ: Double = 0
    var cumulativeP: Double = 1
    var izVariance: Double = 1
    var izMean: Double = 0
    var totalBits: Int = 0
    var totalOnes: Int = 0
    var sampleCount: Int = 0
    var analyzedBitCount: Int = 0
    var leveneSampleCount: Int = 0
    var peakInstHi: Double = 0
    var peakInstLo: Double = 0
    var peakCumHi: Double = 0
    var peakCumLo: Double = 0
}

nonisolated final class AuditEngine {
    
    static func runAudit(
        rawFilePath: String?,
        izValues: [Double],
        totalOnes: Int,
        totalBits: Int,
        sampleCount: Int,
        izMean: Double,
        izVariance: Double,
        peakInstHi: Double,
        peakInstLo: Double,
        peakCumHi: Double,
        peakCumLo: Double,
        direction: Int = 1,
        locale: Locale? = nil,
        progress: @escaping (String) -> Void
    ) throws -> AuditReport {
        
        var report = AuditReport()
        report.totalBits = totalBits
        report.totalOnes = totalOnes
        report.sampleCount = sampleCount
        report.izMean = izMean
        report.izVariance = izVariance
        report.peakInstHi = peakInstHi
        report.peakInstLo = peakInstLo
        report.peakCumHi = peakCumHi
        report.peakCumLo = peakCumLo
        
        // Cumulative Z
        if totalBits > 0 {
            let z = (Double(totalOnes) - Double(totalBits) * 0.5) / sqrt(Double(totalBits) * 0.25)
            report.cumulativeZ = direction == 1 ? z : -z
            report.cumulativeP = 0.5 * erfc(report.cumulativeZ / sqrt(2.0))
        }
        
        // Chi-square
        progress(String(localized: "audit.progress.chi2", locale: locale ?? .current))
        let (chi2, chi2P) = chiSquare(ones: totalOnes, total: totalBits)
        report.chi2 = chi2
        report.chi2P = chi2P
        
        // Read bits from file
        var bits: [UInt8] = []
        if let path = rawFilePath {
            progress(String(localized: "audit.progress.read_raw", locale: locale ?? .current))
            let expectedBits = min(max(0, totalBits), 10_000_000)
            bits = try readBitsFromFile(path: path, maxBits: expectedBits)
            guard bits.count == expectedBits else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path])
            }
        }
        report.analyzedBitCount = bits.count
        
        if !bits.isEmpty {
            // Autocorrelation
            progress(String(localized: "audit.progress.autocorr", locale: locale ?? .current))
            let ac = autocorrelation(bits: bits, maxLag: 50)
            report.autocorrelation = ac
            if let maxEntry = ac.max(by: { abs($0.value) < abs($1.value) }) {
                report.maxACLag = maxEntry.key
                report.maxACValue = maxEntry.value
            }
            
            // Runs test
            progress(String(localized: "audit.progress.runs", locale: locale ?? .current))
            if let (rZ, rP) = runsTest(bits: bits) {
                report.runsZ = rZ
                report.runsP = rP
            }
            
            // Approximate entropy
            progress(String(localized: "audit.progress.approx_entropy", locale: locale ?? .current))
            let apenBits = Array(bits.prefix(100_000))
            report.approxEntropy = approximateEntropy(bits: apenBits, m: 2)
            
            // Hurst exponent
            progress(String(localized: "audit.progress.hurst", locale: locale ?? .current))
            let hurstBits = Array(bits.prefix(500_000))
            report.hurstExponent = hurstExponent(bits: hurstBits)
        }
        
        // Levene's test
        if izValues.count > 20 {
            report.leveneSampleCount = izValues.count
            progress(String(localized: "audit.progress.levene", locale: locale ?? .current))
            let (f, p, v1, v2) = leveneTest(values: izValues)
            report.leveneF = f
            report.leveneP = p
            report.leveneVar1 = v1
            report.leveneVar2 = v2
        }
        
        progress(String(localized: "audit.complete", locale: locale ?? .current))
        return report
    }
    
    // MARK: - Save Report
    
    static func saveReport(_ report: AuditReport, to directory: String, port: String, direction: Int, chunkSize: Int, sessionID: String? = nil) throws -> String {
        let ts = sessionID ?? dateString()
        let filename = "rng_audit_\(ts).txt"
        let path = (directory as NSString).appendingPathComponent(filename)
        
        var text = ""
        text += "随机数测试 EXPERIMENT — FULL AUDIT REPORT\n"
        if let failure = report.sessionFailure {
            text += "Session status: INTERRUPTED — only successfully recorded samples are included.\n"
            text += "Interruption: \(failure)\n"
        }
        if let failure = report.rawDataFailure {
            text += "Raw data unavailable: \(failure)\n"
            text += "Raw-bit tests were not performed; summary statistics remain available.\n"
        }
        text += "Generated: \(Date())\n"
        text += "Device: QCicada QRNG\n"
        text += "Port: \(port)\n"
        text += "Direction: \(direction == 1 ? "MORE 1s" : "MORE 0s")\n"
        text += "Chunk size: \(chunkSize) bytes\n"
        text += String(repeating: "=", count: 70) + "\n\n"
        
        text += "BASIC STATISTICS\n"
        text += "  Samples:        \(report.sampleCount)\n"
        text += "  Total bits:     \(report.totalBits)\n"
        text += "  Ones:           \(report.totalOnes) (\(String(format: "%.4f", Double(report.totalOnes)/Double(max(1,report.totalBits))*100))%)\n"
        text += "  Zeros:          \(report.totalBits - report.totalOnes)\n"
        text += "  Cumulative Z:   \(String(format: "%+.4f", report.cumulativeZ))\n"
        text += "  Cumulative p:   \(String(format: "%.6f", report.cumulativeP)) (one-tail)\n"
        if report.sampleCount > 0 {
            text += "  iZ mean:        \(String(format: "%+.4f", report.izMean))\n"
            text += "  iZ variance:    \(String(format: "%.4f", report.izVariance)) (theory=1.0)\n"
            text += "  iZ peak hi:     \(String(format: "%+.4f", report.peakInstHi))\n"
            text += "  iZ peak lo:     \(String(format: "%+.4f", report.peakInstLo))\n"
            text += "  cZ peak hi:     \(String(format: "%+.4f", report.peakCumHi))\n"
            text += "  cZ peak lo:     \(String(format: "%+.4f", report.peakCumLo))\n\n"
        } else {
            text += "  iZ/cZ statistics: Not run (no collected samples).\n\n"
        }

        text += "DISTRIBUTION INTEGRITY\n"
        if report.totalBits > 0 {
            text += "  Chi-square:     χ²=\(String(format: "%.4f", report.chi2)), p=\(String(format: "%.6f", report.chi2P))\n"
        } else {
            text += "  Chi-square:     Not run (no collected bits).\n"
        }
        text += "  Raw bits read:  \(report.analyzedBitCount) (first 10,000,000 bits at most).\n"
        if let z = report.runsZ, let p = report.runsP {
            text += "  Runs test:      Z=\(String(format: "%+.4f", z)), p=\(String(format: "%.6f", p))\n"
        } else if report.analyzedBitCount >= 100 {
            text += "  Runs test:      Unavailable (requires both bit values and nonzero runs variance).\n"
        } else {
            text += "  Runs test:      Not run (requires at least 100 raw bits).\n"
        }
        
        if !report.autocorrelation.isEmpty {
            text += "  Autocorrelation:\n"
            text += "    Max |r| = \(String(format: "%.6f", abs(report.maxACValue))) at lag \(report.maxACLag)\n"
            for lag in [1, 5, 10, 25, 50] {
                if let val = report.autocorrelation[lag] {
                    text += "    lag \(String(format: "%2d", lag)): r=\(String(format: "%+.6f", val))\n"
                }
            }
        } else {
            text += "  Autocorrelation: Unavailable (requires more than 150 raw bits with nonzero variance).\n"
        }
        text += "\n"
        
        text += "STRUCTURAL MEASURES\n"
        if report.analyzedBitCount >= 100 {
            text += "  Approx Entropy: ApEn=\(String(format: "%.6f", report.approxEntropy)) (max=0.6931, ratio=\(String(format: "%.4f", report.approxEntropy/0.6931)))\n"
            text += "    Raw bits used: \(min(report.analyzedBitCount, 100_000)) (first 100,000 at most).\n"
        } else {
            text += "  Approx Entropy: Not run (requires at least 100 raw bits).\n"
        }
        if report.analyzedBitCount >= 200 {
            text += "  Hurst Exponent: H=\(String(format: "%.4f", report.hurstExponent)) (random=0.5)\n"
            text += "    Raw bits used: \(min(report.analyzedBitCount, 500_000)) (first 500,000 at most).\n"
        } else {
            text += "  Hurst Exponent: Not run (requires at least 200 raw bits).\n"
        }
        if report.leveneSampleCount > 20 {
            if let f = report.leveneF, let p = report.leveneP {
                text += "  Levene's Test:  F=\(String(format: "%.4f", f)), p=\(String(format: "%.6f", p)) (df=1,\(report.leveneSampleCount - 2); median-centered)\n"
            } else {
                text += "  Levene's Test:  Unavailable (zero within-group deviation variance or numerical failure).\n"
            }
            text += "    First half var:  \(String(format: "%.4f", report.leveneVar1))\n"
            text += "    Second half var: \(String(format: "%.4f", report.leveneVar2))\n"
        } else {
            text += "  Levene's Test:  Not run (requires more than 20 samples).\n"
        }
        
        let temporaryURL = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(".qcicada-audit-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporaryURL.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? file.close()
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        try file.write(contentsOf: Data(text.utf8))
        try file.synchronize()
        try file.close()
        guard renamex_np(temporaryURL.path, path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: path])
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return path
    }
    
    // MARK: - Statistical Tests
    
    private static func chiSquare(ones: Int, total: Int) -> (Double, Double) {
        guard total > 0 else { return (0, 1) }
        let expected = Double(total) / 2.0
        let zeros = Double(total - ones)
        let chi2 = pow(Double(ones) - expected, 2) / expected + pow(zeros - expected, 2) / expected
        let z = sqrt(chi2)
        let p = erfc(z / sqrt(2.0))
        return (chi2, p)
    }
    
    private static func autocorrelation(bits: [UInt8], maxLag: Int) -> [Int: Double] {
        let n = bits.count
        guard n > maxLag + 100 else { return [:] }
        let mean = Double(bits.reduce(0) { $0 + Int($1) }) / Double(n)
        let variance = bits.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(n)
        guard variance > 0 else { return [:] }
        
        @Sendable func correlation(at lag: Int) -> Double {
            var cov = 0.0
            for i in 0..<(n - lag) {
                cov += (Double(bits[i]) - mean) * (Double(bits[i + lag]) - mean)
            }
            cov /= Double(n - lag)
            return cov / variance
        }

        var results: [Int: Double] = [:]
        // Short inputs are faster without dispatch overhead. Longer inputs calculate
        // independent lags concurrently, preserving every lag's floating-point order.
        if n < 10_000 || maxLag < 2 {
            for lag in 1...maxLag { results[lag] = correlation(at: lag) }
        } else {
            let values = LagResults(count: maxLag)
            DispatchQueue.concurrentPerform(iterations: maxLag) { index in
                values.set(correlation(at: index + 1), at: index)
            }
            for (index, value) in values.snapshot().enumerated() {
                results[index + 1] = value
            }
        }
        return results
    }

    // Concurrent workers only access this buffer through the lock. The dispatch
    // call finishes before the ordered snapshot is converted to the public result.
    nonisolated private final class LagResults: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double]

        init(count: Int) { values = [Double](repeating: 0, count: count) }
        func set(_ value: Double, at index: Int) {
            lock.withLock { values[index] = value }
        }
        func snapshot() -> [Double] { lock.withLock { values } }
    }
    
    private static func runsTest(bits: [UInt8]) -> (Double, Double)? {
        let n = bits.count
        guard n >= 100 else { return nil }
        let n1 = bits.reduce(0) { $0 + Int($1) }
        let n0 = n - n1
        guard n1 > 0, n0 > 0 else { return nil }
        
        var runs = 1
        for i in 1..<n {
            if bits[i] != bits[i-1] { runs += 1 }
        }
        
        let eRuns = 1.0 + 2.0 * Double(n0) * Double(n1) / Double(n)
        let num = 2.0 * Double(n0) * Double(n1) * (2.0 * Double(n0) * Double(n1) - Double(n))
        let den = Double(n) * Double(n) * Double(n - 1)
        let varRuns = num / den
        guard varRuns > 0 else { return nil }
        
        let z = (Double(runs) - eRuns) / sqrt(varRuns)
        let p = erfc(abs(z) / sqrt(2.0))
        return (z, p)
    }
    
    private static func approximateEntropy(bits: [UInt8], m: Int) -> Double {
        let n = bits.count
        guard n >= 100 else { return 0 }
        
        func phi(_ mVal: Int) -> Double {
            var patterns = [Int](repeating: 0, count: 1 << mVal)
            let mask = patterns.count - 1
            var pattern = 0
            for i in bits.indices {
                pattern = ((pattern << 1) | Int(bits[i])) & mask
                if i >= mVal - 1 { patterns[pattern] += 1 }
            }
            let total = Double(n - mVal + 1)
            return patterns.reduce(0.0) { sum, count in
                guard count > 0 else { return sum }
                let freq = Double(count) / total
                return sum + freq * log(freq)
            }
        }
        
        return phi(m) - phi(m + 1)
    }
    
    private static func hurstExponent(bits: [UInt8], maxK: Int = 20) -> Double {
        let n = bits.count
        guard n >= 200 else { return 0.5 }
        let series = bits.map { $0 == 1 ? 1.0 : -1.0 }
        
        var logSizes: [Double] = []
        var logRS: [Double] = []
        
        for k in 2...maxK {
            let size = n / k
            guard size >= 10 else { break }
            
            var rsList: [Double] = []
            for i in 0..<k {
                let range = (i * size)..<((i + 1) * size)
                var total = 0.0
                for index in range { total += series[index] }
                let mean = total / Double(size)
                var s = 0.0, squares = 0.0
                var minimum = Double.infinity, maximum = -Double.infinity
                // Preserve the original summation order without allocating the chunk,
                // deviations, and cumulative-sum arrays for each group.
                for index in range {
                    let deviation = series[index] - mean
                    s += deviation
                    minimum = min(minimum, s)
                    maximum = max(maximum, s)
                    squares += deviation * deviation
                }
                let r = maximum - minimum
                let std = sqrt(squares / Double(size))
                if std > 0 { rsList.append(r / std) }
            }
            
            if !rsList.isEmpty {
                logSizes.append(log(Double(size)))
                logRS.append(log(rsList.reduce(0, +) / Double(rsList.count)))
            }
        }
        
        guard logSizes.count >= 3 else { return 0.5 }
        
        // Linear regression
        let nPts = Double(logSizes.count)
        let sx = logSizes.reduce(0, +)
        let sy = logRS.reduce(0, +)
        let sxy = zip(logSizes, logRS).reduce(0) { $0 + $1.0 * $1.1 }
        let sxx = logSizes.reduce(0) { $0 + $1 * $1 }
        let denom = nPts * sxx - sx * sx
        guard denom != 0 else { return 0.5 }
        return (nPts * sxy - sx * sy) / denom
    }
    
    private static func leveneTest(values: [Double]) -> (Double?, Double?, Double, Double) {
        let n = values.count
        guard n >= 20 else { return (nil, nil, 0, 0) }
        let half = n / 2
        let g1 = Array(values[0..<half])
        let g2 = Array(values[half...])
        
        func median(_ group: [Double]) -> Double {
            let sorted = group.sorted()
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2)
                ? sorted[middle - 1] / 2 + sorted[middle] / 2
                : sorted[middle]
        }
        let med1 = median(g1)
        let med2 = median(g2)
        
        let d1 = g1.map { abs($0 - med1) }
        let d2 = g2.map { abs($0 - med2) }
        
        let mean1 = d1.reduce(0, +) / Double(d1.count)
        let mean2 = d2.reduce(0, +) / Double(d2.count)
        let meanAll = (d1.reduce(0, +) + d2.reduce(0, +)) / Double(d1.count + d2.count)
        
        let ssb = Double(d1.count) * pow(mean1 - meanAll, 2) + Double(d2.count) * pow(mean2 - meanAll, 2)
        let ssw = d1.reduce(0) { $0 + pow($1 - mean1, 2) } + d2.reduce(0) { $0 + pow($1 - mean2, 2) }
        
        let groupMean1 = g1.reduce(0, +) / Double(g1.count)
        let groupMean2 = g2.reduce(0, +) / Double(g2.count)
        let var1 = g1.reduce(0) { $0 + pow($1 - groupMean1, 2) } / Double(g1.count)
        let var2 = g2.reduce(0) { $0 + pow($1 - groupMean2, 2) } / Double(g2.count)
        guard ssw > 0, ssw.isFinite, ssb.isFinite else { return (nil, nil, var1, var2) }

        // NIST Levene statistic: F with k - 1 and N - k degrees of freedom (k = 2).
        // https://www.itl.nist.gov/div898/handbook/eda/section3/eda35a.htm
        let f = Double(n - 2) * (ssb / ssw)
        guard let p = fSurvival(statistic: f, denominatorDF: n - 2) else {
            return (nil, nil, var1, var2)
        }
        
        return (f, p, var1, var2)
    }

    /// Upper-tail probability for F(1, denominatorDF). Returns nil on numerical failure.
    /// NIST: P(F > f) = I_[nu/(nu+f)](nu/2, 1/2).
    /// https://www.itl.nist.gov/div898/handbook/eda/section3/eda3665.htm
    static func fSurvival(statistic: Double, denominatorDF: Int) -> Double? {
        guard statistic.isFinite, statistic >= 0, denominatorDF > 0 else { return nil }
        if statistic == 0 { return 1 }
        let ratio = statistic / Double(denominatorDF)
        let x = 1 / (1 + ratio)
        let complement = ratio / (1 + ratio)
        return regularizedBeta(x: x, complement: complement, a: Double(denominatorDF) / 2, b: 0.5)
    }

    /// DLMF 8.17.2-4, 8.17.22-23, with the symmetry choice recommended in 8.17(v).
    /// Keeping x and its complement avoids losing small F values by subtracting from 1.
    /// https://dlmf.nist.gov/8.17
    private static func regularizedBeta(x: Double, complement: Double, a: Double, b: Double) -> Double? {
        if x == 0 { return 0 }
        if complement == 0 { return 1 }
        let logX = x > 0.5 ? log1p(-complement) : log(x)
        let logComplement = complement > 0.5 ? log1p(-x) : log(complement)
        let logFactor = a * logX + b * logComplement - (lgamma(a) + lgamma(b) - lgamma(a + b))
        let reflected = x >= (a + 1) / (a + b + 2)
        let first = reflected ? b : a
        let second = reflected ? a : b
        let argument = reflected ? complement : x
        guard let fraction = betaContinuedFraction(a: first, b: second, x: argument), fraction > 0 else {
            return nil
        }
        let tail = exp(logFactor + log(fraction) - log(first))
        guard tail.isFinite, tail >= 0, tail <= 1 + 64 * Double.ulpOfOne else { return nil }
        return min(1, max(0, reflected ? 1 - tail : tail))
    }

    /// Modified Lentz evaluation of the DLMF 8.17.22 continued fraction.
    /// DLMF 3.10(iii) discusses this evaluation method. Exhaustion is an unavailable
    /// result, never a fabricated p value. These limits control numerical convergence only.
    private static func betaContinuedFraction(a: Double, b: Double, x: Double) -> Double? {
        let tolerance = 8 * Double.ulpOfOne
        let minimum = Double.leastNormalMagnitude / tolerance
        func nonzero(_ value: Double) -> Double {
            if abs(value) >= minimum { return value }
            return value.sign == .minus ? -minimum : minimum
        }
        var c = 1.0
        var d = 1 / nonzero(1 - (a + b) * x / (a + 1))
        var result = d
        for index in 1...10_000 {
            let m = Double(index)
            let twiceM = 2 * m
            let even = m * (b - m) * x / ((a + twiceM - 1) * (a + twiceM))
            d = 1 / nonzero(1 + even * d)
            c = nonzero(1 + even / c)
            result *= d * c
            let odd = -(a + m) * (a + b + m) * x / ((a + twiceM) * (a + twiceM + 1))
            d = 1 / nonzero(1 + odd * d)
            c = nonzero(1 + odd / c)
            let change = d * c
            result *= change
            guard result.isFinite else { return nil }
            if abs(change - 1) <= tolerance { return result }
        }
        return nil
    }
    
    // MARK: - File I/O
    
    private static func readBitsFromFile(path: String, maxBits: Int) throws -> [UInt8] {
        var bits: [UInt8] = []
        bits.reserveCapacity(min(maxBits, 10_000_000))
        
        let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { fh.closeFile() }
        
        while bits.count < maxBits {
            guard let chunk = try fh.read(upToCount: 100_000) else { break }
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for byte in bytes {
                    if byte == 0x30 { bits.append(0) } // '0'
                    else if byte == 0x31 { bits.append(1) } // '1'
                    if bits.count >= maxBits { break }
                }
            }
        }
        return bits
    }
    
    private static func dateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}
