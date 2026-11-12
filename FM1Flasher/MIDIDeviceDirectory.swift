import CoreMIDI

/// Shared CoreMIDI device-matching helpers, used by both MIDIManager (the
/// single always-connected FM-1 for reads) and FirmwareInstaller (which
/// scans across possibly-several candidate ports during an install, since
/// the device's MIDI port vanishes and a new one appears across the
/// reboot into the update loader).
enum MIDIDeviceDirectory {
    /// See PLAN.md and isod89/sloop-fm1#131: USB MIDI device names across
    /// the FM-1 community firmware ecosystem are not uniform. This is the
    /// same fragment list the community's own tools already converged on.
    static let knownPortNameFragments = [
        "fm-1", "fm1", "felucca", "ota", "composite", "sinco", "usb-midi", "sloop", "clipper",
    ]

    static func isOffline(_ object: MIDIObjectRef) -> Bool {
        var value: Int32 = 0
        let status = MIDIObjectGetIntegerProperty(object, kMIDIPropertyOffline, &value)
        return status == noErr && value != 0
    }

    static func name(for object: MIDIObjectRef) -> String {
        var unmanagedName: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(object, kMIDIPropertyName, &unmanagedName)
        guard status == noErr, let cfName = unmanagedName?.takeRetainedValue() else {
            return "Unknown device"
        }
        return cfName as String
    }

    static func endpoints(for device: MIDIObjectRef) -> (source: MIDIEndpointRef?, destination: MIDIEndpointRef?) {
        let entityCount = MIDIDeviceGetNumberOfEntities(device)
        for e in 0..<entityCount {
            let entity = MIDIDeviceGetEntity(device, e)
            guard entity != 0 else { continue }
            let sourceCount = MIDIEntityGetNumberOfSources(entity)
            let destinationCount = MIDIEntityGetNumberOfDestinations(entity)
            let source: MIDIEndpointRef? = sourceCount > 0 ? MIDIEntityGetSource(entity, 0) : nil
            let destination: MIDIEndpointRef? = destinationCount > 0 ? MIDIEntityGetDestination(entity, 0) : nil
            if source != nil || destination != nil {
                return (source, destination)
            }
        }
        return (nil, nil)
    }

    /// Online devices whose name matches a known FM-1-family fragment —
    /// candidates worth sending a handshake to.
    static func candidateDevices() -> [MIDIObjectRef] {
        var found: [MIDIObjectRef] = []
        let count = MIDIGetNumberOfDevices()
        for index in 0..<count {
            let device = MIDIGetDevice(index)
            guard device != 0, !isOffline(device) else { continue }
            let deviceName = name(for: device)
            if knownPortNameFragments.contains(where: { deviceName.localizedCaseInsensitiveContains($0) }) {
                found.append(device)
            }
        }
        return found
    }
}
