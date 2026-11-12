import CoreMIDI

struct MIDIDevice: Identifiable, Equatable {
    let id: MIDIObjectRef
    let name: String
}

@MainActor
final class MIDIManager: ObservableObject {
    @Published private(set) var devices: [MIDIDevice] = []
    @Published private(set) var fm1Device: MIDIDevice?

    /// Devices minus the always-present virtual pseudo-devices CoreMIDI
    /// itself creates ("Bluetooth", "Network") — what's left is actual
    /// USB/hardware MIDI accessories, present only while physically
    /// connected. A quick "is anything plugged in at all" signal,
    /// independent of whether it's recognized as the FM-1.
    var connectedHardwareDevices: [MIDIDevice] {
        devices.filter { $0.name != "Bluetooth" && $0.name != "Network" }
    }

    @Published private(set) var isQuerying = false
    @Published private(set) var firmwareVersion: String?
    @Published private(set) var queryErrorMessage: String?

    @Published private(set) var isQueryingFlashID = false
    @Published private(set) var flashJEDEC: String?
    @Published private(set) var flashIDErrorMessage: String?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var started = false

    private var fm1Source: MIDIEndpointRef?
    private var fm1Destination: MIDIEndpointRef?
    private var sysexBuffer: [UInt8] = []
    private var pendingIdentityHandler: ((FM1Protocol.Identity) -> Void)?
    private var pendingFlashIDHandler: ((FM1Protocol.Identity) -> Void)?

    func start() {
        guard !started else { return }
        started = true

        let notifyBlock: MIDINotifyBlock = { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }
        var status = MIDIClientCreateWithBlock("com.nilsel.fm1flasher" as CFString, &client, notifyBlock)
        if status != noErr {
            print("MIDIClientCreateWithBlock failed: \(status)")
        }

        status = MIDIOutputPortCreate(client, "com.nilsel.fm1flasher.out" as CFString, &outputPort)
        if status != noErr {
            print("MIDIOutputPortCreate failed: \(status)")
        }

        status = MIDIInputPortCreateWithBlock(
            client, "com.nilsel.fm1flasher.in" as CFString, &inputPort
        ) { [weak self] packetListPtr, _ in
            // packetListPtr (and the packet memory it points to) is only
            // valid for the duration of this callback — CoreMIDI may reuse
            // or invalidate it as soon as we return. Copy the bytes out
            // synchronously here; only hand already-safe plain data to the
            // MainActor hop below.
            var packet = packetListPtr.pointee.packet
            let numPackets = packetListPtr.pointee.numPackets
            var packets: [[UInt8]] = []
            packets.reserveCapacity(Int(numPackets))
            for _ in 0..<numPackets {
                let bytes = withUnsafeBytes(of: packet.data) { raw -> [UInt8] in
                    Array(raw.prefix(Int(packet.length)))
                }
                packets.append(bytes)
                packet = MIDIPacketNext(&packet).pointee
            }
            Task { @MainActor in
                self?.handleIncoming(packets)
            }
        }
        if status != noErr {
            print("MIDIInputPortCreateWithBlock failed: \(status)")
        }

        refreshDevices()
    }

    // MARK: - Device discovery

    private func refreshDevices() {
        var found: [MIDIDevice] = []
        let count = MIDIGetNumberOfDevices()
        for index in 0..<count {
            let device = MIDIGetDevice(index)
            guard device != 0 else { continue }
            // iOS doesn't remove a USB device's entry from the list on
            // unplug the way macOS does — it stays enumerated but gets
            // marked offline. Skip those, or a disconnected accessory
            // keeps showing as present indefinitely.
            if MIDIDeviceDirectory.isOffline(device) { continue }
            found.append(MIDIDevice(id: device, name: MIDIDeviceDirectory.name(for: device)))
        }
        devices = found
        print("MIDI devices (\(found.count)): \(found.map(\.name))")

        let match = found.first { device in
            MIDIDeviceDirectory.knownPortNameFragments.contains { device.name.localizedCaseInsensitiveContains($0) }
        }
        fm1Device = match

        if let match {
            let endpoints = MIDIDeviceDirectory.endpoints(for: match.id)
            updateConnection(source: endpoints.source, destination: endpoints.destination)
        } else {
            updateConnection(source: nil, destination: nil)
        }
    }

