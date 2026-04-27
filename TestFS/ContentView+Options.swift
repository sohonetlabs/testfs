//
//  ContentView+Options.swift
//  TestFS
//
//  Advanced-options form for ContentView. Split out so the main
//  ContentView.swift stays inside SwiftLint's type/file-length
//  budgets — every section here is independent of the mount /
//  live-mounts UI in the main file.
//

import SwiftUI

extension ContentView {
    @ViewBuilder
    var optionsForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                volumeSection
                readsSection
                throttleSection
                ownershipSection
                loggingSection
                namesSection
                if let err = optionsValidationError {
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Reset to defaults") { options = .default }
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var volumeSection: some View {
        optionsGroup("Volume") {
            optionRow("Volume name") {
                TextField(
                    "",
                    text: Binding(
                        get: { options.volumeName ?? "" },
                        set: { options.volumeName = $0.isEmpty ? nil : $0 }
                    ),
                    prompt: Text(
                        pickedJSON?.deletingPathExtension().lastPathComponent
                            ?? "from filename")
                )
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private var readsSection: some View {
        optionsGroup("Reads") {
            optionRow(
                "Mode",
                help: "Off: fill all reads with the fill char. "
                    + "On: serve deterministic pseudo-random bytes "
                    + "from a pre-generated block cache."
            ) {
                Picker("", selection: $options.semiRandom) {
                    Text("Fill char").tag(false)
                    Text("Semi-random").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
            }
            if !options.semiRandom {
                fillCharRow
            } else {
                semiRandomRows
            }
        }
    }

    @ViewBuilder
    private var fillCharRow: some View {
        optionRow(
            "Fill char",
            help: "Single byte used to fill every read."
        ) {
            HStack(spacing: 6) {
                TextField("", text: $options.fillChar)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 80)
                    .onChange(of: options.fillChar) { _, new in
                        if new.count > 1 {
                            options.fillChar = String(new.first ?? "\u{0000}")
                        }
                    }
                if options.fillChar == "\u{0000}" {
                    Text("(null byte)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var semiRandomRows: some View {
        optionRow(
            "Block size",
            help: "Size of each pre-generated block. "
                + "Accepts 128K, 1M, etc."
        ) {
            TextField("", text: $options.blockSize, prompt: Text("128K"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
        }
        optionRow(
            "Pre-gen blocks",
            help: "Number of pre-generated blocks in the cache. "
                + "Reads cycle through these."
        ) {
            TextField("", value: $options.preGeneratedBlocks, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
        }
        optionRow(
            "Seed",
            help: "Seed for the LCG. Same seed → same bytes."
        ) {
            TextField("", value: $options.seed, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
        }
    }

    @ViewBuilder
    private var throttleSection: some View {
        optionsGroup("Throttle") {
            optionRow(
                "Op delay (s)",
                help: "Minimum delay between operations, in seconds. "
                    + "Fractional values are fine — e.g. 0.05 for a "
                    + "50 ms gap between ops."
            ) {
                nonZeroNumericRow(
                    value: $options.rateLimit,
                    remembered: $rememberedRateLimit,
                    defaultValue: 1.0
                )
            }
            optionRow(
                "IOP limit",
                help: "Maximum operations per second."
            ) {
                nonZeroNumericRow(
                    value: $options.iopLimit,
                    remembered: $rememberedIopLimit,
                    defaultValue: 100
                )
            }
        }
    }

    @ViewBuilder
    private var ownershipSection: some View {
        optionsGroup("Ownership") {
            optionRow(
                "uid",
                help: "Override owner uid for every item. "
                    + "Blank = current user."
            ) {
                TextField(
                    "", value: $options.uid, format: .number,
                    prompt: Text("current")
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
            }
            optionRow(
                "gid",
                help: "Override group gid for every item. "
                    + "Blank = current group."
            ) {
                TextField(
                    "", value: $options.gid, format: .number,
                    prompt: Text("current")
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
            }
            optionRow(
                "mtime",
                help: "Modification + access + change + birth time "
                    + "stamped on every item."
            ) {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { MountOptions.parseMtime(options.mtime) ?? .now },
                        set: { options.mtime = MountOptions.formatMtime($0) }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private var loggingSection: some View {
        optionsGroup("Logging") {
            optionRow(
                "Verbose",
                help: "Log every lookup / enumerate / read in the "
                    + "extension at debug level. Off by default — "
                    + "those would dwarf everything else on a busy "
                    + "filesystem."
            ) {
                Toggle("", isOn: $options.verbose)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            optionRow(
                "Stats summary",
                help: "Emit a once-per-second ops/s + bytes/s line "
                    + "while the volume is active."
            ) {
                Toggle("", isOn: $options.reportStats)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private var namesSection: some View {
        optionsGroup("Names") {
            optionRow(
                "Unicode normalization",
                help: "Form applied to filenames during tree build "
                    + "and lookup. NFD matches macOS HFS+ behaviour."
            ) {
                Picker("", selection: $options.unicodeNormalization) {
                    ForEach(UnicodeNormalization.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 140)
            }
            optionRow(
                "Ignore ._* paths",
                help: "Silently return ENOENT for AppleDouble "
                    + "companion lookups (._foo) instead of logging "
                    + "warnings on every Finder probe."
            ) {
                Toggle("", isOn: $options.ignoreAppledouble)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            optionRow(
                "Suppress Spotlight indexing",
                help: "Adds .metadata_never_index, "
                    + ".metadata_never_index_unless_rootfs, and "
                    + "similar dotfiles at the root so Spotlight, "
                    + "Time Machine, and other indexers skip the "
                    + "volume. (JSON key: add_macos_cache_files.)"
            ) {
                Toggle("", isOn: $options.addMacosCacheFiles)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }

    @ViewBuilder
    fileprivate func optionsGroup<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 6) { content() }
        }
    }

    /// Toggle + Double TextField composite: 0 means disabled.
    @ViewBuilder
    fileprivate func nonZeroNumericRow(
        value: Binding<Double>, remembered: Binding<Double>, defaultValue: Double
    ) -> some View {
        nonZeroToggleRow(
            isEnabled: value.wrappedValue > 0,
            toggle: makeNonZeroToggle(
                value: value, remembered: remembered, defaultValue: defaultValue),
            field: TextField("", value: value, format: .number)
        )
    }

    /// Toggle + Int TextField composite: 0 means disabled.
    @ViewBuilder
    fileprivate func nonZeroNumericRow(
        value: Binding<Int>, remembered: Binding<Int>, defaultValue: Int
    ) -> some View {
        nonZeroToggleRow(
            isEnabled: value.wrappedValue > 0,
            toggle: makeNonZeroToggle(
                value: value, remembered: remembered, defaultValue: defaultValue),
            field: TextField("", value: value, format: .number)
        )
    }

    /// Layout for both numeric overloads; concrete TextField is
    /// passed in by the overload that knows the bound type.
    @ViewBuilder
    private func nonZeroToggleRow<Field: View>(
        isEnabled: Bool, toggle: Binding<Bool>, field: Field
    ) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: toggle)
                .toggleStyle(.switch)
                .labelsHidden()
            if isEnabled {
                field
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
            } else {
                Text("disabled")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private func makeNonZeroToggle<Value>(
        value: Binding<Value>, remembered: Binding<Value>, defaultValue: Value
    ) -> Binding<Bool>
    where Value: Comparable & Numeric & ExpressibleByIntegerLiteral {
        let zero: Value = 0
        return Binding(
            get: { value.wrappedValue > zero },
            set: { isOn in
                if isOn {
                    value.wrappedValue =
                        remembered.wrappedValue > zero
                        ? remembered.wrappedValue : defaultValue
                } else {
                    if value.wrappedValue > zero {
                        remembered.wrappedValue = value.wrappedValue
                    }
                    value.wrappedValue = zero
                }
            }
        )
    }

    @ViewBuilder
    fileprivate func optionRow<Control: View>(
        _ label: String, help: String? = nil, @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 12) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 180, alignment: .leading)
                    .help(help ?? "")
                control()
                Spacer()
            }
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 192)
            }
        }
    }
}
