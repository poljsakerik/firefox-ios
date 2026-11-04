// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import OSLog
import WebKit

/// Hides every image on a page until it's been checked, then shows it, or a placeholder when it's explicit. The page
/// engine from packages/image-check runs as a user script in its own content world and hands each image here: Apple's
/// Sensitive Content Analysis judges it where a parent has Communication Safety or Sensitive Content Warning on, and
/// the bundled model from model.json everywhere else.
@MainActor
public final class ImageCheck: NSObject, WKScriptMessageHandlerWithReply {
    public static let shared = ImageCheck()

    nonisolated static let handlerName = "mirlumiImageCheck"
    nonisolated private static let log = Logger(subsystem: "app.mirlumi.browser", category: "ImageCheck")

    /// Whether the check is on. Set once at launch from `MirlumiBuild.imageCheckEnabled`.
    public var isEnabled = false

    /// The generated config.json: the engine's settings, which MirlumiKit reads a few of.
    struct Settings: Decodable, Sendable {
        let maxBytes: Int
        let maxFrames: Int
    }

    nonisolated static let settings: Settings = {
        guard let settings = try? JSONDecoder().decode(Settings.self, from: Data(resource("config.json").utf8)) else {
            fatalError("ImageCheckGenerated/config.json doesn't hold the image check's settings")
        }
        return settings
    }()

    private let world = WKContentWorld.world(name: "mirlumi-image-check")
    private let checker: ImageChecker
    private lazy var userScript: WKUserScript = {
        let engine = Self.resource("engine.js")
        let config = Self.resource("config.json")
        let source = """
            (function () {
            \(engine)
            mirlumiImageCheck(\(config), function (request) {
              return window.webkit.messageHandlers.\(Self.handlerName).postMessage(request);
            });
            })();
            """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }()

    init(checker: ImageChecker = ImageChecker(settings: ImageCheck.settings, loadModel: ImageCheck.loadModel)) {
        self.checker = checker
    }

    /// Adds the check to `webView`'s pages. Call it whenever the web view's user scripts were (re)installed.
    public func install(in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        if !controller.userScripts.contains(where: { $0 === userScript }) {
            controller.addUserScript(userScript)
        }
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: world)
        controller.addScriptMessageHandler(self, contentWorld: world, name: Self.handlerName)
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard let request = ImageRequest(message.body) else {
            return (ImageAnswer.error("bad request").dictionary, nil)
        }
        // A message without its web view is treated as from a private tab: nothing about it is kept.
        let isPrivate = message.webView.map { !$0.configuration.websiteDataStore.isPersistent } ?? true
        let answer = await checker.check(request, isPrivate: isPrivate)
        return (answer.dictionary, nil)
    }

    nonisolated static var generatedResources: URL {
        Bundle.module.url(forResource: "ImageCheckGenerated", withExtension: nil)!
    }

    nonisolated static func resource(_ name: String) -> String {
        guard let text = try? String(contentsOf: generatedResources.appendingPathComponent(name), encoding: .utf8) else {
            fatalError("ImageCheckGenerated/\(name) is missing from MirlumiKit")
        }
        return text
    }

    /// Whether the long-press menu may offer Save Image and Copy Image, which hand over an image unchecked.
    public var allowsSavingImages: Bool { !isEnabled }

    /// Whether the long-press menu may offer Download Link: not on an image. A link that only leads to one is refused
    /// when its response arrives, by `allowsFile(mimeType:)`.
    public func allowsDownloadLink(hasImage: Bool) -> Bool {
        !isEnabled || !hasImage
    }

    /// Whether a response of this type may be downloaded, or kept to be shared as a file. An image would leave the
    /// browser unchecked, whatever its address looks like.
    public func allowsFile(mimeType: String?) -> Bool {
        !isEnabled || !(mimeType?.lowercased().hasPrefix("image/") ?? false)
    }

    nonisolated static func loadModel() -> OnnxImageModel? {
        do {
            return try OnnxImageModel(directory: generatedResources)
        } catch {
            log.error("image check model didn't load: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// One image the page needs checked: its address, or its bytes for data: and blob: images.
struct ImageRequest: Sendable {
    enum Source: Sendable, Equatable {
        case url(URL, page: URL?)
        /// Decoded by `ImageChecker`, off the main actor: data: URLs can be megabytes.
        case dataURL(String)
    }

    let source: Source

    init(source: Source) {
        self.source = source
    }

    init?(_ body: Any) {
        guard let body = body as? [String: Any] else { return nil }
        if let text = body["url"] as? String, let url = URL(string: text), ["http", "https"].contains(url.scheme) {
            source = .url(url, page: (body["page"] as? String).flatMap(URL.init(string:)))
        } else if let text = body["data"] as? String, text.hasPrefix("data:"), text.contains(",") {
            source = .dataURL(text)
        } else {
            return nil
        }
    }

    static func decodeDataURL(_ text: String) -> (data: Data, mimeType: String)? {
        guard text.hasPrefix("data:"), let comma = text.firstIndex(of: ",") else { return nil }
        let header = text[text.index(text.startIndex, offsetBy: 5)..<comma].split(separator: ";", omittingEmptySubsequences: false)
        let payload = String(text[text.index(after: comma)...])
        let mimeType = header.first.map { String($0).lowercased() } ?? ""
        let data: Data?
        if header.dropFirst().contains(where: { $0.lowercased() == "base64" }) {
            data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        } else {
            data = payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        return data.map { ($0, mimeType.isEmpty ? "application/octet-stream" : mimeType) }
    }
}

/// What engine.js reads back.
enum ImageAnswer: Sendable, Equatable {
    case scores([Float])
    case sensitive(Bool)
    case unsupported
    case error(String)
    indirect case frames([ImageAnswer])

    var dictionary: [String: Any] {
        switch self {
        case .scores(let scores): return ["scores": scores.map(Double.init)]
        case .sensitive(let sensitive): return ["sensitive": sensitive]
        case .unsupported: return ["unsupported": true]
        case .error(let reason): return ["error": reason]
        case .frames(let answers): return ["frames": answers.map(\.dictionary)]
        }
    }
}
