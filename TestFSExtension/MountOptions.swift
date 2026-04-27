//
//  MountOptions.swift
//  TestFSCore / TestFSExtension
//
//  Sidecar config schema decoded by `loadResource` from a known path
//  (~/Library/Application Support/TestFS/active.json by default). Pure
//  Swift, compiled into both the SPM TestFSCore target and the Xcode
//  FSKit extension target.
//
//  Defaults match Python `jsonfs.py`'s CLI defaults, not its constructor
//  defaults — matching what a user running the Python tool would see.
//

import Foundation

/// Identity strings shared by the host app and the extension. Lives
/// in this file because `MountOptions.swift` is one of the few
/// sources compiled into both the FSKit extension and the host
/// app, giving us a single source of truth.
enum TestFSConstants {
    /// `os.Logger` subsystem used by both processes; the host's log
    /// viewer filters on this.
    static let logSubsystem = "com.sohonet.testfs"

    /// Filesystem type passed to `/sbin/mount -t <fstype>` and
    /// matched against `getfsstat`'s `f_fstypename`.
    static let fstype = "testfs"

    /// FSKit extension bundle identifier; the host hand-builds the
    /// extension's sandbox container path from this.
    static let extensionBundleID = "com.sohonet.testfsmount.appex"
}

/// Runtime configuration for a testfs mount. Serialized as JSON in a
/// sidecar file the host app / mount wrapper writes before invoking
/// `mount -F -t testfs`.
struct MountOptions: Equatable, Sendable {
    /// Absolute path to the `tree -J -s` JSON file describing the virtual
    /// filesystem. Required for a real mount; nil is only valid for
    /// `MountOptions.default` / test construction.
    var config: String?

    /// Single character used to fill read buffers in fill-char mode.
    /// Default is the null byte (matches Python `--fill-char` default).
    var fillChar: String

    /// If true, reads return deterministic pseudo-random bytes from the
    /// MD5-indexed block cache instead of `fillChar`.
    var semiRandom: Bool

    /// Size of each pre-generated block in the semi-random cache.
    /// Parseable via `parseSize("128K")` etc.
    var blockSize: String

    /// Number of blocks in the pre-generated semi-random cache.
    var preGeneratedBlocks: Int

    /// Seed for the semi-random LCG.
    var seed: Int

    /// Minimum delay between operations in seconds. 0 disables.
    var rateLimit: Double

    /// Maximum operations per second. 0 disables.
    var iopLimit: Int

    /// Which Unicode normalization form to apply to filenames during
    /// tree build and lookup. Default is NFD (matches Python default).
    var unicodeNormalization: UnicodeNormalization

    /// Override user ID for every item. `nil` means "use `getuid()`".
    var uid: UInt32?

    /// Override group ID for every item. `nil` means "use `getgid()`".
    var gid: UInt32?

    /// Modification time for every item, as a YYYY-MM-DD string.
    /// Default matches Python's 2017-10-17.
    var mtime: String

    /// If true, silently return ENOENT for lookups of `._*` AppleDouble
    /// resource-fork paths instead of logging a warning.
    var ignoreAppledouble: Bool

    /// If true, the tree builder appends `.metadata_never_index` family
    /// dotfiles to the root so Spotlight doesn't index the volume.
    var addMacosCacheFiles: Bool

    /// Display name for the volume in Finder / `mount` output. Optional;
    /// nil or empty falls back to the extension's default ("testfs").
    var volumeName: String?

    /// If true, the extension emits a per-operation debug log line on
    /// every read / lookup / enumerate. Off by default — those would
    /// dwarf everything else on a busy filesystem.
    var verbose: Bool

    /// If true (default), the extension's stats logger emits an
    /// `ops/s` summary every second when there's activity. Turn off
    /// to silence the periodic line.
    var reportStats: Bool

