import CoreServices
import Foundation

enum SpotlightLastUsed {
    /// When the file was last opened, as Spotlight recorded it. Nil when Spotlight doesn't know.
    static func date(forPath path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
