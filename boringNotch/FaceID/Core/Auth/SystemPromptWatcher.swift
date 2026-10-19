import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Watches for macOS's own password dialogs — "… wants to make changes",
/// System Settings unlocks, installer and Keychain prompts (SecurityAgent) and
/// Touch ID sheets with a "Use Password…" fallback (coreautha) — and, after a
/// face match, fills the login password into the dialog through Accessibility.
///
/// Only windows owned by the real system binaries are touched, so a look-alike
/// window drawn by another app never receives the password.
public final class SystemPromptWatcher {
    /// Asked on the main queue; must call the completion exactly once.
    public var verify: ((_ reason: String, _ completion: @escaping (Bool) -> Void) -> Void)?
    /// Supplies the saved login password when a dialog is about to be filled.
    public var password: (() -> String?)?

    private static let trustedOwners: [String: String] = [
        "SecurityAgent": "/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/MacOS/SecurityAgent",
        "coreautha": "/System/Library/Frameworks/LocalAuthentication.framework/Support/coreautha.bundle/Contents/MacOS/coreautha",
    ]
    private static let usePasswordTitles = ["Use Password", "Use password", "Ввести пароль", "使用密码"]

    private var timer: Timer?
    private var handled = Set<Int>()
    private var busy = false

    public init() {}

    public func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private struct Prompt {
        let windowNumber: Int
        let pid: pid_t
        let owner: String
    }

    private func tick() {
        guard !busy, !LockWatcher.isScreenLocked else { return }
        let prompts = Self.currentPrompts()
        // Forget windows that have closed so a re-shown dialog scans again.
        handled.formIntersection(prompts.map(\.windowNumber))
        guard let prompt = prompts.first(where: { !handled.contains($0.windowNumber) }) else { return }
        handled.insert(prompt.windowNumber)
        guard let verify, Self.findPasswordTarget(pid: prompt.pid, allowUsePassword: false) != .notAPasswordPrompt else { return }

        busy = true
        Log.app.info("system password prompt from \(prompt.owner, privacy: .public)")
        verify("dialog \(prompt.owner)") { [weak self] ok in
            guard let self else { return }
            if ok { self.fill(pid: prompt.pid, attempt: 0) } else { self.busy = false }
        }
    }

    private func fill(pid: pid_t, attempt: Int) {
        switch Self.findPasswordTarget(pid: pid, allowUsePassword: true) {
        case .field(let field, let window):
            guard let password = password?() else {
                busy = false
                return
            }
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let set = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, password as CFString)
            Log.app.info("filled system prompt: \(set == .success ? "ok" : "AX error \(set.rawValue)", privacy: .public)")
            Self.pressDefaultButton(in: window)
            busy = false
        case .pressedUsePassword where attempt < 6:
            // The password field appears after the Touch ID sheet switches over.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.fill(pid: pid, attempt: attempt + 1)
            }
        default:
            busy = false
        }
    }

    // MARK: Discovery

    private static func currentPrompts() -> [Prompt] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard
                let owner = info[kCGWindowOwnerName as String] as? String,
                let expected = trustedOwners[owner],
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                let number = info[kCGWindowNumber as String] as? Int,
                executablePath(of: pid) == expected
            else { return nil }
            return Prompt(windowNumber: number, pid: pid, owner: owner)
        }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private enum Target: Equatable {
        case field(AXUIElement, window: AXUIElement)
        case pressedUsePassword
        case usePasswordAvailable
        case notAPasswordPrompt

        static func == (lhs: Target, rhs: Target) -> Bool {
            switch (lhs, rhs) {
            case (.field, .field), (.pressedUsePassword, .pressedUsePassword),
                 (.usePasswordAvailable, .usePasswordAvailable), (.notAPasswordPrompt, .notAPasswordPrompt):
                return true
            default:
                return false
            }
        }
    }

    /// Finds the secure password field of a dialog that asks for *this*
    /// user's password. A dialog naming another user is left alone.
    private static func findPasswordTarget(pid: pid_t, allowUsePassword: Bool) -> Target {
        let app = AXUIElementCreateApplication(pid)
        for window in elements(app, kAXWindowsAttribute) {
            let all = descendants(of: window)
            let secure = all.first { string($0, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String }
            if let secure {
                let names = all
                    .filter { string($0, kAXRoleAttribute) == kAXTextFieldRole as String && string($0, kAXSubroleAttribute) != kAXSecureTextFieldSubrole as String }
                    .compactMap { string($0, kAXValueAttribute) }
                    .filter { !$0.isEmpty }
                if let name = names.first, name != NSFullUserName(), name != NSUserName() {
                    Log.app.info("system prompt is for another user, skipping")
                    return .notAPasswordPrompt
                }
                return .field(secure, window: window)
            }
            if let usePassword = all.first(where: { element in
                string(element, kAXRoleAttribute) == kAXButtonRole as String &&
                    usePasswordTitles.contains { (string(element, kAXTitleAttribute) ?? "").hasPrefix($0) }
            }) {
                guard allowUsePassword else { return .usePasswordAvailable }
                AXUIElementPerformAction(usePassword, kAXPressAction as CFString)
                return .pressedUsePassword
            }
        }
        return .notAPasswordPrompt
    }

    private static func pressDefaultButton(in window: AXUIElement) {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXDefaultButtonAttribute as CFString, &value) == .success,
           let button = value, CFGetTypeID(button) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            return
        }
        // No declared default button: Return submits the focused field.
        try? KeyboardInjector().pressReturn()
    }

    private static func descendants(of element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 12 else { return [] }
        let children = elements(element, kAXChildrenAttribute)
        return children + children.flatMap { descendants(of: $0, depth: depth + 1) }
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
