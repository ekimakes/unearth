import Foundation

/// Formats byte counts the way Finder does: decimal units in the user's locale ("54.19 GB").
public enum ByteFormatting {
    public static func string(_ bytes: Int64, locale: Locale = .current) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }
}
