import AppKit
import SwiftUI

enum SettingsPane: CaseIterable {
    case appearance, charts, export

    static let width: CGFloat = 520

    func title(locale: Locale) -> String {
        switch self {
        case .appearance: String(localized: LocalizedStringResource("settings.appearance", locale: locale))
        case .charts: String(localized: LocalizedStringResource("settings.charts", locale: locale))
        case .export: String(localized: LocalizedStringResource("settings.export", locale: locale))
        }
    }
}

/// One settings window per collection window, sharing its existing preferences.
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    private let settings: AppSettings
    private var selectedPane: SettingsPane = .export
    private let sectionsID = NSToolbarItem.Identifier("settingsSections")
    private var sections: NSToolbarItemGroup!
    private var host: NSHostingController<SettingsView>!
    private var folderPanel: NSOpenPanel?
    private var displayedLanguage: AppSettings.Language?
    private var contentWidth = SettingsPane.width

    init(settings: AppSettings) {
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsPane.width, height: 1),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.delegate = self
        host = NSHostingController(rootView: paneView(height: nil))
        window.contentViewController = host

        sections = makeSections()
        let toolbar = NSToolbar(identifier: "QcicadaSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        refreshWindowConfiguration()
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func open() {
        refreshWindowConfiguration()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    override func close() {
        cancelFolderSelection()
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        cancelFolderSelection()
    }

    private func paneView(height: CGFloat?) -> SettingsView {
        SettingsView(settings: settings, pane: selectedPane, width: contentWidth, height: height,
                     chooseFolder: { [weak self] in self?.chooseFolder() },
                     windowConfigurationChanged: { [weak self] in self?.refreshWindowConfiguration() })
    }

    /// The selected pane's natural height at the current width and language, so every
    /// pane shows all of its settings without scrolling. A pane taller than the screen
    /// gets the available height and scrolls instead.
    private func fittingPaneHeight() -> CGFloat {
        let probe = NSHostingController(rootView: SettingsView(
            settings: settings, pane: selectedPane, width: contentWidth, height: nil,
            chooseFolder: {}, windowConfigurationChanged: {}))
        let natural = ceil(probe.sizeThatFits(in: NSSize(width: contentWidth, height: 10_000)).height)
        guard let window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return natural }
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        return max(1, min(natural, visible.height - chrome))
    }

    /// Shows the selected pane at its fitting size. The window keeps its top-left
    /// corner, and moves up only when its lower edge would otherwise leave the screen.
    private func showSelectedPane() {
        let height = fittingPaneHeight()
        host.rootView = paneView(height: height)
        guard let window else { return }
        window.setContentSize(NSSize(width: contentWidth, height: height))
        if let visible = window.screen?.visibleFrame, window.frame.minY < visible.minY {
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: visible.minY))
        }
    }

    private func makeSections() -> NSToolbarItemGroup {
        let locale = settings.stringResolutionLocale ?? .current
        let item = NSToolbarItemGroup(itemIdentifier: sectionsID,
                                     titles: SettingsPane.allCases.map { $0.title(locale: locale) },
                                     selectionMode: .selectOne, labels: nil,
                                     target: self, action: #selector(selectSection(_:)))
        item.label = localized("settings.title")
        item.controlRepresentation = .expanded
        item.visibilityPriority = .high
        item.selectedIndex = SettingsPane.allCases.firstIndex(of: selectedPane)!
        if #available(macOS 27.0, *) { item.role = .tabs }
        return item
    }

    private func refreshWindowConfiguration() {
        window?.title = localized("settings.title")
        switch settings.colorSchemeOverride {
        case .system: window?.appearance = nil
        case .light: window?.appearance = NSAppearance(named: .aqua)
        case .dark: window?.appearance = NSAppearance(named: .darkAqua)
        }
        if displayedLanguage != settings.language, let toolbar = window?.toolbar {
            displayedLanguage = settings.language
            if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == sectionsID }) {
                toolbar.removeItem(at: index)
                sections = makeSections()
                toolbar.insertItem(withItemIdentifier: sectionsID, at: index)
            }
        }
        resizeForCurrentPane()
    }

    private func resizeForCurrentPane() {
        let locale = settings.stringResolutionLocale ?? .current
        // The Chinese layout is the reference; add the native text expansion
        // for longer translations so the complete group stays out of overflow.
        let referenceLocale = Locale(identifier: "zh-Hans")
        func segmentWidth(_ locale: Locale) -> CGFloat {
            let control = NSSegmentedControl(labels: SettingsPane.allCases.map { $0.title(locale: locale) },
                                             trackingMode: .selectOne, target: nil, action: nil)
            if #available(macOS 27.0, *) { control.role = .tabs }
            control.sizeToFit()
            return control.fittingSize.width
        }
        let referenceTitle = String(localized: LocalizedStringResource("settings.title", locale: referenceLocale))
        let titleExpansion = NSWindow.minFrameWidth(withTitle: localized("settings.title"), styleMask: [.titled, .closable])
            - NSWindow.minFrameWidth(withTitle: referenceTitle, styleMask: [.titled, .closable])
        contentWidth = SettingsPane.width + ceil(max(0, segmentWidth(locale) - segmentWidth(referenceLocale) + titleExpansion))
        showSelectedPane()
    }

    private func localized(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        // Resource locale selects the language; String's locale only formats values.
        resource.locale = settings.stringResolutionLocale ?? .current
        return String(localized: resource)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, sectionsID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, sectionsID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        itemIdentifier == sectionsID ? sections : nil
    }

    @objc private func selectSection(_ sender: NSToolbarItemGroup) {
        guard SettingsPane.allCases.indices.contains(sender.selectedIndex) else { return }
        selectedPane = SettingsPane.allCases[sender.selectedIndex]
        showSelectedPane()
    }

    private func chooseFolder() {
        guard folderPanel == nil, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: settings.exportPath, isDirectory: true)
        panel.message = localized("export.choose_save_folder")
        panel.prompt = localized("export.choose_folder_prompt")
        folderPanel = panel
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self, let panel, self.folderPanel === panel else { return }
            self.folderPanel = nil
            if response == .OK, let url = panel.url {
                self.settings.exportPath = url.path
            }
        }
    }

    private func cancelFolderSelection() {
        let panel = folderPanel
        folderPanel = nil
        panel?.cancel(nil)
    }
}
