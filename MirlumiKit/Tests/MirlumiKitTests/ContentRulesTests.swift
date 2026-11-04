// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CryptoKit
import Foundation
import WebKit
import XCTest

@testable import MirlumiKit

/// Fixtures come from `make-fixtures.mjs`, which signs with the mirlumi repository's packages/content-rules/lib.mjs.
/// They're relative to the bundled rules' version: run it again whenever rules.json's version changes. They're read
/// from the source tree, not bundled: a test target with resources would change `Bundle.module` in every test.
@MainActor
final class ContentRulesTests: XCTestCase {
    /// XCTest makes a new instance for every test, so each one gets its own cache.
    private let cacheURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("rules.json")

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> Data {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        return try Data(contentsOf: fixtures.appendingPathComponent(name))
    }

    private func debugKey() throws -> P256.Signing.PublicKey {
        try P256.Signing.PublicKey(pemRepresentation: String(decoding: fixture("debug.pem"), as: UTF8.self))
    }

    private func rules(publicKey: P256.Signing.PublicKey? = nil) throws -> ContentRules {
        ContentRules(
            cacheURL: cacheURL,
            ruleListStoreURL: ruleListStoreURL,
            publicKey: try publicKey ?? debugKey(),
            session: nil,
            refreshesAutomatically: false
        )
    }