    init(
        config: String? = nil,
        fillChar: String = "\u{0000}",
        semiRandom: Bool = false,
        blockSize: String = "128K",
        preGeneratedBlocks: Int = 100,
        seed: Int = 4,
        rateLimit: Double = 0,
        iopLimit: Int = 0,
        unicodeNormalization: UnicodeNormalization = .nfd,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        mtime: String = "2017-10-17",
        ignoreAppledouble: Bool = false,
        addMacosCacheFiles: Bool = true,
        volumeName: String? = nil,
        verbose: Bool = false,
        reportStats: Bool = true
    ) {
        self.config = config
        self.fillChar = fillChar
        self.semiRandom = semiRandom
        self.blockSize = blockSize
        self.preGeneratedBlocks = preGeneratedBlocks
        self.seed = seed
        self.rateLimit = rateLimit
        self.iopLimit = iopLimit
        self.unicodeNormalization = unicodeNormalization
        self.uid = uid
        self.gid = gid
        self.mtime = mtime
        self.ignoreAppledouble = ignoreAppledouble
        self.addMacosCacheFiles = addMacosCacheFiles
        self.volumeName = volumeName
        self.verbose = verbose
        self.reportStats = reportStats
    }
}

/// Macs constantly probe for AppleDouble companion paths (`._foo` next
/// to `foo`) during copies, previews, and Finder browses. On a read-only
/// synthetic filesystem those lookups always miss; logging each one at
/// warning level produces unreadable output. When the mount opts in with
/// `ignore_appledouble`, return `true` for any `._*` name so the caller
/// can route the miss to a quieter log channel.
func isSuppressedAppleDoubleName(_ name: String, ignoreAppledouble: Bool) -> Bool {
    ignoreAppledouble && name.hasPrefix("._")
}

/// Parse "128K", "1M", "1G", or a bare integer string into a byte count.
/// Returns nil for empty input, missing digits, or unrecognized suffix.
func parseSize(_ raw: String) -> Int? {
    guard !raw.isEmpty else { return nil }
    let scalar: Int
    let body: Substring
    switch raw.last {
    case "K", "k":
        scalar = 1024
        body = raw.dropLast()
    case "M", "m":
        scalar = 1024 * 1024
        body = raw.dropLast()
    case "G", "g":
        scalar = 1024 * 1024 * 1024
        body = raw.dropLast()
    default:
        scalar = 1
        body = Substring(raw)
    }
    guard let value = Int(body), value > 0 else { return nil }
    return value * scalar
}

extension MountOptions {
    /// Parse a `mtime` string, accepting date-only (`YYYY-MM-DD`) or
    /// full ISO 8601 (`YYYY-MM-DDTHH:mm:ssZ`). Date-only is
    /// midnight UTC. Single source of truth used by both the host's
    /// GUI picker and the extension.
    static func parseMtime(_ raw: String) -> Date? {
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        if let date = dateOnly.date(from: raw) { return date }
        let dateTime = ISO8601DateFormatter()
        dateTime.formatOptions = [.withInternetDateTime]
        return dateTime.date(from: raw)
    }

    /// ISO 8601 string `parseMtime` round-trips.
    static func formatMtime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// Unicode normalization form applied to filenames during tree build
/// and lookup. Defaults to NFD to match Python `jsonfs.py`.
enum UnicodeNormalization: String, Codable, Sendable, CaseIterable {
    case nfc = "NFC"
    case nfd = "NFD"
    case nfkc = "NFKC"
    case nfkd = "NFKD"
    case none

    func apply(to input: String) -> String {
        switch self {
        case .nfc: return input.precomposedStringWithCanonicalMapping
        case .nfd: return input.decomposedStringWithCanonicalMapping
        case .nfkc: return input.precomposedStringWithCompatibilityMapping
        case .nfkd: return input.decomposedStringWithCompatibilityMapping
        case .none: return input
        }
    }
}

extension MountOptions {
    /// Snake-case JSON keys, matching Python `jsonfs.py` CLI flag names.
    enum CodingKeys: String, CodingKey {
        case config
        case fillChar = "fill_char"
        case semiRandom = "semi_random"
        case blockSize = "block_size"
        case preGeneratedBlocks = "pre_generated_blocks"
        case seed
        case rateLimit = "rate_limit"
        case iopLimit = "iop_limit"
        case unicodeNormalization = "unicode_normalization"
        case uid
        case gid
        case mtime
        case ignoreAppledouble = "ignore_appledouble"
        case addMacosCacheFiles = "add_macos_cache_files"
        case volumeName = "volume_name"
        case verbose
        case reportStats = "report_stats"
    }

