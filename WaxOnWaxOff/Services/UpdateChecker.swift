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
            var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .error("Could not reach GitHub. Check your internet connection.")
            }

            let release = try JSONDecoder().decode(Release.self, from: data)

            let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            let releaseURL = URL(string: release.htmlUrl)
                ?? URL(string: "https://github.com/sevmorris/WaxOnWaxOff/releases")!
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

@MainActor
func checkForUpdates() async {
    let result = await UpdateChecker().check()

    let alert = NSAlert()

    switch result {
    case .upToDate(let version):
        alert.messageText = "You're up to date"
        alert.informativeText = "WaxOn/WaxOff \(version) is the latest version."
        alert.addButton(withTitle: "OK")
        alert.runModal()

    case .available(let version, let downloadURL, let releaseURL):
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
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
