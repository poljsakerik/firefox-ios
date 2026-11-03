// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

#if canImport(UIKit)
import SwiftUI
import UIKit

/// Keeps Settings, and every other screen that changes the browser, behind a parent's PIN. The PIN is chosen at the end
/// of onboarding and can't be skipped. A screen opened with the PIN is covered again when the app goes to the background.
@MainActor
public final class SettingsLock: NSObject {
    public static let shared = SettingsLock()

    /// Set once at launch from `MirlumiBuild.settingsLockEnabled`.
    public var isEnabled = false

    /// The title of the Settings row that changes the PIN.
    public static var changePINTitle: String { L10n.string("PreferenceTitle") }

    private lazy var pin = SettingsPIN(store: KeychainPINStore())
    private var openedScreens: [WeakScreen] = []
    /// The PIN screen being shown, and whether it's still waiting for its turn to present. A route that clears modals,
    /// such as a deep link, can dismiss the PIN screen without it finishing, so "asking" is read from UIKit's state
    /// rather than kept as a flag, which would stay set and stop the PIN screen opening again until a relaunch.
    private weak var askingController: UIViewController?
    private var awaitingPresentation = false
    private var isAsking: Bool {
        guard let askingController else { return false }
        return awaitingPresentation || askingController.presentingViewController != nil
    }

    override private init() {
        super.init()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(coverOpenedScreens),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: nil)
    }

    /// Asks for the PIN, or for a first PIN if there is none, then calls `open`. Whatever `open` returns is covered
    /// again when the app goes to the background.
    public func requestAccess(from presenter: UIViewController?,
                              then open: @escaping @MainActor () -> UIViewController?) {
        guard isEnabled else {
            _ = open()
            return
        }
        guard !isAsking, let presenter = presenter ?? keyWindowRoot else { return }
        ask(pin.isSet ? .unlock : .setup, required: false, from: presenter) { [weak self] granted in
            guard granted, let screen = open() else { return }
            self?.openedScreens.append(WeakScreen(screen))
        }
    }

    /// Asks for a first PIN, with no way to skip it, unless one is set already. Then calls `next`.
    public func setUpIfNeeded(from presenter: UIViewController?, then next: @escaping @MainActor () -> Void = {}) {
        guard isEnabled, !pin.isSet, !isAsking, let presenter = presenter ?? keyWindowRoot else {
            next()
            return
        }
        ask(.setup, required: true, from: presenter) { _ in next() }
    }

    public func presentChangePIN(from presenter: UIViewController) {
        guard !isAsking else { return }
        ask(.change, required: false, from: presenter) { _ in }
    }

    private var keyWindowRoot: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } }
            .first?.rootViewController
    }

    @objc
    private func coverOpenedScreens() {
        openedScreens.removeAll { $0.screen?.viewIfLoaded?.window == nil }
        guard isEnabled, pin.isSet, !isAsking, let screen = openedScreens.last?.screen else { return }
        ask(.unlock, required: false, from: screen, animated: false) { granted in
            if !granted { screen.presentingViewController?.dismiss(animated: true) }
        }
    }

    private func ask(_ purpose: PINPurpose,
                     required: Bool,
                     from presenter: UIViewController,
                     animated: Bool = true,
                     completion: @escaping @MainActor (Bool) -> Void) {
        let model = PINModel(flow: PINFlow(pin: pin, purpose: purpose), purpose: purpose, canCancel: !required)
        let controller = UIHostingController(rootView: PINView(model: model))
        // Over, not instead of, the screen below: Settings treats disappearing as being closed.
        controller.modalPresentationStyle = .overFullScreen
        controller.isModalInPresentation = true
        controller.view.accessibilityViewIsModal = true
        askingController = controller
        awaitingPresentation = true
        model.onFinish = { [weak self, weak controller] granted in
            self?.askingController = nil
            self?.awaitingPresentation = false
            guard let controller else { return completion(granted) }
            controller.dismiss(animated: true) { completion(granted) }
        }
        present(controller, from: presenter, animated: animated, attemptsLeft: 20)
    }

    /// Presents on top of whatever `presenter` shows, waiting out a presentation or dismissal already under way.
    private func present(_ controller: UIViewController,
                         from presenter: UIViewController,
                         animated: Bool,
                         attemptsLeft: Int) {
        var top = presenter
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        let busy = top.isBeingPresented || top.isBeingDismissed || top.presentedViewController != nil
        if busy, attemptsLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.present(controller, from: presenter, animated: animated, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        if askingController === controller { awaitingPresentation = false }
        top.present(controller, animated: animated)
    }
}

private struct WeakScreen {
    weak var screen: UIViewController?

    init(_ screen: UIViewController) {
        self.screen = screen
    }
}

enum L10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: "SettingsLock", bundle: .module, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: .current, arguments: arguments)
    }
}
#endif
