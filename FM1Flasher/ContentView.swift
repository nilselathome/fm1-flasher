import SwiftUI

struct ContentView: View {
    @StateObject private var midi = MIDIManager()
    @StateObject private var installer = FirmwareInstaller()
    @StateObject private var hubCatalog = FirmwareHubCatalog.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedFirmware: BundledFirmware = FirmwareCatalog.all[0]
    @State private var showConfirmation = false
    @State private var showHubBrowser = false
    @State private var didBackgroundDuringInstall = false

    var body: some View {
        NavigationStack {
            List {
                if didBackgroundDuringInstall {
                    Section {
                        Label("The app left the foreground during an install. The FM-1 may be in an inconsistent state — do not unplug it. Check its screen, then verify which firmware is running before trusting it.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Button("Dismiss") { didBackgroundDuringInstall = false }
                    }
                }

                Section("Install Firmware") {
                    Picker("Firmware", selection: $selectedFirmware) {
                        ForEach(FirmwareCatalog.all) { firmware in
                            Text("\(firmware.displayName) \(firmware.version)").tag(firmware)
                        }
                    }
                    .disabled(installer.phase.isActive)

                    if installer.phase.isActive {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Keep the app open and the FM-1 plugged in", systemImage: "iphone.and.arrow.forward")
                                .foregroundStyle(.orange)
                                .font(.callout.bold())
                            installPhaseView
                        }
                    } else {
                        Button("Install \(selectedFirmware.displayName) \(selectedFirmware.version)") {
                            showConfirmation = true
                        }
                        .disabled(midi.fm1Device == nil)

                        Button("Browse Firmwares Online…") {
                            showHubBrowser = true
                        }
                        .disabled(installer.phase.isActive)

                        switch installer.phase {
                        case .done(let identity):
                            Label("Installed — FM-1 now reports \"\(identity)\"", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failed(let message):
                            Label(message, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        default:
                            EmptyView()
                        }
                    }
                }
                .confirmationDialog(
                    "Install \(selectedFirmware.displayName) \(selectedFirmware.version)?",
                    isPresented: $showConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Install", role: .destructive) {
                        didBackgroundDuringInstall = false
                        Task { await installer.install(firmware: selectedFirmware) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Do not disconnect the FM-1 or leave this app while writing. This replaces the currently running firmware.")
                }

                Section("USB") {
                    if midi.connectedHardwareDevices.isEmpty {
                        Label("No USB MIDI device connected", systemImage: "cable.connector.slash")
                            .foregroundStyle(.red)
                    } else {
                        ForEach(midi.connectedHardwareDevices) { device in
                            Label(device.name, systemImage: "cable.connector")
                                .foregroundStyle(.green)
                        }
                    }
                }

                Section("FM-1") {
                    if let device = midi.fm1Device {
                        Label(device.name, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not connected", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        midi.readFirmwareVersion()
                    } label: {
                        if midi.isQuerying {
                            HStack {
                                ProgressView()
                                Text("Reading firmware version…")
                            }
                        } else {
                            Text("Read Firmware Version")
                        }
                    }
                    .disabled(midi.fm1Device == nil || midi.isQuerying)

                    if let firmwareVersion = midi.firmwareVersion {
                        Label(firmwareVersion, systemImage: "cpu")
                            .foregroundStyle(.green)
                    }
                    if let queryErrorMessage = midi.queryErrorMessage {
                        Text(queryErrorMessage)
                            .foregroundStyle(.red)
                    }

                    Button {
                        midi.readFlashChipID()
                    } label: {
                        if midi.isQueryingFlashID {
                            HStack {
                                ProgressView()
                                Text("Reading flash chip ID…")
                            }
                        } else {
                            Text("Read Flash Chip ID")
                        }
                    }
                    .disabled(midi.fm1Device == nil || midi.isQueryingFlashID)

                    if let flashJEDEC = midi.flashJEDEC {
                        Label(flashJEDEC, systemImage: "memorychip")
                            .foregroundStyle(.green)
                    }
                    if let flashIDErrorMessage = midi.flashIDErrorMessage {
                        Text(flashIDErrorMessage)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("All MIDI devices") {
                    if midi.devices.isEmpty {
                        Text("No MIDI devices found")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(midi.devices) { device in
                            Text(device.name)
                        }
                    }
                }
            }
            .navigationTitle("FM1 Flasher")
            .onAppear { midi.start() }
            .onChange(of: scenePhase) { newPhase in
                if newPhase != .active && installer.phase.isActive {
                    didBackgroundDuringInstall = true
                }
            }
            .sheet(isPresented: $showHubBrowser) {
                FirmwareHubBrowserView(catalog: hubCatalog, installer: installer)
            }
        }
    }

    @ViewBuilder
    private var installPhaseView: some View {
        switch installer.phase {
        case .idle, .done, .failed:
            EmptyView()
        case .downloading:
            HStack {
                ProgressView()
                Text("Downloading firmware…")
            }
        case .checking(let reads):
            HStack {
                ProgressView()
                Text("Checking connection… (\(reads) reads)")
            }
        case .waitingForLoader:
            HStack {
                ProgressView()
                Text("Waiting for the update loader to start…")
            }
        case .writing(let percent):
            VStack(alignment: .leading) {
                ProgressView(value: Double(percent), total: 100)
                Text("Writing firmware… \(percent)%")
            }
        case .rebooting:
            HStack {
                ProgressView()
                Text("Waiting for the FM-1 to reboot…")
            }
        case .verifying:
            HStack {
                ProgressView()
                Text("Verifying…")
            }
        }
    }
}

#Preview {
    ContentView()
}
