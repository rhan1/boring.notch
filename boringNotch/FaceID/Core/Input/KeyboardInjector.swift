import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Synthesises keystrokes via CGEvent. Requires Accessibility permission.
public final class KeyboardInjector {
    public enum InjectError: Error {
        case accessibilityNotTrusted
        case eventCreationFailed
    }

    public init() {}

    public static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public static func requestAccessibility(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func type(_ text: String, interval: TimeInterval = 0) throws {
        guard Self.isAccessibilityTrusted else {
            throw InjectError.accessibilityNotTrusted
        }

        let source = CGEventSource(stateID: .hidSystemState)
        for scalar in text.unicodeScalars {
            var utf16 = Array(String(scalar).utf16)
            guard
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                throw InjectError.eventCreationFailed
            }
            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            if interval > 0 { usleep(useconds_t(interval * 1_000_000)) }
        }
    }

    /// Select-all + delete, so typed text replaces anything already there.
    public func clearFocusedField() throws {
        guard Self.isAccessibilityTrusted else {
            throw InjectError.accessibilityNotTrusted
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        try press(virtualKey: CGKeyCode(kVK_Delete))
    }

    public func pressReturn() throws {
        try press(virtualKey: CGKeyCode(kVK_Return))
    }

    public func press(virtualKey: CGKeyCode) throws {
        guard Self.isAccessibilityTrusted else {
            throw InjectError.accessibilityNotTrusted
        }
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)?
            .post(tap: .cghidEventTap)
    }
}
