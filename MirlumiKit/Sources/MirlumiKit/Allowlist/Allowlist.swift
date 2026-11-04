// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import JavaScriptCore

/// Where `Allowlist` keeps the sites a parent allowed, and the browsing mode they chose.
public protocol ParentSiteStore {
    func read() -> [String]
    func write(_ sites: [String])
    func readMode() -> String?
    func writeMode(_ mode: String)
}

struct DefaultsSiteStore: ParentSiteStore {
    private static let key = "MirlumiAllowlistParentSites"
    private static let modeKey = "MirlumiAllowlistBrowsingMode"
    let defaults: UserDefaults

    func read() -> [String] { defaults.stringArray(forKey: Self.key) ?? [] }
    func write(_ sites: [String]) { defaults.set(sites, forKey: Self.key) }
    func readMode() -> String? { defaults.string(forKey: Self.modeKey) }
    func writeMode(_ mode: String) { defaults.set(mode, forKey: Self.modeKey) }
}

/// What opens besides the list for children and the parent's sites.
public enum BrowsingMode: String, Sendable {
    /// Nothing else.
    case allowlist
    /// Everything else, once the page classifier has checked it on the device.
    case open
}

/// The matcher from packages/allowlist, the file Android's extension runs too, evaluated in JavaScriptCore. The same
/// context runs the page classifier's script for `searchQuery`, which needs no model.
final class AllowlistMatcher {
    private let api: JSValue
    private let classifier: JSValue?
    private let bundled: [String]
    private var matcher: JSValue?
    private var flaggedMatcher: JSValue?

    /// Fails if either script doesn't load: without `searchQuery` open mode couldn't tell a search from a page.
    init?(script: String, classifierScript: String?) {
        guard let context = JSContext() else { return nil }
        context.evaluateScript(script)
        guard context.exception == nil,
              let api = context.objectForKeyedSubscript("MirlumiAllowlist"), api.isObject,
              let bundled = context.objectForKeyedSubscript("MirlumiAllowlistSites")?.toArray() as? [String]
        else { return nil }
        if let classifierScript {
            context.evaluateScript(classifierScript)
            guard context.exception == nil,
                  let classifier = context.objectForKeyedSubscript("MirlumiPageClassifier"),
                  classifier.objectForKeyedSubscript("searchQuery")?.isObject == true
            else { return nil }
            self.classifier = classifier
        } else {
            self.classifier = nil
        }
        self.api = api
        self.bundled = bundled
        update(parentSites: [])
    }

    func update(flaggedSites: [String]) {
        flaggedMatcher = flaggedSites.isEmpty
            ? nil
            : api.invokeMethod("create", withArguments: [[[String](), flaggedSites]])
    }

    /// Whether the flagged sites cover `host` and `path`, as the parent's sites would.
    func isFlagged(host: String, path: String) -> Bool {
        flaggedMatcher?.invokeMethod("allows", withArguments: [host, path])?.toBool() ?? false
    }

    /// Whether `entry` alone covers `host` and `path`.
    func covers(_ entry: String, host: String, path: String) -> Bool {
        api.invokeMethod("create", withArguments: [[[String](), [entry]]])?
            .invokeMethod("allows", withArguments: [host, path])?.toBool() ?? false
    }