    private func updateConnection(source: MIDIEndpointRef?, destination: MIDIEndpointRef?) {
        if let previous = fm1Source, previous != 0, previous != source {
            MIDIPortDisconnectSource(inputPort, previous)
        }
        fm1Source = source
        fm1Destination = destination

        if source == nil || destination == nil {
            isQuerying = false
            firmwareVersion = nil
            queryErrorMessage = nil
            pendingIdentityHandler = nil

            isQueryingFlashID = false
            flashJEDEC = nil
            flashIDErrorMessage = nil
            pendingFlashIDHandler = nil
        }

        if let source, source != 0 {
            let status = MIDIPortConnectSource(inputPort, source, nil)
            print("MIDIPortConnectSource source=\(source) name=\(MIDIDeviceDirectory.name(for: source)) status: \(status == noErr ? "OK" : "failed (\(status))")")
        }
    }

    // MARK: - FM-1 identity query

    /// Sends the SysEx handshake query and reports back the identity string
    /// (e.g. "FM-1_906"), or an error if nothing answers in time. This is a
    /// pure read — see PLAN.md "Protocol notes" for why this is the safe
    /// first milestone before anything that writes flash.
    func readFirmwareVersion() {
        guard !isQuerying else { return }
        guard let destination = fm1Destination, destination != 0 else {
            queryErrorMessage = "FM-1 not connected"
            return
        }

        isQuerying = true
        queryErrorMessage = nil
        firmwareVersion = nil

        pendingIdentityHandler = { [weak self] identity in
            guard let self else { return }
            self.firmwareVersion = identity.text
            self.isQuerying = false
            self.pendingIdentityHandler = nil
        }

        send(FM1Protocol.hsQuery, to: destination)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.isQuerying else { return }
            self.queryErrorMessage = "No response from FM-1"
            self.isQuerying = false
            self.pendingIdentityHandler = nil
        }
    }

    /// Sends the HS_FULL handshake and reports back the flash chip's JEDEC
    /// ID, if this firmware build reports one (not all do — see PLAN.md
    /// "Canonical flash layout and safety notes"). A pure read, same as
    /// readFirmwareVersion().
    func readFlashChipID() {
        guard !isQueryingFlashID else { return }
        guard let destination = fm1Destination, destination != 0 else {
            flashIDErrorMessage = "FM-1 not connected"
            return
        }

        isQueryingFlashID = true
        flashIDErrorMessage = nil
        flashJEDEC = nil

        pendingFlashIDHandler = { [weak self] identity in
            guard let self else { return }
            if let jedec = identity.flashJEDEC {
                self.flashJEDEC = String(format: "0x%06X", jedec)
            } else {
                self.flashIDErrorMessage = "Not reported by this firmware"
            }
            self.isQueryingFlashID = false
            self.pendingFlashIDHandler = nil
        }

        send(FM1Protocol.hsFull, to: destination)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.isQueryingFlashID else { return }
            self.flashIDErrorMessage = "No response from FM-1"
            self.isQueryingFlashID = false
            self.pendingFlashIDHandler = nil
        }
    }

    private func send(_ bytes: [UInt8], to destination: MIDIEndpointRef) {
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        print("FM1 SysEx out, destination=\(destination) name=\(MIDIDeviceDirectory.name(for: destination)): \(hex)")

        let bufferSize = max(1024, bytes.count + 64)
        let rawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize, alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { rawPtr.deallocate() }
        let packetListPtr = rawPtr.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let firstPacket = MIDIPacketListInit(packetListPtr)
        _ = MIDIPacketListAdd(packetListPtr, bufferSize, firstPacket, 0, bytes.count, bytes)

        let status = MIDISend(outputPort, destination, packetListPtr)
        print("MIDISend status: \(status == noErr ? "OK" : "failed (\(status))")")
    }

    private func handleIncoming(_ packets: [[UInt8]]) {
        print("handleIncoming: \(packets.count) packet(s)")
        for bytes in packets {
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            print("  raw packet (\(bytes.count) bytes): \(hex)")
            process(incoming: bytes)
        }
    }

    private func process(incoming bytes: [UInt8]) {
        for byte in bytes {
            if byte == 0xF0 {
                sysexBuffer = [0xF0]
            } else if !sysexBuffer.isEmpty {
                sysexBuffer.append(byte)
                if byte == 0xF7 {
                    let message = sysexBuffer
                    sysexBuffer.removeAll()
                    let hex = message.map { String(format: "%02X", $0) }.joined(separator: " ")
                    print("FM1 SysEx in (\(message.count) bytes): \(hex)")
                    if let identity = FM1Protocol.parseIdentity(message) {
                        pendingIdentityHandler?(identity)
                        pendingFlashIDHandler?(identity)
                    } else {
                        print("FM1 SysEx in: did not parse as identity reply")
                    }
                }
            }
        }
    }
}
