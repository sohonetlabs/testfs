//
//  AboutView.swift
//  TestFS
//
//  Custom About window. Replaces the system About panel so we can
//  surface live system info (chip, memory, OS build) that's
//  copy-pasteable into a bug report, alongside the standard repo
//  / issues / license links.
//

import AppKit
import SwiftUI

struct AboutView: View {
    @Environment(\.openURL) private var openURL

    private static let repoURL = URL(string: "https://github.com/sohonetlabs/testfs")!
    private static let issuesURL = URL(string: "https://github.com/sohonetlabs/testfs/issues")!
    private static let licenseURL = URL(string: "https://github.com/sohonetlabs/testfs/blob/main/LICENSE")!

    var body: some View {
        VStack(spacing: 12) {
            AppEnvironment.icon
                .frame(width: 96, height: 96)
            Text("TestFS").font(.title2).bold()
            Text(AppEnvironment.versionLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Synthetic FSKit filesystem for macOS")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Link("Source: github.com/sohonetlabs/testfs", destination: Self.repoURL)
                Link("Issues: github.com/sohonetlabs/testfs/issues", destination: Self.issuesURL)
                Link("License: MIT", destination: Self.licenseURL)
            }
            .font(.callout)

            HStack(alignment: .top, spacing: 8) {
                Text(Self.diagnostics)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.diagnostics, forType: .string)
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.10))
            )

            Text("Copyright © 2026 Sohonet Ltd.\nBuilt by Ben and the clankers.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(width: 380)
    }

    /// Live system snapshot for bug reports. Computed once per
    /// process — chip / total RAM / OS version don't change between
    /// About-window opens. The Copy button puts this exact string
    /// on the clipboard.
    private static let diagnostics: String = {
        let info = ProcessInfo.processInfo
        let mem = ByteCountFormatter.string(
            fromByteCount: Int64(info.physicalMemory), countStyle: .memory)
        return """
            TestFS \(AppEnvironment.version) (build \(AppEnvironment.build))
            macOS \(info.operatingSystemVersionString)
            \(chipName())
            \(mem) RAM
            """
    }()

    /// `sysctlbyname("machdep.cpu.brand_string")` — returns
    /// "Apple M2 Pro" / "Apple M3 Max" / "Intel(R) Core(TM) i7-…"
    /// depending on the host. Reading via Darwin is the canonical
    /// macOS way; there's no Foundation equivalent.
    private static func chipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Unknown CPU" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}

#Preview {
    AboutView()
}
