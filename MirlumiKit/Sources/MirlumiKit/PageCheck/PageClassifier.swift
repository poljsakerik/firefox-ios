// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import JavaScriptCore

/// The fields of a page the classifier scores, as `MirlumiPageText.readPage` reads them in the page.
struct PageText: Sendable, Equatable {
    var title: String
    var description: String
    var headings: [String]
    var body: String

    init(title: String = "", description: String = "", headings: [String] = [], body: String = "") {
        self.title = title
        self.description = description
        self.headings = headings
        self.body = body
    }

    /// From what the page script sent, or nil if it isn't a page's fields.
    init?(message: Any?) {
        guard let fields = message as? [String: Any] else { return nil }
        self.init(title: fields["title"] as? String ?? "",
                  description: fields["description"] as? String ?? "",
                  headings: (fields["headings"] as? [Any])?.compactMap { $0 as? String } ?? [],
                  body: fields["body"] as? String ?? "")
    }

    var dictionary: [String: Any] {
        ["title": title, "description": description, "headings": headings, "body": body]
    }
}

/// What the page classifier said about a page or a search.
enum PageVerdict: Sendable, Equatable {
    case clear
    case flagged(String)
    /// The classifier couldn't load or failed, or didn't answer in time. Nothing passes on this.
    case failed
}

/// What `PageCheck` and the navigation policy need from the classifier. Tests stand in for it.
protocol PageClassifying: AnyObject, Sendable {
    func prepare()
    func checkPage(_ page: PageText) async -> PageVerdict
    func checkSearch(_ query: String) async -> PageVerdict
}

/// The page classifier from packages/page-classifier, the file Android runs too, in a JavaScriptCore context of its
/// own on a serial background queue: without a JIT the model takes ~50 ms to load and a page ~12 ms to score. The
/// model loads on the first check, or on `prepare()`. If it can't load, every check fails, and nothing passes.
final class PageClassifier: PageClassifying, @unchecked Sendable {
    static let shared = PageClassifier(script: PageClassifier.bundledScript, modelURL: PageClassifier.bundledModelURL)

    private enum State {
        case notLoaded
        case loaded(api: JSValue, model: JSValue)
        case failed
    }

    private let queue = DispatchQueue(label: "app.mirlumi.browser.page-classifier", qos: .userInitiated)
    private let script: String?
    private let modelURL: URL?
    /// Only used on `queue`.
    private var state = State.notLoaded

    init(script: String?, modelURL: URL?) {
        self.script = script
        self.modelURL = modelURL
    }

    /// Loads the model now rather than on the first check.
    func prepare() {
        queue.async { _ = self.loaded() }
    }

    /// Checks a search query, with the model's search thresholds, stricter about blocking than a page's.
    func checkSearch(_ query: String) async -> PageVerdict {
        await run { api, model in api.invokeMethod("checkSearch", withArguments: [model, query]) }
    }

    func checkPage(_ page: PageText) async -> PageVerdict {
        await run { api, model in api.invokeMethod("checkPage", withArguments: [model, page.dictionary]) }
    }

    private func run(_ check: @escaping @Sendable (JSValue, JSValue) -> JSValue?) async -> PageVerdict {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let (api, model) = self.loaded() else { return continuation.resume(returning: .failed) }
                api.context.exception = nil
                let result = check(api, model)
                guard api.context.exception == nil, let result, result.isObject,
                      let flagged = result.objectForKeyedSubscript("flagged")
                else { return continuation.resume(returning: .failed) }
                if flagged.isString, let label = flagged.toString() {
                    continuation.resume(returning: .flagged(label))
                } else if flagged.isNull {
                    continuation.resume(returning: .clear)
                } else {
                    continuation.resume(returning: .failed)
                }
            }
        }
    }

    /// The classifier and its model, loading them the first time. Call on `queue` only.
    private func loaded() -> (JSValue, JSValue)? {
        switch state {
        case .loaded(let api, let model):
            return (api, model)
        case .failed:
            return nil
        case .notLoaded:
            break
        }
        guard let script, let modelURL, let context = JSContext() else { return fail() }
        context.evaluateScript(script)
        guard context.exception == nil,
              let api = context.objectForKeyedSubscript("MirlumiPageClassifier"), api.isObject,
              let bytes = Self.mapModel(at: modelURL, in: context),
              let model = api.invokeMethod("loadModel", withArguments: [bytes]),
              context.exception == nil, model.isObject
        else { return fail() }
        state = .loaded(api: api, model: model)
        return (api, model)
    }

    private func fail() -> (JSValue, JSValue)? {
        state = .failed
        return nil
    }

    /// The model file as a Uint8Array over its mapped pages, so its 17 MB aren't copied. The mapping is private and
    /// writable, as JavaScript expects of an array, and is unmapped when JavaScriptCore frees the array.
    private static func mapModel(at url: URL, in context: JSContext) -> JSValue? {
        let file = open(url.path, O_RDONLY)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_size > 0 else { return nil }
        let length = Int(info.st_size)
        guard let bytes = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE, file, 0),
              bytes != UnsafeMutableRawPointer(bitPattern: -1)
        else { return nil }
        var exception: JSValueRef?
        let array = JSObjectMakeTypedArrayWithBytesNoCopy(
            context.jsGlobalContextRef,
            kJSTypedArrayTypeUint8Array,
            bytes,
            length,
            { bytes, length in munmap(bytes, Int(bitPattern: length)) },
            UnsafeMutableRawPointer(bitPattern: length),
            &exception
        )
        guard let array, exception == nil else {
            munmap(bytes, length)
            return nil
        }
        return JSValue(jsValueRef: array, in: context)
    }

    /// The answer of `work`, or nil if it takes longer than `seconds`.
    @MainActor
    static func first<T: Sendable>(within seconds: TimeInterval,
                                   _ work: @escaping @MainActor @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { continuation in
            let answer = Answer<T>(continuation)
            Task { @MainActor in answer.give(await work()) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                answer.give(nil)
            }
        }
    }

    @MainActor
    private final class Answer<T: Sendable> {
        private var continuation: CheckedContinuation<T?, Never>?
        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

        func give(_ value: T?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    static var bundledScript: String? {
        Bundle.module.url(forResource: "MirlumiPageClassifier", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    static var bundledModelURL: URL? {
        Bundle.module.url(forResource: "page-classifier", withExtension: "mpc")
    }
}
