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
    }

    private final class Document {
        let id: Int
        var revision = 0
        init(id: Int) { self.id = id }
    }

    var timeout = PageCheck.timeout
    private let allowlist: Allowlist
    private let classifier: PageClassifying
    private let userScript: WKUserScript
    private let webViews = NSHashTable<WKWebView>.weakObjects()
    /// The document each page shows, from its script's start.
    private let documents = NSMapTable<AnyObject, Document>.weakToStrongObjects()
    private var lastDocument = 0

    init(allowlist: Allowlist, classifier: PageClassifying) {
        self.allowlist = allowlist
        self.classifier = classifier
        let pageText = Bundle.module.url(forResource: "MirlumiPageText", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        userScript = WKUserScript(source: "\(pageText)\n\(Self.script)",
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: true,
                                  in: Self.world)
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
        update(webView)
    }

    /// Starts a new document in `page`. Returns its number if it needs a check, or nil to show it. Either way, answers
    /// still due for an earlier document in the page become stale.
    func startDocument(in page: AnyObject, at url: URL) -> Int? {
        lastDocument += 1
        documents.setObject(Document(id: lastDocument), forKey: page)
        guard allowlist.needsPageCheck(in: page, at: url) else { return nil }
        classifier.prepare()
        return lastDocument
    }

    /// Checks revision `revision` of document `document` in `page`, at `url`, whose text is `text`, or nil if the page
    /// couldn't be read.
    func check(_ text: PageText?, at url: URL, in page: AnyObject, document: Int, revision: Int) async -> Outcome {
        guard allowlist.checksPages,
              let current = documents.object(forKey: page), current.id == document, revision > current.revision
        else { return .stale }
        current.revision = revision
        var verdict = PageVerdict.failed
        if let text {
            let classifier = classifier
            verdict = await PageClassifier.first(within: timeout) { await classifier.checkPage(text) } ?? .failed
        }
        guard allowlist.checksPages, documents.object(forKey: page) === current, current.revision == revision else {
            return .stale
        }
        guard case .block(let blocked, let reason)? = allowlist.blockCheckedPage(url, in: page, verdict: verdict)
        else { return .clear }
        // The blocked page replaces the document, so nothing it still sends counts.
        documents.removeObject(forKey: page)
        return .block(blocked, reason: reason ?? Allowlist.uncheckedReason)
    }

    private func modeChanged() {
        // No answer due from before the change may show a page.
        documents.removeAllObjects()
        for webView in webViews.allObjects {
            update(webView)
            guard !allowlist.checksPages, let url = webView.url else { continue }
            switch allowlist.revalidate(url, in: webView) {
            case .block(let blocked, let reason):
                webView.stopLoading()
                allowlist.showBlockedPage(at: blocked, reason: reason, in: webView)
            case .pass:
                webView.evaluateJavaScript("if (globalThis.mirlumiPageCheckStop) mirlumiPageCheckStop();",
                                           in: nil,
                                           in: Self.world,
                                           completionHandler: nil)
            default:
                break
            }
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
      const style = document.createElement("style");
      style.textContent = "html{opacity:0 !important}";
      const hide = () => {
        const parent = document.documentElement || root;
        if (style.parentNode !== parent) {
          parent.appendChild(style);
        }
      };
      const show = () => style.remove();
      hide();
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
      // Without the handler nothing can clear the page, so it stays hidden.
      if (!handler) {
        return;
      }
      const text = MirlumiPageText;
      const HIDE_AFTER_CHARS = 200;
      const SETTLE_MS = 300;
      const ATTRIBUTE_READ_MS = 100;
      let stopped = false;
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
        handler.postMessage({ type: "page", document: documentId, revision: current, address, page }).then(
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
        const page = read();
        if (!page || text.changedEnough(sent, text.pageState(location.href, page))) {
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
          hiddenForChange = true;
          hide();
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
        if (stopped || timer) {
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
          if (theirs.length === 0) {
            return;
          }
          added += text.textAdded(theirs);
          if (added >= HIDE_AFTER_CHARS || !sent || location.href !== sent.address) {
            changed(true);
          } else if (theirs.some((record) => record.type === "attributes")) {
            attributeChanged();
          } else {
            changed(false);
          }
        });
        observer.observe(document.documentElement, { subtree: true, childList: true, characterData: true, attributes: true });
        addEventListener("popstate", () => changed(true));
        addEventListener("hashchange", () => changed(true));
      };

      handler.postMessage({ type: "start" }).then(
        (reply) => {
          if (stopped || !reply) {
            return;
          }
          if (!reply.check) {
            show();
            return;
          }
          documentId = reply.document;
          if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", watch, { once: true });
            parsingTimer = setTimeout(watch, \(Int(timeout * 1000)));
          } else {
            watch();
          }
        },
        () => {}
      );
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
        // Only the main frame's document counts; the script isn't in frames, and the world is Mirlumi's alone.
        guard message.frameInfo.isMainFrame,
              let webView = message.webView,
              let url = webView.url ?? message.frameInfo.request.url,
              let body = message.body as? [String: Any]
        else { return replyHandler(nil, nil) }
        switch body["type"] as? String {
        case "start":
            if let document = startDocument(in: webView, at: url) {
                replyHandler(["check": true, "document": document], nil)
            } else {
                replyHandler(["check": false], nil)
            }
        case "page":
            guard let document = body["document"] as? Int, let revision = body["revision"] as? Int else {
                return replyHandler(nil, nil)
            }
            let text = PageText(message: body["page"])
            Task { [weak self, weak webView] in
                guard let self, let webView else { return replyHandler(nil, nil) }
                switch await self.check(text, at: url, in: webView, document: document, revision: revision) {
                case .clear:
                    replyHandler(["verdict": "clear", "revision": revision], nil)
                case .stale:
                    replyHandler(["verdict": "stale", "revision": revision], nil)
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
