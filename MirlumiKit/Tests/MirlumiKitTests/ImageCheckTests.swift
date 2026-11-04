// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import MirlumiKit

final class ImageCheckTests: XCTestCase {
    private func png(red: UInt8, green: UInt8, blue: UInt8, size: Int = 64) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testRequestsNeedAnHTTPAddressOrADataURL() {
        let url = ImageRequest(["url": "https://cdn.example.com/a.jpg", "page": "https://example.com/"])
        XCTAssertEqual(
            url?.source,
            .url(URL(string: "https://cdn.example.com/a.jpg")!, page: URL(string: "https://example.com/"))
        )
        XCTAssertEqual(ImageRequest(["data": "data:image/png;base64,AQID"])?.source, .dataURL("data:image/png;base64,AQID"))
        XCTAssertNil(ImageRequest(["url": "file:///etc/passwd"]))
        XCTAssertNil(ImageRequest(["data": "https://example.com/"]))
        XCTAssertNil(ImageRequest("nonsense"))
    }

    func testDataURLsDecodeInBase64AndPercentEncoding() {
        XCTAssertEqual(ImageRequest.decodeDataURL("data:image/svg+xml,%3Csvg%3E")?.data, Data("<svg>".utf8))
        XCTAssertEqual(ImageRequest.decodeDataURL("data:IMAGE/JPEG;base64,AQID")?.mimeType, "image/jpeg")
    }

    func testPixelsAreRGBInOrder() throws {
        let image = try XCTUnwrap(ImagePixels.decode(try png(red: 200, green: 100, blue: 50), maxSide: 64))
        let pixels = try XCTUnwrap(ImagePixels.rgb(image, width: 4, height: 4))
        XCTAssertEqual(pixels.count, 48)
        XCTAssertEqual(Array(pixels.prefix(3)), [200, 100, 50])
    }

    func testSVGIsRecognisedByContentOnly() async throws {
        XCTAssertTrue(ImagePixels.looksLikeSVG(Data("  <?xml version=\"1.0\"?><svg/>".utf8)))
        XCTAssertFalse(ImagePixels.looksLikeSVG(Data([0xFF, 0xD8])))
        // A photo whose type claims to be SVG is still judged as a photo.
        let checker = ImageChecker(model: nil) { _ in true }
        let labelled = await checker.check(try png(red: 1, green: 2, blue: 3), mimeType: "image/svg")
        XCTAssertEqual(labelled, .sensitive(true))
    }

    func testTheBundledModelGivesAProbabilityPerLabel() throws {
        let model = try XCTUnwrap(ImageCheck.loadModel())
        let image = try XCTUnwrap(ImagePixels.decode(try png(red: 30, green: 120, blue: 220), maxSide: 512))
        let probabilities = try model.probabilities(for: image)
        XCTAssertEqual(probabilities.count, model.manifest.labels.count)
        XCTAssertEqual(probabilities.reduce(0, +), 1, accuracy: 0.001)
    }

    func testTheSystemCheckAnswersFirstAndAnswersAreCached() async throws {
        let calls = Counter()
        let checker = ImageChecker(model: nil) { _ in
            await calls.increment()
            return true
        }
        let data = try png(red: 1, green: 2, blue: 3)
        let first = await checker.check(data, mimeType: "image/png")
        let second = await checker.check(data, mimeType: "image/png")
        XCTAssertEqual(first, .sensitive(true))
        XCTAssertEqual(second, .sensitive(true))
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }

    func testWithoutTheSystemCheckTheModelDecides() async throws {
        let checker = ImageChecker(model: ImageCheck.loadModel()) { _ in nil }
        guard case .scores(let scores) = await checker.check(try png(red: 9, green: 9, blue: 9), mimeType: "image/png") else {
            return XCTFail("expected scores")
        }
        XCTAssertEqual(scores.count, 2)
    }

