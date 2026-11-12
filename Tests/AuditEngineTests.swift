import Foundation

/// Standalone regression runner. Compile this file together with AuditEngine.swift.
@main
struct AuditEngineTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Qcicada-AuditTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        try testDirection()
        try testEmptyInput()
        try testMissingRawFile(in: directory)
        try testReportWrites(in: directory)
        try testEntropyEquivalence(in: directory)
        try testHurstEquivalence(in: directory)
        try testAutocorrelationEquivalence(in: directory)
        try testRawReadEquivalence(in: directory)
        try testLeveneVariance()
        try testFDistributionOracles()
        try testLeveneReferenceCases()
        try testUnavailableStatistics(in: directory)
        try benchmarkLevene()
        print("PASS: all audit regression groups completed")
    }

    private static func audit(
        rawFile: URL? = nil,
        values: [Double] = [],
        ones: Int = 0,
        total: Int = 0,
        direction: Int = 1
    ) throws -> AuditReport {
        try AuditEngine.runAudit(
            rawFilePath: rawFile?.path,
            izValues: values,
            totalOnes: ones,
            totalBits: total,
            sampleCount: values.count,
            izMean: 0,
            izVariance: 1,
            peakInstHi: 0,
            peakInstLo: 0,
            peakCumHi: 0,
            peakCumLo: 0,
            direction: direction,
            locale: Locale(identifier: "en")
        ) { _ in }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }

    private static func requireClose(_ actual: Double, _ expected: Double, _ message: String) throws {
        try require(actual.isFinite && abs(actual - expected) <= 1e-12,
                    "\(message): expected \(expected), received \(actual)")
    }

    private static func requireThrows(_ message: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            return
        }
        throw Failure(description: "Expected an error: \(message)")
    }

    private static func testDirection() throws {
        let moreOnes = try audit(ones: 40, total: 100, direction: 1)
        let moreZeros = try audit(ones: 40, total: 100, direction: 0)
        try requireClose(moreOnes.cumulativeZ, -2, "MORE 1s Z")
        try requireClose(moreZeros.cumulativeZ, 2, "MORE 0s Z")
        try requireClose(moreOnes.cumulativeP, 0.9772498680518208, "MORE 1s p")
        try requireClose(moreZeros.cumulativeP, 0.022750131948179216, "MORE 0s p")
        try requireClose(moreOnes.chi2, moreZeros.chi2, "Chi-square is direction independent")
        print("PASS: direction-specific Z and p")
    }

    private static func testEmptyInput() throws {
        let report = try audit()
        try requireClose(report.chi2, 0, "Empty chi-square")
        try requireClose(report.chi2P, 1, "Empty chi-square p")
        try requireClose(report.cumulativeZ, 0, "Empty cumulative Z")
        try require(report.analyzedBitCount == 0 && report.leveneSampleCount == 0,
                    "Empty input must not claim analyzed samples")
        try require(report.autocorrelation.isEmpty, "Empty input must not have autocorrelation")
        print("PASS: empty input remains finite and unanalysed")
    }

    private static func testMissingRawFile(in directory: URL) throws {
        try requireThrows("missing raw input") {
            _ = try audit(rawFile: directory.appendingPathComponent("missing-raw.txt"))
        }
        print("PASS: missing raw file error propagates")
    }

    private static func testReportWrites(in directory: URL) throws {
        let report = try audit(ones: 40, total: 100, direction: 0)
        let path = try AuditEngine.saveReport(
            report, to: directory.path, port: "test-port", direction: 0,
            chunkSize: 8192, sessionID: "fixed-session"
        )
        let url = URL(fileURLWithPath: path)
        try require(url.lastPathComponent == "rng_audit_fixed-session.txt", "Session filename mismatch")
        let original = try Data(contentsOf: url)
        let text = String(decoding: original, as: UTF8.self)
        try require(text.contains("Cumulative Z:   +2.0000"), "Saved report lost direction")
        try require(text.contains("Runs test:      Not run"), "Missing raw data must not claim a runs result")
        try require(text.contains("Approx Entropy: Not run"), "Missing raw data must not claim entropy")
        try require(text.contains("Hurst Exponent: Not run"), "Missing raw data must not claim Hurst")
        try require(text.contains("first 10,000,000 bits at most"), "Report must disclose its raw sampling limit")

        try requireThrows("existing report must not be overwritten") {
            _ = try AuditEngine.saveReport(
                try audit(), to: directory.path, port: "changed", direction: 1,
                chunkSize: 2048, sessionID: "fixed-session"
            )
        }
        try require(try Data(contentsOf: url) == original, "Collision changed the existing report bytes")
        try requireThrows("missing output directory") {
            _ = try AuditEngine.saveReport(
                report, to: directory.appendingPathComponent("missing-directory").path,
                port: "test-port", direction: 0, chunkSize: 8192, sessionID: "fixed-session"
            )
        }
        print("PASS: report saves, rejects collisions without changing bytes, and propagates output errors")
    }

    private static func oldEntropy(_ bits: [UInt8], m: Int = 2) -> Double {
        guard bits.count >= 100 else { return 0 }
        func phi(_ length: Int) -> Double {
            var counts: [String: Int] = [:]
            for start in 0...(bits.count - length) {
                let pattern = bits[start..<(start + length)].map(String.init).joined()
                counts[pattern, default: 0] += 1
            }
            let total = Double(bits.count - length + 1)
            return counts.values.reduce(0.0) { sum, count in
                let frequency = Double(count) / total
                return sum + frequency * log(frequency)
            }
        }
        return phi(m) - phi(m + 1)
    }

    private static func deterministicBits(count: Int) -> [UInt8] {
        var state: UInt64 = 0x123456789abcdef
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8((state >> 63) & 1)
        }
    }

    private static func testEntropyEquivalence(in directory: URL) throws {
        let fixtures: [(String, [UInt8])] = [
            ("constant-zero", [UInt8](repeating: 0, count: 100)),
            ("constant-one", [UInt8](repeating: 1, count: 199)),
            ("alternating", (0..<513).map { UInt8($0 % 2) }),
            ("deterministic", deterministicBits(count: 4096)),
            ("entropy-limit", deterministicBits(count: 100_005))
        ]
        let rawFile = directory.appendingPathComponent("entropy-raw.txt")
        for (name, bits) in fixtures {
            var data = Data()
            for (index, bit) in bits.enumerated() {
                data.append(bit + 0x30)
                if index % 64 == 63 { data.append(0x0a) }
            }
            try data.write(to: rawFile)
            let ones = bits.reduce(0) { $0 + Int($1) }
            let report = try audit(rawFile: rawFile, ones: ones, total: bits.count)
            let expected = oldEntropy(Array(bits.prefix(100_000)))
            try requireClose(report.approxEntropy, expected, "Entropy equivalence for \(name)")
            try require(report.analyzedBitCount == bits.count, "Raw bit count mismatch for \(name)")
            if name == "entropy-limit" {
                let reportPath = try AuditEngine.saveReport(
                    report, to: directory.path, port: "test-port", direction: 1,
                    chunkSize: 8192, sessionID: "entropy-limit"
                )
                let text = try String(contentsOfFile: reportPath, encoding: .utf8)
                try require(text.contains("Raw bits used: 100000 (first 100,000 at most)"),
                            "Entropy sampling limit must be accurately reported")
                try require(text.contains("Raw bits used: 100005 (first 500,000 at most)"),
                            "Hurst sample count must be accurately reported")
            }
        }
        print("PASS: entropy matches the previous string algorithm across 5 fixtures and the 100K cutoff")
    }

    // Keep the pre-optimization algorithm as an independent differential oracle.
    private static func legacyHurstExponent(bits: [UInt8], maxK: Int = 20) -> Double {
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
    
    private static func testHurstEquivalence(in directory: URL) throws {
        let fixtures: [(String, [UInt8])] = [
            ("empty", []),
            ("below-minimum", deterministicBits(count: 199)),
            ("minimum", deterministicBits(count: 200)),
            ("minimum-plus-one", deterministicBits(count: 201)),
            ("uneven-groups", deterministicBits(count: 509)),
            ("random", deterministicBits(count: 1000)),
            ("large", deterministicBits(count: 100_003)),
            ("sampling-limit", deterministicBits(count: 500_005)),
            ("all-zero", [UInt8](repeating: 0, count: 200)),
            ("all-one", [UInt8](repeating: 1, count: 1001)),
            ("alternating-even", (0..<200).map { UInt8($0 % 2) }),
            ("alternating-odd", (0..<501).map { UInt8($0 % 2) }),
            ("sparse-ones", (0..<10_007).map { UInt8($0 % 97 == 0 ? 1 : 0) }),
            ("two-blocks", [UInt8](repeating: 0, count: 100) + [UInt8](repeating: 1, count: 101))
        ]
        let rawFile = directory.appendingPathComponent("hurst-raw.txt")
        for (name, bits) in fixtures {
            try Data(bits.map { $0 + 0x30 }).write(to: rawFile)
            let report = try audit(rawFile: rawFile, ones: bits.reduce(0) { $0 + Int($1) }, total: bits.count)
            let expected = legacyHurstExponent(bits: Array(bits.prefix(500_000)))
            try require(report.hurstExponent.bitPattern == expected.bitPattern,
                        "Hurst result changed for \(name): expected \(expected), received \(report.hurstExponent)")
        }
        print("PASS: Hurst is bit-identical to the previous algorithm across 14 boundary, random, degenerate and sampling-limit fixtures")
    }

    private static func legacyAutocorrelation(_ bits: [UInt8], maxLag: Int = 50) -> [Int: Double] {
        let n = bits.count
        guard n > maxLag + 100 else { return [:] }
        let mean = Double(bits.reduce(0) { $0 + Int($1) }) / Double(n)
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

    private static func requireSameAutocorrelation(_ actual: [Int: Double], _ expected: [Int: Double], _ name: String) throws {
        try require(actual.count == expected.count, "Autocorrelation lag count changed for \(name)")
        for (lag, value) in expected {
            try require(actual[lag]?.bitPattern == value.bitPattern,
                        "Autocorrelation changed for \(name) at lag \(lag)")
        }
    }

    private static func testAutocorrelationEquivalence(in directory: URL) throws {
        let fixtures: [(String, [UInt8])] = [
            ("below-minimum", deterministicBits(count: 150)),
            ("minimum", deterministicBits(count: 151)),
            ("short-random", deterministicBits(count: 199)),
            ("short-alternating", (0..<201).map { UInt8($0 % 2) }),
            ("all-zero", [UInt8](repeating: 0, count: 1001)),
            ("all-one", [UInt8](repeating: 1, count: 10_001)),
            ("before-parallel", deterministicBits(count: 9999)),
            ("parallel-boundary", deterministicBits(count: 10_000)),
            ("after-parallel", deterministicBits(count: 10_001)),
            ("large-random", deterministicBits(count: 100_007)),
            ("two-blocks", [UInt8](repeating: 0, count: 10_000) + [UInt8](repeating: 1, count: 10_003)),
            ("biased", (0..<100_003).map { UInt8($0 % 97 == 0 ? 1 : 0) }),
            ("sampling-limit", deterministicBits(count: 10_000_005))
        ]
        let rawFile = directory.appendingPathComponent("autocorrelation-raw.txt")
        for (name, bits) in fixtures {
            try Data(bits.map { $0 + 0x30 }).write(to: rawFile)
            let report = try audit(rawFile: rawFile, ones: bits.reduce(0) { $0 + Int($1) }, total: bits.count)
            let analyzed = Array(bits.prefix(10_000_000))
            try require(report.analyzedBitCount == analyzed.count, "Autocorrelation sample limit changed for \(name)")
            try requireSameAutocorrelation(report.autocorrelation, legacyAutocorrelation(analyzed), name)
            if let maximum = report.autocorrelation.values.map({ abs($0) }).max() {
                try require(abs(report.maxACValue) == maximum && report.autocorrelation[report.maxACLag] == report.maxACValue,
                            "Autocorrelation maximum is inconsistent for \(name)")
            }
        }
        print("PASS: all 50 autocorrelation lags are bit-identical across 13 fixtures, including the parallel boundary and 10M-bit limit")
    }

    private static func testRawReadEquivalence(in directory: URL) throws {
        let bits = deterministicBits(count: 150_003)
        var noisy = Data()
        for (index, bit) in bits.enumerated() {
            noisy.append(bit + 0x30)
            if index.isMultiple(of: 47) { noisy.append(contentsOf: [0x20, 0x0a, 0x0d, 0x09, 0xff]) }
        }
        let noisyFile = directory.appendingPathComponent("noisy-raw.txt")
        let cleanFile = directory.appendingPathComponent("clean-raw.txt")
        try noisy.write(to: noisyFile)
        try Data(bits.map { $0 + 0x30 }).write(to: cleanFile)
        for limit in [0, 1, 99, 100, 150, 151, 199, 200, 9999, 10_000, 10_001, 100_000, 100_001, bits.count] {
            let ones = bits.prefix(limit).reduce(0) { $0 + Int($1) }
            let noisyReport = try audit(rawFile: noisyFile, ones: ones, total: limit)
            let cleanReport = try audit(rawFile: cleanFile, ones: ones, total: limit)
            try require(noisyReport.analyzedBitCount == limit, "Noisy input changed bit count at \(limit)")
            try requireSameAutocorrelation(noisyReport.autocorrelation, cleanReport.autocorrelation, "noisy-\(limit)")
            try require(noisyReport.runsZ?.bitPattern == cleanReport.runsZ?.bitPattern &&
                        noisyReport.runsP?.bitPattern == cleanReport.runsP?.bitPattern &&
                        noisyReport.approxEntropy.bitPattern == cleanReport.approxEntropy.bitPattern &&
                        noisyReport.hurstExponent.bitPattern == cleanReport.hurstExponent.bitPattern,
                        "Reading ignored bytes changed derived statistics at \(limit)")
        }
        try requireThrows("truncated raw data must remain an error") {
            _ = try audit(rawFile: noisyFile, ones: 0, total: bits.count + 1)
        }
        print("PASS: raw decoding preserves ignored-byte handling, chunk boundaries, exact limits and short-read errors")
    }

    private static func populationVariance(_ values: ArraySlice<Double>) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    private static func testLeveneVariance() throws {
        let values = (0..<41).map { Double(($0 * 19) % 37 - 18) / 7 }
        let report = try audit(values: values)
        let split = values.count / 2
        try requireClose(report.leveneVar1, populationVariance(values[..<split]), "First group variance")
        try requireClose(report.leveneVar2, populationVariance(values[split...]), "Second group variance")
        try require(report.leveneSampleCount == values.count, "Levene sample count mismatch")
        print("PASS: optimized Levene population variances match independent calculations")
    }

    private static func testFDistributionOracles() throws {
        // Independent Python oracles derived from NIST's F density after t = sqrt(F)
        // and theta = atan(t / sqrt(nu)):
        // P = 2*Gamma((nu+1)/2)/(sqrt(pi)*Gamma(nu/2)) * integral cos(theta)^(nu-1) dtheta.
        // Even nu: exact finite polynomial antiderivative in sin(theta), evaluated with
        // Decimal precision max(100, nu/2+60), independent of the beta continued fraction.
        // Odd nu: Simpson quadrature; doubling 10K to 20K intervals changed P < 1e-12
        // (40K to 80K for nu=999). Includes small probabilities, both CF branches,
        // odd/even degrees of freedom, and values near the 0.05 decision boundary.
        let fixtures: [(Double, Int, Double)] = [
            (1e-12, 20, 0.9999992120228286),
            (0.1, 20, 0.75510627752306669),
            (1, 20, 0.32925657717170909),
            (4, 20, 0.059265535446570476),
            (25, 20, 6.873028579542197e-05),
            (100, 20, 3.163781758714388e-09),
            (1e-12, 22, 0.99999921112790813),
            (0.1, 22, 0.7548104262044385),
            (1, 22, 0.3281832618806706),
            (4, 22, 0.057995701702496079),
            (25, 22, 5.2684120757182024e-05),
            (100, 22, 1.2071612749598836e-09),
            (1e-12, 100, 0.99999920410762611),
            (0.1, 100, 0.75248875419941053),
            (1, 100, 0.31972415578412339),
            (4, 100, 0.048212178731133683),
            (25, 100, 2.4501734135038002e-06),
            (100, 100, 9.9016889845941392e-17),
            (1e-12, 1000, 0.99999920231488537),
            (0.1, 1000, 0.75189562726070902),
            (1, 1000, 0.31755241808467233),
            (4, 1000, 0.045770346493251637),
            (25, 1000, 6.7672563646486306e-07),
            (100, 1000, 1.6670702958600067e-22),
            (0.1, 19, 0.75527736582491711),
            (4, 19, 0.060002036386098211),
            (25, 19, 7.9499749984176222e-05),
            (0.1, 21, 0.75495136050634981),
            (4, 21, 0.058600012048710473),
            (25, 21, 5.993763245513261e-05),
            (0.1, 99, 0.7524954026855567),
            (4, 99, 0.04823969337263212),
            (25, 99, 2.4813960130415642e-06),
            (0.1, 999, 0.7518956933111948),
            (4, 999, 0.04577061697376727),
            (25, 999, 6.768361895804668e-07)
        ]
        for (f, df, expected) in fixtures {
            guard let actual = AuditEngine.fSurvival(statistic: f, denominatorDF: df) else {
                throw Failure(description: "F(1,\(df)) failed at \(f)")
            }
            try require(abs(actual - expected) <= max(1e-30, expected * 5e-10),
                        "F(1,\(df)) at \(f): expected \(expected), received \(actual)")
        }
        try require(AuditEngine.fSurvival(statistic: 0, denominatorDF: 20) == 1, "F zero boundary")
        try require(AuditEngine.fSurvival(statistic: -1, denominatorDF: 20) == nil, "Negative F unavailable")
        try require(AuditEngine.fSurvival(statistic: .nan, denominatorDF: 20) == nil, "NaN F unavailable")
        try require(AuditEngine.fSurvival(statistic: 1, denominatorDF: 0) == nil, "Invalid df unavailable")
        print("PASS: F upper tails match 36 independent integral oracles and 4 boundary cases")
    }

    private static func testLeveneReferenceCases() throws {
        let oddGroup = (-5...5).map(Double.init)
        let odd = try audit(values: oddGroup + oddGroup.map { 1.75 * $0 })
        guard let oddF = odd.leveneF, let oddP = odd.leveneP else {
            throw Failure(description: "Odd-group Levene result missing")
        }
        try requireClose(oddF, 4.01985111662531, "Odd-group Levene F")
        try requireClose(oddP, 0.05869219254249942, "Odd-group Levene finite-df p")
        try require(oddP > 0.05, "Finite-df correction must preserve this nonsignificant result")

        let evenFirst: [Double] = [0, 1, 1, 2, 3, 4, 8, 9, 9, 10, 11, 20]
        let evenSecond: [Double] = [-5, -4, -2, 0, 0, 1, 1, 2, 6, 8, 10, 12]
        let even = try audit(values: evenFirst + evenSecond)
        guard let evenF = even.leveneF, let evenP = even.leveneP else {
            throw Failure(description: "Even-group Levene result missing")
        }
        try requireClose(evenF, 0.1717107359031542, "Even-group averaged-median F")
        try requireClose(evenP, 0.6826083952705625, "Even-group averaged-median p")
        print("PASS: odd/even group medians and Levene p match independent reference cases")
    }

    private static func testUnavailableStatistics(in directory: URL) throws {
        let first = (0..<12).map { $0.isMultiple(of: 2) ? -1.0 : 1.0 }
        let second = first.map { 2 * $0 }
        let degenerate = try audit(values: first + second)
        try require(degenerate.leveneF == nil && degenerate.leveneP == nil,
                    "Zero within-group deviation variance must not claim F=0, p=1")
        try requireClose(degenerate.leveneVar1, 1, "Degenerate first variance preserved")
        try requireClose(degenerate.leveneVar2, 4, "Degenerate second variance preserved")
        let reportPath = try AuditEngine.saveReport(
            degenerate, to: directory.path, port: "test-port", direction: 1,
            chunkSize: 8192, sessionID: "degenerate-levene"
        )
        let text = try String(contentsOfFile: reportPath, encoding: .utf8)
        try require(text.contains("Levene's Test:  Unavailable"), "Degenerate Levene report must say unavailable")
        try require(text.contains("First half var:  1.0000") && text.contains("Second half var: 4.0000"),
                    "Degenerate report must retain group variances")

        for bit in [UInt8(0), UInt8(1)] {
            let rawFile = directory.appendingPathComponent("constant-\(bit).txt")
            try Data(repeating: 0x30 + bit, count: 1000).write(to: rawFile)
            let report = try audit(rawFile: rawFile, ones: Int(bit) * 1000, total: 1000)
            try require(report.runsZ == nil && report.runsP == nil,
                        "A constant bitstream must not claim a passing runs test")
            let path = try AuditEngine.saveReport(
                report, to: directory.path, port: "test-port", direction: 1,
                chunkSize: 8192, sessionID: "constant-\(bit)"
            )
            let reportText = try String(contentsOfFile: path, encoding: .utf8)
            try require(reportText.contains("Runs test:      Unavailable"),
                        "Constant bitstream report must say runs unavailable")
        }
        print("PASS: degenerate Levene retains variances, and single-valued runs are unavailable")
    }

    private static func benchmarkLevene() throws {
        print("Levene scaling benchmark (whole audit without raw data; includes median sorting):")
        for count in [25_000, 50_000, 100_000] {
            let values = (0..<count).map { Double(($0 * 7919) % 10007 - 5003) / 1500 }
            var elapsed: [Double] = []
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                let report = try audit(values: values)
                let end = DispatchTime.now().uptimeNanoseconds
                try require(report.leveneF?.isFinite == true && report.leveneVar1 > 0,
                            "Benchmark must compute a nondegenerate result")
                elapsed.append(Double(end - start) / 1_000_000)
            }
            let median = elapsed.sorted()[1]
            print(String(format: "  %d samples: %.3f ms median of 3", count, median))
        }
    }
}
