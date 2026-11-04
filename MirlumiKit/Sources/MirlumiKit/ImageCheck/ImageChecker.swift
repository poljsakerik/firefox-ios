// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import OnnxRuntimeBindings
#if canImport(SensitiveContentAnalysis)
import SensitiveContentAnalysis
#endif

/// Fetches an image the page showed and judges it: Apple's check where it's on, the bundled model otherwise. Answers
/// are cached by content, so an image seen on another page isn't checked again.
actor ImageChecker {
    /// The longest side Apple's check gets: enough detail, far less than full-size photos.
    static let systemImageSide = 1024

    private let maxBytes: Int
    private let maxFrames: Int

    private var model: OnnxImageModel?
    /// Loads the model on the first check that needs it, off the main thread.
    private var loadModel: (@Sendable () -> OnnxImageModel?)?
    private let systemCheck: @Sendable (CGImage) async -> Bool?
    private let session = URLSession(configuration: ImageChecker.configuration(ephemeral: false))
    private let privateSession = URLSession(configuration: ImageChecker.configuration(ephemeral: true))
    private var answers: [String: ImageAnswer] = [:]
    private var order: [String] = []

    init(
        settings: ImageCheck.Settings = ImageCheck.settings,
        model: OnnxImageModel?,
        systemCheck: @escaping @Sendable (CGImage) async -> Bool? = SystemSensitivity.check
    ) {
        maxBytes = settings.maxBytes
        maxFrames = settings.maxFrames
        self.model = model
        self.systemCheck = systemCheck
    }

    init(
        settings: ImageCheck.Settings = ImageCheck.settings,
        loadModel: @escaping @Sendable () -> OnnxImageModel?,
        systemCheck: @escaping @Sendable (CGImage) async -> Bool? = SystemSensitivity.check
    ) {
        maxBytes = settings.maxBytes
        maxFrames = settings.maxFrames
        self.loadModel = loadModel
        self.systemCheck = systemCheck
    }

    func check(_ request: ImageRequest, isPrivate: Bool) async -> ImageAnswer {
        let data: Data
        let mimeType: String
        switch request.source {
        case .dataURL(let text):
            guard let decoded = ImageRequest.decodeDataURL(text) else { return .error("bad data: URL") }
            (data, mimeType) = decoded
        case .url(let url, let page):
            do {
                (data, mimeType) = try await fetch(url, page: page, isPrivate: isPrivate)
            } catch {
                return .error("fetch failed")
            }
        }
        return await check(data, mimeType: mimeType)
    }

    func check(_ data: Data, mimeType: String) async -> ImageAnswer {
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let cached = answers[key] { return cached }
        let answer = await judge(data, mimeType: mimeType)
        if case .error = answer { return answer }
        remember(answer, for: key)
        return answer
    }

    /// The answer for one image, or for each frame of an animated one: engine.js decides on them together.
    private func judge(_ data: Data, mimeType: String) async -> ImageAnswer {
        let frames = ImagePixels.frames(data, maxSide: Self.systemImageSide, limit: maxFrames)
        // Only bytes that decode to nothing and read as SVG are SVG; a type that merely says so isn't trusted.
        guard !frames.isEmpty else { return ImagePixels.looksLikeSVG(data) ? .unsupported : .error("not an image") }
        var answers: [ImageAnswer] = []
        for frame in frames {
            answers.append(await judge(frame))
        }
        return answers.count == 1 ? answers[0] : .frames(answers)
    }

    private func judge(_ frame: CGImage) async -> ImageAnswer {
        if let sensitive = await systemCheck(frame) { return .sensitive(sensitive) }
        if model == nil, let load = loadModel {
            loadModel = nil
            model = load()
        }
        guard let model else { return .error("no model") }
        do {
            return .scores(try model.probabilities(for: frame))
        } catch {
            return .error("model failed")
        }
    }

    private func remember(_ answer: ImageAnswer, for key: String) {
        answers[key] = answer
        order.append(key)
        if order.count > 512 {
            answers[order.removeFirst()] = nil
        }
    }

    private func fetch(_ url: URL, page: URL?, isPrivate: Bool) async throws -> (Data, String) {
        var request = URLRequest(url: url)
        request.setValue("image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8", forHTTPHeaderField: "Accept")
        if let page, ["http", "https"].contains(page.scheme), let host = page.host {
            // The page's origin only, as browsers send to other sites by default.
            let port = page.port.map { ":\($0)" } ?? ""
            request.setValue("\(page.scheme ?? "https")://\(host)\(port)/", forHTTPHeaderField: "Referer")
        }
        let (data, response) = try await (isPrivate ? privateSession : session).data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= maxBytes
        else { throw URLError(.badServerResponse) }
        return (data, (http.mimeType ?? "").lowercased())
    }

    /// No cookies, so a check never signs in anywhere. Private tabs' images are kept in memory only.
    private static func configuration(ephemeral: Bool) -> URLSessionConfiguration {
        let configuration = ephemeral ? URLSessionConfiguration.ephemeral : URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        if !ephemeral {
            configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 0)
        }
        return configuration
    }
}

