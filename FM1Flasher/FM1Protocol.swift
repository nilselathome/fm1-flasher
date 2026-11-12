import Foundation

/// The FM-1's custom SysEx protocol, ported from the ChoralRootFM1 reference
/// implementation (tools/fm1_install.py). See PLAN.md "Protocol notes" for
/// the full write-up; this file only covers the read-only identity query,
/// the safe first step before anything that writes flash.
enum FM1Protocol {
    /// F0 00 32 45 00 00 00 40 7F F7 — ask the device who it is (plain query:
    /// name truncated to NAME_ + up to 3 digits, for M-UPGRADE compatibility).
    static let hsQuery: [UInt8] = [0xF0, 0x00, 0x32, 0x45, 0x00, 0x00, 0x00, 0x40, 0x7F, 0xF7]

    /// F0 00 32 45 08 00 00 40 00 7E 01 F7 — the handshake with the one-byte
    /// body 01: the identity untruncated (not every firmware answers this;
    /// stock/older builds fall back to the plain answer). See PLAN.md
    /// "Canonical flash layout and safety notes".
    static let hsFull: [UInt8] = [0xF0, 0x00, 0x32, 0x45, 0x08, 0x00, 0x00, 0x40, 0x00, 0x7E, 0x01, 0xF7]

    struct Identity: Equatable {
        let text: String
        let model: String?
        let version: Int?
        /// The flash chip's JEDEC ID, from bytes 24-26 of the identity field
        /// — only some firmware builds report this (newer felucca-bsp
        /// vendored copies); nil when those bytes are all zero.
        let flashJEDEC: UInt32?

        /// True when this identity is the Felucca update loader itself
        /// (model "ota-FM-1" etc.), not the regular application firmware —
        /// Identity.loader in fm1_install.py.
        var isLoader: Bool {
            model?.lowercased().hasPrefix("ota-") ?? false
        }
    }

    // MARK: - Write-flow protocol (UPGRADE / read-request-serve-response)

    /// F0 22 24 35 7F F7 — tells the device to start the update loader
    /// (Check phase from the app firmware, or the actual write once the
    /// loader itself answers). UPGRADE in fm1_install.py.
    static let upgrade: [UInt8] = [0xF0, 0x22, 0x24, 0x35, 0x7F, 0xF7]

    /// Sentinel read-request addresses the device sends when it's done
    /// reading: finishing the no-op Check pass (FINISH_CHECK) or finishing
    /// the real write (FINISH_WRITE). fm1_install.py's FINISH_CHECK/FINISH_WRITE.
    static let finishCheck: UInt32 = 0xE000_0000
    static let finishWrite: UInt32 = 0xF000_0000

    /// The device never asks for more than this many bytes in one read
    /// request — MAX_DATA in fm1_install.py.
    static let maxReadLength = 512

    /// .fwsc package layout: 20 fixed-size blocks, each holding one
    /// identity-string character hidden in its last byte. BLOCKS/BLK/KEEP
    /// in fm1_install.py.
    static let packageBlocks = 20
    static let packageBlockSize = 0x30
    static let packageBlockKeep = 0x2F

    /// Byte signature fm1_install.py's load_package() requires somewhere in
    /// a package before it'll offer to install it — the actual Felucca
    /// update-loader binary blob embeds this literal string.
    static let loaderMarker: [UInt8] = Array("FELUCCA-LOADER-1".utf8)

    struct ReadRequest: Equatable {
        let flags: UInt8
        let addr: UInt32
        let length: UInt32
    }

    /// Parses a complete F0...F7 SysEx message as a device read request
    /// (parse_request() in fm1_install.py): magic 00 59 30, 1 flags byte,
    /// a little-endian 4-byte address, a little-endian 3-byte length, and a
    /// one's-complement checksum over those 8 bytes.
    static func parseReadRequest(_ message: [UInt8]) -> ReadRequest? {
        guard message.count >= 2, message.first == 0xF0, message.last == 0xF7 else { return nil }
        let body = unpack7(Array(message[1..<(message.count - 1)]))
        guard body.count == 15, body[0] == 0x00, body[1] == 0x59, body[2] == 0x30 else { return nil }

        let checksum = body[6...13].reduce(UInt8(0)) { $0 &+ $1 }
        guard ~checksum == body[14] else { return nil }

        let flags = body[6]
        let addr = (0..<4).reduce(UInt32(0)) { acc, i in acc | (UInt32(body[7 + i]) << (8 * i)) }
        let length = (0..<3).reduce(UInt32(0)) { acc, i in acc | (UInt32(body[11 + i]) << (8 * i)) }
        return ReadRequest(flags: flags, addr: addr, length: length)
    }