    /// The search in a DuckDuckGo results address, or nil for any other address.
    func searchQuery(_ address: String) -> String? {
        guard let query = classifier?.invokeMethod("searchQuery", withArguments: [address]), query.isString else {
            return nil
        }
        return query.toString()
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

    /// Set once at launch from `MirlumiBuild.pageClassifierEnabled`. Without it the mode is always `.allowlist`.
    public var isOpenModeAvailable = false

    /// The blocked page navigates here to ask for the PIN.
    static let allowURL = URL(string: "internal://local/mirlumi/allow")!

    /// What to do with a navigation.
    enum Decision: Equatable {
        /// Leave it to the browser.
        case pass
        case cancel
        /// Cancel it and show the blocked page in its place, with the page classifier's reason if it flagged it.
        case block(URL, reason: String? = nil)
        /// Cancel it and ask for the PIN to allow this address.
        case askToAllow(URL)
        /// Hold it until the page classifier has checked `query`, then call `decideSearch`.
        case checkSearch(URL, query: String)
    }

    /// Posted on the main actor whenever the parent's sites change.
    public static let parentSitesDidChange = Notification.Name("MirlumiAllowlistParentSitesDidChange")
    /// Posted on the main actor whenever the browsing mode changes.
    public static let browsingModeDidChange = Notification.Name("MirlumiAllowlistBrowsingModeDidChange")

    /// The address a page's latest main frame navigation went to, whether its page needs checking once loaded, and
    /// whether it's the blocked page.
    private final class PageMark {
        let url: URL
        let needsCheck: Bool
        let isBlockedPage: Bool
        init(url: URL, needsCheck: Bool, isBlockedPage: Bool) {
            self.url = url
            self.needsCheck = needsCheck
            self.isBlockedPage = isBlockedPage
        }
    }

    private let store: ParentSiteStore
    private let matcher: AllowlistMatcher?
    private var sites: [String]
    /// The address each page is blocked at, and the one whose blocked page is about to be shown there.
    private let blockedAddresses = NSMapTable<AnyObject, NSURL>.weakToStrongObjects()
    private let simulatedAddresses = NSMapTable<AnyObject, NSURL>.weakToStrongObjects()
    /// The search each page may go to without another check, once the classifier passed it.
    private let checkedSearches = NSMapTable<AnyObject, NSURL>.weakToStrongObjects()
    private let pageMarks = NSMapTable<AnyObject, PageMark>.weakToStrongObjects()
    private var storedMode: BrowsingMode
    /// Sites the page classifier flagged this session, as entries like the parent's, with the label each was flagged
    /// for. A parent allowing a site clears its entry.
    private var flaggedSites: [String: String] = [:]

    init(store: ParentSiteStore, script: String?, classifierScript: String? = PageClassifier.bundledScript) {
        self.store = store
        self.matcher = script.flatMap { AllowlistMatcher(script: $0, classifierScript: classifierScript) }
        self.sites = []
        self.storedMode = store.readMode().flatMap(BrowsingMode.init(rawValue:)) ?? .allowlist
        let stored = store.read().filter { matcher?.isEntry($0) == true }
        self.sites = Array(Set(stored)).sorted()
        matcher?.update(parentSites: sites)
    }

    /// The sites a parent allowed, sorted.
    public var parentSites: [String] { sites }

    /// The mode a parent chose. Always `.allowlist` while open mode isn't available.
    public var browsingMode: BrowsingMode {
        get { isOpenModeAvailable ? storedMode : .allowlist }
        set {
            guard newValue != storedMode else { return }
            storedMode = newValue
            store.writeMode(newValue.rawValue)
            NotificationCenter.default.post(name: Self.browsingModeDidChange, object: self)
        }
    }

    /// Whether pages outside the lists open after a check: the allowlist is on, in open mode.
    public var checksPages: Bool { isEnabled && browsingMode == .open }

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
        if flaggedSites.removeValue(forKey: entry) != nil {
            matcher?.update(flaggedSites: Array(flaggedSites.keys))
        }
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
    /// In open mode, a page no list allows passes and is marked for `needsPageCheck`, unless its site was flagged.
    func decide(_ url: URL, in page: AnyObject, isMainFrame: Bool, isLoad: Bool, source: URL?) -> Decision {
        if url == Self.allowURL {
            guard let blocked = blockedAddresses.object(forKey: page) as URL?, source == blocked else { return .cancel }
            return .askToAllow(blocked)
        }
        // A frame of a site flagged this session loads nothing in open mode. Other frames load, and are checked.
        guard isMainFrame else { return checksPages && isFlaggedFrame(url) ? .cancel : .pass }
        let checked = checkedSearches.object(forKey: page) as URL?
        checkedSearches.removeObject(forKey: page)
        if let article = Self.readerArticle(of: url) {
            guard let article else { return .cancel }
            if allows(article) {
                mark(url, in: page, needsCheck: false)
                return .pass
            }
            guard checksPages else { return block(article, in: page, reason: nil) }
            if let label = flaggedLabel(of: article) { return block(article, in: page, reason: label) }
            // Reader view shows the article's text, which the page check reads like any page.
            mark(url, in: page, needsCheck: true)
            return .pass
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .pass }
        // The blocked page is loaded in the address's place without fetching it. That load is the very next
        // navigation in the page, so whatever comes next uses up the exception.
        let simulated = simulatedAddresses.object(forKey: page) as URL?
        simulatedAddresses.removeObject(forKey: page)
        if isLoad, simulated == url {
            mark(url, in: page, needsCheck: false, isBlockedPage: true)
            return .pass
        }
        // DuckDuckGo is on the list, so its searches are checked before the list is asked.
        if checksPages, checked != url, let query = matcher?.searchQuery(url.absoluteString) {
            return .checkSearch(url, query: query)
        }
        if allows(url) {
            blockedAddresses.removeObject(forKey: page)
            mark(url, in: page, needsCheck: false)
            return .pass
        }
        guard checksPages else { return block(url, in: page, reason: nil) }
        if let label = flaggedLabel(of: url) { return block(url, in: page, reason: label) }
        mark(url, in: page, needsCheck: true)
        return .pass
    }

    /// Decides a search `decide` held for the classifier. A flagged search is blocked with no way to allow it, since
    /// the search engine's site is allowed already, and so is one that couldn't be checked. Returns nil when the
    /// navigation should be decided again, which then passes the search to the list.
    func decideSearch(_ url: URL, in page: AnyObject, verdict: PageVerdict) -> Decision? {
        let reason: String
        switch verdict {
        case .clear:
            checkedSearches.setObject(url as NSURL, forKey: page)
            return nil
        case .flagged(let label):
            reason = "search:\(label)"
        case .failed:
            reason = "search:\(Self.uncheckedReason)"
        }
        blockedAddresses.removeObject(forKey: page)
        simulatedAddresses.setObject(url as NSURL, forKey: page)
        return .block(url, reason: reason)
    }

    /// Whether the document at `url` in `page` waits for the page classifier before it's shown. Only open mode checks
    /// pages; there, a page the navigation policy didn't see is checked unless a list allows it.
    /// Whether a frame's document at `frameURL`, in a page at `pageURL`, waits for the page classifier. A frame with an
    /// http or https address is judged as its own site; any other, such as `about:srcdoc` or `about:blank`, with the
    /// page that holds it. Only open mode checks frames.
    func needsFrameCheck(at frameURL: URL?, inPageAt pageURL: URL?) -> Bool {
        guard checksPages else { return false }
        if let frameURL, Self.isWebAddress(frameURL) { return !allows(frameURL) }
        return pageURL.map { !allows($0) } ?? true
    }

    /// Whether a frame's navigation to `url` goes to a site flagged this session that no list allows.
    func isFlaggedFrame(_ url: URL) -> Bool {
        Self.isWebAddress(url) && !allows(url) && flaggedLabel(of: url) != nil
    }

    static func isWebAddress(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    func needsPageCheck(in page: AnyObject, at url: URL) -> Bool {
        guard checksPages else { return false }
        if let mark = pageMarks.object(forKey: page), Self.isSameDocument(mark.url, url) { return mark.needsCheck }
        return !allows(url)
    }

    /// Blocks the page at `url` in `page` after its check: `verdict` flagged it, or the check failed. A reader view
    /// page is blocked at its article's address. A flagged site stays blocked in every page for the session, until a
    /// parent allows it, which they can from the blocked page. Returns nil for a clear verdict, unless the site was
    /// flagged meanwhile, in another page.
    func blockCheckedPage(_ url: URL, in page: AnyObject, verdict: PageVerdict) -> Decision? {
        let target = Self.checkedAddress(of: url)
        switch verdict {
        case .clear:
            guard !allows(target), let label = flaggedLabel(of: target) else { return nil }
            return block(target, in: page, reason: label)
        case .flagged(let label):
            flag(target, label: label)
            return block(target, in: page, reason: label)
        case .failed:
            return block(target, in: page, reason: Self.uncheckedReason)
        }
    }

    /// After a site was flagged in another page: blocks the document at `url` in `page` if it belongs to a flagged site,
    /// as `decide` would now. A reader view page counts by its article. The blocked page and allowed sites stay.
    func blockIfFlagged(_ url: URL, in page: AnyObject) -> Decision? {
        guard checksPages else { return nil }
        if let mark = pageMarks.object(forKey: page), mark.isBlockedPage, Self.isSameDocument(mark.url, url) {
            return nil
        }
        let target = Self.checkedAddress(of: url)
        guard let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https",
              !allows(target), let label = flaggedLabel(of: target)
        else { return nil }
        return block(target, in: page, reason: label)
    }

    /// The address a page check judges: a reader view page's article, or the address itself.
    private static func checkedAddress(of url: URL) -> URL {
        if case .some(.some(let article)) = readerArticle(of: url) { return article }
        return url
    }

    /// Decides again what the document at `url` in `page` may show, after the mode changed. The blocked page stays.
    func revalidate(_ url: URL, in page: AnyObject) -> Decision {
        if let mark = pageMarks.object(forKey: page), mark.isBlockedPage, Self.isSameDocument(mark.url, url) {
            return .pass
        }
        return decide(url, in: page, isMainFrame: true, isLoad: false, source: nil)
    }

    /// The blocked page's reason for a page whose check timed out or failed.
    static let uncheckedReason = "unchecked"

    private func block(_ url: URL, in page: AnyObject, reason: String?) -> Decision {
        blockedAddresses.setObject(url as NSURL, forKey: page)
        simulatedAddresses.setObject(url as NSURL, forKey: page)
        return .block(url, reason: reason)
    }

    private func mark(_ url: URL, in page: AnyObject, needsCheck: Bool, isBlockedPage: Bool = false) {
        pageMarks.setObject(PageMark(url: url, needsCheck: needsCheck, isBlockedPage: isBlockedPage), forKey: page)
    }

    /// Marks the site of `url` flagged for the session, as a page check that flagged it does.
    func flag(_ url: URL, label: String) {
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false).flatMap(Self.host(of:)),
              let entry = matcher?.entry(forHost: host)
        else { return }
        flaggedSites[entry] = label
        matcher?.update(flaggedSites: Array(flaggedSites.keys))
    }

    /// The label the site of `url` was flagged for this session, or nil if it wasn't.
    private func flaggedLabel(of url: URL) -> String? {
        guard !flaggedSites.isEmpty, let matcher,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = Self.host(of: components)
        else { return nil }
        let path = components.percentEncodedPath
        guard matcher.isFlagged(host: host, path: path) else { return nil }
        return flaggedSites.keys.sorted().first { matcher.covers($0, host: host, path: path) }
            .flatMap { flaggedSites[$0] }
    }

    /// Whether two addresses name the same document: the same but for the fragment.
    static func isSameDocument(_ first: URL, _ second: URL) -> Bool {
        func withoutFragment(_ url: URL) -> String {
            let address = url.absoluteString
            return address.firstIndex(of: "#").map { String(address[..<$0]) } ?? address
        }
        return withoutFragment(first) == withoutFragment(second)
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

    /// The blocked page, saying why when the page classifier flagged the page: `reason` is a category such as
    /// `gambling`, or `search:gambling` for a search. The page reads it from its root element's `data-reason`.
    static func blockedPage(reason: String?) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_:")
        guard let reason, !reason.isEmpty, reason.unicodeScalars.allSatisfy(allowed.contains),
              let root = blockedPage.range(of: "<html>")
        else { return blockedPage }
        return blockedPage.replacingCharacters(in: root, with: "<html data-reason=\"\(reason)\">")
    }

    static var bundledScript: String? {
        Bundle.module.url(forResource: "MirlumiAllowlist", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
