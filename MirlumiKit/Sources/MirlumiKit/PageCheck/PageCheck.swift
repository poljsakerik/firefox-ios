// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

#if canImport(WebKit)
import Foundation
import WebKit

/// Open mode's page check. A user script, in a content world of its own, hides each main frame document as it starts
/// and asks whether it needs a check: one the navigation policy let through without a list allowing it. If it does,
/// the script sends the page's text once the document has loaded, and the classifier scores it. Only a clear verdict
/// for the document's latest text shows it. A flagged page is replaced by the blocked page, from which a parent can
/// allow the site; a check that fails or takes longer than `timeout` is replaced by the blocked page too, saying the
/// page couldn't be checked. After a clear verdict the script keeps watching: when the address or enough of the text
/// changes, as when a single page app moves on or an empty shell fills, it hides the page and asks again. Each ask
/// carries the document and a revision, and an answer for an older one is ignored.
///
/// The script is only in web views while open mode is on, so allowlist mode's pages are never held. Frames aren't
/// checked.
@MainActor
public final class PageCheck: NSObject {
    public static let shared = PageCheck(allowlist: .shared, classifier: PageClassifier.shared)

    /// How long a check, or a search's, may take before the page counts as unchecked.
    nonisolated static let timeout: TimeInterval = 3
    static let handlerName = "mirlumiPageCheck"
    static let world = WKContentWorld.world(name: "MirlumiPageCheck")

    /// What becomes of a page after a check of one of its revisions.
    enum Outcome: Equatable {
        /// Show it.
        case clear
        /// Replace it with the blocked page at this address, for this reason.
        case block(URL, reason: String)
        /// An answer for an older document or revision, or from before the mode changed: change nothing.
        case stale
        /// A frame that was flagged, or couldn't be checked: it stays hidden by its own gate.
        case hideFrame
    }

    /// The main frame's key among a page's frames. A frame's own key is its security origin and the token its
    /// script picked at random where the page can't read it: WebKit has no public identifier for a frame.
    static let mainFrame = "main"

    /// The documents of a page's frames, by frame key. A new main frame document drops them all.
    private final class PageDocuments {
        var frames: [String: Document] = [:]
    }

    private final class Document {
        let id: Int
        var revision = 0
        /// The address its latest revision was checked at, or where it started.
        var url: URL
        /// Whether its latest revision was cleared, or it needed no check.
        var cleared: Bool
        /// The latest revision when the script last hid the page for a change: clearing it, or an earlier one, no
        /// longer shows the page.
        var hiddenRevision = 0
        init(id: Int, url: URL, cleared: Bool) {
            self.id = id
            self.url = url
            self.cleared = cleared
        }
    }

    var timeout = PageCheck.timeout
    private let allowlist: Allowlist
    private let classifier: PageClassifying
    private let userScript: WKUserScript
    private let webViews = NSHashTable<WKWebView>.weakObjects()
    /// The documents each page shows, in its main frame and its other frames, from their scripts' start.
    private let documents = NSMapTable<AnyObject, PageDocuments>.weakToStrongObjects()
    private var lastDocument = 0
    /// The pages kept from view natively until their check clears them.
    private let concealed = NSHashTable<AnyObject>.weakObjects()
    private let loadingObservations = NSMapTable<WKWebView, NSKeyValueObservation>.weakToStrongObjects()
    /// The pages open now and the address each shows: every web view the check is installed in. Tests replace it.
    var openPages: () -> [(page: AnyObject, url: URL)]
    /// Replaces `page` with the blocked page. Tests replace it.
    var showBlocked: (AnyObject, URL, String) -> Void
    /// Hides `page` from view and touch, or shows it again. Tests replace it.
    var setPageConcealed: (AnyObject, Bool) -> Void
    /// Tells the script in `page` to stop checking and show it. Tests replace it.
    var stopScript: (AnyObject) -> Void