    func testTheModelLoadsOnceOnTheFirstCheckThatNeedsIt() async throws {
        let loads = LoadCounter()
        let checker = ImageChecker(loadModel: {
            loads.increment()
            return ImageCheck.loadModel()
        }, systemCheck: { _ in nil })
        XCTAssertEqual(loads.value, 0)
        _ = await checker.check(try png(red: 1, green: 1, blue: 1), mimeType: "image/png")
        _ = await checker.check(try png(red: 2, green: 2, blue: 2), mimeType: "image/png")
        XCTAssertEqual(loads.value, 1)
    }

    private func gif(_ colors: [(UInt8, UInt8, UInt8)]) throws -> Data {
        let frames = try colors.map { try XCTUnwrap(ImagePixels.decode(try png(red: $0.0, green: $0.1, blue: $0.2), maxSide: 64)) }
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil)
        )
        frames.forEach { CGImageDestinationAddImage(destination, $0, nil) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testAnAnimatedImageIsJudgedByEachOfItsFrames() async throws {
        let data = try gif([(10, 10, 10), (200, 30, 30), (30, 30, 200)])
        let checker = ImageChecker(model: nil) { image in
            (ImagePixels.rgb(image, width: 1, height: 1) ?? [0])[0] > 150
        }
        let answer = await checker.check(data, mimeType: "image/gif")
        XCTAssertEqual(answer, .frames([.sensitive(false), .sensitive(true), .sensitive(false)]))
    }

    func testFramesAreSpreadToTheLastOne() throws {
        // Twelve frames, only the last red: eight samples spread from the first to the last must include it.
        var colors = Array(repeating: (UInt8(10), UInt8(10), UInt8(10)), count: 12)
        colors[11] = (200, 30, 30)
        let frames = ImagePixels.frames(try gif(colors), maxSide: 64, limit: 8)
        XCTAssertEqual(frames.count, 8)
        XCTAssertTrue(frames.contains { (ImagePixels.rgb($0, width: 1, height: 1) ?? [0])[0] > 150 })
    }

    func testDataURLsAreDecodedByTheChecker() async throws {
        let checker = ImageChecker(model: nil) { _ in false }
        let url = "data:image/png;base64," + (try png(red: 5, green: 5, blue: 5)).base64EncodedString()
        let answer = await checker.check(ImageRequest(source: .dataURL(url)), isPrivate: true)
        XCTAssertEqual(answer, .sensitive(false))
        let broken = await checker.check(ImageRequest(source: .dataURL("data:image/png;base64")), isPrivate: true)
        XCTAssertEqual(broken, .error("bad data: URL"))
    }

    @MainActor
    func testTheMenuAndDownloadsLoseImagesWhileTheCheckIsOn() {
        let check = ImageCheck(checker: ImageChecker(model: nil) { _ in nil })
        XCTAssertTrue(check.allowsSavingImages)
        XCTAssertTrue(check.allowsDownloadLink(hasImage: true))
        XCTAssertTrue(check.allowsFile(mimeType: "image/jpeg"))
        check.isEnabled = true
        XCTAssertFalse(check.allowsSavingImages)
        XCTAssertFalse(check.allowsDownloadLink(hasImage: true))
        XCTAssertTrue(check.allowsDownloadLink(hasImage: false))
        XCTAssertFalse(check.allowsFile(mimeType: "IMAGE/PNG"))
        XCTAssertTrue(check.allowsFile(mimeType: "application/pdf"))
        XCTAssertTrue(check.allowsFile(mimeType: nil))
    }

    func testWhatIsntAnImageFailsAndSVGIsUnsupported() async {
        let checker = ImageChecker(model: nil) { _ in nil }
        let garbage = await checker.check(Data([1, 2, 3]), mimeType: "image/png")
        XCTAssertEqual(garbage, .error("not an image"))
        let svg = await checker.check(Data("<svg/>".utf8), mimeType: "image/svg+xml")
        XCTAssertEqual(svg, .unsupported)
    }
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}

private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
