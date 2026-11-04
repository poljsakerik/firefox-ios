// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import JavaScriptCore

/// Where `Allowlist` keeps the sites a parent allowed.
public protocol ParentSiteStore {
    func read() -> [String]
    func write(_ sites: [String])
}

struct DefaultsSiteStore: ParentSiteStore {
    private static let key = "MirlumiAllowlistParentSites"
    let defaults: UserDefaults

    func read() -> [String] { defaults.stringArray(forKey: Self.key) ?? [] }
    func write(_ sites: [String]) { defaults.set(sites, forKey: Self.key) }
}

/// The matcher from packages/allowlist, the file Android's extension runs too, evaluated in JavaScriptCore.
final class AllowlistMatcher {
    private let api: JSValue
    private let bundled: [String]
    private var matcher: JSValue?

    init?(script: String) {
        guard let context = JSContext() else { return nil }
        context.evaluateScript(script)
        guard context.exception == nil,
              let api = context.objectForKeyedSubscript("MirlumiAllowlist"), api.isObject,
              let bundled = context.objectForKeyedSubscript("MirlumiAllowlistSites")?.toArray() as? [String]
        else { return nil }
        self.api = api
        self.bundled = bundled
        update(parentSites: [])
    }

    func update(parentSites: [String]) {
        matcher = api.invokeMethod("create", withArguments: [[bundled, parentSites]])
    }

    func allows(host: String, path: String) -> Bool {
        matcher?.invokeMethod("allows", withArguments: [host, path])?.toBool() ?? false
    }

    func entry(forHost host: String) -> String? {
        guard let entry = api.invokeMethod("entryForHost", withArguments: [host]), entry.isString else { return nil }
        return entry.toString()
    }

    func isEntry(_ entry: String) -> Bool {
        guard let parsed = api.invokeMethod("parseEntry", withArguments: [entry]) else { return false }
        return parsed.isObject
    }
}

/// Allowlist-only browsing: only sites on the list for children, and sites a parent allowed with the Settings PIN,
/// open. Any other page is replaced by a page that says so, from which a parent can allow the site.
@MainActor
public final class Allowlist {
    public static let shared = Allowlist(store: DefaultsSiteStore(defaults: .standard),
                                         script: Allowlist.bundledScript)

    /// Set once at launch from `MirlumiBuild.allowlistEnabled`.
    public var isEnabled = false

    /// The blocked page navigates here to ask for the PIN.
    static let allowURL = URL(string: "internal://local/mirlumi/allow")!

    /// What to do with a navigation.
    enum Decision: Equatable {
        /// Leave it to the browser.
        case pass
        case cancel
        /// Cancel it and show the blocked page in its place.
        case block(URL)
        /// Cancel it and ask for the PIN to allow this address.
        case askToAllow(URL)
    }

    /// Posted on the main actor whenever the parent's sites change.
    public static let parentSitesDidChange = Notification.Name("MirlumiAllowlistParentSitesDidChange")

    private let store: ParentSiteStore
    private let matcher: AllowlistMatcher?
    private var sites: [String]
    /// The address each page is blocked at, and the one whose blocked page is about to be shown there.
    private let blockedAddresses = NSMapTable<AnyObject, NSURL>.weakToStrongObjects()
    private let simulatedAddresses = NSMapTable<AnyObject, NSURL>.weakToStrongObjects()

    init(store: ParentSiteStore, script: String?) {
        self.store = store
        self.matcher = script.flatMap(AllowlistMatcher.init(script:))
        self.sites = []
        let stored = store.read().filter { matcher?.isEntry($0) == true }
        self.sites = Array(Set(stored)).sorted()
        matcher?.update(parentSites: sites)
    }

    /// The sites a parent allowed, sorted.
    public var parentSites: [String] { sites }