    init(allowlist: Allowlist, classifier: PageClassifying) {
        self.allowlist = allowlist
        self.classifier = classifier
        let pageText = Bundle.module.url(forResource: "MirlumiPageText", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        userScript = WKUserScript(source: "\(pageText)\n\(Self.script)",
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false,
                                  in: Self.world)
        let webViews = webViews
        openPages = { webViews.allObjects.compactMap { webView in webView.url.map { (webView, $0) } } }
        showBlocked = { page, url, reason in
            guard let webView = page as? WKWebView else { return }
            webView.stopLoading()
            allowlist.showBlockedPage(at: url, reason: reason, in: webView)
        }
        setPageConcealed = { page, isConcealed in
            #if canImport(UIKit)
            guard let webView = page as? WKWebView else { return }
            // Alpha rather than isHidden, so the page still lays out and runs its scripts.
            webView.alpha = isConcealed ? 0 : 1
            webView.isUserInteractionEnabled = !isConcealed
            #endif
        }
        stopScript = { page in
            (page as? WKWebView)?.evaluateJavaScript("if (globalThis.mirlumiPageCheckStop) mirlumiPageCheckStop();",
                                                     in: nil,
                                                     in: Self.world,
                                                     completionHandler: nil)
        }
        super.init()
        NotificationCenter.default.addObserver(
            forName: Allowlist.browsingModeDidChange, object: allowlist, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.modeChanged() }
        }
    }