    /// Builds the host's reply to a read request — response() in
    /// fm1_install.py: magic 00 59 30, a little-endian length-plus-8 field,
    /// a little-endian 4-byte address, a little-endian data-length field,
    /// the data itself, and a one's-complement checksum over everything
    /// from the flags byte onward.
    static func response(addr: UInt32, data: [UInt8], flags: UInt8 = 0) -> [UInt8] {
        let n = data.count
        var body: [UInt8] = [0x00, 0x59, 0x30, UInt8((n + 8) & 0xFF), UInt8(((n + 8) >> 8) & 0xFF), 0x00, flags]
        body += withUnsafeBytes(of: addr.littleEndian) { Array($0) }
        body += [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), 0x00]
        body += data

        let checksum = body[6...].reduce(UInt8(0)) { $0 &+ $1 }
        body.append(~checksum)
        return [0xF0] + pack7(body) + [0xF7]
    }

    /// Extracts the hidden identity string from a raw .fwsc package's first
    /// 20 blocks — product_of() in fm1_install.py. Each block's marker byte
    /// encodes one character as `(marker - blockIndex - 1) & 0xFF`, unless
    /// the marker is the "no character here" sentinel 0x7D.
    static func packageProductIdentity(_ raw: [UInt8]) -> String? {
        guard raw.count >= packageBlocks * packageBlockSize else { return nil }
        var chars: [UInt8] = []
        for i in 0..<packageBlocks {
            let marker = raw[i * packageBlockSize + packageBlockKeep]
            if marker == 0x7D { continue }
            chars.append(UInt8((Int(marker) - i - 1) & 0xFF))
        }
        guard !chars.isEmpty, let text = String(bytes: chars, encoding: .isoLatin1) else { return nil }
        return text
    }

    /// Strips the per-block marker byte from a raw .fwsc package's first 20
    /// blocks to recover the real device-bound image — logical_image() in
    /// fm1_install.py. This is what actually gets served to the device's
    /// read requests, byte-for-byte.
    static func packageLogicalImage(_ raw: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(raw.count)
        for i in 0..<packageBlocks {
            let start = i * packageBlockSize
            out += raw[start..<(start + packageBlockKeep)]
        }
        out += raw[(packageBlocks * packageBlockSize)...]
        return out
    }

    /// The model portion of an identity string, with any "ota-" loader
    /// prefix stripped — model_of() in fm1_install.py. Used to confirm a
    /// package is meant for the connected device's model regardless of
    /// whether the device is currently running its app firmware or its
    /// update loader.
    static func modelOf(_ text: String) -> String {
        let base = text.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        if base.lowercased().hasPrefix("ota-") {
            return String(base.dropFirst(4))
        }
        return base
    }

    /// 8-bit -> 7-bit MIDI SysEx packing (LSB-first), matching pack7() in fm1_install.py.
    static func pack7(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var acc: UInt32 = 0
        var nb = 0
        for b in data {
            acc |= UInt32(b) << nb
            nb += 8
            while nb >= 7 {
                out.append(UInt8(acc & 0x7F))
                acc >>= 7
                nb -= 7
            }
        }
        if nb > 0 {
            out.append(UInt8(acc & 0x7F))
        }
        return out
    }

    /// The inverse of pack7, matching unpack7() in fm1_install.py.
    static func unpack7(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var acc: UInt32 = 0
        var nb = 0
        for b in data {
            acc |= UInt32(b & 0x7F) << nb
            nb += 7
            while nb >= 8 {
                out.append(UInt8(acc & 0xFF))
                acc >>= 8
                nb -= 8
            }
        }
        return out
    }

    /// Parses a complete F0...F7 SysEx message as an identity reply
    /// (parse_identity() in fm1_install.py): magic 00 59 11, then a
    /// null-terminated "MODEL_VERSION" string, e.g. "FM-1_906".
    static func parseIdentity(_ message: [UInt8]) -> Identity? {
        guard message.count >= 2, message.first == 0xF0, message.last == 0xF7 else { return nil }
        let body = unpack7(Array(message[1..<(message.count - 1)]))
        guard body.count == 34, body[0] == 0x00, body[1] == 0x59, body[2] == 0x11 else { return nil }

        let textBytes = Array(body[6..<33])
        let nullIndex = textBytes.firstIndex(of: 0) ?? textBytes.count
        guard let text = String(bytes: textBytes[0..<nullIndex], encoding: .isoLatin1), !text.isEmpty else {
            return nil
        }

        let jedecBytes = body[30..<33]
        let jedec = jedecBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let flashJEDEC: UInt32? = jedec != 0 ? jedec : nil

        guard let underscore = text.lastIndex(of: "_") else {
            return Identity(text: text, model: nil, version: nil, flashJEDEC: flashJEDEC)
        }
        let model = String(text[text.startIndex..<underscore])
        let versionText = String(text[text.index(after: underscore)...])
        return Identity(text: text, model: model, version: Int(versionText), flashJEDEC: flashJEDEC)
    }
}
