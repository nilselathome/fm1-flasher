import CryptoKit
import Foundation

/// Anything FirmwareInstaller can flash: a name/version to show, and bytes
/// to load. A synchronous throwing function satisfies this async
/// requirement fine — BundledFirmware's load is sync (bundle read),
/// RemoteFirmware's isn't (network).
protocol InstallableFirmware {
    var displayName: String { get }
    var version: String { get }
    func loadBytes() async throws -> [UInt8]
}

struct BundledFirmware: Identifiable, Equatable, Hashable {
    let id: String
    let displayName: String
    let version: String
    let resourceName: String
    /// Pinned at the time this file was added, verified against each
    /// release's own SHA256SUMS — a defense against the bundled resource
    /// silently changing (build pipeline issue, bad copy), not just trust
    /// in the file being present.
    let sha256: String
}

enum FirmwareLoadError: LocalizedError {
    case missingResource(String)
    case checksumMismatch(expected: String, got: String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            return "Bundled firmware \"\(name)\" is missing from the app"
        case .checksumMismatch(let expected, let got):
            return "Bundled firmware failed checksum verification (expected \(expected), got \(got))"
        }
    }
}

enum FirmwareCatalog {
    static let all: [BundledFirmware] = [
        BundledFirmware(
            id: "x0x-1.2.2",
            displayName: "X0X",
            version: "1.2.2",
            resourceName: "x0x-1.2.2",
            sha256: "bbe601bc260e54f7109e54821e200f17a11ddba8fcce0bb2b612d72eaf448dd3"
        ),
        BundledFirmware(
            id: "coralflower-0.7.1",
            displayName: "CoralFlower",
            version: "0.7.1",
            resourceName: "coralflower-0.7.1",
            sha256: "d87d6327e0f98000cfa740bab70487728de85d3d64fd96c3a65dfd6bbdf71bbd"
        ),
        BundledFirmware(
            id: "sloop-2.8.5",
            displayName: "Sloop",
            version: "2.8.5",
            resourceName: "sloop-2.8.5",
            sha256: "b0446effb840740a3aa5c386ce004e79334e4f833d48d82a9eb5edbfde92ae67"
        ),
        BundledFirmware(
            id: "jiant-V10.7.17",
            displayName: "Jiant FM",
            version: "V10.7.17",
            resourceName: "jiant-V10.7.17",
            sha256: "1f097f9d2543d2e1bafa566cb6e7d405a87fb857336d519c5a90adde58a0e777"
        ),
        BundledFirmware(
            id: "skiff-2.5.1",
            displayName: "Skiff",
            version: "2.5.1",
            resourceName: "skiff-2.5.1",
            sha256: "4b7f99b3ff972a4115e5d63e5c5b3beea9f7ca14ac700c604db8a99a12b61dc6"
        ),
        BundledFirmware(
            id: "obervave-3.3.2",
            displayName: "OberVave",
            version: "3.3.2",
            resourceName: "obervave-3.3.2",
            sha256: "ba54723e1ec0d40d3552fb463a384d3b9a33290e57fdf8a615f7f22fa34644a2"
        ),
        BundledFirmware(
            id: "zen-1.2",
            displayName: "Zen-1",
            version: "1.2",
            resourceName: "zen-1.2",
            sha256: "e3c51c045b1a763b6d16d2a7e783289ee874b25790e9010c0a5a084ddb65a125"
        ),
        BundledFirmware(
            id: "dub-1.4.3",
            displayName: "Dub-1",
            version: "1.4.3",
            resourceName: "dub-1.4.3",
            sha256: "19cc9649583192d0634467e18e28532078d4d7889231c9e842da7fb4ff869c0a"
        ),
        BundledFirmware(
            id: "hyp1-1.5.62",
            displayName: "Hyp-1",
            version: "1.5.62",
            resourceName: "hyp1-1.5.62",
            sha256: "7b858f2acb7c9913fbc2118f769db1ee8b548c6570186c376c266b915c27c777"
        ),
        BundledFirmware(
            id: "niagara-0.2.1",
            displayName: "Niagra Drift",
            version: "0.2.1",
            resourceName: "niagara-0.2.1",
            sha256: "11b2fce37efdd33d981bedacd84b4dbd15af3060137cfabe04ebd2eeadd492f4"
        ),
        BundledFirmware(
            id: "fomni-0.4.1",
            displayName: "FoMni",
            version: "0.4.1",
            resourceName: "fomni-0.4.1",
            sha256: "f937b807da1cfe13d43bef86c2469fa45d6a88b2b3a7f4b6f5b9741bdb0351ab"
        ),
        BundledFirmware(
            id: "fimba-0.7.0",
            displayName: "FiMba-1",
            version: "0.7.0",
            resourceName: "fimba-0.7.0",
            sha256: "c77036f22fb85a0922310cd50f40c00edbef504cbceffc7506468843dbe4dc34"
        ),
        BundledFirmware(
            id: "fumi-1.1.0",
            displayName: "FuMi-1",
            version: "1.1.0",
            resourceName: "fumi-1.1.0",
            sha256: "211db1c2efc379b0a29a284aea523c67e230d98dab7a7f91336cc3fbd1201188"
        ),
        BundledFirmware(
            id: "tuna-1.2-6f9a6dd",
            displayName: "Tuna",
            version: "1.2-6f9a6dd",
            resourceName: "tuna-1.2-6f9a6dd",
            sha256: "1e3fdda10a00d50bb1df6dc181be7f0a9872f6caf3fa8aa75c4b85d0f3ac066d"
        ),
        BundledFirmware(
            id: "x0xrmx-1.1.0",
            displayName: "X0X-RMX",
            version: "1.1.0",
            resourceName: "x0xrmx-1.1.0",
            sha256: "b343c135779c1de933d655236b14628103816036e170d65faed706aba620dcaa"
        ),
        BundledFirmware(
            id: "nmsfm-0.9",
            displayName: "No Man Sky FM",
            version: "0.9",
            resourceName: "nmsfm-0.9",
            sha256: "3633c4ff4955ab107df2bec30919017ab40c02469d8e922f64f8b9963db623f0"
        ),
        BundledFirmware(
            id: "guitchordi-0.1.0-beta.1",
            displayName: "GuitChordi",
            version: "0.1.0-beta.1",
            resourceName: "guitchordi-0.1.0-beta.1",
            sha256: "330396f043093bcdda65aacbd0098dd1fc1f253a17d5707db19ff5d971e05217"
        ),
        BundledFirmware(
            id: "bytemania-1.3.1",
            displayName: "Bytemania",
            version: "1.3.1",
            resourceName: "bytemania-1.3.1",
            sha256: "ba94dcb0fb9902fa29a8fa22b0818a7e80dc6ed334bfe9bb86d7c1242ca43925"
        ),
        BundledFirmware(
            id: "xmod-1.2.0",
            displayName: "XMOD",
            version: "1.2.0",
            resourceName: "xmod-1.2.0",
            sha256: "e985c66c5e19cabc6ee6b102c3aba7fe5f663a312a4cceb5cb735ee5f5519697"
        ),
        BundledFirmware(
            id: "satie1-0.1.3-beta",
            displayName: "Satie-1",
            version: "0.1.3-beta",
            resourceName: "satie1-0.1.3-beta",
            sha256: "1714f65080b5f3adef44afa84b3287b2a06f2e3299d8f709b0d5fff0f6cc1d46"
        ),
    ]

    static func load(_ firmware: BundledFirmware) throws -> [UInt8] {
        guard let url = Bundle.main.url(forResource: firmware.resourceName, withExtension: "fwsc") else {
            throw FirmwareLoadError.missingResource(firmware.resourceName)
        }
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == firmware.sha256 else {
            throw FirmwareLoadError.checksumMismatch(expected: firmware.sha256, got: digest)
        }
        return Array(data)
    }
}

extension BundledFirmware: InstallableFirmware {
    func loadBytes() throws -> [UInt8] {
        try FirmwareCatalog.load(self)
    }
}