    private var ruleListStoreURL: URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent("rule-lists", isDirectory: true)
    }

    private func validate(_ text: String) throws -> ContentRules.Validated? {
        ContentRules.validate(text, validator: try generated("validate.js"), ruleList: try generated("rule-list.js"))
    }

    private func generated(_ name: String) throws -> String {
        try String(contentsOf: ContentRules.generatedResources.appendingPathComponent(name), encoding: .utf8)
    }

    func testBundledRulesValidate() throws {
        let validated = try XCTUnwrap(validate(generated("rules.json")))
        // The bundled list is generate.mjs's content-rule-list.json; rule-list.js in JavaScriptCore makes the same.
        XCTAssertEqual(validated.ruleList, try generated("content-rule-list.json"))
        XCTAssertEqual(try rules().current, validated)
        for site in ["instagram", "youtube", "snapchat"] {
            XCTAssertTrue(validated.json.contains("\"\(site)\":["), site)
        }
    }

    func testPageScriptRunsTheEngineWithTheRules() throws {
        let rules = try rules()
        let script = rules.userScript
        XCTAssertEqual(script.injectionTime, .atDocumentStart)
        XCTAssertTrue(script.isForMainFrameOnly)
        XCTAssertTrue(script.source.hasPrefix("(function () {\n"))
        XCTAssertTrue(script.source.contains("function mirlumiContentRules(rules)"))
        XCTAssertTrue(script.source.hasSuffix("mirlumiContentRules(\(rules.current.json));\n})();"))
    }

    /// The real configuration: what the debug key signs verifies with config.json's key while that's the placeholder.
    func testConfiguredKeyAcceptsDebugSignedRulesWhilePlaceholder() throws {
        let config = try JSONSerialization.jsonObject(with: Data(generated("config.json").utf8)) as? [String: Any]
        guard config?["placeholderKey"] as? Bool == true else {
            throw XCTSkip("config.json trusts the real release key; debug-signed fixtures no longer verify")
        }
        let rules = ContentRules(
            cacheURL: cacheURL, ruleListStoreURL: ruleListStoreURL, session: nil, refreshesAutomatically: false
        )
        XCTAssertTrue(try rules.accept(fixture("next-version.json")))
    }

    func testAcceptsNewerSignedRulesAndStartsFromThemNextTime() throws {
        let rules = try rules()
        let bundledVersion = rules.current.version
        XCTAssertTrue(try rules.accept(fixture("next-version.json")))
        XCTAssertEqual(rules.current.version, bundledVersion + 1)
        XCTAssertTrue(rules.userScript.source.contains(rules.current.json))
        XCTAssertEqual(try self.rules().current.version, bundledVersion + 1)
    }

    func testRefusesRulesThatAreNotNewer() throws {
        let rules = try rules()
        XCTAssertFalse(try rules.accept(fixture("same-version.json")))
        XCTAssertTrue(try rules.accept(fixture("next-version.json")))
        XCTAssertFalse(try rules.accept(fixture("next-version.json")))
        XCTAssertFalse(try rules.accept(fixture("same-version.json")))
    }

    func testRefusesDocumentsThatDoNotVerifyOrValidate() throws {
        let rules = try rules()
        let bundled = rules.current
        for name in ["other-key.json", "byte-order-mark.json", "invalid-rules.json"] {
            XCTAssertFalse(try rules.accept(fixture(name)), name)
        }

        let signed = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("next-version.json")) as? [String: String])
        let payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(signed["payload"])))
        var tampered = payload
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        let documents: [String: [String: Any]] = [
            "tampered payload": ["payload": tampered.base64EncodedString(), "signature": signed["signature"]!],
            "signature of something else": [
                "payload": payload.base64EncodedString(),
                "signature": Data(count: 64).base64EncodedString(),
            ],
            "extra key": signed.merging(["note": "x"]) { $1 },
            "missing signature": ["payload": signed["payload"]!],
            "signature as a number": ["payload": signed["payload"]!, "signature": 1],
        ]
        for (name, document) in documents {
            XCTAssertFalse(try rules.accept(JSONSerialization.data(withJSONObject: document)), name)
        }

        // A valid document padded past the size limit.
        var oversize = try fixture("next-version.json")
        oversize.append(Data(repeating: 0x20, count: ContentRules.maxBytes))
        XCTAssertFalse(try rules.accept(oversize))

        XCTAssertEqual(rules.current, bundled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testIgnoresACacheThatDoesNotVerify() throws {
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture("other-key.json").write(to: cacheURL)
        let bundled = try validate(generated("rules.json"))
        XCTAssertEqual(try rules().current, bundled)
    }

    func testValidatorRefusesWhatTheEngineMustNotSee() throws {
        let group = #"{"hosts":["instagram.com"],"blockPaths":["^/reels"]}"#
        XCTAssertNotNil(try validate(#"{"schema":1,"version":1,"sites":{"instagram":[\#(group)]}}"#))
        for text in [
            "",
            "{}",
            #"{"schema":1,"version":1,"sites":{}} x"#,
            #"{"schema":1,"version":1,"sites":{},}"#,
            #"{"schema":2,"version":1,"sites":{}}"#,
            #"{"schema":1,"version":0,"sites":{}}"#,
            #"{"schema":1,"version":1,"sites":{},"extra":true}"#,
            #"{"schema":1,"version":1,"sites":{"instagram":[{"hosts":["instagram.com"],"blockPaths":["^/("]}]}}"#,
            #"{"schema":1,"version":1,"sites":{"instagram":[{"hosts":["instagram.com"],"hide":["a{}"]}]}}"#,
            #"{"schema":1,"version":1,"sites":{"instagram":[{"hosts":["instagram.com"],"blockPaths":["^/x"],"redirect":"/x"}]}}"#,
        ] {
            XCTAssertNil(try validate(text), text)
        }
    }

    func testInstallsTheScriptOnceAndSwapsItWhenRulesChange() throws {
        let rules = try rules()
        let webView = WKWebView()
        let controller = webView.configuration.userContentController
        let other = WKUserScript(source: "1", injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        controller.addUserScript(other)
        rules.install(in: webView)
        rules.install(in: webView)
        XCTAssertEqual(controller.userScripts.count, 2)

        let previous = rules.userScript
        XCTAssertTrue(try rules.accept(fixture("next-version.json")))
        XCTAssertEqual(controller.userScripts.count, 2)
        XCTAssertTrue(controller.userScripts.contains { $0 === other })
        XCTAssertTrue(controller.userScripts.contains { $0 === rules.userScript })
        XCTAssertFalse(controller.userScripts.contains { $0 === previous })
    }

    func testRuleListIsEmptyWhenNothingIsHidden() throws {
        let rules = try XCTUnwrap(validate(#"{"schema":1,"version":1,"sites":{"instagram":[{"hosts":["instagram.com"],"blockPaths":["^/reels"]}]}}"#))
        XCTAssertEqual(rules.ruleList, "[]\n")
    }

    // MARK: In WebKit

    private let instagram = URL(string: "https://www.instagram.com/")!
    private let feed = """
        <article id="photo"><a href="/p/abc/">post</a></article>
        <article id="reel"><a href="/reel/xyz/">reel</a></article>
        """

    private func display(_ id: String, in webView: WKWebView) async throws -> String? {
        try await webView.callAsyncJavaScript(
            "return getComputedStyle(document.getElementById(id)).display", arguments: ["id": id], contentWorld: .page
        ) as? String
    }

    func testRuleListHidesWithoutThePageScript() async throws {
        let rules = try rules()
        await rules.compiling?.value
        XCTAssertNotNil(rules.ruleList)
        let webView = WKWebView()
        rules.install(in: webView)
        webView.configuration.userContentController.removeAllUserScripts()
        try await PageLoad().load(feed, baseURL: instagram, in: webView)
        let reel = try await display("reel", in: webView)
        XCTAssertEqual(reel, "none")
        let photo = try await display("photo", in: webView)
        XCTAssertEqual(photo, "block")
    }

    /// What the hook in Firefox's ContentBlocker does after it removed every list from a web view.
    func testInstallingAgainRestoresTheRuleListAfterAllListsWereRemoved() async throws {
        let rules = try rules()
        await rules.compiling?.value
        let webView = WKWebView()
        rules.install(in: webView)
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        rules.install(in: webView)
        controller.removeAllUserScripts()
        try await PageLoad().load(feed, baseURL: instagram, in: webView)
        let reel = try await display("reel", in: webView)
        XCTAssertEqual(reel, "none")
    }

    func testNewerRulesGetTheirOwnRuleList() async throws {
        let rules = try rules()
        await rules.compiling?.value
        let previous = try XCTUnwrap(rules.ruleList)
        XCTAssertTrue(try rules.accept(fixture("next-version.json")))
        await rules.compiling?.value
        let current = try XCTUnwrap(rules.ruleList)
        XCTAssertFalse(current === previous)
    }

    /// WebKit before Safari 16.4, which iOS 15 to 16.3 have, can't construct a CSSStyleSheet.
    func testPageScriptHidesWithoutConstructibleStyleSheets() async throws {
        let rules = try rules()
        let webView = WKWebView()
        let controller = webView.configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: "window.CSSStyleSheet = function () { throw new TypeError('Illegal constructor'); };",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
        controller.addUserScript(rules.userScript)
        try await PageLoad().load(feed, baseURL: instagram, in: webView)
        let constructs = try await webView.callAsyncJavaScript(
            "try { new CSSStyleSheet(); return true } catch (e) { return false }", contentWorld: .page
        ) as? Bool
        XCTAssertEqual(constructs, false)
        let reel = try await display("reel", in: webView)
        XCTAssertEqual(reel, "none")
        let photo = try await display("photo", in: webView)
        XCTAssertEqual(photo, "block")
    }
}

/// Loads HTML into a web view and waits for it to finish.
@MainActor
private final class PageLoad: NSObject, WKNavigationDelegate {
    private var finished: CheckedContinuation<Void, Error>?

    func load(_ html: String, baseURL: URL, in webView: WKWebView) async throws {
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            finished = continuation
            webView.loadHTMLString("<!doctype html><body>\(html)</body>", baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished?.resume()
        finished = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finished?.resume(throwing: error)
        finished = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finished?.resume(throwing: error)
        finished = nil
    }
}
