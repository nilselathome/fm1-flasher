import SwiftUI

enum FirmwareSortOption: String, CaseIterable, Identifiable {
    case stars = "Stars"
    case installs = "Installs"
    case name = "Name"
    case recentlyUpdated = "Recently Updated"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .stars: return "star.fill"
        case .installs: return "arrow.down.circle.fill"
        case .name: return "textformat"
        case .recentlyUpdated: return "clock.fill"
        }
    }
}

struct FirmwareHubBrowserView: View {
    @ObservedObject var catalog: FirmwareHubCatalog
    @ObservedObject var installer: FirmwareInstaller
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var pendingFirmware: RemoteFirmware?
    @State private var sortOption: FirmwareSortOption = .stars

    private var filtered: [RemoteFirmware] {
        let sorted: [RemoteFirmware]
        switch sortOption {
        case .stars:
            sorted = catalog.firmwares.sorted { $0.stars > $1.stars }
        case .installs:
            sorted = catalog.firmwares.sorted { $0.installs > $1.installs }
        case .name:
            sorted = catalog.firmwares.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .recentlyUpdated:
            sorted = catalog.firmwares.sorted { ($0.publishedAt ?? "") > ($1.publishedAt ?? "") }
        }
        guard !searchText.isEmpty else { return sorted }
        let q = searchText.lowercased()
        return sorted.filter {
            $0.displayName.lowercased().contains(q) || $0.author.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage = catalog.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                if !catalog.firmwares.isEmpty {
                    HStack {
                        Text("\(filtered.count) firmwares")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            Picker("Sort by", selection: $sortOption) {
                                ForEach(FirmwareSortOption.allCases) { option in
                                    Label(option.rawValue, systemImage: option.icon).tag(option)
                                }
                            }
                        } label: {
                            Label("Sort: \(sortOption.rawValue)", systemImage: "arrow.up.arrow.down")
                                .font(.caption)
                        }
                    }
                    .listRowSeparator(.hidden)
                }

                ForEach(filtered) { firmware in
                    Button {
                        pendingFirmware = firmware
                    } label: {
                        FirmwareRow(firmware: firmware)
                    }
                    .disabled(installer.phase.isActive)
                }

                Section {
                    Link(destination: URL(string: "https://thefirmwarehub.com")!) {
                        Text("Firmware list: The Firmware Hub – thefirmwarehub.com")
                    }
                    .font(.caption)
                } footer: {
                    Text("Card text, pictures and firmwares belong to each project's own maker, not The Firmware Hub. Licensed CC BY 4.0.")
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Search firmwares or makers")
            .navigationTitle("Browse Firmwares")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if catalog.isLoading {
                        ProgressView()
                    } else {
                        Button {
                            Task { await catalog.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(!catalog.canRefreshNow)
                    }
                }
            }
            .overlay {
                if catalog.firmwares.isEmpty && catalog.isLoading {
                    ProgressView("Loading catalog…")
                } else if catalog.firmwares.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "wifi.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No firmwares loaded")
                            .font(.headline)
                        Text(catalog.errorMessage ?? "Pull to refresh once you have a connection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
            .task {
                await catalog.refreshIfNeeded()
            }
            .confirmationDialog(
                pendingFirmware.map { "Install \($0.displayName) \($0.version)?" } ?? "",
                isPresented: Binding(
                    get: { pendingFirmware != nil },
                    set: { if !$0 { pendingFirmware = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Install", role: .destructive) {
                    guard let firmware = pendingFirmware else { return }
                    pendingFirmware = nil
                    dismiss()
                    Task { await installer.install(firmware: firmware) }
                }
                Button("Cancel", role: .cancel) { pendingFirmware = nil }
            } message: {
                if let firmware = pendingFirmware {
                    Text("Downloads from \(firmware.repo) and verifies its checksum before installing. Do not disconnect the FM-1 or leave this app while writing. This replaces the currently running firmware.")
                }
            }
        }
    }
}

private struct FirmwareRow: View {
    let firmware: RemoteFirmware

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CachedThumbnail(url: firmware.thumbnailURL)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(firmware.displayName)
                        .font(.body.weight(.semibold))
                    Text(firmware.version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("by \(firmware.author)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !firmware.whatText.isEmpty {
                    Text(firmware.whatText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 10) {
                    if firmware.stars > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                            Text("\(firmware.stars)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if firmware.installs > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(firmware.installs)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
