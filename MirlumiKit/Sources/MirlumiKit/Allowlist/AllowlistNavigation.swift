// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

#if canImport(UIKit)
import UIKit
import WebKit

extension Allowlist {
    /// Decides `action` if it's the allowlist's to decide: a page that isn't allowed, or a parent allowing one. Call
    /// first in `webView(_:decidePolicyFor:decisionHandler:)`. Returns false, without calling `decisionHandler`, when
    /// the browser should decide as usual. In open mode a DuckDuckGo search is held while the page classifier checks
    /// it; if it passes, `decideAgain` runs, and should call that delegate method again with the same arguments.
    public func handle(_ action: WKNavigationAction,
                       in webView: WKWebView,
                       presenter: UIViewController?,
                       decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void,
                       decideAgain: @escaping @MainActor () -> Void) -> Bool {
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
        case .block(let blocked, let reason):
            decisionHandler(.cancel)
            showBlockedPage(at: blocked, reason: reason, in: webView)
        case .askToAllow(let blocked):
            decisionHandler(.cancel)
            SettingsLock.shared.requestAccess(from: presenter) { [weak self, weak webView] in
                self?.allow(blocked)
                webView?.load(URLRequest(url: blocked))
                return nil
            }
        case .checkSearch(let search, let query):
            Task { [weak self, weak webView] in
                let verdict = await PageClassifier.first(within: PageCheck.timeout) {
                    await PageClassifier.shared.checkSearch(query)
                } ?? .failed
                guard let self, let webView else { return decisionHandler(.cancel) }
                // If open mode ended meanwhile, the allowlist decides the search as any other address.
                guard self.checksPages,
                      case .block(let blocked, let reason)? = self.decideSearch(search, in: webView, verdict: verdict)
                else { return decideAgain() }
                decisionHandler(.cancel)
                self.showBlockedPage(at: blocked, reason: reason, in: webView)
            }
        }
        return true
    }

    /// The policy for a load the user doesn't see as a page, such as reader view fetching an article: anything that
    /// isn't allowed, including where a redirect leads, is cancelled. In open mode it loads, since reader view's page
    /// is checked when it's shown.
    public func policy(forBackgroundLoad action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard isEnabled, !checksPages, action.targetFrame?.isMainFrame ?? true, let url = action.request.url
        else { return .allow }
        return allows(url) ? .allow : .cancel
    }

    /// Whether a link preview may load. Previews open in a web view without the browser's navigation delegate, where
    /// a redirect couldn't be checked and no page check runs, so there are none while the allowlist is on, in either
    /// mode.
    public var allowsLinkPreviews: Bool { !isEnabled }
}
#endif