    /// Adds the page check to `webView` where the build offers open mode, and keeps it there while open mode is on.
    /// Call it after the web view's user scripts were (re)installed.
    public func install(in webView: WKWebView?) {
        guard let webView, allowlist.isEnabled, allowlist.isOpenModeAvailable else { return }
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
        controller.addScriptMessageHandler(self, contentWorld: Self.world, name: Self.handlerName)
        webViews.add(webView)
        if loadingObservations.object(forKey: webView) == nil {
            let observation = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, change in
                guard change.newValue == false else { return }
                MainActor.assumeIsolated { self?.loadingStopped(in: webView) }
            }
            loadingObservations.setObject(observation, forKey: webView)
        }
        update(webView)
    }

    /// Whether `page` is kept from view until its check clears it.
    func isConcealed(_ page: AnyObject) -> Bool { concealed.contains(page) }

    /// The navigation policy let a main frame navigation to `url` in `page` through. A page that needs a check is
    /// hidden from here, before anything of it can be painted, until its check clears it; any other page is shown.
    func navigationPassed(to url: URL, in page: AnyObject) {
        let needsCheck = allowlist.needsPageCheck(in: page, at: url)
        conceal(page, needsCheck)
        guard needsCheck, let webView = page as? WKWebView else { return }
        // A navigation the browser cancels after the policy never loads, and leaves the page it came from.
        Task { [weak self, weak webView] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, let webView, !webView.isLoading else { return }
            self.loadingStopped(in: webView)
        }
    }

    private func document(in page: AnyObject, frame: String) -> Document? {
        documents.object(forKey: page)?.frames[frame]
    }

    /// Starts a new document in `page`'s frame `frame`. Returns its number if it needs a check, or nil to show it.
    /// Either way, answers still due for an earlier document in the frame become stale; a new main frame document
    /// makes every frame's stale. `url` is the page's address, and `frameURL` a frame's own.
    func startDocument(in page: AnyObject,
                       at url: URL,
                       frame: String = PageCheck.mainFrame,
                       frameURL: URL? = nil) -> Int? {
        lastDocument += 1
        let needsCheck: Bool
        if frame == Self.mainFrame {
            needsCheck = allowlist.needsPageCheck(in: page, at: url)
            let frames = PageDocuments()
            frames.frames[frame] = Document(id: lastDocument, url: url, cleared: !needsCheck)
            documents.setObject(frames, forKey: page)
            conceal(page, needsCheck)
        } else {
            // A frame is hidden by its own gate, not by concealing the web view, so a slow frame doesn't blank
            // the page around it.
            needsCheck = allowlist.needsFrameCheck(at: frameURL, inPageAt: url)
            let frames = documents.object(forKey: page) ?? PageDocuments()
            frames.frames[frame] = Document(id: lastDocument, url: frameURL ?? url, cleared: !needsCheck)
            documents.setObject(frames, forKey: page)
        }
        guard needsCheck else { return nil }
        classifier.prepare()
        return lastDocument
    }

    /// The script hid document `document` in frame `frame` of `page` for a change: only a clear verdict for a later
    /// revision shows it again, and a main frame is concealed now. Messages from an earlier document are ignored.
    func pageHidden(in page: AnyObject, document: Int, frame: String = PageCheck.mainFrame) {
        guard allowlist.checksPages, let current = self.document(in: page, frame: frame), current.id == document else {
            return
        }
        current.cleared = false
        current.hiddenRevision = current.revision
        if frame == Self.mainFrame {
            conceal(page, true)
        }
    }

    /// Checks revision `revision` of document `document` in frame `frame` of `page`, at `url`, whose text is `text`,
    /// or nil if the page couldn't be read. A main frame is hidden from view while it's checked, and shown only if
    /// this is still the latest revision of its document when the classifier clears it. A frame keeps its own gate
    /// until then; `frameURL` is its address.
    func check(_ text: PageText?,
               at url: URL,
               in page: AnyObject,
               document: Int,
               revision: Int,
               frame: String = PageCheck.mainFrame,
               frameURL: URL? = nil) async -> Outcome {
        let isMain = frame == Self.mainFrame
        guard allowlist.checksPages,
              let current = self.document(in: page, frame: frame), current.id == document, revision > current.revision
        else { return .stale }
        current.revision = revision
        current.cleared = false
        if isMain {
            current.url = url
            conceal(page, true)
        }
        var verdict = PageVerdict.failed
        if let text {
            let classifier = classifier
            verdict = await PageClassifier.first(within: timeout) { await classifier.checkPage(text) } ?? .failed
        }
        guard allowlist.checksPages, self.document(in: page, frame: frame) === current, current.revision == revision
        else { return .stale }
        if !isMain, let frameURL, Allowlist.isWebAddress(frameURL) {
            return frameOutcome(verdict, at: frameURL, in: page, frame: frame, document: current)
        }
        if !isMain, case .failed = verdict {
            // A frame that couldn't be checked stays hidden; it doesn't block the page around it.
            documents.object(forKey: page)?.frames[frame] = nil
            return .hideFrame
        }
        // The main frame, or a frame without an address of its own, which is judged with the page that holds it.
        guard case .block(let blocked, let reason)? = allowlist.blockCheckedPage(url, in: page, verdict: verdict)
        else {
            guard revision > current.hiddenRevision else { return .stale }
            current.cleared = true
            if isMain {
                conceal(page, false)
            }
            return .clear
        }
        // The blocked page replaces the document, so nothing it or its frames still send counts. It stays hidden
        // until the blocked page loads, which the navigation policy shows.
        documents.removeObject(forKey: page)
        conceal(page, true)
        if case .flagged = verdict {
            blockOtherPages(onSiteOf: page)
        }
        return .block(blocked, reason: reason ?? Allowlist.uncheckedReason)
    }

    /// The outcome for a frame with an address of its own: a flagged one flags its site, whose other open pages are
    /// blocked, and stays hidden, as does one that couldn't be checked or whose site was flagged meanwhile.
    private func frameOutcome(_ verdict: PageVerdict,
                              at frameURL: URL,
                              in page: AnyObject,
                              frame: String,
                              document: Document) -> Outcome {
        switch verdict {
        case .clear where !allowlist.isFlaggedFrame(frameURL):
            guard document.revision > document.hiddenRevision else { return .stale }
            document.cleared = true
            return .clear
        case .flagged(let label):
            allowlist.flag(frameURL, label: label)
            documents.object(forKey: page)?.frames[frame] = nil
            blockOtherPages(onSiteOf: nil)
            return .hideFrame
        default:
            documents.object(forKey: page)?.frames[frame] = nil
            return .hideFrame
        }
    }

    /// After a page was flagged: every other open page of its site is blocked now, and no answer still due for one of
    /// them can show it.
    private func blockOtherPages(onSiteOf flagged: AnyObject?) {
        for (page, url) in openPages() where page !== flagged {
            guard case .block(let blocked, let reason)? = allowlist.blockIfFlagged(url, in: page) else { continue }
            documents.removeObject(forKey: page)
            conceal(page, true)
            showBlocked(page, blocked, reason ?? Allowlist.uncheckedReason)
        }
    }

    private func modeChanged() {
        // No answer due from before the change may show a page.
        documents.removeAllObjects()
        for webView in webViews.allObjects {
            update(webView)
        }
        guard !allowlist.checksPages else { return }
        var blocked: [AnyObject] = []
        for (page, url) in openPages() {
            switch allowlist.revalidate(url, in: page) {
            case .block(let address, let reason):
                // Kept hidden until the blocked page loads.
                blocked.append(page)
                conceal(page, true)
                showBlocked(page, address, reason ?? Allowlist.uncheckedReason)
            case .pass:
                stopScript(page)
            default:
                break
            }
        }
        for page in concealed.allObjects where !blocked.contains(where: { $0 === page }) {
            conceal(page, false)
        }
    }

    private func conceal(_ page: AnyObject, _ isConcealed: Bool) {
        guard isConcealed != concealed.contains(page) else { return }
        if isConcealed {
            concealed.add(page)
        } else {
            concealed.remove(page)
        }
        setPageConcealed(page, isConcealed)
    }

    /// A load ended, or never started. A document that was cleared, or needs no check, is shown; one still being
    /// checked stays hidden until its answer. A document that needed a check but whose script never asked, such as a
    /// file scripts don't run in, counts as unchecked once `timeout` has passed.
    private func loadingStopped(in webView: WKWebView) {
        guard isConcealed(webView) else { return }
        guard let url = webView.url else { return conceal(webView, false) }
        if let document = document(in: webView, frame: Self.mainFrame), Allowlist.isSameDocument(document.url, url) {
            if document.cleared { conceal(webView, false) }
            return
        }
        guard allowlist.needsPageCheck(in: webView, at: url) else { return conceal(webView, false) }
        Task { [weak self, weak webView] in
            try? await Task.sleep(nanoseconds: UInt64((self?.timeout ?? PageCheck.timeout) * 1_000_000_000))
            guard let self, let webView, self.isConcealed(webView), !webView.isLoading, webView.url == url,
                  self.document(in: webView, frame: Self.mainFrame)
                    .map({ !Allowlist.isSameDocument($0.url, url) }) ?? true,
                  self.allowlist.needsPageCheck(in: webView, at: url),
                  case .block(let blocked, let reason)? = self.allowlist.blockCheckedPage(url,
                                                                                          in: webView,
                                                                                          verdict: .failed)
            else { return }
            self.showBlocked(webView, blocked, reason ?? Allowlist.uncheckedReason)
        }
    }

    private func update(_ webView: WKWebView) {
        let controller = webView.configuration.userContentController
        let installed = controller.userScripts.contains { $0 === userScript }
        if allowlist.checksPages, !installed {
            controller.addUserScript(userScript)
            classifier.prepare()
        } else if !allowlist.checksPages, installed {
            // WebKit can only remove every user script, so put back all the others.
            let others = controller.userScripts.filter { $0 !== userScript }
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
        }
    }

    /// Hides the document and asks whether it needs a check. If it does, sends its text once loaded, and shows it
    /// only on a clear verdict for the latest revision. Then watches it: a batch of mutations that adds enough text,
    /// or a new address, hides it before it's painted, and a recheck follows unless `changedEnough` says the page
    /// hardly changed. Nothing here shows a page on a timeout or an error.
    private static let script = """
    (function () {
      "use strict";
      const root = document.documentElement;
      if (!root) {
        return;
      }
      // An isolated world keeps this script's variables from the page, not the DOM: the gate is an element in the
      // page's own tree, which its scripts can remove, edit or override, and its style sheet can be changed through
      // the CSSOM without any DOM mutation. While the page should be hidden, the gate is repaired whenever a mutation
      // is seen, whenever the page changes, before it's read, and before every frame. Native concealment is what
      // holds: the web view itself is hidden whenever a check is due. The gap left is between an in-page hide and
      // native hearing of it, a message's trip of a few milliseconds.
      const GATE = ":root:root:root:root{opacity:0 !important;pointer-events:none !important}";
      const style = document.createElement("style");
      style.textContent = GATE;
      let gated = false;
      let stopped = false;
      let gateRule = null;
      let frame = 0;
      const repairSheet = () => {
        const sheet = style.sheet;
        if (!sheet) {
          return;
        }
        if (sheet.disabled) {
          sheet.disabled = false;
        }
        try {
          const rules = sheet.cssRules;
          if (gateRule === null && rules.length === 1) {
            gateRule = rules[0].cssText;
          }
          if (rules.length !== 1 || rules[0].cssText !== gateRule) {
            while (sheet.cssRules.length > 0) {
              sheet.deleteRule(0);
            }
            sheet.insertRule(GATE, 0);
          }
        } catch (e) {
          style.textContent = "";
          style.textContent = GATE;
        }
      };
      const restore = () => {
        const parent = document.documentElement || root;
        if (style.disabled) {
          style.disabled = false;
        }
        if (style.textContent !== GATE) {
          style.textContent = GATE;
        }
        if (style.parentNode !== parent) {
          parent.appendChild(style);
        }
        repairSheet();
        const inline = parent.style;
        if (inline) {
          for (const property of ["opacity", "visibility", "display"]) {
            if (inline.getPropertyValue(property)) {
              inline.removeProperty(property);
            }
          }
        }
      };
      const keepGate = () => {
        frame = 0;
        if (stopped || !gated) {
          return;
        }
        restore();
        frame = requestAnimationFrame(keepGate);
      };
      const hide = () => {
        gated = true;
        restore();
        if (!frame && typeof requestAnimationFrame === "function") {
          frame = requestAnimationFrame(keepGate);
        }
      };
      const show = () => {
        gated = false;
        if (frame) {
          cancelAnimationFrame(frame);
          frame = 0;
        }
        style.remove();
      };
      const guard = new MutationObserver(() => {
        if (gated && !stopped) {
          restore();
        }
      });
      guard.observe(root, { childList: true, attributes: true, attributeFilter: ["style"] });
      guard.observe(style, { childList: true, characterData: true, subtree: true, attributes: true });
      hide();
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
      // Without the handler nothing can clear the page, so it stays hidden.
      if (!handler) {
        return;
      }
      const text = MirlumiPageText;
      // This script runs in every frame. Native tells a frame's documents apart by this token, which only this world
      // can read, and the frame's origin.
      const frameToken = (() => {
        const values = new Uint32Array(4);
        if (typeof crypto !== "undefined" && crypto.getRandomValues) {
          crypto.getRandomValues(values);
        } else {
          for (let i = 0; i < values.length; i++) {
            values[i] = Math.floor(Math.random() * 4294967296);
          }
        }
        return Array.from(values, (value) => value.toString(16)).join("");
      })();
      const HIDE_AFTER_CHARS = 200;
      const SETTLE_MS = 300;
      const ATTRIBUTE_READ_MS = 100;
      let documentId = 0;
      let revision = 0;
      let cleared = false;
      let hiddenForChange = false;
      let sent = null;
      let added = 0;
      let timer = 0;
      let observer = null;
      let watching = false;
      let parsingTimer = 0;
      let lastAttributeRead = 0;
      let attributeTimer = 0;

      globalThis.mirlumiPageCheckStop = () => {
        stopped = true;
        guard.disconnect();
        if (observer) {
          observer.disconnect();
        }
        clearTimeout(timer);
        clearTimeout(parsingTimer);
        clearTimeout(attributeTimer);
        show();
      };

      const read = () => {
        try {
          return text.readPage(document);
        } catch (e) {
          return null;
        }
      };

      const send = (page) => {
        revision += 1;
        const current = revision;
        cleared = false;
        hiddenForChange = false;
        added = 0;
        hide();
        const address = location.href;
        sent = page ? text.pageState(address, page) : null;
        const message = { type: "page", frame: frameToken, document: documentId, revision: current, address, page };
        handler.postMessage(message).then(
          (reply) => {
            if (stopped || !reply || reply.verdict !== "clear" || reply.revision !== current || current !== revision) {
              return;
            }
            hide();
            const latest = read();
            if (!latest || text.changedEnough(sent, text.pageState(location.href, latest))) {
              send(latest);
              return;
            }
            cleared = true;
            if (!hiddenForChange) {
              show();
            }
          },
          () => {}
        );
      };

      const settle = () => {
        timer = 0;
        if (stopped) {
          return;
        }
        if (gated) {
          restore();
        }
        const page = read();
        // Once native was told the page is hidden for a change, only a new check shows it, even if the text went back.
        if (hiddenForChange || !page || text.changedEnough(sent, text.pageState(location.href, page))) {
          send(page);
          return;
        }
        added = 0;
        hiddenForChange = false;
        if (cleared) {
          show();
        }
      };

      const changed = (hideNow) => {
        if (stopped) {
          return;
        }
        if (hideNow) {
          hide();
          if (!hiddenForChange) {
            hiddenForChange = true;
            // Native conceals the web view at once, and shows it again only for a later revision's clear verdict.
            handler.postMessage({ type: "hidden", frame: frameToken, document: documentId, revision })
              .then(() => {}, () => {});
          }
        } else if (gated) {
          restore();
        }
        if (!timer) {
          timer = setTimeout(settle, SETTLE_MS);
        }
      };

      // Attribute changes can reveal hidden text, but animations make them constantly. The page is read at most once
      // every ATTRIBUTE_READ_MS, with one read after the last change, and hidden only if its text changed enough.
      const attributeCheck = () => {
        attributeTimer = 0;
        lastAttributeRead = Date.now();
        if (stopped) {
          return;
        }
        const page = read();
        if (!page || !sent || text.changedEnough(sent, text.pageState(location.href, page))) {
          changed(true);
        }
      };

      const attributeChanged = () => {
        if (attributeTimer) {
          return;
        }
        const wait = lastAttributeRead + ATTRIBUTE_READ_MS - Date.now();
        if (wait <= 0) {
          attributeCheck();
        } else {
          attributeTimer = setTimeout(attributeCheck, wait);
        }
      };

      const watch = () => {
        if (stopped || watching) {
          return;
        }
        watching = true;
        clearTimeout(parsingTimer);
        send(read());
        observer = new MutationObserver((records) => {
          const theirs = records.filter((record) => {
            if (record.target === style) {
              return false;
            }
            const nodes = [...record.addedNodes, ...record.removedNodes];
            return nodes.length === 0 || !nodes.every((node) => node === style);
          });
          if (gated) {
            restore();
          }
          if (theirs.length === 0) {
            return;
          }
          added += text.textAdded(theirs);
          const attributes = theirs.filter((record) => record.type === "attributes");
          // An attribute change on elements holding real text is read at once, before paint, and hides the page only
          // if its text changed, so a class change on <html> or <body> doesn't blink. Small animated elements are read
          // on the throttle.
          if (added >= HIDE_AFTER_CHARS || !sent || location.href !== sent.address) {
            changed(true);
          } else if (attributes.length > 0 && text.attributeText(attributes) >= HIDE_AFTER_CHARS) {
            clearTimeout(attributeTimer);
            attributeCheck();
          } else if (attributes.length > 0) {
            attributeChanged();
          } else {
            changed(false);
          }
        });
        observer.observe(document.documentElement,
          { subtree: true, childList: true, characterData: true, attributes: true });
        addEventListener("popstate", () => changed(true));
        addEventListener("hashchange", () => changed(true));
      };

      const begin = () => handler.postMessage({ type: "start", frame: frameToken }).then(
        (reply) => {
          if (stopped || !reply) {
            return;
          }
          if (!reply.check) {
            show();
            return;
          }
          documentId = reply.document;
          if (watching) {
            send(read());
          } else if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", watch, { once: true });
            parsingTimer = setTimeout(watch, \(Int(timeout * 1000)));
          } else {
            watch();
          }
        },
        () => {}
      );
      begin();
      // A page restored from the back-forward cache doesn't run this script again, but native counts it as a new
      // document, which has to be checked before it's shown.
      addEventListener("pageshow", (event) => {
        if (event.persisted && !stopped) {
          hide();
          begin();
        }
      });
    })();
    """
}

