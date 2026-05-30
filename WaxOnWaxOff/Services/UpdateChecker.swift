import AppKit

actor UpdateChecker {

    enum Result {
        case upToDate(version: String)
        case available(version: String, downloadURL: URL, releaseURL: URL)
        case error(String)
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlUrl: String
        let assets: [Asset]

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
        }
    }

    func check() async -> Result {
        guard let apiURL = URL(string: "https://api.github.com/repos/sevmorris/WaxOnWaxOff/releases/latest") else {
            return .error("Invalid update URL.")
        }

        do {
            // 15 s caps both connect and resource time so a silent launch-time
            // check doesn't hold a URLSession open for the default 60 s when
            // GitHub is slow or the user is offline.
            var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .error("Could not reach GitHub. Check your internet connection.")
            }

            let release = try JSONDecoder().decode(Release.self, from: data)

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
                return .available(version: latestVersion, downloadURL: downloadURL, releaseURL: releaseURL)
            } else {
                return .upToDate(version: currentVersion)
            }

        } catch {
            return .error(error.localizedDescription)
        }
    }
}

/// Show an update dialog. When `silent` is true (launch check), only prompt if
/// an update is actually available — don't bother the user with "you're up to date".
///
/// Silent (launch) checks are throttled to once per 24 h via UserDefaults so a
/// frequently-relaunched app doesn't hit GitHub's rate-limited API on every
/// open. Explicit "Check for Updates…" menu invocations bypass the throttle.
@MainActor
func checkForUpdates(silent: Bool = false) async {
    let throttleKey = "UpdateChecker.lastSuccessfulCheckAt"
    let throttleInterval: TimeInterval = 24 * 60 * 60
    if silent {
        let last = UserDefaults.standard.double(forKey: throttleKey)
        if last > 0, Date().timeIntervalSince1970 - last < throttleInterval {
            return
        }
    }

    let result = await UpdateChecker().check()

    // Only record success — failed checks shouldn't suppress the next attempt.
    switch result {
    case .upToDate, .available:
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: throttleKey)
    case .error:
        break
    }

    switch result {
    case .upToDate(let version):
        guard !silent else { return }
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "WaxOn/WaxOff \(version) is the latest version."
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

    case .error(let message):
        guard !silent else { return }
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