/// Apple's Sensitive Content Analysis. It answers only when the device has Communication Safety or Sensitive Content
/// Warning on and the app holds the com.apple.developer.sensitivecontentanalysis.client entitlement; otherwise nil.
enum SystemSensitivity {
    @Sendable
    static func check(_ image: CGImage) async -> Bool? {
        #if canImport(SensitiveContentAnalysis) && !os(macOS)
        if #available(iOS 17.0, *) {
            let analyzer = SCSensitivityAnalyzer()
            guard analyzer.analysisPolicy != .disabled else { return nil }
            return try? await analyzer.analyzeImage(image).isSensitive
        }
        #endif
        return nil
    }
}

/// Decoding and resizing, the same way on every model: stretched to the model's size, RGB bytes row by row.
enum ImagePixels {
    static func decode(_ data: Data, maxSide: Int) -> CGImage? {
        frames(data, maxSide: maxSide, limit: 1).first
    }

    /// Up to `limit` frames spread evenly over an animated image, or its only frame.
    static func frames(_ data: Data, maxSide: Int, limit: Int) -> [CGImage] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return [] }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        // Spread from the first frame to the last, so no stretch of the animation goes unseen.
        let n = Swift.min(Swift.max(1, limit), count)
        let indices = n == 1 ? [0] : (0..<n).map { $0 * (count - 1) / (n - 1) }
        return indices.compactMap { CGImageSourceCreateThumbnailAtIndex(source, $0, options as CFDictionary) }
    }

    static func rgb(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[i * 3] = rgba[i * 4]
            rgb[i * 3 + 1] = rgba[i * 4 + 1]
            rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return rgb
    }

    static func looksLikeSVG(_ data: Data) -> Bool {
        let start = String(decoding: data.prefix(512), as: UTF8.self).drop(while: \.isWhitespace)
        return start.hasPrefix("<svg") || (start.hasPrefix("<?xml") && start.contains("<svg"))
    }
}

/// The bundled model, as model.json describes it: uint8 RGB [1, height, width, 3] in, a probability per label out.
/// Nothing here depends on which model it is, so replacing it needs no code change.
final class OnnxImageModel: @unchecked Sendable {
    struct Manifest: Decodable {
        struct Input: Decodable {
            let width: Int
            let height: Int
        }

        let file: String
        let input: Input
        let labels: [String]
    }

    let manifest: Manifest
    private let session: ORTSession
    private let inputName: String
    private let outputName: String
    private let lock = NSLock()

    init(directory: URL) throws {
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("model.json")))
        let environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))))
        try options.setGraphOptimizationLevel(.all)
        session = try ORTSession(
            env: environment,
            modelPath: directory.appendingPathComponent(manifest.file).path,
            sessionOptions: options
        )
        guard let input = try session.inputNames().first, let output = try session.outputNames().first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        inputName = input
        outputName = output
    }

    func probabilities(for image: CGImage) throws -> [Float] {
        let width = manifest.input.width
        let height = manifest.input.height
        guard let pixels = ImagePixels.rgb(image, width: width, height: height) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let tensor = NSMutableData(bytes: pixels, length: pixels.count)
        let input = try ORTValue(
            tensorData: tensor,
            elementType: .uInt8,
            shape: [1, NSNumber(value: height), NSNumber(value: width), 3]
        )
        lock.lock()
        defer { lock.unlock() }
        let outputs = try session.run(withInputs: [inputName: input], outputNames: [outputName], runOptions: nil)
        guard let output = outputs[outputName] else { throw CocoaError(.fileReadCorruptFile) }
        let data = try output.tensorData() as Data
        let probabilities = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard probabilities.count == manifest.labels.count else { throw CocoaError(.fileReadCorruptFile) }
        return probabilities
    }
}
