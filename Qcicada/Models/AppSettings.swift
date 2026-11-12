// AppSettings.swift
// Qcicada

import SwiftUI
import AppKit
import Observation

@Observable
final class AppSettings {
    private static let languageKey = "settings.language"
    private static let exportPathKey = "settings.exportPath"
    @ObservationIgnored private let defaults: UserDefaults
    
    // MARK: - Active Theme
    var activePreset: ThemePreset = .default_ {
        didSet { applyPreset(activePreset) }
    }
    
    // MARK: - Color Scheme (user controls this independently)
    var colorSchemeOverride: ColorSchemeOption = .system
    
    // MARK: - Language
    var language: Language = .system {
        didSet {
            defaults.set(language.rawValue, forKey: Self.languageKey)
        }
    }
    
    // MARK: - Chart Colors (user-adjustable)
    var instantZColor: Color = .green
    var cumulativeZColor: Color = .orange
    var varianceColor: Color = .pink
    var thresholdColor: Color = .yellow.opacity(0.5)
    var chartLineWidth: Double = 1.2
    
    // MARK: - Export
    var exportPath: String = NSHomeDirectory() + "/Documents" {
        didSet { defaults.set(exportPath, forKey: Self.exportPathKey) }
    }
    var autoSavePlot: Bool = true
    var autoSaveAudit: Bool = true
    
    // MARK: - Theme-driven properties
    var windowMaterial: NSVisualEffectView.Material = .windowBackground
    var toolbarMaterial: NSVisualEffectView.Material = .titlebar
    var useNativeBlur: Bool = false
    var showDividers: Bool = true
    var dividerOpacity: Double = 1.0
    var chartBackgroundOpacity: Double = 0.0
    
    // MARK: - Enums
    
    enum ThemePreset: String, CaseIterable, Identifiable {
        case default_ = "default"
        case appleMusic = "appleMusic"
        case appleTV = "appleTV"
        case xcode = "xcode"
        case finder = "finder"
        
        var id: String { rawValue }
        
        var localizedName: LocalizedStringResource {
            switch self {
            case .default_: "theme.default.name"
            case .appleMusic: "theme.apple_music.name"
            case .appleTV: "theme.apple_tv.name"
            case .xcode: "theme.xcode.name"
            case .finder: "theme.finder.name"
            }
        }
        
        var localizedDescription: LocalizedStringResource {
            switch self {
            case .default_: "theme.default.desc"
            case .appleMusic: "theme.apple_music.desc"
            case .appleTV: "theme.apple_tv.desc"
            case .xcode: "theme.xcode.desc"
            case .finder: "theme.finder.desc"
            }
        }
        
        var icon: String {
            switch self {
            case .default_: return "macwindow"
            case .appleMusic: return "music.note"
            case .appleTV: return "tv"
            case .xcode: return "hammer"
            case .finder: return "folder"
            }
        }
        
    }
    
    enum ColorSchemeOption: String, CaseIterable, Identifiable {
        case system
        case light
        case dark
        var id: String { rawValue }
        
        var localizedTitle: LocalizedStringResource {
            switch self {
            case .system: "color_scheme.system"
            case .light: "color_scheme.light"
            case .dark: "color_scheme.dark"
            }
        }
    }
    
    enum Language: String, CaseIterable, Identifiable {
        case system
        case zh
        case en
        var id: String { rawValue }
        
        var localizedTitle: LocalizedStringResource {
            switch self {
            case .system: "language.system"
            case .zh: "language.chinese"
            case .en: "language.english"
            }
        }
    }
    
    // MARK: - Resolved Color Scheme
    
