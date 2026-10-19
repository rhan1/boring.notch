// From FaceMac by c1osed1 — https://github.com/c1osed1/FaceMac (GPL-3.0).
// Adapted for Boring Notch.

import Foundation
import Security

/// Stores the macOS login password needed to type it at the lock screen.
/// It never leaves the machine: generic password item in the user's Keychain.
///
/// The item is written and read through Apple's `/usr/bin/security` tool rather
/// than by this app directly. Keychain access is granted per code signature, and
/// a self-signed app gets a new one on every rebuild, which made macOS ask for
/// the login password again after each update. `security` never changes, so the
/// grant made when the item is created holds for good.
///
/// Trade-off: any process running as this user can read the item through the
/// same tool without a prompt.
public final class KeychainStore {
    public enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
        case dataConversion
        case toolFailed(Int32)
    }

    public static let shared = KeychainStore()

    private static let tool = "/usr/bin/security"

    private let service: String
    /// FaceMac's original item, read once (may prompt) and migrated.
    private let legacyService: String
    private var cached: String?

    public init(service: String = "com.facemac.app.login", legacyService: String = "com.facemac.app") {
        self.service = service
        self.legacyService = legacyService
    }

    public func setPassword(_ password: String, account: String = "login") throws {
        let status = Self.run([
            "add-generic-password", "-U",
            "-s", service, "-a", account,
            "-l", "Face ID login password",
            "-T", Self.tool,
            "-w", password,
        ])
        guard status == 0 else { throw KeychainError.toolFailed(status) }
        cached = password
    }

    public func password(account: String = "login") throws -> String? {
        if let cached { return cached }
        if let value = Self.read(service: service, account: account) {
            cached = value
            return value
        }
        // One-time move from FaceMac's original item.
        if let legacy = try legacyPassword(account: account) {
            try setPassword(legacy, account: account)
            return legacy
        }
        return nil
    }

    public func deletePassword(account: String = "login") throws {
        cached = nil
        _ = Self.run(["delete-generic-password", "-s", service, "-a", account])
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Helpers

    private func legacyPassword(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataConversion
        }
        return value
    }

    private static func read(service: String, account: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              var value = String(data: data, encoding: .utf8) else { return nil }
        if value.hasSuffix("\n") { value.removeLast() }
        return value
    }

    @discardableResult
    private static func run(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
