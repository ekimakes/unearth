import Testing
@testable import UnearthCore

/// Cache folders are named after a bundle id, an app, or the app's maker, in whatever case the app chose.
struct AppOwnershipTests {
    @Test func matchesBundleIDsAndNamesIgnoringCase() {
        #expect(AppOwnership.owner("com.foo.Bar", matchesBundleID: "com.foo.bar", name: nil))
        #expect(AppOwnership.owner("discord", matchesBundleID: "com.hnc.Discord", name: "Discord"))
        #expect(AppOwnership.owner("Obsidian", matchesBundleID: "md.obsidian", name: nil))
        #expect(AppOwnership.owner("Code", matchesBundleID: "com.microsoft.VSCode", name: "Code"))
    }

    @Test func matchesTheMakersFolder() {
        #expect(AppOwnership.owner("JetBrains", matchesBundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA"))
        #expect(AppOwnership.owner("Adobe", matchesBundleID: "com.adobe.Photoshop", name: "Adobe Photoshop 2026"))
    }

    @Test func matchesHelpersOfTheApp() {
        #expect(AppOwnership.owner("com.alpha", matchesBundleID: "com.alpha.helper", name: "Alpha Helper"))
    }

    @Test func leavesUnrelatedAppsAlone() {
        #expect(!AppOwnership.owner("pip", matchesBundleID: "com.apple.Safari", name: "Safari"))
        #expect(!AppOwnership.owner("com", matchesBundleID: "com.apple.Safari", name: "Safari"))
        #expect(!AppOwnership.owner("com.alpha", matchesBundleID: "com.alphabet.maps", name: "Maps"))
        #expect(!AppOwnership.owner("Google", matchesBundleID: nil, name: "Googlebot Viewer"))
    }
}
