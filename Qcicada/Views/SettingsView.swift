// SettingsView.swift
// Qcicada

import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Window title bar area
            HStack {
                Text(LocalizedStringResource("settings.title"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            Divider()
            
            TabView {
                appearanceTab
                    .tabItem {
                        Label(LocalizedStringResource("settings.appearance"), systemImage: "paintbrush")
                    }
                
                chartsTab
                    .tabItem {
                        Label(LocalizedStringResource("settings.charts"), systemImage: "chart.xyaxis.line")
                    }
                
                exportTab
                    .tabItem {
                        Label(LocalizedStringResource("settings.export"), systemImage: "square.and.arrow.up")
                    }
            }
        }
        .frame(width: 500, height: 480)
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
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                    Text(settings.exportPath)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Button {
                        chooseExportPath()
                    } label: {
                        Text(LocalizedStringResource("export.choose_ellipsis"))
                    }
                    .controlSize(.small)
                }
            } header: {
                Text(LocalizedStringResource("export.folder"))
            }
            
            Section {
                Toggle(isOn: $settings.autoSavePlot) {
                    Text(LocalizedStringResource("export.auto_plot"))
                }
                Toggle(isOn: $settings.autoSaveAudit) {
                    Text(LocalizedStringResource("export.auto_audit"))
                }
            } header: {
                Text(LocalizedStringResource("export.auto_on_stop"))
            }
        }
        .formStyle(.grouped)
    }
    
    private func chooseExportPath() {
        let loc = settings.stringResolutionLocale
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "export.choose_folder_title", locale: loc ?? .current)
        panel.prompt = String(localized: "export.choose_folder_prompt", locale: loc ?? .current)
        
        if panel.runModal() == .OK, let url = panel.url {
            settings.exportPath = url.path
        }
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
