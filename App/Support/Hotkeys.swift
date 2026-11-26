import AppKit
import Carbon.HIToolbox

/// Actions that can be triggered with a global keyboard shortcut.
enum HotkeyAction: String, CaseIterable {
    case start, pause, stop, mute, camera

    var title: String {
        switch self {
        case .start: return "Start recording"
        case .pause: return "Pause / resume"
        case .stop: return "Stop recording"
        case .mute: return "Mute / unmute microphone"
        case .camera: return "Camera on / off"
        }
    }

    /// Defaults use Control-Option-Command, which other apps rarely take.
    var defaultShortcut: Shortcut {
        let hyper: NSEvent.ModifierFlags = [.control, .option, .command]
        switch self {
        case .start: return Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: hyper, key: "R")
        case .pause: return Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: hyper, key: "P")
        case .stop: return Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: hyper, key: "S")
        case .mute: return Shortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: hyper, key: "M")
        case .camera: return Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: hyper, key: "C")
        }
    }
}

/// A key with modifiers, e.g. ⌃⌥⌘R.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    private var modifierBits: UInt
    /// Key as shown to the user ("R", "F5", "Space").
    var key: String

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifierBits = modifiers.intersection([.control, .option, .shift, .command]).rawValue
        self.key = key
    }

    /// From a key press; nil unless Command or Control is held (macOS ignores Option-only global shortcuts).
    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard mods.contains(.command) || mods.contains(.control) else { return nil }
        let key = Self.specialKeys[Int(event.keyCode)]
            ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !key.isEmpty, !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods, key: key)
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierBits) }

    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    /// Shows the shortcut next to a menu item (only for plain letter and digit keys).
    func apply(to item: NSMenuItem) {
        guard key.count == 1, key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return }
        item.keyEquivalent = key.lowercased()
        item.keyEquivalentModifierMask = modifiers
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]
}

extension Settings {
    private static func shortcutKey(_ action: HotkeyAction) -> String { "shortcut." + action.rawValue }

    /// The shortcut for an action; nil when the user turned it off.
    static func shortcut(for action: HotkeyAction) -> Shortcut? {
        let d = UserDefaults.standard
        guard let stored = d.object(forKey: shortcutKey(action)) else { return action.defaultShortcut }
        guard let data = stored as? Data else { return nil } // "none"
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    static func setShortcut(_ shortcut: Shortcut?, for action: HotkeyAction) {
        let d = UserDefaults.standard
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            d.set(data, forKey: shortcutKey(action))
        } else {
            d.set("none", forKey: shortcutKey(action))
        }
    }

    static func resetShortcuts() {
        for a in HotkeyAction.allCases { UserDefaults.standard.removeObject(forKey: shortcutKey(a)) }
    }
}

/// System-wide keyboard shortcuts (Carbon hot keys: they need no Accessibility permission).
final class Hotkeys {
    static let shared = Hotkeys()
    /// Called on the main queue.
    var handler: ((HotkeyAction) -> Void)?
    /// Actions whose shortcut another app already uses.
    private(set) var conflicts: Set<HotkeyAction> = []

    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x6D52_6563 // "mRec"

    /// (Re)registers all shortcuts from the settings.
    func register() {
        installHandler()
        unregister()
        conflicts = []
        for (i, action) in HotkeyAction.allCases.enumerated() {
            guard let s = Settings.shortcut(for: action) else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(s.keyCode, s.carbonModifiers, EventHotKeyID(signature: signature, id: UInt32(i)),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                conflicts.insert(action)
                log.error("Shortcut \(s.display, privacy: .public) for \(action.rawValue, privacy: .public) is not available (\(status))")
            }
        }
    }

    /// Turns all shortcuts off, e.g. while a new one is being typed.
    func unregister() {
        for r in refs { UnregisterEventHotKey(r) }
        refs = []
    }

    private func installHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, Int(id.id) < HotkeyAction.allCases.count else { return status }
            let action = HotkeyAction.allCases[Int(id.id)]
            DispatchQueue.main.async { Hotkeys.shared.handler?(action) }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
