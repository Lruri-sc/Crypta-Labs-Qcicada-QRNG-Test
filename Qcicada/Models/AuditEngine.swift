// AuditEngine.swift
// Qcicada
//
// Post-session statistical audit: chi-square, autocorrelation, runs test,
// approximate entropy, Hurst exponent, Levene's test.

import Foundation

struct AuditReport {
    // Distribution Integrity
    var chi2: Double = 0
    var chi2P: Double = 1
    var runsZ: Double = 0
    var runsP: Double = 1
    var autocorrelation: [Int: Double] = [:]
    var maxACLag: Int = 0
    var maxACValue: Double = 0
    
    // Structural Measures
    var approxEntropy: Double = 0
    var hurstExponent: Double = 0.5
    var leveneF: Double = 0
    var leveneP: Double = 1
    var leveneVar1: Double = 0
    var leveneVar2: Double = 0
    
    // Summary
    var cumulativeZ: Double = 0
    var cumulativeP: Double = 1
    var izVariance: Double = 1
    var izMean: Double = 0
    var totalBits: Int = 0
    var totalOnes: Int = 0
    var sampleCount: Int = 0
    var peakInstHi: Double = 0
    var peakInstLo: Double = 0
    var peakCumHi: Double = 0
    var peakCumLo: Double = 0
}

