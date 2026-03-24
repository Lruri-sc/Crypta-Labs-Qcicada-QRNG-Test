// ContentView.swift
// Qcicada

import SwiftUI
import AppKit

struct ContentView: View {
    @State private var engine = RandomTestEngine()
    @State private var settings = AppSettings()
    @State private var availablePorts: [String] = []
    @State private var showSettings = false
    @State private var showAuditProgress = false
    @State private var auditStatus = ""
    @State private var auditComplete = false
    @State private var lastAuditPath = ""
    @State private var isClosingFlow = false
    @State private var pendingWindowClose: (() -> Void)?
    
    var body: some View {
        ZStack {
            // Native blur background
            if settings.useNativeBlur {
                VisualEffectView(
                    material: settings.windowMaterial,
                    blendingMode: .behindWindow,
                    state: .active
                )
                .ignoresSafeArea()
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
            }
            
            VStack(spacing: 0) {
                toolbar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(toolbarBackground)
                
                if settings.showDividers {
                    Divider()
                        .opacity(settings.dividerOpacity)
                }
                
                Group {
                    if engine.isRunning || showAuditProgress {
                        waveformArea
                            .padding(16)
                    } else if engine.isConnected {
                        readyView
                    } else {
                        connectView
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: engine.isRunning)
                .animation(.easeInOut(duration: 0.25), value: engine.isConnected)
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .environment(\.locale, settings.localeForEnvironment)
        .preferredColorScheme(settings.resolvedColorScheme)
        .onAppear {
            RandomTestEngine.uiLocale = settings.stringResolutionLocale
            availablePorts = RandomTestEngine.availablePorts()
            if let first = availablePorts.first {
                engine.portPath = first
            }
        }
        .onChange(of: settings.language) { _, _ in
            RandomTestEngine.uiLocale = settings.stringResolutionLocale
        }
        .onDisappear {
            engine.stop()
            engine.disconnect()
            engine.releaseMemory()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings)
                .environment(\.locale, settings.localeForEnvironment)
        }
        .background(
            WindowCloseInterceptor { _ in
                requestWindowClose {
                    NSApplication.shared.terminate(nil)
                }
            }
        )
    }
    
    // MARK: - Toolbar Background
    
    @ViewBuilder
    private var toolbarBackground: some View {
        if settings.useNativeBlur {
            VisualEffectView(
                material: settings.toolbarMaterial,
                blendingMode: .withinWindow,
                state: .active
            )
        } else {
            Color.clear
        }
    }
    
    // MARK: - Toolbar
    
    private var toolbar: some View {
        HStack(spacing: 12) {
            // App identity
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.tint)
            
            Text(LocalizedStringResource("app.title"))
                .font(.system(size: 14, weight: .semibold))
            
            Spacer()
            
            // Port selector
            if !engine.isRunning {
                HStack(spacing: 6) {
                    Picker(selection: $engine.portPath) {
                        if availablePorts.isEmpty {
                            Text(LocalizedStringResource("main.no_device")).tag("")
                        }
                        ForEach(availablePorts, id: \.self) { port in
                            Text(port.replacingOccurrences(of: "/dev/", with: ""))
                                .tag(port)
                        }
                    } label: { EmptyView() }
                    .frame(maxWidth: 200)
                    
                    Button {
                        availablePorts = RandomTestEngine.availablePorts()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help(LocalizedStringResource("help.refresh_ports"))
                }
            }
            
            // Direction
            Picker(selection: $engine.direction) {
                Text(LocalizedStringResource("direction.more_ones")).tag(1)
                Text(LocalizedStringResource("direction.more_zeros")).tag(0)
            } label: { EmptyView() }
            .pickerStyle(.segmented)
            .frame(width: 136)
            .disabled(engine.isRunning)
            
            // Chunk size
            if !engine.isRunning {
                Picker(selection: $engine.chunkSize) {
                    Text("2K").tag(2048)
                    Text("4K").tag(4096)
                    Text("8K").tag(8192)
                    Text("16K").tag(16384)
                } label: { EmptyView() }
                .pickerStyle(.segmented)
                .frame(width: 176)
            }
            
            // Action buttons
            connectionButtons
            
            // Settings
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help(LocalizedStringResource("help.settings"))
            
        }
    }
    
    @ViewBuilder
    private var connectionButtons: some View {
        if engine.isRunning {
            Button {
                stopAndAudit()
            } label: {
                Label(LocalizedStringResource("main.stop"), systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.regular)
        } else if engine.isConnected {
            HStack(spacing: 8) {
                Button {
                    engine.exportDirectory = settings.exportPath
                    engine.start()
                } label: {
                    Label(LocalizedStringResource("main.start"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.regular)
                
                Button {
                    engine.disconnect()
                } label: {
                    Label(LocalizedStringResource("main.disconnect"), systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        } else {
            Button {
                engine.connect()
            } label: {
                Label(LocalizedStringResource("main.connect"), systemImage: "cable.connector")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(engine.portPath.isEmpty)
        }
    }
    
    // MARK: - Stop + Audit + Export
    
    private func stopAndAudit(completion: (() -> Void)? = nil) {
        let izSnapshot = Array(engine.izFull)
        let czSnapshot = Array(engine.czFull)
        let varSnapshot = Array(engine.varFull)
        let rawFilePath = engine.currentRawFilePath
        let totalOnes = engine.totalOnes
        let totalBits = engine.totalBits
        let sampleCount = engine.sampleCount
        let izMean = engine.izMean
        let izVariance = engine.izVariance
        let peakInstHi = engine.peakInstHi
        let peakInstLo = engine.peakInstLo
        let peakCumHi = engine.peakCumHi
        let peakCumLo = engine.peakCumLo
        let exportPath = settings.exportPath
        let port = engine.portPath
        let direction = engine.direction
        let chunkSize = engine.chunkSize
        let doPlot = settings.autoSavePlot
        let doAudit = settings.autoSaveAudit
        let loc = settings.stringResolutionLocale
        
        engine.stop()
        
        guard doPlot || doAudit else {
            auditComplete = true
            completion?()
            return
        }
        
        showAuditProgress = true
        auditComplete = false
        auditStatus = String(localized: "audit.saving", locale: loc ?? .current)
        
        DispatchQueue.global(qos: .userInitiated).async {
            if doPlot && !izSnapshot.isEmpty {
                DispatchQueue.main.async { auditStatus = String(localized: "audit.status.plot", locale: loc ?? .current) }
                PlotExporter.saveFullPlot(
                    iz: izSnapshot, cz: czSnapshot, vr: varSnapshot,
                    stats: (sampleCount, totalBits, totalOnes, peakInstHi, peakInstLo, peakCumHi, peakCumLo, izMean, izVariance),
                    to: exportPath
                )
            }
            
            if doAudit {
                DispatchQueue.main.async { auditStatus = String(localized: "audit.status.run", locale: loc ?? .current) }
                let report = AuditEngine.runAudit(
                    rawFilePath: rawFilePath,
                    izValues: izSnapshot,
                    totalOnes: totalOnes,
                    totalBits: totalBits,
                    sampleCount: sampleCount,
                    izMean: izMean,
                    izVariance: izVariance,
                    peakInstHi: peakInstHi,
                    peakInstLo: peakInstLo,
                    peakCumHi: peakCumHi,
                    peakCumLo: peakCumLo,
                    locale: loc
                ) { status in
                    DispatchQueue.main.async { auditStatus = status }
                }
                
                let auditPath = AuditEngine.saveReport(
                    report, to: exportPath, port: port,
                    direction: direction, chunkSize: chunkSize
                )
                
                DispatchQueue.main.async { lastAuditPath = auditPath }
            }
            
            DispatchQueue.main.async {
                auditComplete = true
                showAuditProgress = false
                completion?()
                
                // If the user clicked the red close button during audit, close now.
                if let pendingClose = pendingWindowClose {
                    pendingWindowClose = nil
                    performCleanupAndClose(pendingClose)
                }
            }
        }
    }
    
    private func requestWindowClose(closeNow: @escaping () -> Void) {
        if isClosingFlow { return }
        
        if showAuditProgress {
            // Audit is already saving in background; close after it completes.
            isClosingFlow = true
            pendingWindowClose = closeNow
            return
        }
        
        isClosingFlow = true
        if engine.isRunning {
            stopAndAudit {
                performCleanupAndClose(closeNow)
            }
        } else {
            performCleanupAndClose(closeNow)
        }
    }
    
    private func performCleanupAndClose(_ closeNow: @escaping () -> Void) {
        engine.stop()
        engine.disconnect()
        engine.releaseMemory()
        isClosingFlow = false
        closeNow()
    }
    
    // MARK: - Connect View
    
    private var connectView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "cable.connector.slash")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text(LocalizedStringResource("connect.title"))
                .font(.title3.weight(.medium))
            Text(LocalizedStringResource("connect.choose_port"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let error = engine.connectionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        .red.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Ready View
    
    private var readyView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text(LocalizedStringResource("ready.connected"))
                .font(.title3.weight(.medium))
            Text(
                String(
                    format: String(localized: "ready.detail", locale: settings.stringResolutionLocale ?? .current),
                    locale: settings.localeForEnvironment,
                    arguments: [engine.deviceSerial as NSString, NSNumber(value: engine.readyBytes)]
                )
            )
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            
            if auditComplete && !lastAuditPath.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Text(LocalizedStringResource("ready.audit_saved"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
            
            Text(LocalizedStringResource("ready.hint_start"))
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Waveform Area
    
    private var waveformArea: some View {
        VStack(spacing: 10) {
            statsBar
            
            if showAuditProgress {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(auditStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Instant Z
                VStack(alignment: .leading, spacing: 4) {
                    chartHeader(
                        title: tx("chart.header.instant_z"),
                        value: engine.instantZ,
                        hi: engine.peakInstHi,
                        lo: engine.peakInstLo,
                        color: settings.instantZColor
                    )
                    WaveformChart(
                        title: tx("chart.instant_z"),
                        data: engine.izHistory,
                        color: settings.instantZColor,
                        lineWidth: settings.chartLineWidth,
                        thresholds: [1.96, 2.58],
                        thresholdColor: settings.thresholdColor,
                        referenceValue: 0,
                        historySize: engine.historySize,
                        chartBackground: settings.chartBackground
                    )
                    .frame(maxHeight: .infinity)
                }
                
                // Inset divider (Apple style: not edge-to-edge)
                if settings.showDividers {
                    Divider()
                        .opacity(settings.dividerOpacity)
                        .padding(.horizontal, 4)
                }
                
                // Cumulative Z
                VStack(alignment: .leading, spacing: 4) {
                    chartHeader(
                        title: tx("chart.header.cumulative_z"),
                        value: engine.cumulativeZ,
                        hi: engine.peakCumHi,
                        lo: engine.peakCumLo,
                        color: settings.cumulativeZColor
                    )
                    WaveformChart(
                        title: tx("chart.cumulative_z"),
                        data: engine.czHistory,
                        color: settings.cumulativeZColor,
                        lineWidth: settings.chartLineWidth,
                        thresholds: [1.96],
                        thresholdColor: settings.thresholdColor,
                        referenceValue: 0,
                        historySize: engine.historySize,
                        chartBackground: settings.chartBackground
                    )
                    .frame(maxHeight: .infinity)
                }
                
                if settings.showDividers {
                    Divider()
                        .opacity(settings.dividerOpacity)
                        .padding(.horizontal, 4)
                }
                
                // Variance
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(LocalizedStringResource("chart.variance_axis"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(settings.varianceColor)
                        StatPill(label: tx("pill.var"), value: String(format: "%.4f", engine.izVariance), color: settings.varianceColor)
                        StatPill(
                            label: tx("pill.z_var"),
                            value: String(format: "%+.2f", engine.varianceZScore),
                            color: abs(engine.varianceZScore) > 1.96 ? .red : .secondary
                        )
                    }
                    WaveformChart(
                        title: tx("chart.variance"),
                        data: engine.varHistory,
                        color: settings.varianceColor,
                        lineWidth: settings.chartLineWidth,
                        referenceValue: 1.0,
                        historySize: engine.historySize,
                        chartBackground: settings.chartBackground
                    )
                    .frame(height: 80)
                }
            }
        }
    }
    
    // MARK: - Stats Bar
    
    private var statsBar: some View {
        HStack(spacing: 6) {
            StatPill(label: tx("pill.sample_index"), value: "\(engine.sampleCount)", color: .primary)
            StatPill(label: tx("pill.bits"), value: formatNumber(engine.totalBits), color: .primary)
            StatPill(
                label: tx("pill.ones_pct"),
                value: engine.totalBits > 0
                    ? String(format: "%.4f%%", Double(engine.totalOnes) / Double(engine.totalBits) * 100)
                    : tx("placeholder.em_dash"),
                color: .primary
            )
            StatPill(label: tx("pill.mean"), value: String(format: "%+.3f", engine.izMean), color: .secondary)
            Spacer()
            significanceLabel
        }
    }
    
    @ViewBuilder
    private var significanceLabel: some View {
        let z = engine.cumulativeZ
        let label = localizedSignificance(z)
        if !label.isEmpty {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(significanceColor(z))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(significanceColor(z).opacity(0.12), in: Capsule())
        }
    }
    
    private func chartHeader(title: String, value: Double, hi: Double, lo: Double, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
            StatPill(label: tx("pill.z"), value: String(format: "%+.2f", value), color: color)
            StatPill(label: tx("pill.high"), value: String(format: "%+.2f", hi > -900 ? hi : 0), color: .green)
            StatPill(label: tx("pill.low"), value: String(format: "%+.2f", lo < 900 ? lo : 0), color: .red)
        }
    }
    
    private func significanceColor(_ z: Double) -> Color {
        let az = abs(z)
        if az >= 3.29 { return .red }
        if az >= 2.58 { return .orange }
        if az >= 1.96 { return .yellow }
        if az >= 1.645 { return .mint }
        return .secondary
    }
    
    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
        return "\(n)"
    }
    
    private func tx(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), locale: settings.stringResolutionLocale ?? .current)
    }
    
    private func localizedSignificance(_ z: Double) -> String {
        let code = RandomTestEngine.interpret(z)
        switch code {
        case "EXTREME": return tx("sig.extreme")
        case "VERY SIG": return tx("sig.very_significant")
        case "SIGNIF": return tx("sig.significant")
        case "MARGINAL": return tx("sig.marginal")
        case "trend": return tx("sig.trend")
        default: return code
        }
    }
}
