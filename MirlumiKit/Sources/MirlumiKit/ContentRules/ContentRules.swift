// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CryptoKit
import Foundation
import JavaScriptCore
import WebKit
import os
#if canImport(UIKit)
import UIKit
#endif

/// Hides and blocks short-form video (Instagram Reels, YouTube Shorts, Snapchat Spotlight) and app prompts. A content
/// rule list hides what the rules hide, in every frame and before any script runs; a user script runs the page engine,
/// which also redirects blocked paths, refuses links to them and pauses hidden media. The app bundles a set of rules
/// and replaces it with newer signed rules it downloads, so the rules follow site changes without an app release.
///
/// The rules, the page engine, the validator and the rule list converter come from `packages/content-rules/` in the
/// mirlumi repository, through `Generated/`, with the bundled rules' list already converted. Whatever the source, only
/// what `validate.js` rebuilt reaches a page.
@MainActor
public final class ContentRules {
    /// Rules that passed `validate.js`: `json` is rebuilt from the checked fields, never the downloaded text, and
    /// `ruleList` is the WKContentRuleList `rule-list.js` makes from them.
    struct Validated: Equatable {
        let version: Int
        let json: String
        let ruleList: String
    }

    nonisolated static let ruleListIdentifier = "mirlumi-content-rules"

    /// Far above the rules' size (a few KB); stops a broken server or cache from filling memory.
    nonisolated static let maxBytes = 1024 * 1024

    public static let shared = ContentRules()

    /// The script every page's main frame gets at document start, in the page world: where WebKit lacks the
    /// Navigation API, the engine replaces `History.prototype` methods, which only the page's own world shares.
    public private(set) var userScript: WKUserScript
    private(set) var current: Validated
    /// The compiled list for `current`, once compiled. Nil also when `current` hides nothing.
    private(set) var ruleList: WKContentRuleList?
    /// The compilation of `current`'s list.
    private(set) var compiling: Task<Void, Never>?

    private let engine: String
    private let validator: String
    private let ruleListScript: String
    /// Mirlumi's own store: Firefox empties the default one when it resets its tracking protection lists.
    private let ruleListStore: WKContentRuleListStore?
    private let publicKey: P256.Signing.PublicKey?
    private let remoteURL: URL?
    private let cacheURL: URL
    private let session: URLSession?
    private let webViews = NSHashTable<WKWebView>.weakObjects()
    private var refreshing = false
    nonisolated private static let log = Logger(subsystem: "app.mirlumi.browser", category: "ContentRules")

    private struct Config: Decodable {
        let url: String
        let publicKey: String
        let placeholderKey: Bool
    }

    /// - Parameters:
    ///   - publicKey: the key downloads must be signed with; nil means config.json's.
    ///   - session: what refreshes download with; nil never downloads.
    ///   - refreshesAutomatically: download on creation and whenever the app returns to the foreground.
    init(
        cacheURL: URL = ContentRules.defaultCacheURL,
        ruleListStoreURL: URL = ContentRules.defaultRuleListStoreURL,
        publicKey: P256.Signing.PublicKey? = nil,
        session: URLSession? = ContentRules.downloadSession(),
        refreshesAutomatically: Bool = true
    ) {
        func resource(_ name: String) -> String {
            let url = Self.generatedResources.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                fatalError("Generated/\(name) is missing from MirlumiKit")
            }
            return text
        }
        let engine = resource("engine.js")
        let validator = resource("validate.js")
        let ruleListScript = resource("rule-list.js")
        self.engine = engine
        self.validator = validator
        self.ruleListScript = ruleListScript
        try? FileManager.default.createDirectory(at: ruleListStoreURL, withIntermediateDirectories: true)
        ruleListStore = WKContentRuleListStore(url: ruleListStoreURL)
        let config = try? JSONDecoder().decode(Config.self, from: Data(resource("config.json").utf8))
        let publicKey = publicKey ?? config
            .flatMap { Data(base64Encoded: $0.publicKey) }
            .flatMap { try? P256.Signing.PublicKey(derRepresentation: $0) }
        self.publicKey = publicKey
        remoteURL = config.flatMap { URL(string: $0.url) }.flatMap { $0.scheme == "https" ? $0 : nil }
        self.cacheURL = cacheURL
        self.session = session

