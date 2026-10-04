import AppKit

actor UpdateChecker {

    enum Result {
        case upToDate(version: String)
        case available(version: String, downloadURL: URL, releaseURL: URL)
        /// Newer than this build, but it needs a newer macOS than this Mac has.
        case needsNewerMacOS(version: String, minimum: String, installed: String)
        case error(String)
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlUrl: String
        let assets: [Asset]
        /// The release notes, which carry the minimum-macos marker.
        let body: String?

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadUrl = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case assets
            case body
        }
    }

    /// The GitHub error envelope (`{"message": "...", ...}`) returned on non-200 responses.
    private struct APIError: Decodable {
        let message: String?
    }

    /// Maps a non-200 GitHub API response to an error. GitHub answers 403 (not 200)
    /// when the unauthenticated hourly quota is exhausted, so a 403/429 whose body
    /// carries a rate-limit message is surfaced as a rate-limit error rather than a
    /// connectivity failure. Pure and `nonisolated` so it can be unit-tested in isolation.
    nonisolated static func responseError(statusCode: Int, body: Data) -> UpdateFetchError {
        if (statusCode == 403 || statusCode == 429), isRateLimitBody(body) {
            return .rateLimited
        }
        return .badResponse
    }

    /// True when the response body is a GitHub error whose message mentions a rate
    /// limit (covers both the primary hourly quota and secondary/abuse rate limits).
    nonisolated static func isRateLimitBody(_ body: Data) -> Bool {
        guard let decoded = try? JSONDecoder().decode(APIError.self, from: body),
              let message = decoded.message else { return false }
        return message.range(of: "rate limit", options: .caseInsensitive) != nil
    }

    /// App release tags only (`v1.2.3`). Ignores `ffmpeg-deps-*` and other asset releases.
    private static func isAppReleaseTag(_ tag: String) -> Bool {
        guard tag.first == "v" else { return false }
        let version = tag.dropFirst()
        guard version.contains(".") else { return false }
        return version.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// The macOS a release says it needs. release.sh ends every release's notes
    /// with `<!-- minimum-macos: 15.0 -->`, read from the built app's
    /// LSMinimumSystemVersion; GitHub does not render the comment. nil when there
    /// is no marker: a release from before it existed, which runs on every macOS
    /// this build does.
    nonisolated static func minimumMacOS(inReleaseNotes notes: String?) -> OperatingSystemVersion? {
        guard let notes,
              let start = notes.range(of: "<!-- minimum-macos:"),
              let end = notes[start.upperBound...].range(of: "-->") else { return nil }
        return macOSVersion(String(notes[start.upperBound..<end.lowerBound]))
    }

    /// "15", "15.0" or "15.2.1" as a version; nil for anything else.
    nonisolated static func macOSVersion(_ string: String) -> OperatingSystemVersion? {
        let fields = string.trimmingCharacters(in: .whitespaces)
            .split(separator: ".", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { Int($0) }
        guard (1...3).contains(fields.count), numbers.count == fields.count else { return nil }
        return OperatingSystemVersion(majorVersion: numbers[0],
                                      minorVersion: numbers.count > 1 ? numbers[1] : 0,
                                      patchVersion: numbers.count > 2 ? numbers[2] : 0)
    }

    /// True when a Mac running `os` meets `minimum`.
    nonisolated static func runs(on os: OperatingSystemVersion, given minimum: OperatingSystemVersion) -> Bool {
        (os.majorVersion, os.minorVersion, os.patchVersion)
            >= (minimum.majorVersion, minimum.minorVersion, minimum.patchVersion)
    }

    /// "15.0", or "15.2.1" when there is a patch number.
    nonisolated static func describe(_ version: OperatingSystemVersion) -> String {
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion > 0 ? "\(base).\(version.patchVersion)" : base
    }

    func check() async -> Result {
        do {
            guard let release = try await fetchLatestAppRelease() else {
                return .error("No app release found on GitHub.")
            }

            let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            guard let releaseURL = URL(string: release.htmlUrl)
                    ?? URL(string: "https://github.com/sevmorris/WaxOnWaxOff/releases") else {
                return .error("Invalid release URL in GitHub response.")
            }
            let downloadURL = release.assets.first(where: { $0.name.hasSuffix(".dmg") })
                .flatMap { URL(string: $0.browserDownloadUrl) }
                ?? releaseURL

            if latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending {
                // A release this Mac cannot run is not an update for it: its DMG
                // would replace a working app with one that will not open.
                if let minimum = Self.minimumMacOS(inReleaseNotes: release.body),
                   !Self.runs(on: ProcessInfo.processInfo.operatingSystemVersion, given: minimum) {
                    return .needsNewerMacOS(version: latestVersion, minimum: Self.describe(minimum),
                                            installed: currentVersion)
                }
                return .available(version: latestVersion, downloadURL: downloadURL, releaseURL: releaseURL)
            } else {
                return .upToDate(version: currentVersion)
            }

        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func githubRequest(path: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: "https://api.github.com\(path)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            throw Self.responseError(statusCode: http.statusCode, body: data)
        }
        return (data, http)
    }

    private func fetchLatestAppRelease() async throws -> Release? {
        let (latestData, _) = try await githubRequest(
            path: "/repos/sevmorris/WaxOnWaxOff/releases/latest"
        )
        let latest = try JSONDecoder().decode(Release.self, from: latestData)
        if Self.isAppReleaseTag(latest.tagName) {
            return latest
        }

        // `/releases/latest` can point at non-app releases (e.g. ffmpeg-deps-*).
        let (listData, _) = try await githubRequest(
            path: "/repos/sevmorris/WaxOnWaxOff/releases?per_page=30"
        )
        let releases = try JSONDecoder().decode([Release].self, from: listData)
        return releases.first { Self.isAppReleaseTag($0.tagName) }
    }
}

enum UpdateFetchError: LocalizedError {
    case badResponse
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "Could not reach GitHub. Check your internet connection."
        case .rateLimited:
            return "WaxOn/WaxOff reached the GitHub API rate limit. Try again later."
        }
    }
}

/// Show an update dialog. When `silent` is true (launch check), only prompt if
/// an update is actually available — don't bother the user with "you're up to date".
///
@MainActor
func checkForUpdates(silent: Bool = false) async {
    let result = await UpdateChecker().check()

    switch result {
    case .upToDate(let version):
        guard !silent else { return }
        let alert = NSAlert()
        alert.messageText = "You have the latest version"
        alert.informativeText = "WaxOn/WaxOff \(version) is installed."
        alert.addButton(withTitle: "OK")
        alert.runModal()

    case .available(let version, let downloadURL, let releaseURL):
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "WaxOn/WaxOff \(version) is available."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(downloadURL)
        } else if response == .alertSecondButtonReturn {
            NSWorkspace.shared.open(releaseURL)
        }

    case .needsNewerMacOS(let version, let minimum, let installed):
        // Nothing this Mac can install, so the check at launch says nothing.
        guard !silent else { return }
        let alert = NSAlert()
        alert.messageText = "WaxOn/WaxOff \(version) needs macOS \(minimum)"
        alert.informativeText = "This Mac has macOS \(UpdateChecker.describe(ProcessInfo.processInfo.operatingSystemVersion)), "
            + "so WaxOn/WaxOff \(installed) is the newest version it can run."
        alert.addButton(withTitle: "OK")
        alert.runModal()

    case .error(let message):
        guard !silent else { return }
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
