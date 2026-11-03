// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import XCTest
@testable import MirlumiKit

final class MemoryPINStore: PINStore {
    var values: [String: String] = [:]

    func value(for key: String) -> String? { values[key] }
    func set(_ value: String, for key: String) { values[key] = value }
    func remove(_ key: String) { values[key] = nil }
}

final class SettingsPINTests: XCTestCase {
    private var store = MemoryPINStore()
    private var now = Date(timeIntervalSince1970: 1_000_000)
    private var uptime: TimeInterval = 5_000
    private lazy var pin = makePIN()

    private func makePIN() -> SettingsPIN {
        SettingsPIN(store: store, now: { [unowned self] in self.now }, uptime: { [unowned self] in self.uptime })
    }

    private func advance(_ seconds: TimeInterval) {
        now.addTimeInterval(seconds)
        uptime += seconds
    }

    func testStoresASaltedHashAndNeverThePIN() {
        pin.set("4821")
        let other = MemoryPINStore()
        SettingsPIN(store: other).set("4821")

        XCTAssertTrue(pin.isSet)
        XCTAssertFalse(store.values.values.contains { $0.contains("4821") })
        XCTAssertNotEqual(store.values["pin"], other.values["pin"])
    }

    func testAcceptsOnlyThePINThatWasSet() {
        pin.set("4821")

        XCTAssertEqual(pin.check("4821"), .correct)
        XCTAssertEqual(pin.check("4822"), .wrong)
        XCTAssertEqual(pin.check("482"), .wrong)
    }

    func testNothingIsCorrectBeforeAPINIsSet() {
        XCTAssertFalse(pin.isSet)
        XCTAssertEqual(pin.check("0000"), .wrong)
    }

    func testRejectsPINsThatArentFourDigits() {
        for value in ["", "123", "12345", "12a4", "١٢٣٤"] {
            XCTAssertFalse(SettingsPIN.isValid(value), value)
        }
        XCTAssertTrue(SettingsPIN.isValid("0000"))
    }

    func testLocksOutAfterTheFreeAttemptsDoublingEachTimeAndACorrectPINResets() {
        pin.set("4821")
        for _ in 0..<SettingsPIN.freeAttempts { _ = pin.check("0000") }

        XCTAssertEqual(pin.check("0000"), .lockedOut(until: now.addingTimeInterval(30)))
        XCTAssertEqual(pin.check("4821"), .lockedOut(until: now.addingTimeInterval(30)))

        advance(30)
        XCTAssertNil(pin.lockedOutUntil())
        XCTAssertEqual(pin.check("0000"), .lockedOut(until: now.addingTimeInterval(60)))

        advance(60)
        XCTAssertEqual(pin.check("4821"), .correct)
        XCTAssertEqual(pin.check("0000"), .wrong)
    }

    func testTheLockoutNeverExceedsAnHour() {
        pin.set("4821")
        for _ in 0..<40 {
            _ = pin.check("0000")
            if let until = pin.lockedOutUntil() { advance(until.timeIntervalSince(now)) }
        }
        _ = pin.check("0000")

        XCTAssertEqual(pin.lockedOutUntil(), now.addingTimeInterval(SettingsPIN.maxLockout))
    }

    func testChangingTheClockDoesntShortenOrLengthenTheLockout() {
        pin.set("4821")
        for _ in 0...SettingsPIN.freeAttempts { _ = pin.check("0000") }
        advance(10)

        now.addTimeInterval(24 * 60 * 60)
        XCTAssertEqual(pin.lockedOutUntil(), now.addingTimeInterval(20))
        guard case .lockedOut = pin.check("4821") else { return XCTFail("Expected a lockout") }

        now.addTimeInterval(-48 * 60 * 60)
        XCTAssertEqual(pin.lockedOutUntil(), now.addingTimeInterval(20))
    }

    func testRestartingTheDeviceDoesntEndTheLockout() {
        pin.set("4821")
        for _ in 0...SettingsPIN.freeAttempts { _ = pin.check("0000") }

        // Ten seconds after a restart, uptime is far below where the lockout began.
        uptime = 10
        XCTAssertEqual(pin.lockedOutUntil(), now.addingTimeInterval(20))

        uptime = 30
        XCTAssertNil(pin.lockedOutUntil())
    }

    func testTheAttemptCountSurvivesARestart() {
        pin.set("4821")
        for _ in 0..<SettingsPIN.freeAttempts { _ = pin.check("0000") }

        let restarted = makePIN()

        guard case .lockedOut = restarted.check("0000") else { return XCTFail("Expected a lockout") }
    }

    func testSettingANewPINReplacesTheOldOneAndClearsTheAttempts() {
        pin.set("4821")
        _ = pin.check("0000")
        pin.set("1357")

        XCTAssertEqual(pin.check("4821"), .wrong)
        XCTAssertNil(store.values["lockout_started"])
        XCTAssertEqual(store.values["failures"], "1")
        XCTAssertEqual(pin.check("1357"), .correct)
    }
}
