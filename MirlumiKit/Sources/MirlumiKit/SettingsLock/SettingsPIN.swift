// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CommonCrypto
import Foundation
import Security

/// Where `SettingsPIN` keeps its values.
public protocol PINStore: AnyObject {
    func value(for key: String) -> String?
    func set(_ value: String, for key: String)
    func remove(_ key: String)
}

/// The parent's PIN for Settings. Only a salted PBKDF2 hash is stored. After `freeAttempts` wrong entries in a row,
/// each further wrong entry locks entry for twice as long as the last, from `firstLockout` up to `maxLockout`.
/// The count survives restarts, and only a correct entry resets it.
///
/// A lockout is measured on `uptime`, the time since the device started, which keeps counting during sleep and doesn't
/// move when someone changes the clock. `now` only turns what's left of it into a time to show.
public final class SettingsPIN {
    public enum Result: Equatable {
        case correct
        case wrong
        case lockedOut(until: Date)
    }

    public static let length = 4
    public static let freeAttempts = 5
    public static let firstLockout: TimeInterval = 30
    public static let maxLockout: TimeInterval = 60 * 60

    private static let maxDoublings = 10
    private static let iterations = 20_000
    private static let saltBytes = 16
    private static let hashBytes = 32

    private enum Key {
        static let pin = "pin"
        static let failures = "failures"
        static let lockoutStarted = "lockout_started"
        static let lockoutLength = "lockout_length"
    }

    private let store: PINStore
    private let now: () -> Date
    private let uptime: () -> TimeInterval

    public init(store: PINStore,
                now: @escaping () -> Date = Date.init,
                uptime: @escaping () -> TimeInterval = SettingsPIN.deviceUptime) {
        self.store = store
        self.now = now
        self.uptime = uptime
    }

    /// Time since the device started, including sleep. `CLOCK_MONOTONIC` keeps counting while the device sleeps.
    public static func deviceUptime() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    public static func isValid(_ pin: String) -> Bool {
        pin.count == length && pin.allSatisfy { ("0"..."9").contains($0) }
    }

    public var isSet: Bool {
        store.value(for: Key.pin) != nil
    }

    public func set(_ pin: String) {
        precondition(Self.isValid(pin), "A PIN is \(Self.length) digits")
        var salt = [UInt8](repeating: 0, count: Self.saltBytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        let hash = Self.hash(pin, salt: salt, iterations: Self.iterations)
        store.set("\(Self.iterations):\(Data(salt).base64EncodedString()):\(Data(hash).base64EncodedString())",
                  for: Key.pin)
        resetAttempts()
    }

    /// When entry opens again, or nil if it's open now.
    public func lockedOutUntil() -> Date? {
        remainingLockout().map { now().addingTimeInterval($0) }
    }

    private func remainingLockout() -> TimeInterval? {
        guard let started = store.value(for: Key.lockoutStarted).flatMap(TimeInterval.init),
              let length = store.value(for: Key.lockoutLength).flatMap(TimeInterval.init) else { return nil }
        let clock = uptime()
        // Uptime starts again at zero when the device restarts. Everything since then came after the lockout began,
        // so counting only that time can make a lockout longer, never shorter.
        let served = clock >= started ? clock - started : clock
        let remaining = length - served
        return remaining > 0 ? remaining : nil
    }

    public func check(_ pin: String) -> Result {
        if let until = lockedOutUntil() { return .lockedOut(until: until) }
        let parts = store.value(for: Key.pin)?.split(separator: ":").map(String.init) ?? []
        if Self.isValid(pin),
           parts.count == 3,
           let iterations = Int(parts[0]),
           let salt = Data(base64Encoded: parts[1]),
           let expected = Data(base64Encoded: parts[2]),
           Self.constantTimeEqual(Self.hash(pin, salt: [UInt8](salt), iterations: iterations), [UInt8](expected)) {
            resetAttempts()
            return .correct
        }
        let failures = (store.value(for: Key.failures).flatMap(Int.init) ?? 0) + 1
        store.set(String(failures), for: Key.failures)
        if failures <= Self.freeAttempts { return .wrong }
        let doublings = min(failures - Self.freeAttempts - 1, Self.maxDoublings)
        let lockout = min(Self.firstLockout * pow(2, Double(doublings)), Self.maxLockout)
        store.set(String(uptime()), for: Key.lockoutStarted)
        store.set(String(lockout), for: Key.lockoutLength)
        return .lockedOut(until: now().addingTimeInterval(lockout))
    }

    private func resetAttempts() {
        store.remove(Key.failures)
        store.remove(Key.lockoutStarted)
        store.remove(Key.lockoutLength)
    }

    private static func hash(_ pin: String, salt: [UInt8], iterations: Int) -> [UInt8] {
        var derived = [UInt8](repeating: 0, count: hashBytes)
        let password = Array(pin.utf8).map { Int8(bitPattern: $0) }
        _ = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password,
            password.count,
            salt,
            salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            UInt32(iterations),
            &derived,
            derived.count
        )
        return derived
    }

    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Keeps the PIN in this device's keychain, out of backups. Keychain items outlive the app, so the first launch after
/// an install removes any left by an earlier one: reinstalling is how a forgotten PIN is reset.
final class KeychainPINStore: PINStore {
    private static let service = "app.mirlumi.settings-lock"
    private static let installedKey = "app.mirlumi.settingsLock.installed"

    init(defaults: UserDefaults = .standard) {
        if !defaults.bool(forKey: Self.installedKey) {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service] as CFDictionary)
            defaults.set(true, forKey: Self.installedKey)
        }
    }

    func value(for key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(key)
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    func remove(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    private func baseQuery(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: Self.service,
         kSecAttrAccount: key,
         kSecAttrSynchronizable: false]
    }
}
