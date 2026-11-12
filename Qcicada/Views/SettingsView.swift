// SettingsView.swift
// Qcicada

import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let pane: SettingsPane
    let width: CGFloat
    /// The height the window gives this pane. `nil` lays the pane out at its natural
    /// height, which is how the window controller measures it.
    let height: CGFloat?
    let chooseFolder: () -> Void
    let windowConfigurationChanged: () -> Void

    var body: some View {
        Group {
            switch pane {
            case .appearance: appearanceTab
            case .charts: chartsTab
            case .export: exportTab
            }
        }
        .environment(\.locale, settings.localeForEnvironment)
        .preferredColorScheme(settings.resolvedColorScheme)
        .fixedSize(horizontal: false, vertical: height == nil)
        .frame(width: width, height: height)
        .onChange(of: settings.language) { _, _ in windowConfigurationChanged() }
        .onChange(of: settings.colorSchemeOverride) { _, _ in windowConfigurationChanged() }
    }

    // MARK: - 外观
    
    private var appearanceTab: some View {
        Form {
            Section {
                ThemeListView(settings: settings)
            } header: {
                Text(LocalizedStringResource("settings.theme_style"))
            }
            
            Section {
                Picker(selection: $settings.colorSchemeOverride) {
                    ForEach(AppSettings.ColorSchemeOption.allCases) { option in
                        Text(option.localizedTitle).tag(option)
                    }
                } label: {
                    Text(LocalizedStringResource("settings.appearance_mode"))
                }
                .pickerStyle(.segmented)
            } header: {
                Text(LocalizedStringResource("settings.color_mode_section"))
            }
            
            Section {
                Picker(selection: $settings.language) {
                    ForEach(AppSettings.Language.allCases) { lang in
                        Text(lang.localizedTitle).tag(lang)
                    }
                } label: {
                    Text(LocalizedStringResource("language.ui"))
                }
            } header: {
                Text(LocalizedStringResource("settings.language_section"))
            } footer: {
                Text(LocalizedStringResource("settings.language_footer"))
            }
            
            Section {
                Toggle(isOn: $settings.showDividers) {
                    Text(LocalizedStringResource("settings.show_dividers"))
                }
            } header: {
                Text(LocalizedStringResource("settings.display_options"))
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - 图表
    
    private var chartsTab: some View {
        Form {
            Section {
                ColorPicker(selection: $settings.instantZColor) {
                    Text(LocalizedStringResource("settings.color.instant_z"))
                }
                ColorPicker(selection: $settings.cumulativeZColor) {
                    Text(LocalizedStringResource("settings.color.cumulative_z"))
                }
                ColorPicker(selection: $settings.varianceColor) {
                    Text(LocalizedStringResource("settings.color.variance"))
                }
                ColorPicker(selection: $settings.thresholdColor) {
                    Text(LocalizedStringResource("settings.color.thresholds"))
                }
            } header: {
                Text(LocalizedStringResource("settings.chart_colors"))
            }
            
            Section {
                HStack {
                    Text(LocalizedStringResource("settings.line_width"))
                    Spacer()
                    Slider(value: $settings.chartLineWidth, in: 0.5...3.0, step: 0.1)
                        .frame(maxWidth: 200)
                    Text(String(format: "%.1f", settings.chartLineWidth))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 28, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(LocalizedStringResource("settings.lines"))
            }
            
            Section {
                Button {
                    settings.applyPreset(settings.activePreset)
                } label: {
                    Text(LocalizedStringResource("settings.reset_theme_colors"))
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - 导出
    
    private var exportTab: some View {
        Form {
            Section {
                HStack {
                    SettingsPathControl(path: settings.exportPath)
                    Button(action: chooseFolder) {
                        Text(LocalizedStringResource("export.choose_ellipsis"))
                    }
                }
            } header: {
                Text(LocalizedStringResource("export.save_location"))
            } footer: {
                Text(LocalizedStringResource("export.save_location_footer"))
            }

            Section {
                Toggle(isOn: $settings.autoSavePlot) {
                    Text(LocalizedStringResource("export.waveform"))
                }
                Toggle(isOn: $settings.autoSaveAudit) {
                    Text(LocalizedStringResource("export.audit_report"))
                }
            } header: {
                Text(LocalizedStringResource("export.save_when_stopping"))
            }
        }
        .formStyle(.grouped)
    }
}

private struct SettingsPathControl: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> NSPathControl {
        let view = NSPathControl()
        view.pathStyle = .standard
        view.isEditable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSPathControl, context: Context) {
        view.url = URL(fileURLWithPath: path, isDirectory: true)
    }
}

// MARK: - Theme List (extracted to avoid compiler timeout)

struct ThemeListView: View {
    @Bindable var settings: AppSettings
    
    var body: some View {
        ForEach(AppSettings.ThemePreset.allCases) { preset in
            themeRow(preset)
        }
    }
    
    private func themeRow(_ preset: AppSettings.ThemePreset) -> some View {
        Button {
            settings.activePreset = preset
        } label: {
            HStack(spacing: 12) {
                Image(systemName: preset.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(settings.activePreset == preset ? .white : .secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        settings.activePreset == preset
                        ? Color.accentColor
                        : Color.gray.opacity(0.2),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.localizedName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(preset.localizedDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                if settings.activePreset == preset {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
