// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// What the PIN screen is for.
public enum PINPurpose {
    /// Opening Settings, or another screen that changes the browser.
    case unlock
    /// Choosing the first PIN.
    case setup
    /// Replacing the PIN from Settings.
    case change
}

/// The steps of entering, choosing and confirming a PIN, with no UI.
public final class PINFlow {
    public enum Step: Equatable { case current, choose, confirm }

    public enum Message: Equatable {
        case wrong
        case lockedOut(until: Date)
        case mismatch
    }

    public struct State: Equatable {
        public var step: Step
        public var digits = 0
        public var message: Message?
        public var done = false

        public var isLockedOut: Bool {
            if case .lockedOut = message { return true }
            return false
        }
    }

    private let pin: SettingsPIN
    private let choosesNewPIN: Bool
    private var entered = ""
    private var chosen = ""

    public private(set) var state: State

    public init(pin: SettingsPIN, purpose: PINPurpose) {
        self.pin = pin
        let choosesFirstPIN = purpose == .setup || !pin.isSet
        choosesNewPIN = choosesFirstPIN || purpose == .change
        state = State(step: choosesFirstPIN ? .choose : .current)
        refreshLockout()
    }

    public var isLockedOut: Bool { state.isLockedOut }

    public func type(_ digit: Character) {
        guard !state.done, !isLockedOut, entered.count < SettingsPIN.length, ("0"..."9").contains(digit) else { return }
        entered.append(digit)
        state.digits = entered.count
        if entered.count == 1 { state.message = nil }
        if entered.count == SettingsPIN.length { submit() }
    }

    public func delete() {
        guard !state.done, !entered.isEmpty else { return }
        entered.removeLast()
        state.digits = entered.count
    }

    /// Clears an expired lockout, or shows one that began elsewhere.
    public func refreshLockout() {
        guard state.step == .current else { return }
        if let until = pin.lockedOutUntil() {
            state.message = .lockedOut(until: until)
        } else if isLockedOut {
            state.message = nil
        }
    }

    private func submit() {
        let value = entered
        entered = ""
        state.digits = 0
        switch state.step {
        case .current:
            switch pin.check(value) {
            case .correct:
                if choosesNewPIN { state = State(step: .choose) } else { state.done = true }
            case .wrong:
                state.message = .wrong
            case .lockedOut(let until):
                state.message = .lockedOut(until: until)
            }
        case .choose:
            chosen = value
            state = State(step: .confirm)
        case .confirm:
            if value == chosen {
                pin.set(value)
                state.done = true
            } else {
                state = State(step: .choose, message: .mismatch)
            }
        }
    }
}
