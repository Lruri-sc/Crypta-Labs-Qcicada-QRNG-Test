import Foundation
import Darwin

/// A process-local file-size limit exercises an actual interrupted write without
/// filling the user's disk or changing any system-wide setting.
@main
struct AuditWriteFailureTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QcicadaAuditWriteFailure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let filename = "rng_audit_retry.txt"
        var report = AuditReport()
        report.sessionFailure = String(repeating: "interrupted session ", count: 1024)
        var original = rlimit()
        precondition(getrlimit(RLIMIT_FSIZE, &original) == 0)
        let previousHandler = signal(SIGXFSZ, SIG_IGN)
        defer { signal(SIGXFSZ, previousHandler) }
        var limited = original
        limited.rlim_cur = min(original.rlim_cur, 1024)
        precondition(setrlimit(RLIMIT_FSIZE, &limited) == 0)
        var writeFailed = false
        do {
            defer { precondition(setrlimit(RLIMIT_FSIZE, &original) == 0) }
            do {
                _ = try AuditEngine.saveReport(report, to: directory.path, port: "test",
                                               direction: 1, chunkSize: 8192, sessionID: "retry")
            } catch { writeFailed = true }
        }
        precondition(writeFailed)
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path))
        let afterFailure = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(afterFailure.isEmpty, "Failed write left staging files behind")
        let saved = try AuditEngine.saveReport(report, to: directory.path, port: "test",
                                               direction: 1, chunkSize: 8192, sessionID: "retry")
        precondition(URL(fileURLWithPath: saved).lastPathComponent == filename)
        let text = try String(contentsOfFile: saved, encoding: .utf8)
        precondition(text.contains(report.sessionFailure!))
        let afterSuccess = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(afterSuccess == [filename])
        print("PASS: real partial report-write failure leaves no final/temp file; identical session retry succeeds")
    }
}
