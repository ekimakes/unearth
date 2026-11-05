import Darwin
import Foundation

/// Where a downloaded file came from, read from the "where from" record macOS keeps on downloads.
public enum DownloadSource {
    /// A host matches a domain or any of its subdomains. More specific services come first. Each name has a logo in
    /// the app's asset catalog, named by `logo(for:)`.
    private static let sources: [(name: String, domains: [String])] = [
        ("ChatGPT", ["chatgpt.com", "chat.openai.com", "oaiusercontent.com", "openai.com"]),
        ("Claude", ["claude.ai"]),
        ("Gemini", ["gemini.google.com", "aistudio.google.com"]),
        ("Copilot", ["copilot.microsoft.com"]),
        ("Perplexity", ["perplexity.ai"]),
        ("Grok", ["grok.com", "x.ai"]),
        ("DeepSeek", ["deepseek.com"]),
        ("Midjourney", ["midjourney.com"]),
        ("Gmail", ["mail.google.com"]),
        ("Outlook", ["outlook.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com"]),
        ("Slack", ["slack.com", "slack-edge.com", "files.slack.com"]),
        ("WhatsApp", ["whatsapp.com", "whatsapp.net"]),
        ("Telegram", ["t.me", "telegram.org", "telegram.me"]),
        ("Messenger", ["messenger.com"]),
        ("Signal", ["signal.org"]),
        ("Discord", ["discord.com", "discordapp.com", "discordapp.net"]),
        ("Microsoft Teams", ["teams.microsoft.com", "teams.live.com"]),
        ("Zoom", ["zoom.us", "zoom.com"]),
        ("X", ["x.com", "twitter.com", "twimg.com"]),
        ("Instagram", ["instagram.com", "cdninstagram.com"]),
        ("Threads", ["threads.net", "threads.com"]),
        ("Facebook", ["facebook.com", "fbcdn.net", "fb.com"]),
        ("TikTok", ["tiktok.com", "tiktokcdn.com", "tiktokcdn-us.com", "tiktokv.com"]),
        ("YouTube", ["youtube.com", "youtu.be", "ytimg.com", "googlevideo.com"]),
        ("Reddit", ["reddit.com", "redd.it", "redditmedia.com", "redditstatic.com"]),
        ("LinkedIn", ["linkedin.com", "licdn.com"]),
        ("Pinterest", ["pinterest.com", "pinimg.com"]),
        ("Snapchat", ["snapchat.com"]),
        ("Bluesky", ["bsky.app", "bsky.social"]),
        ("Twitch", ["twitch.tv"]),
        ("Google Drive", ["drive.google.com", "docs.google.com", "drive.usercontent.google.com"]),
        ("Dropbox", ["dropbox.com", "dropboxusercontent.com"]),
        ("OneDrive", ["onedrive.live.com", "1drv.ms", "sharepoint.com"]),
        ("iCloud", ["icloud.com", "icloud-content.com"]),
        ("WeTransfer", ["wetransfer.com"]),
        ("Box", ["box.com", "boxcloud.com"]),
        ("MEGA", ["mega.nz", "mega.io"]),
        ("Notion", ["notion.so", "notion.com"]),
        ("Figma", ["figma.com"]),
        ("Canva", ["canva.com"]),
        ("Adobe", ["adobe.com"]),
        ("Behance", ["behance.net"]),
        ("Dribbble", ["dribbble.com"]),
        ("Trello", ["trello.com"]),
        ("Unsplash", ["unsplash.com"]),
        ("Pexels", ["pexels.com"]),
        ("Freepik", ["freepik.com"]),
        ("Pixabay", ["pixabay.com"]),
        ("Imgur", ["imgur.com"]),
        ("Spotify", ["spotify.com", "scdn.co"]),
        ("Vimeo", ["vimeo.com", "vimeocdn.com"]),
        ("Wikipedia", ["wikipedia.org", "wikimedia.org"]),
        ("GitHub", ["github.com", "githubusercontent.com"]),
        ("GitLab", ["gitlab.com"]),
        ("Apple", ["apple.com"]),
        ("Microsoft", ["microsoft.com"]),
        ("Google", ["google.com"]),
    ]
    /// Second-level labels under a country code ("example.co.uk").
    private static let countrySecondLevels: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or", "go"]

    /// The services Unearth recognizes by name.
    public static var knownNames: [String] { sources.map(\.name) }

    private static let logos: [String: String] = Dictionary(uniqueKeysWithValues: sources.map { source in
        (source.name, source.name.lowercased().filter { $0.isLetter || $0.isNumber })
    })

    /// The name of a service's logo; a website Unearth doesn't recognize has none.
    public static func logo(for name: String) -> String? { logos[name] }

    /// Before a service was recognized, its files were stored under its domain.
    static var namedDomains: [(domain: String, name: String)] {
        sources.flatMap { source in
            source.domains.filter { registrableDomain($0) == $0 }.map { ($0, source.name) }
        }
    }

    public static func whereFroms(atPath path: String) -> [String] {
        (metadata("kMDItemWhereFroms", atPath: path) as? [Any])?.compactMap { $0 as? String } ?? []
    }

    public static func isScreenCapture(atPath path: String) -> Bool {
        metadata("kMDItemIsScreenCapture", atPath: path) as? Bool ?? false
    }

    /// macOS records the file's own address and the page it came from. A known service among them wins
    /// (a Gmail attachment's address is a Google content server); otherwise the first site's domain.
    public static func name(for urls: [String]) -> String? {
        let hosts = urls.compactMap(host)
        for host in hosts {
            if let source = sources.first(where: { $0.domains.contains { host == $0 || host.hasSuffix("." + $0) } }) {
                return source.name
            }
        }
        return hosts.first.map(registrableDomain)
    }

    private static func host(_ url: String) -> String? {
        let address = url.hasPrefix("blob:") ? String(url.dropFirst(5)) : url
        guard let host = URL(string: address)?.host(), !host.isEmpty else { return nil }
        return host.lowercased()
    }

    private static func registrableDomain(_ host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2, !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        let keep = labels.last!.count == 2 && countrySecondLevels.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// Spotlight metadata macOS stores on the file itself, as a binary property list.
    private static func metadata(_ name: String, atPath path: String) -> Any? {
        let attribute = "com.apple.metadata:" + name
        let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size < 1 << 20 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }
}
