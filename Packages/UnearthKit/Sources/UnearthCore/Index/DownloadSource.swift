import Darwin
import Foundation

/// Where a downloaded file came from, read from the "where from" record macOS keeps on downloads.
public enum DownloadSource {
    /// A host matches a domain or any of its subdomains. More specific services come first.
    private static let sources: [(name: String, domains: [String])] = [
        ("ChatGPT", ["chatgpt.com", "chat.openai.com", "oaiusercontent.com"]),
        ("Claude", ["claude.ai"]),
        ("Gmail", ["mail.google.com"]),
        ("Google Drive", ["drive.google.com", "docs.google.com", "drive.usercontent.google.com"]),
        ("Slack", ["slack.com", "slack-edge.com", "files.slack.com"]),
        ("X", ["x.com", "twitter.com", "twimg.com"]),
        ("WhatsApp", ["whatsapp.com", "whatsapp.net"]),
        ("Telegram", ["t.me", "telegram.org"]),
        ("Discord", ["discord.com", "discordapp.com", "discordapp.net"]),
        ("Dropbox", ["dropbox.com", "dropboxusercontent.com"]),
        ("Notion", ["notion.so"]),
        ("Figma", ["figma.com"]),
        ("Canva", ["canva.com"]),
        ("Apple", ["apple.com"]),
        ("GitHub", ["github.com", "githubusercontent.com"]),
        ("Google", ["google.com"]),
    ]
    /// Second-level labels under a country code ("example.co.uk").
    private static let countrySecondLevels: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or", "go"]

    /// The services Unearth recognizes by name.
    public static var knownNames: [String] { sources.map(\.name) }

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
