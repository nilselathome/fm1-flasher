import CryptoKit
import Foundation

/// A firmware listed on thefirmwarehub.com's own public `catalog.json` —
/// not bundled with the app, downloaded on demand when the user picks it
/// from the online browser.
struct RemoteFirmware: Identifiable, Equatable, Hashable {
    let id: String
    let displayName: String
    let author: String
    let version: String
    let repo: String
    let whatText: String
    let stars: Int
    let installs: Int
    /// ISO 8601 — sortable lexically, no need to parse into `Date`.
    let publishedAt: String?
    let hubPackagePath: String
    let sha256: String
    let size: Int
    let releaseTag: String?

    var repoURL: URL? { URL(string: "https://github.com/\(repo)") }

    /// The site's own per-firmware icon, used throughout its UI — unlike
    /// `catalog.json`'s `card` field (an auto-generated screenshot that's
    /// absent for most entries), this exists for virtually every id and
    /// 404s cleanly when it truly doesn't.
    var thumbnailURL: URL? {
        URL(string: "https://thefirmwarehub.com/img/w160/\(id).webp")
    }
}

extension RemoteFirmware: InstallableFirmware {
    func loadBytes() async throws -> [UInt8] {
        try await FirmwareHubClient.shared.downloadAndVerify(self)
    }
}

enum FirmwareHubError: LocalizedError {
    case badResponse(Int)
    case missingAsset
    case checksumMismatch(expected: String, got: String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code):
            return "The Firmware Hub returned an error (HTTP \(code))"
        case .missingAsset:
            return "Couldn't find a .fwsc file in that release"
        case .checksumMismatch(let expected, let got):
            return "Downloaded firmware failed checksum verification (expected \(expected), got \(got))"
        }
    }
}

/// Fetches and caches thefirmwarehub.com's `catalog.json` — a CC-BY-4.0
/// licensed listing of every firmware the hub has verified (identity,
/// SHA-256, release, preview image). Its own published rules
/// (thefirmwarehub.com/kb/#catalog) ask tools to read this file at most
/// once a day with an identifying User-Agent, so refresh is throttled
/// client-side rather than left to the user to accidentally hammer it.
@MainActor
final class FirmwareHubCatalog: ObservableObject {
    static let shared = FirmwareHubCatalog()

    @Published private(set) var firmwares: [RemoteFirmware] = []
    @Published private(set) var lastFetched: Date?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let minimumRefreshInterval: TimeInterval = 24 * 60 * 60
    private let lastFetchedKey = "FirmwareHubCatalog.lastFetched"
    private let cacheURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheURL = dir.appendingPathComponent("firmware_hub_catalog.json")
        if let saved = UserDefaults.standard.object(forKey: lastFetchedKey) as? Date {
            lastFetched = saved
        }
        loadFromDiskCache()
    }

    var canRefreshNow: Bool {
        guard let lastFetched else { return true }
        return Date().timeIntervalSince(lastFetched) >= minimumRefreshInterval
    }

    /// Fetches only if there's nothing cached yet, or the daily window has
    /// elapsed — safe to call every time the browser sheet opens.
    func refreshIfNeeded() async {
        guard firmwares.isEmpty || canRefreshNow else { return }
        await refresh()
    }

    func refresh() async {
        guard firmwares.isEmpty || canRefreshNow else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var request = URLRequest(url: URL(string: "https://thefirmwarehub.com/catalog.json")!)
            request.setValue(FirmwareHubClient.userAgent, forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw FirmwareHubError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            firmwares = try Self.parse(data)
            try? data.write(to: cacheURL, options: .atomic)
            lastFetched = Date()
            UserDefaults.standard.set(lastFetched, forKey: lastFetchedKey)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadFromDiskCache() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        firmwares = (try? Self.parse(data)) ?? []
    }

    private struct CatalogResponse: Decodable {
        let firmwares: [Entry]
        struct Entry: Decodable {
            let id: String
            let name: String
            let author: String
            let repo: String
            let what: String?
            let version: String
            let pkg: String
            let sha256: String
            let size: Int
            let stars: Int?
            let installs: Int?
            let published: String?
            let tag: String?
        }
    }

    private static func parse(_ data: Data) throws -> [RemoteFirmware] {
        let decoded = try JSONDecoder().decode(CatalogResponse.self, from: data)
        return decoded.firmwares.map { entry in
            RemoteFirmware(
                id: entry.id,
                displayName: entry.name,
                author: entry.author,
                version: entry.version,
                repo: entry.repo,
                whatText: entry.what ?? "",
                stars: entry.stars ?? 0,
                installs: entry.installs ?? 0,
                publishedAt: entry.published,
                hubPackagePath: entry.pkg,
                sha256: entry.sha256,
                size: entry.size,
                releaseTag: entry.tag
            )
        }
    }
}

/// Downloads and verifies a `RemoteFirmware`'s actual `.fwsc` bytes, then
/// caches them to disk so re-installing the same version doesn't refetch.
///
/// Per thefirmwarehub.com/kb/#catalog, a tool built on `catalog.json`
/// should download packages "from the makers' releases, not from the
/// hub" — so this prefers the project's own GitHub release asset
/// (resolved via the `tag` catalog.json gives us), and only falls back to
/// the hub's own mirror for the firmwares it builds itself, which have no
/// release tag at all (e.g. Jiant FM, HYP-1).
actor FirmwareHubClient {
    static let shared = FirmwareHubClient()
    static let userAgent = "FM1Flasher-iOS/1.0 (+personal FM-1 firmware flasher app)"

    func downloadAndVerify(_ firmware: RemoteFirmware) async throws -> [UInt8] {
        let dir = try cacheDirectory()
        let cachedFile = dir.appendingPathComponent("\(firmware.id)-\(firmware.version).fwsc")

        if let cached = try? Data(contentsOf: cachedFile), sha256Hex(cached) == firmware.sha256 {
            return Array(cached)
        }

        let data = try await fetchPackageBytes(firmware)
        let digest = sha256Hex(data)
        guard digest == firmware.sha256 else {
            throw FirmwareHubError.checksumMismatch(expected: firmware.sha256, got: digest)
        }
        try? data.write(to: cachedFile, options: .atomic)
        return Array(data)
    }

    private func fetchPackageBytes(_ firmware: RemoteFirmware) async throws -> Data {
        if let tag = firmware.releaseTag,
           let fromRelease = try? await downloadFromGitHubRelease(repo: firmware.repo, tag: tag) {
            return fromRelease
        }
        let hubURL = URL(string: "https://thefirmwarehub.com/\(firmware.hubPackagePath)")!
        return try await download(hubURL)
    }

    private func downloadFromGitHubRelease(repo: String, tag: String) async throws -> Data {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        struct Release: Decodable { let assets: [Asset] }

        let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/tags/\(tag)")!
        var request = URLRequest(url: apiURL)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FirmwareHubError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".fwsc") }),
              let url = URL(string: asset.browserDownloadURL) else {
            throw FirmwareHubError.missingAsset
        }
        return try await download(url)
    }

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FirmwareHubError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    private func cacheDirectory() throws -> URL {
        let dir = try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("DownloadedFirmware", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
