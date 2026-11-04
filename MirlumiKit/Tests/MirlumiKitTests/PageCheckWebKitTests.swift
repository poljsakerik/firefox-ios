// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

#if canImport(WebKit)
import Foundation
import WebKit
import XCTest
@testable import MirlumiKit

/// The page check's script in a real web view: what a page can do to the gate from its own world.
@MainActor
final class PageCheckWebKitTests: XCTestCase {
    private final class MemoryStore: ParentSiteStore {
        func read() -> [String] { [] }
        func write(_ sites: [String]) {}
        func readMode() -> String? { "open" }
        func writeMode(_ mode: String) {}
    }

    /// Holds each check until the test answers it.
    private final class HeldClassifier: PageClassifying, @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<PageVerdict, Never>] = []

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return waiting.count
        }

        func prepare() {}
        func checkPage(_ page: PageText) async -> PageVerdict { await hold() }
        func checkSearch(_ query: String) async -> PageVerdict { await hold() }

        func answerAll(with verdict: PageVerdict) {
            lock.lock()
            let answers = waiting
            waiting.removeAll()
            lock.unlock()
            answers.forEach { $0.resume(returning: verdict) }
        }

        private func hold() async -> PageVerdict {
            await withCheckedContinuation { continuation in
                lock.lock()
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Waits for `condition`, letting WebKit's messages through on the main actor meanwhile.
    private func waitUntil(_ what: String, seconds: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The gate's rules as the page sees them: the count of rules in the style sheet that hides the page, or -1 if
    /// there's no such style element in the document.
    private func gateRules(in webView: WKWebView) async throws -> Int {
        let script = """
        (() => {
          const gate = [...document.querySelectorAll("style")]
            .find((style) => style.textContent.startsWith(":root:root:root:root"));
          return gate ? (gate.sheet ? gate.sheet.cssRules.length : 0) : -1;
        })()
        """
        return try await webView.evaluateJavaScript(script) as? Int ?? -2
    }

    /// The browser's navigation policy hook, as `Allowlist.handle` runs it in the app.
    private final class Policy: NSObject, WKNavigationDelegate {
        let allowlist: Allowlist
        let check: PageCheck
        init(allowlist: Allowlist, check: PageCheck) {
            self.allowlist = allowlist
            self.check = check
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.allow) }
            let isMainFrame = action.targetFrame?.isMainFrame ?? false
            let sourceFrame: WKFrameInfo? = action.sourceFrame
            switch allowlist.decide(url, in: webView, isMainFrame: isMainFrame,
                                    isLoad: action.navigationType == .other, source: sourceFrame?.request.url) {
            case .pass:
                if isMainFrame { check.navigationPassed(to: url, in: webView) }
                decisionHandler(.allow)
            case .block(let blocked, let reason):
                decisionHandler(.cancel)
                allowlist.showBlockedPage(at: blocked, reason: reason, in: webView)
            default:
                decisionHandler(.cancel)
            }
        }
    }

    private func openPage(_ html: String, at address: String) -> (WKWebView, PageCheck, Policy) {
        let allowlist = Allowlist(store: MemoryStore(), script: Allowlist.bundledScript)
        allowlist.isEnabled = true
        allowlist.isOpenModeAvailable = true
        let check = PageCheck(allowlist: allowlist,
                              classifier: PageClassifier(script: PageClassifier.bundledScript,
                                                         modelURL: PageClassifier.bundledModelURL))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let policy = Policy(allowlist: allowlist, check: check)
        webView.navigationDelegate = policy
        check.install(in: webView)
        webView.loadHTMLString(html, baseURL: URL(string: address)!)
        return (webView, check, policy)
    }

    private func reason(in webView: WKWebView) async -> String? {
        try? await webView.evaluateJavaScript("document.documentElement.getAttribute('data-reason') || ''") as? String
    }

    private let gardenText = """
        <h1>Growing tomatoes</h1><p>Plant tomatoes in a sunny spot after the last frost. Water them deeply once a week,
        tie the stems to stakes as they grow, and pinch out the side shoots. Feed them with compost every month.</p>
        """
    private let casinoText = """
        <h1>Play slots for real money</h1><h2>Best sports betting odds</h2><p>Sign up, deposit and play over 2,000
        casino games. Spin the slots, try live roulette and blackjack, and bet on football with the best odds.
        Withdraw your winnings fast. Claim a 200% welcome bonus and 100 free spins.</p>
        """

    func testAPageWithASrcdocFrameOfCasinoTextIsBlocked() async throws {
        let html = """
            <!DOCTYPE html><html><head><title>Growing tomatoes</title></head><body>\(gardenText)
            <iframe style="position:fixed;inset:0;width:100%;height:100%;border:0"
              srcdoc="<!DOCTYPE html><title>Casino</title>\(casinoText.replacingOccurrences(of: "\"", with: "&quot;"))">
            </iframe></body></html>
            """
        let (webView, check, policy) = openPage(html, at: "https://harmless.example/")
        var blockedReason: String?
        try await waitUntil("the page is blocked", seconds: 20) {
            Task { blockedReason = await self.reason(in: webView) }
            return blockedReason == "gambling"
        }
        try await waitUntil("the blocked page is shown") { !check.isConcealed(webView) }
        _ = policy
    }

    func testAPageWithAHarmlessSrcdocFrameIsShown() async throws {
        let html = """
            <!DOCTYPE html><html><head><title>Growing tomatoes</title></head><body>\(gardenText)
            <iframe srcdoc="<p>Basil likes the same sunny spot as tomatoes, and keeps some pests away.</p>"></iframe>
            </body></html>
            """
        let (webView, check, policy) = openPage(html, at: "https://harmless.example/")
        try await waitUntil("the page is shown", seconds: 20) { !check.isConcealed(webView) }
        try await Task.sleep(nanoseconds: 500_000_000)
        let shownReason = await reason(in: webView)
        XCTAssertEqual(shownReason, "")
        XCTAssertFalse(check.isConcealed(webView))
        _ = policy
    }

    func testAPageThatDeletesTheGateRuleAfterAChangeStaysConcealedUntilItsRecheckClears() async throws {
        let allowlist = Allowlist(store: MemoryStore(), script: Allowlist.bundledScript)
        allowlist.isEnabled = true
        allowlist.isOpenModeAvailable = true
        let classifier = HeldClassifier()
        let check = PageCheck(allowlist: allowlist, classifier: classifier)
        check.timeout = 60
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        check.install(in: webView)
        webView.loadHTMLString("""
            <!DOCTYPE html><html><head><title>Banana bread</title></head>
            <body><h1>Banana bread</h1><p>Mash three ripe bananas and bake for an hour.</p></body></html>
            """, baseURL: URL(string: "https://example.com/")!)

        try await waitUntil("the first check arrives") { classifier.count == 1 }
        XCTAssertTrue(check.isConcealed(webView))
        classifier.answerAll(with: .clear)
        try await waitUntil("the page is shown") { !check.isConcealed(webView) }
        // Native shows the web view as it replies; the script takes the gate down when the reply reaches it.
        var shownRules = try await gateRules(in: webView)
        for _ in 0..<100 where shownRules != -1 {
            try await Task.sleep(nanoseconds: 20_000_000)
            shownRules = try await gateRules(in: webView)
        }
        XCTAssertEqual(shownRules, -1, "the gate is gone once the page is cleared")

        // The page swaps in new text, which hides it again, then deletes the gate's rule through the CSSOM, which no
        // DOM mutation reports.
        _ = try await webView.evaluateJavaScript("""
            document.body.innerHTML = "<p>" + "Play slots and roulette for real money. ".repeat(20) + "</p>"; 1
            """)
        try await waitUntil("native conceals the web view") { check.isConcealed(webView) }
        XCTAssertEqual(classifier.count, 0, "concealed as the page hid, before its recheck was sent")
        let hiddenRules = try await gateRules(in: webView)
        XCTAssertEqual(hiddenRules, 1)
        _ = try await webView.evaluateJavaScript("""
            [...document.querySelectorAll("style")]
              .find((style) => style.textContent.startsWith(":root:root:root:root")).sheet.deleteRule(0); 1
            """)

        // The recheck is sent with the gate repaired, and the web view stays concealed while it's under way.
        try await waitUntil("the recheck arrives") { classifier.count == 1 }
        let repairedRules = try await gateRules(in: webView)
        XCTAssertEqual(repairedRules, 1)
        XCTAssertTrue(check.isConcealed(webView))

        classifier.answerAll(with: .clear)
        try await waitUntil("the page is shown again") { !check.isConcealed(webView) }
    }
}
#endif
