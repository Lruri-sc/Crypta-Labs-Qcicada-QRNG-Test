import Foundation

nonisolated struct SessionExportRequest: Sendable {
    let snapshot: CompletedSessionSnapshot
    let savePlot: Bool
    let saveAudit: Bool
    let locale: Locale?
    var savedPlotPath: String?
    var savedAuditPath: String?
}

nonisolated struct SessionExportResult: Sendable {
    var plotPath: String?
    var auditPath: String?
    var errors: [String] = []
    var succeeded: Bool { errors.isEmpty }
}

nonisolated protocol SessionExporting: Sendable {
    func export(_ request: SessionExportRequest, progress: @escaping @Sendable (String) -> Void) -> SessionExportResult
}

nonisolated struct SessionExporter: SessionExporting {
    func export(_ request: SessionExportRequest, progress: @escaping @Sendable (String) -> Void) -> SessionExportResult {
        let s = request.snapshot
        var result = SessionExportResult(plotPath: request.savedPlotPath, auditPath: request.savedAuditPath)
        // File creation can fail before a session exists; there is then no accepted data to export.
        guard let fileID = s.fileID else { return result }
        if request.savePlot, s.sampleCount > 0, result.plotPath == nil {
            progress(String(localized: "audit.status.plot", locale: request.locale ?? .current))
            do {
                result.plotPath = try PlotExporter.saveFullPlot(
                    iz: s.iz, cz: s.cz, vr: s.variance,
                    stats: (s.sampleCount, s.totalBits, s.totalOnes, s.peakInstHi, s.peakInstLo,
                            s.peakCumHi, s.peakCumLo, s.izMean, s.izVariance),
                    to: s.directory, sessionID: fileID
                )
            } catch { result.errors.append(error.localizedDescription) }
        }
        if request.saveAudit, result.auditPath == nil {
            progress(String(localized: "audit.status.run", locale: request.locale ?? .current))
            do {
                var report: AuditReport
                do {
                    report = try audit(s, rawPath: s.rawFilePath, locale: request.locale, progress: progress)
                } catch {
                    // Preserve usable summary statistics when the raw file cannot be read.
                    report = try audit(s, rawPath: nil, locale: request.locale, progress: progress)
                    report.rawDataFailure = error.localizedDescription
                }
                report.sessionFailure = s.failure
                result.auditPath = try AuditEngine.saveReport(
                    report, to: s.directory, port: s.port, direction: s.direction,
                    chunkSize: s.chunkSize, sessionID: fileID
                )
            } catch { result.errors.append(error.localizedDescription) }
        }
        return result
    }

    private func audit(_ s: CompletedSessionSnapshot, rawPath: String?, locale: Locale?,
                       progress: @escaping @Sendable (String) -> Void) throws -> AuditReport {
        try AuditEngine.runAudit(
            rawFilePath: rawPath, izValues: s.iz, totalOnes: s.totalOnes,
            totalBits: s.totalBits, sampleCount: s.sampleCount, izMean: s.izMean,
            izVariance: s.izVariance, peakInstHi: s.peakInstHi, peakInstLo: s.peakInstLo,
            peakCumHi: s.peakCumHi, peakCumLo: s.peakCumLo,
            direction: s.direction, locale: locale, progress: progress
        )
    }
}
