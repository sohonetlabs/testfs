//
//  LoadFailureMarker.swift
//  TestFSCore / TestFSExtension
//
//  Shape of the failure-marker JSON the extension writes on
//  `loadResource` error so the host can decode the underlying
//  reason instead of polling blind for the full 15s timeout.
//
//  Pure Swift — do NOT add `import FSKit` here. This file is
//  dual-membership (TestFS host + TestFSExtension via pbxproj);
//  FSKit isn't linked into the host target and an import would
//  silently break the host build only on a clean rebuild.
//

import Foundation

/// `attemptToken` mirrors the `attempt_token` field the host stages
/// into the sidecar; the host accepts a marker only when the tokens
/// match. Optional for forward-compat with markers written before
/// the token plumbing existed (those markers are ignored, which is
/// safe — stage-time delete already prevents stale markers in the
/// common path).
struct LoadFailureMarker: Codable {
    let error: String
    let attemptToken: String?

    enum CodingKeys: String, CodingKey {
        case error
        case attemptToken = "attempt_token"
    }
}
