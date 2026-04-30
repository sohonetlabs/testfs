//
//  BundledExamples.swift
//  TestFSCore (host-only consumer)
//
//  Directory-listing helper for the host's bundled examples folder.
//  Pure Foundation so unit tests can drive it against a temp directory
//  without standing up the Xcode app bundle. Lives under
//  TestFSExtension/ because that's the SPM source root for TestFSCore;
//  the appex compiles it but doesn't reference it.
//

import Foundation

enum BundledExamples {
    /// Every `*.json` URL in `dir`, sorted by basename. Returns an
    /// empty array if `dir` is nil, missing, or unreadable. Filter
    /// is `pathExtension == "json"` (not `hasSuffix`) so a name
    /// like `imdbfslayout.json.zip` is correctly excluded.
    static func sortedJSONURLs(in dir: URL?) -> [URL] {
        guard let dir,
            let urls = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