    /// Whether `url` opens. Addresses other than http and https are left to the browser. If the matcher couldn't load,
    /// nothing opens.
    public func allows(_ url: URL) -> Bool {
        if let article = Self.readerArticle(of: url) { return article.map(allows) ?? false }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return true }
        guard let matcher,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = Self.host(of: components)
        else { return false }
        return matcher.allows(host: host, path: components.percentEncodedPath)
    }

    /// Adds the site at `url` to the parent's sites. Returns the entry added, or nil if there's nothing to add.
    @discardableResult
    func allow(_ url: URL) -> String? {
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false).flatMap(Self.host(of:)),
              let entry = matcher?.entry(forHost: host)
        else { return nil }
        if !sites.contains(entry) {
            sites = (sites + [entry]).sorted()
            changed()
        }
        return entry
    }

    public func remove(_ entry: String) {
        guard sites.contains(entry) else { return }
        sites.removeAll { $0 == entry }
        changed()
    }

    private func changed() {
        store.write(sites)
        matcher?.update(parentSites: sites)
        NotificationCenter.default.post(name: Self.parentSitesDidChange, object: self)
    }

    /// Decides a navigation to `url` in `page`. `isMainFrame` is whether it replaces the page itself, `isLoad` whether
    /// the app started it rather than a link, reload or history, and `source` the address of the document it came from.
    func decide(_ url: URL, in page: AnyObject, isMainFrame: Bool, isLoad: Bool, source: URL?) -> Decision {
        if url == Self.allowURL {
            guard let blocked = blockedAddresses.object(forKey: page) as URL?, source == blocked else { return .cancel }
            return .askToAllow(blocked)
        }
        guard isMainFrame else { return .pass }
        if let article = Self.readerArticle(of: url) {
            guard let article else { return .cancel }
            if allows(article) { return .pass }
            blockedAddresses.setObject(article as NSURL, forKey: page)
            simulatedAddresses.setObject(article as NSURL, forKey: page)
            return .block(article)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .pass }
        // The blocked page is loaded in the address's place without fetching it. That load is the very next
        // navigation in the page, so whatever comes next uses up the exception.
        let simulated = simulatedAddresses.object(forKey: page) as URL?
        simulatedAddresses.removeObject(forKey: page)
        if isLoad, simulated == url { return .pass }
        if allows(url) {
            blockedAddresses.removeObject(forKey: page)
            return .pass
        }
        blockedAddresses.setObject(url as NSURL, forKey: page)
        simulatedAddresses.setObject(url as NSURL, forKey: page)
        return .block(url)
    }

    /// The host as entries are written: an international name in its ASCII form, anything else still percent-encoded so
    /// that the matcher refuses it. Before iOS 16 international names stay percent-encoded, so they don't open.
    static func host(of components: URLComponents) -> String? {
        if #available(iOS 16, macOS 13, *) { return components.encodedHost }
        return components.percentEncodedHost
    }

    /// For a reader view address, the article it shows, or `.some(nil)` if it doesn't name exactly one; nil for any other
    /// address. Reader view loads the article itself, so it's the article that has to be allowed. Every page of the
    /// reader scheme, and every reader path of the local server, counts, since their routers match path prefixes; and
    /// two `url` parameters are refused, since the server keeps the last and this check would see the first.
    static func readerArticle(of url: URL) -> URL?? {
        let scheme = url.scheme?.lowercased(), host = url.host?.lowercased()
        let isLocal = host == "localhost" || host == "127.0.0.1"
        let isReader = scheme == "readermode"
            || (scheme == "http" && isLocal && url.path.lowercased().hasPrefix("/reader-mode/"))
            || url.absoluteString.lowercased().hasPrefix("about:reader")
        guard isReader else { return nil }
        let articles = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name == "url" } ?? []
        guard articles.count == 1 else { return .some(nil) }
        return .some(articles[0].value.flatMap(URL.init(string:)))
    }

    /// The blocked page, from packages/allowlist.
    static let blockedPage: String = Bundle.module.url(forResource: "MirlumiBlocked", withExtension: "html")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    static var bundledScript: String? {
        Bundle.module.url(forResource: "MirlumiAllowlist", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