        // The bundled rules' list was converted when they were generated, by the same rule-list.js.
        let bundled = Self.validate(resource("rules.json"), validator: validator, ruleList: ruleListScript)
            .map { Validated(version: $0.version, json: $0.json, ruleList: resource("content-rule-list.json")) }
        let cached = (try? FileHandle(forReadingFrom: cacheURL))
            // One byte over the limit is enough for verify to refuse the file.
            .flatMap { try? $0.read(upToCount: Self.maxBytes + 1) }
            .flatMap { Self.verify($0, publicKey: publicKey, validator: validator, ruleList: ruleListScript) }
        // Running without rules would quietly show a child everything; the generator refuses invalid bundled rules.
        guard let rules = [bundled, cached].compactMap({ $0 }).max(by: { $0.version < $1.version }) else {
            fatalError("Generated/rules.json is invalid")
        }
        current = rules
        userScript = Self.userScript(engine: engine, rules: rules)
        compileRuleList(for: rules)

        if refreshesAutomatically {
            #if canImport(UIKit)
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshInBackground() }
            }
            #endif
            refreshInBackground()
        }
    }

    /// Adds the rules to `webView`'s pages, and keeps them current there when newer rules arrive. Call it after
    /// the web view's user scripts were (re)installed, and after its content rule lists were all removed.
    public func install(in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        if !controller.userScripts.contains(where: { $0 === userScript }) {
            controller.addUserScript(userScript)
        }
        // A list with the same identifier replaces the one there.
        if let ruleList {
            controller.add(ruleList)
        }
        webViews.add(webView)
    }

    /// Downloads the signed rules. Returns whether they replaced the current ones.
    @discardableResult
    func refresh() async -> Bool {
        guard let session, let remoteURL, !refreshing else { return false }
        refreshing = true
        defer { refreshing = false }
        do {
            var request = URLRequest(url: remoteURL)
            request.httpShouldHandleCookies = false
            let (bytes, response) = try await session.bytes(for: request, delegate: RefuseRedirects())
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= Self.maxBytes else {
                    bytes.task.cancel()
                    Self.log.error("content rules rejected: too large")
                    return false
                }
            }
            return try accept(data)
        } catch {
            Self.log.error("content rules refresh failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Makes a signed document the current rules and caches it, if it verifies and is newer than the current ones.
    func accept(_ data: Data) throws -> Bool {
        guard let rules = Self.verify(data, publicKey: publicKey, validator: validator, ruleList: ruleListScript) else {
            Self.log.error("content rules rejected: bad signature or invalid rules")
            return false
        }
        // Only ever move forward, so an older signed file served again can't bring back rules that were replaced.
        guard rules.version > current.version else { return false }
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
        apply(rules)
        Self.log.info("content rules updated to version \(rules.version)")
        return true
    }

    private func refreshInBackground() {
        Task { await refresh() }
    }

    /// Swaps in `rules` for later page loads, and in pages already open: the engine replaces its rules in place.
    private func apply(_ rules: Validated) {
        let previous = userScript
        current = rules
        userScript = Self.userScript(engine: engine, rules: rules)
        for webView in webViews.allObjects {
            let controller = webView.configuration.userContentController
            // WebKit can only remove every user script, so put back all the others.
            let others = controller.userScripts.filter { $0 !== previous && $0 !== userScript }
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
            controller.addUserScript(userScript)
            webView.evaluateJavaScript(userScript.source, in: nil, in: .page, completionHandler: nil)
        }
        compileRuleList(for: rules)
    }

    /// Compiles `rules`' list and puts it in every web view in place of the previous one, unless newer rules came
    /// first. Until then the previous list stays, and the engine hides what the new rules hide.
    private func compileRuleList(for rules: Validated) {
        let previous = compiling
        compiling = Task { [weak self] in
            await previous?.value
            guard let self, self.current == rules else { return }
            var compiled: WKContentRuleList?
            if !Self.isEmpty(rules.ruleList) {
                do {
                    compiled = try await self.ruleListStore?.compileContentRuleList(
                        forIdentifier: Self.ruleListIdentifier, encodedContentRuleList: rules.ruleList
                    )
                } catch {
                    Self.log.error("content rule list failed to compile: \(error.localizedDescription, privacy: .public)")
                    return
                }
            }
            guard self.current == rules else { return }
            let replaced = self.ruleList
            self.ruleList = compiled
            for webView in self.webViews.allObjects {
                let controller = webView.configuration.userContentController
                if let replaced {
                    controller.remove(replaced)
                }
                if let compiled {
                    controller.add(compiled)
                }
            }
        }
    }

    /// WebKit refuses to compile a list without rules.
    nonisolated private static func isEmpty(_ ruleList: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(ruleList.utf8)) as? [Any])?.isEmpty ?? false
    }

    static func userScript(engine: String, rules: Validated) -> WKUserScript {
        WKUserScript(
            source: "(function () {\n\(engine)\nmirlumiContentRules(\(rules.json));\n})();",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
    }

    /// The rules in a signed `{payload, signature}` document: base64 of the rules JSON, and base64 of its
    /// ECDSA P-256 / SHA-256 signature in the raw 64-byte form. Nil unless the signature holds and the rules are valid.
    nonisolated static func verify(
        _ signed: Data,
        publicKey: P256.Signing.PublicKey?,
        validator: String,
        ruleList: String
    ) -> Validated? {
        guard signed.count <= maxBytes,
              let publicKey,
              let document = try? JSONSerialization.jsonObject(with: signed) as? [String: Any],
              Set(document.keys) == ["payload", "signature"],
              let encodedPayload = document["payload"] as? String,
              let encodedSignature = document["signature"] as? String,
              let payload = Data(base64Encoded: encodedPayload),
              let raw = Data(base64Encoded: encodedSignature),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
              publicKey.isValidSignature(signature, for: payload),
              // JSON.parse refuses a byte order mark, but decoding could drop it first.
              !payload.starts(with: [0xEF, 0xBB, 0xBF]),
              let text = String(data: payload, encoding: .utf8)
        else { return nil }
        return validate(text, validator: validator, ruleList: ruleList)
    }

    /// The rules in `text` as `validate.js` rebuilds them, with the list `rule-list.js` makes of them, or nil when
    /// `validate.js` refuses them.
    nonisolated static func validate(_ text: String, validator: String, ruleList: String) -> Validated? {
        guard text.utf8.count <= maxBytes, let context = JSContext() else { return nil }
        var failed = false
        context.exceptionHandler = { _, exception in
            failed = true
            log.error("content rules invalid: \(exception?.toString() ?? "", privacy: .public)")
        }
        context.evaluateScript(validator)
        context.evaluateScript(ruleList)
        // The text is passed as a value, so nothing in it is ever evaluated as code.
        guard !failed,
              let result = context.objectForKeyedSubscript("validateContentRules")?.call(withArguments: [text]),
              !failed,
              let json = result.forProperty("json"), json.isString,
              let version = result.forProperty("version"), version.isNumber,
              let list = context.objectForKeyedSubscript("mirlumiContentRuleList")?
                  .call(withArguments: [result.forProperty("rules") as Any]),
              !failed,
              // Formatted as generate.mjs writes content-rule-list.json, so the bundled rules' lists are identical.
              let listJSON = context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [list, NSNull(), 2]),
              !failed, listJSON.isString
        else { return nil }
        return Validated(version: Int(version.toDouble()), json: json.toString(), ruleList: listJSON.toString() + "\n")
    }

    nonisolated static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mirlumi-content-rules.json")
    }

    nonisolated static var defaultRuleListStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mirlumi-content-rule-lists", isDirectory: true)
    }

    nonisolated static var generatedResources: URL {
        Bundle.module.url(forResource: "Generated", withExtension: nil)!
    }

    /// No cookies, no cache: the request carries nothing about the person using the app.
    nonisolated static func downloadSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }
}

/// Only the configured URL counts: a redirect could only come from a misconfigured or compromised host.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
