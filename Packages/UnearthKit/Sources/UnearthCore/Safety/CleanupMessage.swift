import Foundation

/// What the result banner says once things have moved to the Trash.
public enum CleanupMessage {
    /// "Removed 12 duplicates"; one thing goes by its name. `titles` has one title for each thing that moved, and
    /// `kind` says what they're called.
    public static func removed(_ titles: [String], kind: CollectionKind? = nil) -> String {
        if titles.count == 1 { return "Removed “\(titles[0])”" }
        return "Removed " + (kind?.counted(titles.count) ?? "\(titles.count.formatted()) items")
    }

    /// Where it went, and what that does for the disk.
    public static func detail(bytes: Int64) -> String {
        guard bytes > 0 else { return "Moved to the Trash. This frees no space on this Mac." }
        return "\(ByteFormatting.string(bytes)) moved to the Trash. Empty the Trash to get the space back."
    }
}
