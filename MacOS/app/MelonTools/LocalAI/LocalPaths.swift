import Foundation

/// Central filesystem layout for Local AI.
///
/// Pure static paths on purpose: the one-time migration has to snapshot user
/// data **before** any shared service is created, and `LocalModelStore.shared`
/// rewrites the registry in its initializer. Reaching the same directories
/// through this enum keeps the migration order-independent.
enum LocalPaths {
    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Test-only redirect of the whole layout into a temporary folder.
    private static let overrideLock = NSLock()
    private static var _baseOverride: URL?

    static var baseOverride: URL? {
        get { overrideLock.lock(); defer { overrideLock.unlock() }; return _baseOverride }
        set { overrideLock.lock(); _baseOverride = newValue; overrideLock.unlock() }
    }

    static var base: URL {
        if let override = baseOverride { return override }
        return applicationSupport.appendingPathComponent("MelonTools", isDirectory: true)
    }

    static var models: URL { base.appendingPathComponent("models", isDirectory: true) }
    static var downloads: URL { base.appendingPathComponent("downloads", isDirectory: true) }
    static var runtime: URL { base.appendingPathComponent("runtime", isDirectory: true) }
    static var metadata: URL { base.appendingPathComponent("metadata", isDirectory: true) }
    static var logs: URL { base.appendingPathComponent("logs", isDirectory: true) }

    static var registry: URL { metadata.appendingPathComponent("models.json") }
    static var storageSettings: URL { metadata.appendingPathComponent("storage_settings.json") }
    static var enginePreset: URL { metadata.appendingPathComponent("models.ini") }
    static var engineLog: URL { logs.appendingPathComponent("llama-server.log") }
    /// SHA-256 of the preset the currently running engine was started with.
    static var appliedPresetDigest: URL { metadata.appendingPathComponent("models.ini.applied") }
    static var downloadJournal: URL { downloads.appendingPathComponent("downloads.json") }

    /// Gateway configuration, the file that carries every provider route.
    ///
    /// Computed from the same support directory as `CodexGatewayService.gatewayDir`
    /// without touching that service: the migration has to read this path before
    /// any service initializer runs.
    static var gatewayConfig: URL {
        base.appendingPathComponent("gateway", isDirectory: true)
            .appendingPathComponent("config.yaml")
    }

    /// Directories that hold disposable work in progress. Anything under these
    /// prefixes is safe for the startup garbage collector to drop once it is
    /// old enough and no operation owns it.
    static let temporaryPrefixes = [
        ".staging-", ".install-", ".extract-", ".download-", ".catalog-", ".publish-",
    ]

    static func isTemporaryArtifact(_ name: String, extraPrefixes: [String] = []) -> Bool {
        (temporaryPrefixes + extraPrefixes).contains { name.hasPrefix($0) }
    }
}
