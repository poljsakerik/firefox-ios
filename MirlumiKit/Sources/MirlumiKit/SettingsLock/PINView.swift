// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

#if canImport(UIKit)
import Combine
import SwiftUI
import UIKit

@MainActor
final class PINModel: ObservableObject {
    @Published private(set) var state: PINFlow.State
    @Published private(set) var now = Date()

    let purpose: PINPurpose
    let canCancel: Bool
    var onFinish: (@MainActor (Bool) -> Void)?

    private let flow: PINFlow
    private var finished = false

    init(flow: PINFlow, purpose: PINPurpose, canCancel: Bool) {
        self.flow = flow
        self.purpose = purpose
        self.canCancel = canCancel
        state = flow.state
    }

    func type(_ digit: Character) {
        let before = state.message
        flow.type(digit)
        update()
        if state.message != nil, state.message != before {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    func delete() {
        flow.delete()
        update()
    }

    func tick() {
        now = Date()
        flow.refreshLockout()
        update()
    }

    func cancel() {
        finish(false)
    }

    private func update() {
        state = flow.state
        if state.done {
            if purpose == .change {
                UIAccessibility.post(notification: .announcement, argument: L10n.string("Changed"))
            }
            finish(true)
        }
    }

    private func finish(_ granted: Bool) {
        guard !finished else { return }
        finished = true
        onFinish?(granted)
    }
}

struct PINView: View {
    @ObservedObject var model: PINModel

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let keySize: CGFloat = 72

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.mirlumiAccent)
                    .accessibilityHidden(true)
                    .padding(.bottom, 16)
                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let bodyText {
                    Text(bodyText)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                        .padding(.top, 8)
                }
                dots.padding(.top, 32)
                Text(message ?? " ")
                    .font(.callout)
                    .foregroundColor(Color(.systemRed))
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 56)
                    .padding(.vertical, 8)
                    .accessibilityHidden(message == nil)
                keypad
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .onReceive(timer) { _ in
            if model.state.isLockedOut { model.tick() }
        }
        .onChange(of: model.state.message) { message in
            guard let message else { return }
            UIAccessibility.post(notification: .announcement, argument: describe(message))
        }
    }

    private var dots: some View {
        HStack(spacing: 16) {
            ForEach(0..<SettingsPIN.length, id: \.self) { index in
                Circle()
                    .strokeBorder(Color.mirlumiAccent, lineWidth: 2)
                    .background(Circle().fill(index < model.state.digits ? Color.mirlumiAccent : .clear))
                    .frame(width: 16, height: 16)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("Progress", model.state.digits, SettingsPIN.length))
    }

    private var keypad: some View {
        VStack(spacing: 12) {
            ForEach(["123", "456", "789"], id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(Array(row), id: \.self) { digitKey($0) }
                }
            }
            HStack(spacing: 24) {
                Group {
                    if model.canCancel {
                        Button(L10n.string("Cancel")) { model.cancel() }
                            .foregroundColor(.mirlumiAccent)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: keySize, height: keySize)
                digitKey("0")
                Button { model.delete() } label: {
                    Image(systemName: "delete.left")
                        .font(.title2)
                        .frame(width: keySize, height: keySize)
                }
                .foregroundColor(.primary)
                .disabled(model.state.isLockedOut)
                .accessibilityLabel(L10n.string("Delete"))
            }
        }
    }

    private func digitKey(_ digit: Character) -> some View {
        Button { model.type(digit) } label: {
            Text(String(digit))
                .font(.title)
                .frame(width: keySize, height: keySize)
                .background(Circle().fill(Color(.secondarySystemBackground)))
        }
        .foregroundColor(.primary)
        .disabled(model.state.isLockedOut)
        .opacity(model.state.isLockedOut ? 0.4 : 1)
    }

    private var title: String {
        switch model.state.step {
        case .current: L10n.string(model.purpose == .change ? "CurrentTitle" : "UnlockTitle")
        case .choose: L10n.string(model.purpose == .change ? "NewTitle" : "SetupTitle")
        case .confirm: L10n.string("ConfirmTitle")
        }
    }

    private var bodyText: String? {
        switch model.state.step {
        case .current: model.purpose == .change ? nil : L10n.string("UnlockBody")
        case .choose: L10n.string("SetupBody")
        case .confirm: L10n.string("ConfirmBody")
        }
    }

    private var message: String? {
        model.state.message.map(describe)
    }

    private func describe(_ message: PINFlow.Message) -> String {
        switch message {
        case .wrong:
            return L10n.string("Wrong")
        case .mismatch:
            return L10n.string("Mismatch")
        case .lockedOut(let until):
            let seconds = max(1, Int(until.timeIntervalSince(model.now).rounded(.up)))
            let wait = seconds < 60
                ? L10n.format("Seconds", seconds)
                : L10n.format("Minutes", (seconds + 59) / 60)
            return L10n.format("LockedOut", wait)
        }
    }
}

extension Color {
    /// Mirlumi blue, lighter in dark mode, as the app's accents.
    static let mirlumiAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x6d / 255, green: 0xb4 / 255, blue: 0xf8 / 255, alpha: 1)
            : UIColor(red: 0x2f / 255, green: 0x7f / 255, blue: 0xe8 / 255, alpha: 1)
    })
}
#endif
