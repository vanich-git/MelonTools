import CryptoKit
import XCTest
@testable import MelonTools

@MainActor
final class CodexGatewayEngineTests: XCTestCase {
    func testExtractsVerifiesAndRepairsTheEmbeddedEngine() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data("#!/bin/sh\necho melon\n".utf8)
        let payloadURL = root.appendingPathComponent("cliproxyapi")
        try payload.write(to: payloadURL)
        let gzURL = root.appendingPathComponent("cliproxyapi.gz")
        FileManager.default.createFile(atPath: gzURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: gzURL)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-9", "-c", payloadURL.path]
        gzip.standardOutput = output
        gzip.standardError = FileHandle.nullDevice
        try gzip.run()
        gzip.waitUntilExit()
        try output.close()
        XCTAssertEqual(gzip.terminationStatus, 0)

        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let hashURL = root.appendingPathComponent("cliproxyapi.sha256")
        try "\(digest)  cliproxyapi\n".write(to: hashURL, atomically: true, encoding: .utf8)

        let targetDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let first = try XCTUnwrap(CodexGatewayService.extractEngine(
            gzURL: gzURL,
            hashURL: hashURL,
            targetDirectory: targetDirectory
        ))
        XCTAssertEqual(try Data(contentsOf: first), payload)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: first.path))

        // A tampered extracted copy must be replaced from the verified bundle.
        try Data("evil".utf8).write(to: first)
        let second = try XCTUnwrap(CodexGatewayService.extractEngine(
            gzURL: gzURL,
            hashURL: hashURL,
            targetDirectory: targetDirectory
        ))
        XCTAssertEqual(try Data(contentsOf: second), payload)
    }

    func testRejectsAnEngineWithTheWrongDigest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-test-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payloadURL = root.appendingPathComponent("payload")
        try Data("not the engine".utf8).write(to: payloadURL)
        let gzURL = root.appendingPathComponent("cliproxyapi.gz")
        FileManager.default.createFile(atPath: gzURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: gzURL)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-9", "-c", payloadURL.path]
        gzip.standardOutput = output
        gzip.standardError = FileHandle.nullDevice
        try gzip.run()
        gzip.waitUntilExit()
        try output.close()

        let hashURL = root.appendingPathComponent("cliproxyapi.sha256")
        try String(repeating: "0", count: 64).write(to: hashURL, atomically: true, encoding: .utf8)
        XCTAssertNil(CodexGatewayService.extractEngine(
            gzURL: gzURL,
            hashURL: hashURL,
            targetDirectory: root.appendingPathComponent("bin", isDirectory: true)
        ))
    }
}