final class AuditEngine {
    
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
        locale: Locale? = nil,
        progress: @escaping (String) -> Void
    ) -> AuditReport {
        
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
            report.cumulativeZ = (Double(totalOnes) - Double(totalBits) * 0.5) / sqrt(Double(totalBits) * 0.25)
            report.cumulativeP = 0.5 * erfc(report.cumulativeZ / sqrt(2.0))
        }
        
        // Chi-square
        progress(String(localized: "audit.progress.chi2", locale: locale ?? .current))
        let (chi2, chi2P) = chiSquare(ones: totalOnes, total: totalBits)
        report.chi2 = chi2
        report.chi2P = chi2P
        
        // Read bits from file
        var bits: [Int] = []
        if let path = rawFilePath {
            progress(String(localized: "audit.progress.read_raw", locale: locale ?? .current))
            bits = readBitsFromFile(path: path, maxBits: 10_000_000)
        }
        
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
            let (rZ, rP) = runsTest(bits: bits)
            report.runsZ = rZ
            report.runsP = rP
            
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
    
    static func saveReport(_ report: AuditReport, to directory: String, port: String, direction: Int, chunkSize: Int) -> String {
        let ts = dateString()
        let filename = "rng_audit_\(ts).txt"
        let path = (directory as NSString).appendingPathComponent(filename)
        
        var text = ""
        text += "随机数测试 EXPERIMENT — FULL AUDIT REPORT\n"
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
        text += "  iZ mean:        \(String(format: "%+.4f", report.izMean))\n"
        text += "  iZ variance:    \(String(format: "%.4f", report.izVariance)) (theory=1.0)\n"
        text += "  iZ peak hi:     \(String(format: "%+.4f", report.peakInstHi))\n"
        text += "  iZ peak lo:     \(String(format: "%+.4f", report.peakInstLo))\n"
        text += "  cZ peak hi:     \(String(format: "%+.4f", report.peakCumHi))\n"
        text += "  cZ peak lo:     \(String(format: "%+.4f", report.peakCumLo))\n\n"
        
        text += "DISTRIBUTION INTEGRITY\n"
        text += "  Chi-square:     χ²=\(String(format: "%.4f", report.chi2)), p=\(String(format: "%.6f", report.chi2P))\n"
        text += "  Runs test:      Z=\(String(format: "%+.4f", report.runsZ)), p=\(String(format: "%.6f", report.runsP))\n"
        
        if !report.autocorrelation.isEmpty {
            text += "  Autocorrelation:\n"
            text += "    Max |r| = \(String(format: "%.6f", abs(report.maxACValue))) at lag \(report.maxACLag)\n"
            for lag in [1, 5, 10, 25, 50] {
                if let val = report.autocorrelation[lag] {
                    text += "    lag \(String(format: "%2d", lag)): r=\(String(format: "%+.6f", val))\n"
                }
            }
        }
        text += "\n"
        
        text += "STRUCTURAL MEASURES\n"
        text += "  Approx Entropy: ApEn=\(String(format: "%.6f", report.approxEntropy)) (max=0.6931, ratio=\(String(format: "%.4f", report.approxEntropy/0.6931)))\n"
        text += "  Hurst Exponent: H=\(String(format: "%.4f", report.hurstExponent)) (random=0.5)\n"
        text += "  Levene's Test:  F=\(String(format: "%.4f", report.leveneF)), p=\(String(format: "%.6f", report.leveneP))\n"
        text += "    First half var:  \(String(format: "%.4f", report.leveneVar1))\n"
        text += "    Second half var: \(String(format: "%.4f", report.leveneVar2))\n"
        
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
    
    // MARK: - Statistical Tests
    
    private static func chiSquare(ones: Int, total: Int) -> (Double, Double) {
        let expected = Double(total) / 2.0
        let zeros = Double(total - ones)
        let chi2 = pow(Double(ones) - expected, 2) / expected + pow(zeros - expected, 2) / expected
        let z = sqrt(chi2)
        let p = erfc(z / sqrt(2.0))
        return (chi2, p)
    }
    
    private static func autocorrelation(bits: [Int], maxLag: Int) -> [Int: Double] {
        let n = bits.count
        guard n > maxLag + 100 else { return [:] }
        let mean = Double(bits.reduce(0, +)) / Double(n)
        let variance = bits.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(n)
        guard variance > 0 else { return [:] }
        
        var results: [Int: Double] = [:]
        for lag in 1...maxLag {
            var cov = 0.0
            for i in 0..<(n - lag) {
                cov += (Double(bits[i]) - mean) * (Double(bits[i + lag]) - mean)
            }
            cov /= Double(n - lag)
            results[lag] = cov / variance
        }
        return results
    }
    
    private static func runsTest(bits: [Int]) -> (Double, Double) {
        let n = bits.count
        guard n >= 100 else { return (0, 1) }
        let n1 = bits.reduce(0, +)
        let n0 = n - n1
        
        var runs = 1
        for i in 1..<n {
            if bits[i] != bits[i-1] { runs += 1 }
        }
        
        let eRuns = 1.0 + 2.0 * Double(n0) * Double(n1) / Double(n)
        let num = 2.0 * Double(n0) * Double(n1) * (2.0 * Double(n0) * Double(n1) - Double(n))
        let den = Double(n) * Double(n) * Double(n - 1)
        let varRuns = num / den
        guard varRuns > 0 else { return (0, 1) }
        
        let z = (Double(runs) - eRuns) / sqrt(varRuns)
        let p = erfc(abs(z) / sqrt(2.0))
        return (z, p)
    }
    
    private static func approximateEntropy(bits: [Int], m: Int) -> Double {
        let n = bits.count
        guard n >= 100 else { return 0 }
        
        func phi(_ mVal: Int) -> Double {
            var patterns: [String: Int] = [:]
            for i in 0...(n - mVal) {
                let pat = bits[i..<(i + mVal)].map(String.init).joined()
                patterns[pat, default: 0] += 1
            }
            let total = Double(n - mVal + 1)
            return patterns.values.reduce(0.0) { sum, count in
                let freq = Double(count) / total
                return sum + freq * log(freq)
            }
        }
        
        return phi(m) - phi(m + 1)
    }
    
    private static func hurstExponent(bits: [Int], maxK: Int = 20) -> Double {
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
                let chunk = Array(series[(i * size)..<((i + 1) * size)])
                let mean = chunk.reduce(0, +) / Double(chunk.count)
                let deviations = chunk.map { $0 - mean }
                var cumsum: [Double] = []
                var s = 0.0
                for d in deviations { s += d; cumsum.append(s) }
                let r = (cumsum.max() ?? 0) - (cumsum.min() ?? 0)
                let std = sqrt(deviations.reduce(0) { $0 + $1 * $1 } / Double(deviations.count))
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
    
    private static func leveneTest(values: [Double]) -> (Double, Double, Double, Double) {
        let n = values.count
        guard n >= 20 else { return (0, 1, 0, 0) }
        let half = n / 2
        let g1 = Array(values[0..<half])
        let g2 = Array(values[half...])
        
        let med1 = g1.sorted()[g1.count / 2]
        let med2 = g2.sorted()[g2.count / 2]
        
        let d1 = g1.map { abs($0 - med1) }
        let d2 = g2.map { abs($0 - med2) }
        
        let mean1 = d1.reduce(0, +) / Double(d1.count)
        let mean2 = d2.reduce(0, +) / Double(d2.count)
        let meanAll = (d1.reduce(0, +) + d2.reduce(0, +)) / Double(d1.count + d2.count)
        
        let ssb = Double(d1.count) * pow(mean1 - meanAll, 2) + Double(d2.count) * pow(mean2 - meanAll, 2)
        let ssw = d1.reduce(0) { $0 + pow($1 - mean1, 2) } + d2.reduce(0) { $0 + pow($1 - mean2, 2) }
        
        let N = Double(d1.count + d2.count)
        guard ssw > 0 else { return (0, 1, 0, 0) }
        
        let f = ((N - 2) / 1) * (ssb / ssw)
        let zApprox = sqrt(max(0, f))
        let p = erfc(zApprox / sqrt(2.0))
        
        let var1 = g1.reduce(0) { $0 + pow($1 - g1.reduce(0, +) / Double(g1.count), 2) } / Double(g1.count)
        let var2 = g2.reduce(0) { $0 + pow($1 - g2.reduce(0, +) / Double(g2.count), 2) } / Double(g2.count)
        
        return (f, p, var1, var2)
    }
    
    // MARK: - File I/O
    
    private static func readBitsFromFile(path: String, maxBits: Int) -> [Int] {
        var bits: [Int] = []
        bits.reserveCapacity(min(maxBits, 10_000_000))
        
        guard let fh = FileHandle(forReadingAtPath: path) else { return bits }
        defer { fh.closeFile() }
        
        while bits.count < maxBits {
            guard let chunk = try? fh.read(upToCount: 100_000) else { break }
            if chunk.isEmpty { break }
            for byte in chunk {
                if byte == 0x30 { bits.append(0) } // '0'
                else if byte == 0x31 { bits.append(1) } // '1'
                if bits.count >= maxBits { break }
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
