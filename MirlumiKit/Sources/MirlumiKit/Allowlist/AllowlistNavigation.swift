// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

#if canImport(UIKit)
import UIKit
import WebKit

extension Allowlist {
    /// Decides `action` if it's the allowlist's to decide: a page that isn't allowed, or a parent allowing one. Call
    /// first in `webView(_:decidePolicyFor:decisionHandler:)`. Returns false, without calling `decisionHandler`, when
    /// the browser should decide as usual.
    public func handle(_ action: WKNavigationAction,
                       in webView: WKWebView,
                       presenter: UIViewController?,
                       decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) -> Bool {
        guard isEnabled, let url = action.request.url else { return false }
        // A new window has no target frame yet. Its first load is decided in the new web view.
        let sourceFrame: WKFrameInfo? = action.sourceFrame
        let decision = decide(url,
                              in: webView,
                              isMainFrame: action.targetFrame?.isMainFrame ?? false,
                              isLoad: action.navigationType == .other,
                              source: sourceFrame?.request.url)
        switch decision {
        case .pass:
            return false
        case .cancel:
            decisionHandler(.cancel)
        case .block(let blocked):
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak webView] in
                webView?.loadSimulatedRequest(URLRequest(url: blocked), responseHTML: Self.blockedPage)
            }
        case .askToAllow(let blocked):
            decisionHandler(.cancel)
            SettingsLock.shared.requestAccess(from: presenter) { [weak self, weak webView] in
                self?.allow(blocked)
                webView?.load(URLRequest(url: blocked))
                return nil
            }
        }
        return true
    }

    /// The policy for a load the user doesn't see as a page, such as reader view fetching an article: anything that
    /// isn't allowed, including where a redirect leads, is cancelled.
    public func policy(forBackgroundLoad action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard isEnabled, action.targetFrame?.isMainFrame ?? true, let url = action.request.url else { return .allow }
        return allows(url) ? .allow : .cancel
    }

    /// Whether a link preview may load. Previews open in a web view without the browser's navigation delegate, where
    /// a redirect couldn't be checked, so there are none while the allowlist is on.
    public var allowsLinkPreviews: Bool { !isEnabled }
}
#endif
