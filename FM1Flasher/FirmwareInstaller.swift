import CoreMIDI
import Foundation
import UIKit

/// Bridges the realtime CoreMIDI input callback into something an async
/// install flow can `await` with a timeout — mirrors fm1_install.py's
/// queue.Queue + read(timeout) pairing.
actor SysExInbox {
    private var pending: [[UInt8]] = []
    private var waiter: CheckedContinuation<[UInt8]?, Never>?

    func push(_ message: [UInt8]) {
        if let waiter {
            waiter.resume(returning: message)
            self.waiter = nil
        } else {
            pending.append(message)
        }
    }

    /// Discards anything buffered — used when switching which device port
    /// we're listening to, so a stale reply from the old link can't be
    /// mistaken for one from the new link.
    func drain() {
        pending.removeAll()
    }

    func next(timeoutSeconds: Double) async -> [UInt8]? {
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[UInt8]?, Never>) in
            self.waiter = continuation
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(timeoutSeconds, 0) * 1_000_000_000))
                await self.fireTimeout()
            }
        }
    }

    private func fireTimeout() {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: nil)
    }
}

/// Drives the two-phase FM-1 firmware install (Check, then Write, then
/// Verify), ported from fm1_install.py's Updater class. Owns its own
/// CoreMIDI client, separate from MIDIManager's, since it needs to
/// dynamically scan/connect/disconnect across candidate ports as the
/// device's MIDI port vanishes and reappears across each reboot.
@MainActor
final class FirmwareInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading
        case checking(reads: Int)
        case waitingForLoader
        case writing(percent: Int)
        case rebooting
        case verifying
        case done(identity: String)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .idle, .done, .failed: return false
            default: return true
            }
        }
    }

    private struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct FoundDevice {
        let device: MIDIObjectRef
        let source: MIDIEndpointRef
        let destination: MIDIEndpointRef
        let identity: FM1Protocol.Identity
    }

    private enum ServeOutcome {
        case finished(reads: Int)
        case stoppedResponding(reads: Int)
        case lost(reads: Int)
        case badRequest(addr: UInt32, length: UInt32)
    }

    @Published private(set) var phase: Phase = .idle

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var connectedSource: MIDIEndpointRef?
    private var sysexBuffer: [UInt8] = []
    private let inbox = SysExInbox()
    private var started = false

    func install(firmware: some InstallableFirmware) async {
        guard !phase.isActive else { return }
        ensureStarted()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        print("Installer: starting install of \(firmware.displayName) \(firmware.version)")

        do {
            phase = .downloading
            let raw = try await firmware.loadBytes()
            guard let product = FM1Protocol.packageProductIdentity(raw), isValidProductIdentity(product) else {
                throw InstallError(message: "Not a valid FM-1 package (bad identity marker)")
            }
            guard containsLoaderMarker(raw) else {
                throw InstallError(message: "No Felucca update loader found inside this package")
            }
            let image = FM1Protocol.packageLogicalImage(raw)
            print("Installer: package product=\(product) image bytes=\(image.count)")

            phase = .checking(reads: 0)

            guard let dev = await findDeviceOnce(wantLoader: nil) else {
                throw InstallError(message: "FM-1 not found. Check the USB connection.")
            }
            print("Installer: found device id=\(dev.device) identity=\(dev.identity.text) isLoader=\(dev.identity.isLoader)")
            guard FM1Protocol.modelOf(dev.identity.text) == FM1Protocol.modelOf(product) else {
                disconnectCurrentSource()
                throw InstallError(message: "Connected device (\(dev.identity.text)) doesn't match this package's model")
            }

            let ota: FoundDevice
            if dev.identity.isLoader {
                ota = dev
            } else {
                print("Installer: Check phase — sending UPGRADE to \(dev.identity.text)")
                _ = sendDirect(FM1Protocol.upgrade, to: dev.destination)
                try await Task.sleep(nanoseconds: 2_000_000_000)

                let checkOutcome = await serve(
                    device: dev.device, destination: dev.destination,
                    image: image, finishAddr: FM1Protocol.finishCheck, idleTimeout: 8.0, label: "Check"
                ) { [weak self] reads, _ in
                    self?.phase = .checking(reads: reads)
                }
                disconnectCurrentSource()
                print("Installer: Check outcome = \(checkOutcome)")
                try throwIfFailed(checkOutcome, contextPrefix: "Check")

                phase = .waitingForLoader
                try await Task.sleep(nanoseconds: 10_000_000_000)
                guard let loaderDevice = await findDevice(wantLoader: true, timeoutSeconds: 30) else {
                    throw InstallError(message: "Update loader did not appear. The FM-1 stays in update mode — replug it and run the install again.")
                }
                print("Installer: loader found id=\(loaderDevice.device) identity=\(loaderDevice.identity.text)")
                ota = loaderDevice
            }

            try await writeWithRetries(ota: ota, image: image)
            phase = .writing(percent: 100)

            phase = .rebooting
            try await Task.sleep(nanoseconds: 3_000_000_000)
            guard let back = await findDevice(wantLoader: false, timeoutSeconds: 40) else {
                throw InstallError(message: "The FM-1 did not come back after writing. Power-cycle it, then check which firmware is running.")
            }
            print("Installer: device back, identity=\(back.identity.text)")

            phase = .verifying
            guard back.identity.text == product else {
                throw InstallError(message: "Written, but the FM-1 now reports \"\(back.identity.text)\" (expected \"\(product)\")")
            }
            phase = .done(identity: back.identity.text)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            print("Installer: FAILED — \(message)")
            phase = .failed(message)
        }
    }

    func reset() {
        guard !phase.isActive else { return }
        phase = .idle
    }

    private func throwIfFailed(_ outcome: ServeOutcome, contextPrefix: String, replugHint: Bool = false) throws {
        let hint = replugHint ? " Replug the FM-1 and run the install again to finish." : " Nothing was written yet."
        switch outcome {
        case .finished:
            return
        case .lost(let reads):
            throw InstallError(message: "\(contextPrefix): FM-1 disconnected after \(reads) read(s).\(hint)")
        case .stoppedResponding(let reads):
            throw InstallError(message: "\(contextPrefix): FM-1 stopped answering after \(reads) read(s).\(hint)")
        case .badRequest(let addr, let length):
            throw InstallError(message: "\(contextPrefix): FM-1 asked for an out-of-range chunk (addr \(addr), length \(length)).\(hint)")
        }
    }

    /// Repeats the Write pass against the update loader if it drops the
    /// connection partway through. Observed on real hardware: the first
    /// Write attempt after a fresh Check->reboot reliably fails a couple of
    /// reads in, then a second attempt against the same (already-booted)
    /// loader completes cleanly — consistent with the loader's own USB
    /// handling needing a moment to settle right after it starts actually
    /// erasing/programming flash, rather than a host-side cable/power
    /// problem (see PLAN.md). This automates the "just run it again" manual
    /// recovery the resumable-install design already supports.
    private func writeWithRetries(ota initialOTA: FoundDevice, image: [UInt8], maxAttempts: Int = 3) async throws {
        var ota = initialOTA
        await pollLoaderReadiness(ota)

        for attempt in 1...maxAttempts {
            phase = .writing(percent: 0)
            print("Installer: Write attempt \(attempt)/\(maxAttempts) — sending UPGRADE to \(ota.identity.text)")
            _ = sendDirect(FM1Protocol.upgrade, to: ota.destination)
            try await Task.sleep(nanoseconds: 2_000_000_000)

            let outcome = await serve(
                device: ota.device, destination: ota.destination,
                image: image, finishAddr: FM1Protocol.finishWrite, idleTimeout: 180.0, label: "Write"
            ) { [weak self] _, endOffset in
                let percent = min(99, endOffset * 100 / max(image.count, 1))
                self?.phase = .writing(percent: percent)
            }
            disconnectCurrentSource()
            print("Installer: Write attempt \(attempt) outcome = \(outcome)")

            if case .finished = outcome {
                return
            }

            let isLastAttempt = attempt == maxAttempts
            if isLastAttempt {
                try throwIfFailed(outcome, contextPrefix: "Write (after \(maxAttempts) attempts)", replugHint: true)
                fatalError("throwIfFailed always throws for a non-.finished outcome")
            }

            print("Installer: Write attempt \(attempt) failed, letting the loader settle before retrying…")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            guard let rediscovered = await findDevice(wantLoader: true, timeoutSeconds: 15) else {
                throw InstallError(message: "Update loader did not come back after a failed write attempt. Replug the FM-1 and run the install again.")
            }
            ota = rediscovered
        }
    }

    /// Pings the loader with plain HS_QUERY a few times before the first
    /// Write attempt. This is informational pacing, not a hard gate — on
    /// real hardware the loader already answered the Check-phase's reads
    /// normally and still dropped out a couple of reads into Write, which
    /// points at something tied to the loader starting its first real
    /// flash erase/program operation, not simple USB-not-ready-yet. So
    /// this is unlikely to eliminate the one-retry pattern by itself; the
    /// real fix is writeWithRetries() automatically redoing the attempt.
    /// Kept anyway since it's cheap and doesn't block on failure.
    private func pollLoaderReadiness(_ ota: FoundDevice, attempts: Int = 3) async {
        for i in 1...attempts {
            let identity = await askIdentity(FM1Protocol.hsQuery, to: ota.destination, timeout: 1.0)
            print("Installer: readiness poll \(i)/\(attempts) — \(identity?.text ?? "no response")")
            if i < attempts {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: - Serve loop (shared by Check and Write)

    private func serve(
        device: MIDIObjectRef, destination: MIDIEndpointRef,
        image: [UInt8], finishAddr: UInt32, idleTimeout: Double, label: String,
        onProgress: @escaping (Int, Int) -> Void
    ) async -> ServeOutcome {
        var served = 0
        var lastActivity = Date()
        while true {
            let message = await inbox.next(timeoutSeconds: 1.0)
            guard let message else {
                if MIDIDeviceDirectory.isOffline(device) {
                    print("\(label): device \(device) reported offline by CoreMIDI after \(served) read(s)")
                    return .lost(reads: served)
                }
                if Date().timeIntervalSince(lastActivity) > idleTimeout {
                    print("\(label): idle timeout (\(idleTimeout)s) after \(served) read(s)")
                    return .stoppedResponding(reads: served)
                }
                continue
            }
            guard let request = FM1Protocol.parseReadRequest(message) else {
                print("\(label): unparsed message while serving (\(message.count) bytes), ignoring")
                continue
            }
            lastActivity = Date()

            if request.addr == FM1Protocol.finishCheck || request.addr == FM1Protocol.finishWrite {
                print("\(label): finish request addr=0x\(String(request.addr, radix: 16)) after \(served) read(s)")
                _ = sendDirect(FM1Protocol.response(addr: request.addr, data: Array("success\0".utf8)), to: destination)
                if request.addr == finishAddr {
                    return .finished(reads: served)
                }
                continue
            }

            guard request.length <= FM1Protocol.maxReadLength,
                  Int(request.addr) + Int(request.length) <= image.count else {
                print("\(label): bad request addr=\(request.addr) length=\(request.length) (image is \(image.count) bytes)")
                return .badRequest(addr: request.addr, length: request.length)
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
            let start = Int(request.addr)
            let end = start + Int(request.length)
            let chunk = Array(image[start..<end])
            let sendStatus = sendDirectStatus(FM1Protocol.response(addr: request.addr, data: chunk, flags: request.flags), to: destination)
            guard sendStatus == noErr else {
                print("\(label): MIDISend failed with status \(sendStatus) after \(served) read(s) (addr=\(request.addr) length=\(request.length))")
                return .lost(reads: served)
            }
            served += 1
            if served <= 5 || served % 50 == 0 {
                print("\(label): served read #\(served) addr=\(request.addr) length=\(request.length)")
            }
            onProgress(served, end)
        }
    }

    // MARK: - Device finding

    private func identify(device: MIDIObjectRef) async -> FoundDevice? {
        let endpoints = MIDIDeviceDirectory.endpoints(for: device)
        guard let source = endpoints.source, source != 0,
              let destination = endpoints.destination, destination != 0 else {
            print("Installer: device \(device) (\(MIDIDeviceDirectory.name(for: device))) has no usable source/destination")
            return nil
        }
        connect(source: source)
        await inbox.drain()

        guard let plain = await askIdentity(FM1Protocol.hsQuery, to: destination, timeout: 1.0) else {
            print("Installer: device \(device) (\(MIDIDeviceDirectory.name(for: device))) did not answer HS_QUERY")
            return nil
        }
        var identity = plain
        if !identity.isLoader, isAmbiguouslyTruncated(identity.text),
           let full = await askIdentity(FM1Protocol.hsFull, to: destination, timeout: 0.6),
           full.model == identity.model, full.text.hasPrefix(identity.text) {
            identity = full
        }
        return FoundDevice(device: device, source: source, destination: destination, identity: identity)
    }

    private func askIdentity(_ query: [UInt8], to destination: MIDIEndpointRef, timeout: Double) async -> FM1Protocol.Identity? {
        guard sendDirect(query, to: destination) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let message = await inbox.next(timeoutSeconds: remaining) else { return nil }
            if let identity = FM1Protocol.parseIdentity(message) {
                return identity
            }
        }
    }

    /// One pass over currently-known candidate devices, no retry — mirrors
    /// fm1_install.py's find() (used for the very first lookup, before we
    /// know anything is even connected).
    private func findDeviceOnce(wantLoader: Bool?) async -> FoundDevice? {
        for device in MIDIDeviceDirectory.candidateDevices() {
            if let found = await identify(device: device), wantLoader == nil || found.identity.isLoader == wantLoader {
                return found
            }
            disconnectCurrentSource()
        }
        return nil
    }

    /// Retries findDeviceOnce() until timeoutSeconds elapses — mirrors
    /// fm1_install.py's wait_for(), used across a reboot where the device's
    /// MIDI port disappears and reappears.
    private func findDevice(wantLoader: Bool?, timeoutSeconds: Double) async -> FoundDevice? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            if let found = await findDeviceOnce(wantLoader: wantLoader) {
                return found
            }
            if Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// fm1_install.py's handshake() asks HS_FULL only when the plain reply
    /// looks like it *might* be the 3-digit-truncated form (NAME_DDD, exactly
    /// 3 digits) — anything else is already complete.
    private func isAmbiguouslyTruncated(_ text: String) -> Bool {
        let parts = text.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].count == 3 else { return false }
        return parts[1].allSatisfy(\.isNumber)
    }

    private func isValidProductIdentity(_ text: String) -> Bool {
        let parts = text.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return parts[1].allSatisfy(\.isNumber)
    }

    private func containsLoaderMarker(_ raw: [UInt8]) -> Bool {
        let marker = FM1Protocol.loaderMarker
        guard raw.count >= marker.count else { return false }
        for i in 0...(raw.count - marker.count) {
            if Array(raw[i..<(i + marker.count)]) == marker { return true }
        }
        return false
    }

    // MARK: - CoreMIDI plumbing

    private func ensureStarted() {
        guard !started else { return }
        started = true

        MIDIClientCreateWithBlock("com.nilsel.fm1flasher.installer" as CFString, &client, nil)
        MIDIOutputPortCreate(client, "com.nilsel.fm1flasher.installer.out" as CFString, &outputPort)
        MIDIInputPortCreateWithBlock(
            client, "com.nilsel.fm1flasher.installer.in" as CFString, &inputPort
        ) { [weak self] packetListPtr, _ in
            // Same pointer-lifetime rule as MIDIManager: extract plain bytes
            // synchronously here, only hand safe data across the actor hop.
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
            guard let self else { return }
            Task { await self.handle(packets: packets) }
        }
    }

    private func handle(packets: [[UInt8]]) async {
        for bytes in packets {
            for byte in bytes {
                if byte == 0xF0 {
                    sysexBuffer = [0xF0]
                } else if !sysexBuffer.isEmpty {
                    sysexBuffer.append(byte)
                    if byte == 0xF7 {
                        let message = sysexBuffer
                        sysexBuffer.removeAll()
                        await inbox.push(message)
                    }
                }
            }
        }
    }

    private func connect(source: MIDIEndpointRef) {
        disconnectCurrentSource()
        let status = MIDIPortConnectSource(inputPort, source, nil)
        if status == noErr {
            connectedSource = source
        }
    }

    private func disconnectCurrentSource() {
        if let connectedSource {
            MIDIPortDisconnectSource(inputPort, connectedSource)
        }
        connectedSource = nil
    }

    private func sendDirectStatus(_ bytes: [UInt8], to destination: MIDIEndpointRef) -> OSStatus {
        let bufferSize = max(1024, bytes.count + 64)
        let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { rawPtr.deallocate() }
        let packetListPtr = rawPtr.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let firstPacket = MIDIPacketListInit(packetListPtr)
        _ = MIDIPacketListAdd(packetListPtr, bufferSize, firstPacket, 0, bytes.count, bytes)
        return MIDISend(outputPort, destination, packetListPtr)
    }

    @discardableResult
    private func sendDirect(_ bytes: [UInt8], to destination: MIDIEndpointRef) -> Bool {
        sendDirectStatus(bytes, to: destination) == noErr
    }
}
