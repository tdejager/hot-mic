import AppKit
import Carbon.HIToolbox
import Combine
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let recordDictation = Self("recordDictation")
}

@MainActor
final class RecordingShortcutController: ObservableObject {
    @Published private(set) var shortcutLabel = "Choose a recording shortcut in setup."

    private static let defaultShortcut = KeyboardShortcuts.Shortcut(.space, modifiers: [.control, .option])
    private static let shortcutChangedNotification = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")
    // SDK 3.0.1 removes nil choices for names without an initial shortcut.
    // Its stored disabled value prevents the default from returning on relaunch.
    private static let storedShortcutKey = "KeyboardShortcuts_recordDictation"
    private let onActivate: @MainActor () -> Void
    private var observer: NSObjectProtocol?
    private var isShutdown = false

    init(onActivate: @escaping @MainActor () -> Void) {
        self.onActivate = onActivate
        if !migratePreviousShortcut() {
            installDefaultShortcutIfSafe()
        }
        KeyboardShortcuts.onKeyDown(for: .recordDictation) { [weak self] in
            guard let self, !self.isShutdown else { return }
            // KeyboardShortcuts delivers an initial press, not its separate repeating stream.
            // Never require a still-held key: even a completed quick tap starts dictation.
            self.onActivate()
        }
        observer = NotificationCenter.default.addObserver(
            forName: Self.shortcutChangedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
                  name.rawValue == KeyboardShortcuts.Name.recordDictation.rawValue else { return }
            MainActor.assumeIsolated { self?.updateShortcutLabel(persistClearedChoice: true) }
        }
        updateShortcutLabel()
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        KeyboardShortcuts.removeHandler(for: .recordDictation)
    }

    /// One-time preference migration, including a user's explicitly cleared shortcut.
    /// The obsolete name is removed, not retained as a second shortcut or alias.
    private func migratePreviousShortcut() -> Bool {
        let names = KeyboardShortcuts.storedNames
        let hasCurrent = names.contains { $0.rawValue == KeyboardShortcuts.Name.recordDictation.rawValue }
        guard let previous = names.first(where: { $0.rawValue == "holdToTalk" }) else { return hasCurrent }
        if !hasCurrent {
            if let shortcut = KeyboardShortcuts.getShortcut(for: previous) {
                KeyboardShortcuts.setShortcut(shortcut, for: .recordDictation)
            } else {
                UserDefaults.standard.set(false, forKey: Self.storedShortcutKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: "KeyboardShortcuts_holdToTalk")
        return true
    }

    private func installDefaultShortcutIfSafe() {
        guard Self.systemShortcutRegistryIsAvailable(),
              !Self.defaultShortcut.isTakenBySystem,
              !(NSApp.mainMenu.map(Self.menuContainsDefaultShortcut) ?? false) else { return }
        KeyboardShortcuts.setShortcut(Self.defaultShortcut, for: .recordDictation)
    }

    private func updateShortcutLabel(persistClearedChoice: Bool = false) {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .recordDictation) else {
            if persistClearedChoice {
                UserDefaults.standard.set(false, forKey: Self.storedShortcutKey)
            }
            shortcutLabel = "Choose a recording shortcut in setup."
            return
        }
        shortcutLabel = KeyboardShortcuts.isEnabled(for: .recordDictation)
            ? "Press \(shortcut) to dictate"
            : "\(shortcut) is unavailable. Choose another shortcut."
    }

    private static func systemShortcutRegistryIsAvailable() -> Bool {
        var shortcuts: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&shortcuts) == noErr, let shortcuts else { return false }
        _ = shortcuts.takeRetainedValue()
        return true
    }

    private static func menuContainsDefaultShortcut(_ menu: NSMenu) -> Bool {
        let relevantModifiers: NSEvent.ModifierFlags = [.capsLock, .shift, .control, .option, .command, .function]
        for item in menu.items {
            if item.keyEquivalent == " ",
               item.keyEquivalentModifierMask.intersection(relevantModifiers) == [.control, .option] {
                return true
            }
            if let submenu = item.submenu, menuContainsDefaultShortcut(submenu) { return true }
        }
        return false
    }
}
