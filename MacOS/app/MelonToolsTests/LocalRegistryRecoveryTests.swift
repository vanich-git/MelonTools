import XCTest
@testable import MelonTools

@MainActor
final class LocalRegistryRecoveryTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("melon-registry-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCorruptRegistryIsPreservedAndEverySaveIsBlocked() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("registry.json")
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: url)
        let store = LocalModelStore(directory: directory)
        XCTAssertNotNil(store.registryError)
        XCTAssertFalse(store.canWriteRegistry)
        XCTAssertFalse(store.saveRegistry())
        store.normalizeRuntimeStates()
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        let backup = try XCTUnwrap(store.registryBackupURL)
        XCTAssertEqual(try Data(contentsOf: backup), corrupt)
        store.loadRegistry()
        XCTAssertEqual(store.registryBackupURL, backup)
    }

    func testExplicitRestoreThenRetryUnlocksRegistryWithoutDeletingBackup() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("registry.json")
        try Data("not JSON".utf8).write(to: url)
        let store = LocalModelStore(directory: directory)
        let backup = try XCTUnwrap(store.registryBackupURL)
        try Data("[]".utf8).write(to: url, options: .atomic)
        store.loadRegistry()
        XCTAssertNil(store.registryError)
        XCTAssertTrue(store.canWriteRegistry)
        XCTAssertTrue(store.saveRegistry())
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testRemovingBrokenRegistryDoesNotSilentlyResetIt() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("registry.json")
        try Data("broken".utf8).write(to: url)
        let store = LocalModelStore(directory: directory)
        try FileManager.default.removeItem(at: url)
        store.loadRegistry()
        XCTAssertFalse(store.canWriteRegistry)
        XCTAssertFalse(store.saveRegistry())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNewerSchemaRegistryRemainsReadOnly() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var model = LocalModel(
            id: "local/x", displayName: "X", provider: "Local AI", source: "import",
            repoId: nil, revision: nil, files: ["x.gguf"], fileSize: 0,
            quantization: "Q4_K_M", format: "GGUF", contextLength: 32768, configuredContext: 8192,
            backend: .metal, gpuOffload: nil, threads: nil, runtimeStatus: .installed,
            capabilities: [.text], installedAt: Date(), updatedAt: Date(), lastUsedAt: nil,
            license: nil, checksum: nil, userSettings: .defaultSettings(forContext: 8192)
        )
        model.schemaVersion = PersistenceSchema.current + 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode([model])
        let url = directory.appendingPathComponent("registry.json")
        try bytes.write(to: url)
        let store = LocalModelStore(directory: directory)
        XCTAssertFalse(store.canWriteRegistry)
        XCTAssertFalse(store.saveRegistry())
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testAbsentRegistryOnFirstUseIsWritable() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalModelStore(directory: directory)
        XCTAssertTrue(store.canWriteRegistry)
        XCTAssertTrue(store.saveRegistry())
        let models = try JSONDecoder().decode([LocalModel].self, from: Data(contentsOf: store.registryFileURL))
        XCTAssertTrue(models.isEmpty)
    }
}
