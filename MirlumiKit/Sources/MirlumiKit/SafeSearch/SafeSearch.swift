// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import JavaScriptCore

/// Sends every page load on a DuckDuckGo search host to safe.duckduckgo.com, where DuckDuckGo applies strict safe
/// search whatever the page's own setting says. The rules are `safe-search.js`, which packages/safe-search in the
/// mirlumi repository generates for both platforms. Android runs the same file in a built-in extension.
@MainActor
public final class SafeSearch {
    public static let shared = SafeSearch()

    /// Set once at launch from `MirlumiBuild.safeSearchEnabled`.
    public var isEnabled = false

    private let rewrite: JSValue?
    #if canImport(WebKit)
    private lazy var navigationGuard = NavigationGuard(safeSearch: self)
    #endif

    init(script: String? = SafeSearch.bundledScript()) {
        let context = JSContext()
        if let script {
            context?.evaluateScript(script)
        }
        rewrite = context?.objectForKeyedSubscript("MirlumiSafeSearch")?.objectForKeyedSubscript("safeSearchUrl")
        assert(rewrite?.isObject == true, "safe-search.js didn't define MirlumiSafeSearch.safeSearchUrl")
    }

    /// The address to load instead of `url`, or nil to load `url` unchanged.
    public func safeURL(for url: URL) -> URL? {
        guard isEnabled,
              let result = rewrite?.call(withArguments: [url.absoluteString]),
              result.isString,
              let address = result.toString()
        else { return nil }
        return URL(string: address)
    }

    nonisolated static func bundledScript() -> String? {
        guard let url = Bundle.module.url(forResource: "safe-search", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

#if canImport(WebKit)
import WebKit

extension SafeSearch {
    /// Cancels `action` when it loads a page on a DuckDuckGo search host, and loads the safe search address in its
    /// place. A frame inside a page is only cancelled. Returns false, deciding nothing, for every other action.
    public func redirect(_ action: WKNavigationAction,
                         in webView: WKWebView,
                         decisionHandler: @MainActor (WKNavigationActionPolicy) -> Void) -> Bool {
        // A link to a new window has no frame yet: its own load, in the new tab, comes back here.
        guard let frame = action.targetFrame,
              let url = action.request.url,
              let safeURL = safeURL(for: url)
        else { return false }

        decisionHandler(.cancel)
        if frame.isMainFrame {
            var request = action.request
            request.url = safeURL
            webView.load(request)
        }
        return true
    }

    /// Applies `redirect` to every navigation in a web view that has no navigation delegate of its own, such as a link
    /// preview.
    public func guardNavigation(of webView: WKWebView) {
        webView.navigationDelegate = navigationGuard
    }
}

@MainActor
final class NavigationGuard: NSObject, WKNavigationDelegate {
    private unowned let safeSearch: SafeSearch

    init(safeSearch: SafeSearch) {
        self.safeSearch = safeSearch
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if !safeSearch.redirect(navigationAction, in: webView, decisionHandler: decisionHandler) {
            decisionHandler(.allow)
        }
    }
}
#endif