extension Allowlist {
    /// Shows the blocked page in place of `url`, so the address bar keeps the address and reload asks again.
    func showBlockedPage(at url: URL, reason: String?, in webView: WKWebView) {
        let html = Self.blockedPage(reason: reason)
        DispatchQueue.main.async { [weak webView] in
            webView?.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
        }
    }
}

extension PageCheck: WKScriptMessageHandlerWithReply {
    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage,
                                      replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        // Every frame's script talks here, from Mirlumi's own world, which the page's scripts can't reach.
        guard let webView = message.webView, let body = message.body as? [String: Any] else {
            return replyHandler(nil, nil)
        }
        let isMain = message.frameInfo.isMainFrame
        let frame: String
        if isMain {
            frame = Self.mainFrame
        } else {
            guard let token = body["frame"] as? String, !token.isEmpty else { return replyHandler(nil, nil) }
            let origin = message.frameInfo.securityOrigin
            frame = "\(origin.protocol)://\(origin.host):\(origin.port)/\(token)"
        }
        guard let url = webView.url ?? (isMain ? message.frameInfo.request.url : nil) else {
            return replyHandler(nil, nil)
        }
        let frameURL = isMain ? nil : message.frameInfo.request.url
        switch body["type"] as? String {
        case "start":
            if let document = startDocument(in: webView, at: url, frame: frame, frameURL: frameURL) {
                replyHandler(["check": true, "document": document], nil)
            } else {
                replyHandler(["check": false], nil)
            }
        case "hidden":
            if let document = body["document"] as? Int {
                pageHidden(in: webView, document: document, frame: frame)
            }
            replyHandler(nil, nil)
        case "page":
            guard let document = body["document"] as? Int, let revision = body["revision"] as? Int else {
                return replyHandler(nil, nil)
            }
            let text = PageText(message: body["page"])
            Task { [weak self, weak webView] in
                guard let self, let webView else { return replyHandler(nil, nil) }
                let outcome = await self.check(text,
                                               at: url,
                                               in: webView,
                                               document: document,
                                               revision: revision,
                                               frame: frame,
                                               frameURL: frameURL)
                switch outcome {
                case .clear:
                    replyHandler(["verdict": "clear", "revision": revision], nil)
                case .stale:
                    replyHandler(["verdict": "stale", "revision": revision], nil)
                case .hideFrame:
                    replyHandler(["verdict": "blocked", "revision": revision], nil)
                case .block(let blocked, let reason):
                    replyHandler(["verdict": "blocked", "revision": revision], nil)
                    webView.stopLoading()
                    self.allowlist.showBlockedPage(at: blocked, reason: reason, in: webView)
                }
            }
        default:
            replyHandler(nil, nil)
        }
    }
}
#endif
