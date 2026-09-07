import AppKit
import KeyboardShortcuts

@main
@MainActor
struct RecordingShortcutSmoke {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    static func encoded(_ shortcut: KeyboardShortcuts.Shortcut) throws -> String {
        String(data: try JSONEncoder().encode(shortcut), encoding: .utf8)!
    }

    static func main() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        check(domain == "recording-shortcut-smoke", "Run using the documented isolated executable name")
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let legacyKey = "KeyboardShortcuts_holdToTalk"
        let currentKey = "KeyboardShortcuts_recordDictation"
        let oldChoice = KeyboardShortcuts.Shortcut(.f18, modifiers: [.control, .option])
        let newChoice = KeyboardShortcuts.Shortcut(.f19, modifiers: [.control, .option])

        for scenario in ["custom", "cleared", "existing", "clear-current"] {
            defaults.removeObject(forKey: legacyKey)
            defaults.removeObject(forKey: currentKey)
            switch scenario {
            case "custom":
                defaults.set(try encoded(oldChoice), forKey: legacyKey)
            case "cleared":
                defaults.set(false, forKey: legacyKey)
            case "existing":
                defaults.set(try encoded(oldChoice), forKey: legacyKey)
                defaults.set(try encoded(newChoice), forKey: currentKey)
            case "clear-current":
                defaults.set(try encoded(oldChoice), forKey: currentKey)
            default:
                fatalError("Unknown scenario")
            }

            var activations = 0
            let controller = RecordingShortcutController(onActivate: { activations += 1 })
            defer { controller.shutdown() }
            let initialChoice: KeyboardShortcuts.Shortcut? = scenario == "cleared"
                ? nil : scenario == "existing" ? newChoice : oldChoice
            check(KeyboardShortcuts.getShortcut(for: .recordDictation) == initialChoice,
                  "\(scenario): migration overwrote the saved choice")
            check(defaults.object(forKey: legacyKey) == nil, "\(scenario): legacy preference survived")

            if scenario == "clear-current" {
                KeyboardShortcuts.setShortcut(nil, for: .recordDictation)
            }
            let expectedChoice = scenario == "clear-current" ? nil : initialChoice
            controller.shutdown()
            let relaunched = RecordingShortcutController(onActivate: { activations += 1 })
            defer { relaunched.shutdown() }
            check(KeyboardShortcuts.getShortcut(for: .recordDictation) == expectedChoice,
                  "\(scenario): relaunch changed the choice or re-enabled a cleared shortcut")
            check(activations == 0, "\(scenario): setup activated recording without a press")
            print("PASS shortcut migration and relaunch: \(scenario)")
        }
    }
}
