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