    var resolvedColorScheme: ColorScheme? {
        switch colorSchemeOverride {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    
    /// SwiftUI environment locale (follows system when `.system`).
    var localeForEnvironment: Locale {
        switch language {
        case .system: return .autoupdatingCurrent
        case .zh: return Locale(identifier: "zh-Hans")
        case .en: return Locale(identifier: "en")
        }
    }
    
    /// `nil` means use the system default string resolution (matches “Match System”).
    var stringResolutionLocale: Locale? {
        switch language {
        case .system: return nil
        case .zh: return Locale(identifier: "zh-Hans")
        case .en: return Locale(identifier: "en")
        }
    }
    
    // MARK: - Apply Preset (NEVER touches colorSchemeOverride)
    
    func applyPreset(_ preset: ThemePreset) {
        switch preset {
            
        case .default_:
            useNativeBlur = false
            windowMaterial = .windowBackground
            toolbarMaterial = .titlebar
            showDividers = true
            dividerOpacity = 1.0
            chartBackgroundOpacity = 0.0
            instantZColor = .green
            cumulativeZColor = .orange
            varianceColor = .pink
            thresholdColor = .yellow.opacity(0.5)
            chartLineWidth = 1.2
            
        case .appleMusic:
            useNativeBlur = true
            windowMaterial = .hudWindow
            toolbarMaterial = .hudWindow
            showDividers = false
            dividerOpacity = 0.0
            chartBackgroundOpacity = 0.3
            instantZColor = Color(nsColor: NSColor(red: 0.988, green: 0.235, blue: 0.267, alpha: 1.0))
            cumulativeZColor = Color(nsColor: NSColor(red: 1.0, green: 0.584, blue: 0.0, alpha: 1.0))
            varianceColor = Color(nsColor: NSColor(red: 0.75, green: 0.35, blue: 0.95, alpha: 1.0))
            thresholdColor = .white.opacity(0.12)
            chartLineWidth = 1.5
            
        case .appleTV:
            useNativeBlur = true
            windowMaterial = .sidebar
            toolbarMaterial = .titlebar
            showDividers = true
            dividerOpacity = 0.15
            chartBackgroundOpacity = 0.05
            instantZColor = Color(nsColor: .controlAccentColor)
            cumulativeZColor = Color(nsColor: NSColor(red: 0.95, green: 0.77, blue: 0.26, alpha: 1.0))
            varianceColor = Color(nsColor: NSColor(red: 0.47, green: 0.84, blue: 0.56, alpha: 1.0))
            thresholdColor = Color(nsColor: .separatorColor).opacity(0.4)
            chartLineWidth = 1.3
            
        case .xcode:
            useNativeBlur = true
            windowMaterial = .contentBackground
            toolbarMaterial = .titlebar
            showDividers = true
            dividerOpacity = 0.3
            chartBackgroundOpacity = 0.15
            instantZColor = Color(nsColor: NSColor(red: 0.384, green: 0.847, blue: 0.502, alpha: 1.0))
            cumulativeZColor = Color(nsColor: NSColor(red: 0.898, green: 0.722, blue: 0.271, alpha: 1.0))
            varianceColor = Color(nsColor: NSColor(red: 0.682, green: 0.424, blue: 0.933, alpha: 1.0))
            thresholdColor = .yellow.opacity(0.25)
            chartLineWidth = 1.0
            
        case .finder:
            useNativeBlur = true
            windowMaterial = .sidebar
            toolbarMaterial = .headerView
            showDividers = true
            dividerOpacity = 0.5
            chartBackgroundOpacity = 0.0
            instantZColor = Color(nsColor: .systemBlue)
            cumulativeZColor = Color(nsColor: .systemOrange)
            varianceColor = Color(nsColor: .systemPurple)
            thresholdColor = Color(nsColor: .separatorColor)
            chartLineWidth = 1.2
        }
    }
    
    // MARK: - Semantic Colors
    
    var backgroundColor: Color {
        if useNativeBlur { return .clear }
        return Color(nsColor: .windowBackgroundColor)
    }
    
    var toolbarBackgroundColor: Color {
        if useNativeBlur { return .clear }
        return Color(nsColor: .windowBackgroundColor)
    }
    
    var dividerColor: Color {
        Color(nsColor: .separatorColor).opacity(dividerOpacity)
    }
    
    var chartBackground: Color {
        switch activePreset {
        case .appleMusic:
            return .black.opacity(chartBackgroundOpacity)
        case .xcode:
            return Color(nsColor: NSColor(white: 0.08, alpha: 1.0)).opacity(chartBackgroundOpacity)
        default:
            return .clear
        }
    }
    
    // MARK: - Init
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let savedPath = defaults.string(forKey: Self.exportPathKey), !savedPath.isEmpty {
            exportPath = savedPath
        }
        if let raw = defaults.string(forKey: Self.languageKey),
           let saved = Language(rawValue: raw) {
            language = saved
        }
        applyPreset(.default_)
    }
}
