// Run: swiftc -swift-version 5 -default-isolation MainActor Qcicada/Models/AppSettings.swift Tests/SettingsTests.swift -o /tmp/qcicada-settings-tests && /tmp/qcicada-settings-tests
import Foundation

@main
struct SettingsTests {
    @MainActor
    static func main() throws {
        let suite = "Qcicada.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppSettings(defaults: defaults)
        precondition(first.exportPath == NSHomeDirectory() + "/Documents")
        let selected = "/Volumes/Test volume/保存结果"
        first.exportPath = selected
        let reopened = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        precondition(reopened.exportPath == selected)
        precondition(reopened.activePreset == .default_)
        precondition(reopened.chartLineWidth == 1.2)
        precondition(reopened.colorSchemeOverride == .system)
        // Preserve an unavailable volume choice so collection can report failure;
        // silently falling back would save the user's files in the wrong place.
        precondition(!FileManager.default.fileExists(atPath: selected))
        defaults.set("", forKey: "settings.exportPath")
        precondition(AppSettings(defaults: defaults).exportPath == NSHomeDirectory() + "/Documents")
        print("PASS: default folder, persistent Unicode/space path, unavailable-volume choice, empty setting, unchanged appearance defaults")
    }
}
