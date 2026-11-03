// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import XCTest
@testable import MirlumiKit

final class PINFlowTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_000_000)
    private lazy var pin = SettingsPIN(store: MemoryPINStore(),
                                       now: { [unowned self] in self.now },
                                       uptime: { [unowned self] in self.now.timeIntervalSince1970 })

    private func enter(_ digits: String, into flow: PINFlow) {
        digits.forEach(flow.type)
    }

    func testSetupAsksForThePINTwiceAndStoresIt() {
        let flow = PINFlow(pin: pin, purpose: .setup)
        XCTAssertEqual(flow.state.step, .choose)

        enter("2468", into: flow)
        XCTAssertEqual(flow.state.step, .confirm)
        XCTAssertFalse(pin.isSet)

        enter("2468", into: flow)
        XCTAssertTrue(flow.state.done)
        XCTAssertEqual(pin.check("2468"), .correct)
    }

    func testSetupStartsAgainWhenTheTwoPINsDiffer() {
        let flow = PINFlow(pin: pin, purpose: .setup)
        enter("2468", into: flow)
        enter("2469", into: flow)

        XCTAssertEqual(flow.state, PINFlow.State(step: .choose, message: .mismatch))
        XCTAssertFalse(pin.isSet)

        flow.type("1")
        XCTAssertNil(flow.state.message)
    }

    func testUnlockingWithoutAPINChoosesOneInstead() {
        XCTAssertEqual(PINFlow(pin: pin, purpose: .unlock).state.step, .choose)
    }

    func testUnlockFinishesOnTheRightPINOnly() {
        pin.set("2468")
        let flow = PINFlow(pin: pin, purpose: .unlock)
        XCTAssertEqual(flow.state.step, .current)

        enter("1111", into: flow)
        XCTAssertEqual(flow.state, PINFlow.State(step: .current, message: .wrong))

        enter("2468", into: flow)
        XCTAssertTrue(flow.state.done)
    }

    func testDeleteRemovesTheLastDigit() {
        pin.set("2468")
        let flow = PINFlow(pin: pin, purpose: .unlock)
        enter("247", into: flow)
        flow.delete()
        enter("68", into: flow)

        XCTAssertTrue(flow.state.done)
    }

    func testChangeChecksTheCurrentPINBeforeChoosingANewOne() {
        pin.set("2468")
        let flow = PINFlow(pin: pin, purpose: .change)
        enter("2468", into: flow)
        XCTAssertEqual(flow.state.step, .choose)

        enter("1357", into: flow)
        enter("1357", into: flow)

        XCTAssertTrue(flow.state.done)
        XCTAssertEqual(pin.check("1357"), .correct)
    }

    func testALockoutBlocksTypingUntilItEnds() {
        pin.set("2468")
        let flow = PINFlow(pin: pin, purpose: .unlock)
        for _ in 0...SettingsPIN.freeAttempts { enter("1111", into: flow) }
        XCTAssertTrue(flow.isLockedOut)

        enter("2468", into: flow)
        XCTAssertFalse(flow.state.done)
        XCTAssertEqual(flow.state.digits, 0)

        now.addTimeInterval(SettingsPIN.firstLockout)
        flow.refreshLockout()
        enter("2468", into: flow)
        XCTAssertTrue(flow.state.done)
    }

    func testALockoutFromAnEarlierVisitShowsAtOnce() {
        pin.set("2468")
        for _ in 0...SettingsPIN.freeAttempts { _ = pin.check("1111") }

        XCTAssertTrue(PINFlow(pin: pin, purpose: .unlock).isLockedOut)
    }
}
