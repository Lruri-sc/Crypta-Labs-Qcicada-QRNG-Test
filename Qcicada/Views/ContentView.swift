// ContentView.swift
// Qcicada

import SwiftUI
import AppKit

struct ContentView: View {
    @State private var engine = RandomTestEngine()
    @State private var settings = AppSettings()
    @State private var availablePorts: [String] = []
    @State private var settingsWindow: SettingsWindowController?
    @State private var session: SessionController?
    @State private var isWindowClosing = false
    private var showAuditProgress: Bool { session?.isSaving ?? false }
    private var auditStatus: String { session?.auditStatus ?? "" }
    private var auditComplete: Bool { session?.auditComplete ?? false }
    private var lastAuditPath: String { session?.lastAuditPath ?? "" }

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
                        WaveformArea(engine: engine, settings: settings,
                                     showAuditProgress: showAuditProgress, auditStatus: auditStatus)
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
            if session == nil { session = SessionController(engine: engine, settings: settings) }
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
            settingsWindow?.close()
            settingsWindow = nil
            session?.detach()
        }
        .background(
            WindowCloseInterceptor { closeNow in
                requestWindowClose(closeNow: closeNow)
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
                if settingsWindow == nil {
                    settingsWindow = SettingsWindowController(settings: settings)
                }
                settingsWindow?.open()
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
                    session?.start()
                } label: {
                    Label(LocalizedStringResource("main.start"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.regular)
                
                Button {
                    session?.disconnect()
                } label: {
                    Label(LocalizedStringResource("main.disconnect"), systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        } else {
            Button {
                session?.connect()
            } label: {
                Label(LocalizedStringResource("main.connect"), systemImage: "cable.connector")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(engine.portPath.isEmpty)
        }
    }
    
    // MARK: - Stop + Audit + Export
    
    private func stopAndAudit() {
        session?.stopAndSave()
    }

    private func requestWindowClose(closeNow: @escaping () -> Void) {
        guard !isWindowClosing else { return }
        guard let session else { closeNow(); return }
        isWindowClosing = true
        session.prepareForShutdown { saved in
            if saved { closeNow() }
            else {
                isWindowClosing = false
                session.resumeAfterCancelledShutdown()
            }
        }
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
            Text(
                String(
                    format: String(localized: "ready.detail", locale: settings.stringResolutionLocale ?? .current),
                    locale: settings.localeForEnvironment,
                    arguments: [engine.deviceSerial as NSString, engine.readyBytes]
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
}