    /// Python-CLI defaults, used both as `.default` and as the fallback
    /// source for any field missing from a sidecar JSON. Single source
    /// of truth — tests assert against this.
    static let `default` = MountOptions()
}

extension MountOptions: Codable {
    /// Custom decoder that applies `.default` values for any field
    /// missing from the JSON, so a sidecar containing just
    /// `{"config": "/tmp/tree.json"}` decodes successfully.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MountOptions.default
        self.init(
            config: try container.decodeIfPresent(String.self, forKey: .config),
            fillChar: try container.decodeIfPresent(String.self, forKey: .fillChar) ?? defaults.fillChar,
            semiRandom: try container.decodeIfPresent(Bool.self, forKey: .semiRandom) ?? defaults.semiRandom,
            blockSize: try container.decodeIfPresent(String.self, forKey: .blockSize) ?? defaults.blockSize,
            preGeneratedBlocks: try container.decodeIfPresent(Int.self, forKey: .preGeneratedBlocks)
                ?? defaults.preGeneratedBlocks,
            seed: try container.decodeIfPresent(Int.self, forKey: .seed) ?? defaults.seed,
            rateLimit: try container.decodeIfPresent(Double.self, forKey: .rateLimit) ?? defaults.rateLimit,
            iopLimit: try container.decodeIfPresent(Int.self, forKey: .iopLimit) ?? defaults.iopLimit,
            unicodeNormalization: try container.decodeIfPresent(
                UnicodeNormalization.self, forKey: .unicodeNormalization)
                ?? defaults.unicodeNormalization,
            uid: try container.decodeIfPresent(UInt32.self, forKey: .uid),
            gid: try container.decodeIfPresent(UInt32.self, forKey: .gid),
            mtime: try container.decodeIfPresent(String.self, forKey: .mtime) ?? defaults.mtime,
            ignoreAppledouble: try container.decodeIfPresent(Bool.self, forKey: .ignoreAppledouble)
                ?? defaults.ignoreAppledouble,
            addMacosCacheFiles: try container.decodeIfPresent(Bool.self, forKey: .addMacosCacheFiles)
                ?? defaults.addMacosCacheFiles,
            volumeName: try container.decodeIfPresent(String.self, forKey: .volumeName),
            verbose: try container.decodeIfPresent(Bool.self, forKey: .verbose) ?? defaults.verbose,
            reportStats: try container.decodeIfPresent(Bool.self, forKey: .reportStats) ?? defaults.reportStats
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(config, forKey: .config)
        try container.encode(fillChar, forKey: .fillChar)
        try container.encode(semiRandom, forKey: .semiRandom)
        try container.encode(blockSize, forKey: .blockSize)
        try container.encode(preGeneratedBlocks, forKey: .preGeneratedBlocks)
        try container.encode(seed, forKey: .seed)
        try container.encode(rateLimit, forKey: .rateLimit)
        try container.encode(iopLimit, forKey: .iopLimit)
        try container.encode(unicodeNormalization, forKey: .unicodeNormalization)
        try container.encodeIfPresent(uid, forKey: .uid)
        try container.encodeIfPresent(gid, forKey: .gid)
        try container.encode(mtime, forKey: .mtime)
        try container.encode(ignoreAppledouble, forKey: .ignoreAppledouble)
        try container.encode(addMacosCacheFiles, forKey: .addMacosCacheFiles)
        try container.encodeIfPresent(volumeName, forKey: .volumeName)
        try container.encode(verbose, forKey: .verbose)
        try container.encode(reportStats, forKey: .reportStats)
    }
}

extension MountOptions {
    enum LoadError: Error, LocalizedError {
        case missingConfig
        case invalidFillChar(String)
        case invalidBlockSize(String)
        case invalidPreGeneratedBlocks(Int)
        case invalidRateLimit(Double)
        case invalidIopLimit(Int)
        case malformed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .missingConfig:
                return "sidecar config must include a 'config' key pointing at a tree -J -s JSON file"
            case .invalidFillChar(let value):
                return "fill_char must be exactly one character, got \(value.count): '\(value)'"
            case .invalidBlockSize(let value):
                return "block_size must be a positive integer or '<n>K|M|G', got '\(value)'"
            case .invalidPreGeneratedBlocks(let value):
                return "pre_generated_blocks must be > 0, got \(value)"
            case .invalidRateLimit(let value):
                return "rate_limit must be >= 0, got \(value)"
            case .invalidIopLimit(let value):
                return "iop_limit must be >= 0, got \(value)"
            case .malformed(let err):
                return "malformed sidecar JSON: \(err.localizedDescription)"
            }
        }
    }

    /// `blockSize` parsed into bytes. `MountOptions.load` rejects invalid
    /// values, so this is safe to force-unwrap on a loaded instance.
    var blockSizeBytes: Int { parseSize(blockSize)! }

    /// Per-device sidecar path. Each mount writes its own
    /// `active-<bsdName>.json`, so concurrent mounts on distinct
    /// /dev/diskN devices can serve different tree JSONs simultaneously.
    ///
    /// Lives in the extension's own sandbox Application Support —
    /// `~/Library/Containers/com.sohonet.testfsmount.appex/Data/Library/
    /// Application Support/TestFS/`. The extension reads its own
    /// container without sandbox friction, and any non-sandboxed writer
    /// (shell scripts, the host app) can write here as the user.
    ///
    /// The App Group container is NOT used: FSKit extensions appear to
    /// get a stricter sandbox profile that denies reads from Group
    /// Containers even with the `application-groups` entitlement present.
    static func sidecarURL(forBSDName bsd: String) -> URL {
        extensionContainerTestFSDir().appendingPathComponent("active-\(bsd).json")
    }

    /// Base directory for sidecar + staged tree JSON files in the
    /// extension's own sandbox container.
    static func extensionContainerTestFSDir() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TestFS", isDirectory: true)
    }

    /// Decode and validate a sidecar JSON blob.
    static func load(from data: Data) throws -> MountOptions {
        let options: MountOptions
        do {
            options = try JSONDecoder().decode(MountOptions.self, from: data)
        } catch {
            throw LoadError.malformed(underlying: error)
        }
        guard let path = options.config, !path.isEmpty else {
            throw LoadError.missingConfig
        }
        // Enforce a single-byte fill char. `fillChar.count == 1` only
        // checks grapheme-cluster count (so "é" — 2 UTF-8 bytes — would
        // pass). Extension's read path memsets a single byte, so the
        // underlying representation must also be one byte.
        guard options.fillChar.utf8.count == 1 else {
            throw LoadError.invalidFillChar(options.fillChar)
        }
        guard parseSize(options.blockSize) != nil else {
            throw LoadError.invalidBlockSize(options.blockSize)
        }
        guard options.preGeneratedBlocks > 0 else {
            throw LoadError.invalidPreGeneratedBlocks(options.preGeneratedBlocks)
        }
        guard options.rateLimit >= 0 else {
            throw LoadError.invalidRateLimit(options.rateLimit)
        }
        guard options.iopLimit >= 0 else {
            throw LoadError.invalidIopLimit(options.iopLimit)
        }
        return options
    }

    /// Convenience: decode and validate a sidecar file at the given URL.
    static func load(from url: URL) throws -> MountOptions {
        try load(from: try Data(contentsOf: url))
    }
}
