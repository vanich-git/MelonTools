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

    // MARK: - Config write idempotency

    func testConfigWriteIsSkippedForAnUnchangedGeneration() {
        XCTAssertFalse(CodexGatewayService.configNeedsWrite(
            proposed: "config-version: 8\n",
            lastWritten: "config-version: 8\n",
            fileExists: true
        ))
        XCTAssertTrue(CodexGatewayService.configNeedsWrite(
            proposed: "config-version: 8\n",
            lastWritten: "config-version: 7\n",
            fileExists: true
        ))
        XCTAssertTrue(CodexGatewayService.configNeedsWrite(
            proposed: "config-version: 8\n",
            lastWritten: nil,
            fileExists: true
        ))
        // A deleted config must be restored even when the generation matches.
        XCTAssertTrue(CodexGatewayService.configNeedsWrite(
            proposed: "config-version: 8\n",
            lastWritten: "config-version: 8\n",
            fileExists: false
        ))
    }

    func testModelSourcesStoreTreatsAMissingFileAsLoaded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sources-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ModelSourcesStore(storeURL: root.appendingPathComponent("model-sources.json"))
        XCTAssertTrue(store.isLoaded)
        XCTAssertTrue(store.sources.isEmpty)
    }

    func testModelSourcesStoreReadsAValidFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sources-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("model-sources.json")
        try #"{"sources": []}"#.write(to: url, atomically: true, encoding: .utf8)
        let store = ModelSourcesStore(storeURL: url)
        XCTAssertTrue(store.isLoaded)
        XCTAssertTrue(store.sources.isEmpty)
    }

    func testModelSourcesStoreLeavesAnUnreadableFileUnloaded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sources-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("model-sources.json")
        try Data("not json at all".utf8).write(to: url)
        let store = ModelSourcesStore(storeURL: url)
        // An unreadable store must not authorise a config write: the empty
        // in-memory list would strip every provider from the gateway config.
        XCTAssertFalse(store.isLoaded)
        XCTAssertTrue(store.sources.isEmpty)
    }

    func testForcedWriterReplacesSameGenerationAndWritesAddRemove() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.yaml")

        func inode() throws -> UInt64 {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }

        let base = "server:\n  port: 8080\n"
        XCTAssertTrue(try CodexGatewayService.writeConfigFile(
            base, to: url, lastWritten: nil, force: false, loadedGuard: {}
        ))
        let before = try inode()

        // Same generation without force: no disk replacement.
        XCTAssertFalse(try CodexGatewayService.writeConfigFile(
            base, to: url, lastWritten: base, force: false, loadedGuard: {}
        ))
        XCTAssertEqual(try inode(), before)

        // Same generation with force: the explicit publication replaces it.
        XCTAssertTrue(try CodexGatewayService.writeConfigFile(
            base, to: url, lastWritten: base, force: true, loadedGuard: {}
        ))
        XCTAssertNotEqual(try inode(), before)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), base)

        // Adding and removing a provider changes the generation and writes.
        let added = base + "  # added provider\n"
        XCTAssertTrue(try CodexGatewayService.writeConfigFile(
            added, to: url, lastWritten: base, force: false, loadedGuard: {}
        ))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), added)
        let afterAdd = try inode()
        XCTAssertTrue(try CodexGatewayService.writeConfigFile(
            added, to: url, lastWritten: added, force: true, loadedGuard: {}
        ))
        XCTAssertNotEqual(try inode(), afterAdd)

        let removed = "server:\n"
        XCTAssertTrue(try CodexGatewayService.writeConfigFile(
            removed, to: url, lastWritten: added, force: false, loadedGuard: {}
        ))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), removed)
        let afterRemove = try inode()
        XCTAssertTrue(try CodexGatewayService.writeConfigFile(
            removed, to: url, lastWritten: removed, force: true, loadedGuard: {}
        ))
        XCTAssertNotEqual(try inode(), afterRemove)
    }

    func testWriterRefusesUnloadedSourcesBeforeTouchingDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.yaml")
        let storeURL = root.appendingPathComponent("model-sources.json")
        try Data("not json at all".utf8).write(to: storeURL)
        let store = ModelSourcesStore(storeURL: storeURL)
        XCTAssertFalse(store.isLoaded)

        XCTAssertThrowsError(try CodexGatewayService.writeConfigFile(
            "server: {}\n",
            to: url,
            lastWritten: nil,
            force: true,
            loadedGuard: {
                guard store.isLoaded else {
                    throw CodexGatewayService.ConfigError.modelSourcesUnavailable
                }
            }
        )) { error in
            guard let configError = error as? CodexGatewayService.ConfigError,
                  case .modelSourcesUnavailable = configError else {
                return XCTFail("expected modelSourcesUnavailable, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPublicationRetryWriteFailureIsVisible() async throws {
        let service = LocalInferenceService.shared
        defer { service.resetPublicationForTesting() }
        var writes = 0
        var servedCalls = 0
        service.publicationHooks = .init(
            writeConfig: {
                writes += 1
                if writes == 2 {
                    throw NSError(
                        domain: "writer-test",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "disk is full"]
                    )
                }
            },
            refreshCatalog: {},
            gatewayIsRunning: { true },
            servedModelIDs: {
                servedCalls += 1
                return servedCalls == 1 ? [] : ["local/ready"]
            },
            readyAliases: { ["local/ready"] },
            wait: { _ in }
        )

        service.publishLocalRoutes()
        await service.waitForPublication()

        let error = try XCTUnwrap(service.publicationError)
        XCTAssertTrue(error.contains("could not be rewritten"), error)
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(servedCalls, 1, "a failed rewrite must not fall through to a matching catalogue")
    }
}
