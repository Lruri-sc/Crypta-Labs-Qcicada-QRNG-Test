import Foundation
import Observation

/// One lifecycle for Stop, device failure, window close, and application Quit.
@MainActor
@Observable
final class SessionController: ShutdownParticipant {
    let engine: RandomTestEngine
    let settings: AppSettings
    private(set) var isSaving = false
    private(set) var auditStatus = ""
    private(set) var auditComplete = false
    private(set) var lastAuditPath = ""
    private(set) var isShuttingDown = false
    @ObservationIgnored private let exporter: any SessionExporting
    @ObservationIgnored private let shutdown: ApplicationShutdownCoordinator
    @ObservationIgnored private var pending: SessionExportRequest?
    @ObservationIgnored private var handledSessionID: UUID?
    @ObservationIgnored private var exportAttemptID: UUID?
    @ObservationIgnored private var saveWaiters: [(Bool) -> Void] = []
    @ObservationIgnored private var shutdownWaiters: [(Bool) -> Void] = []
    @ObservationIgnored private var shutdownAttemptActive = false
    @ObservationIgnored private var closeReady = false

    init(engine: RandomTestEngine, settings: AppSettings,
         exporter: any SessionExporting = SessionExporter(),
         shutdown: ApplicationShutdownCoordinator? = nil) {
        let shutdown = shutdown ?? .shared
        self.engine = engine
        self.settings = settings
        self.exporter = exporter
        self.shutdown = shutdown
        engine.onSessionFinished = { [weak self] snapshot in self?.receive(snapshot) }
        shutdown.register(self)
    }

    func connect() {
        guard !isSaving, !isShuttingDown, !shutdown.isTerminating else { return }
        engine.connect()
    }

    func start() {
        guard !isSaving, !isShuttingDown, !shutdown.isTerminating,
              !engine.isBusy, !engine.isRunning else { return }
        if pending != nil {
            stopAndSave { [weak self] saved in if saved { self?.start() } }
            return
        }
        auditComplete = false
        lastAuditPath = ""
        closeReady = false
        engine.exportDirectory = settings.exportPath
        engine.start()
    }

    func disconnect() {
        guard !isSaving, !isShuttingDown, !shutdown.isTerminating else { return }
        engine.disconnect()
    }

    func stopAndSave(completion: ((Bool) -> Void)? = nil) {
        if let completion { saveWaiters.append(completion) }
        guard !isSaving else { return }
        if engine.isRunning {
            isSaving = true
            auditComplete = false
            auditStatus = String(localized: "audit.saving", locale: settings.stringResolutionLocale ?? .current)
            engine.stop() // receive() starts export after all accepted data has been sealed.
        } else if pending != nil {
            beginExport()
        } else if let snapshot = engine.completedSession, snapshot.id != handledSessionID {
            receive(snapshot)
        } else {
            finishSaveWaiters(success: true)
        }
    }

    private func receive(_ snapshot: CompletedSessionSnapshot) {
        guard snapshot.id != handledSessionID else { return }
        handledSessionID = snapshot.id
        auditComplete = false
        lastAuditPath = ""
        pending = SessionExportRequest(snapshot: snapshot, savePlot: settings.autoSavePlot,
                                       saveAudit: settings.autoSaveAudit, locale: settings.stringResolutionLocale)
        beginExport()
    }

    private func beginExport() {
        guard let request = pending else { finishSaveWaiters(success: true); return }
        let needsPlot = request.savePlot && request.snapshot.sampleCount > 0 && request.savedPlotPath == nil
        let needsAudit = request.saveAudit && request.savedAuditPath == nil
        guard request.snapshot.fileID != nil, needsPlot || needsAudit else {
            pending = nil
            isSaving = false
            auditComplete = true
            lastAuditPath = request.savedAuditPath ?? ""
            engine.connectionError = request.snapshot.failure
            finishSaveWaiters(success: true)
            return
        }
        isSaving = true
        let attempt = UUID()
        exportAttemptID = attempt
        auditStatus = String(localized: "audit.saving", locale: request.locale ?? .current)
        let exporter = exporter
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = exporter.export(request) { status in
                DispatchQueue.main.async {
                    guard let self, self.exportAttemptID == attempt, self.isSaving else { return }
                    self.auditStatus = status
                }
            }
            DispatchQueue.main.async {
                guard let self, self.exportAttemptID == attempt, self.isSaving else { return }
                self.isSaving = false
                self.exportAttemptID = nil
                self.lastAuditPath = result.auditPath ?? ""
                self.auditComplete = result.succeeded
                if result.succeeded {
                    self.pending = nil
                    self.engine.connectionError = request.snapshot.failure
                } else {
                    self.pending?.savedPlotPath = result.plotPath
                    self.pending?.savedAuditPath = result.auditPath
                    self.engine.connectionError = ([request.snapshot.failure].compactMap { $0 } + result.errors)
                        .joined(separator: "\n")
                }
                self.finishSaveWaiters(success: result.succeeded)
            }
        }
    }

    private func finishSaveWaiters(success: Bool) {
        let waiters = saveWaiters
        saveWaiters.removeAll()
        waiters.forEach { $0(success) }
    }

    func prepareForShutdown(completion: @escaping (Bool) -> Void) {
        isShuttingDown = true
        if closeReady { completion(true); return }
        shutdownWaiters.append(completion)
        guard !shutdownAttemptActive else { return }
        shutdownAttemptActive = true
        stopAndSave { [self] saved in
            guard saved else { finishShutdown(success: false); return }
            engine.disconnect { [self] in
                closeReady = true
                finishShutdown(success: true)
            }
        }
    }

    private func finishShutdown(success: Bool) {
        shutdownAttemptActive = false
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0(success) }
    }

    func resumeAfterCancelledShutdown() {
        isShuttingDown = false
        closeReady = false
    }

    func detach() {
        prepareForShutdown { [self] saved in
            guard saved else { resumeAfterCancelledShutdown(); return }
            engine.releaseMemory()
            shutdown.unregister(self)
        }
    }
}
