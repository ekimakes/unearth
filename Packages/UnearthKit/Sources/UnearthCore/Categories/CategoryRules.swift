import Foundation

/// Where each part of the Data volume belongs. A folder takes the rule that matches it exactly
/// (the last such rule in this list wins), otherwise it inherits its parent's category.
public enum CategoryRules {
    public static func standard(homePath home: String) -> [CategoryRule] {
        var rules: [CategoryRule] = []
        func add(_ patterns: [String], _ category: StorageCategory, _ bucket: SystemDataBucket? = nil) {
            rules += patterns.map { CategoryRule(pattern: PathPattern($0, homePath: home), category: category, bucket: bucket) }
        }

        add(["/"], .systemData, .otherSystem)
        add(["/Applications", "~/Applications"], .apps)
        add(["/Users"], .other)
        add(["/Users/Shared", "~"], .documents)
        add(["~/Library", "~/.*"], .systemData, .appData)
        add(["~/Pictures/*.photoslibrary"], .photosVideos)
        add(["~/Music", "~/Movies/TV", "~/.Trash", "~/Library/Mail", "~/Library/Messages", "~/Library/Mobile Documents",
             "~/Library/Containers/com.apple.mail"], .other)
        add(["~/Library/Application Support/MobileSync"], .iosBackups)
        add(["~/Library/Developer"], .developer)
        add(["~/Library/Application Support", "~/Library/Containers", "~/Library/Group Containers",
             "/Library/Application Support"], .systemData, .appData)
        add(["~/Library/Caches", "/Library/Caches"], .systemData, .appCaches)
        add(["~/Library/Logs", "/Library/Logs", "/private/var/log"], .systemData, .logs)
        add(["~/Library/Caches/Homebrew", "~/Library/Caches/pip", "~/Library/Caches/Yarn", "~/Library/Caches/CocoaPods",
             "~/Library/Caches/org.swift.swiftpm", "~/Library/Caches/ms-playwright", "~/.npm", "~/.cache/uv",
             "~/.cache/pip", "~/.cache/puppeteer", "~/.cargo", "~/.gradle", "~/.m2", "~/.bun", "~/.yarn",
             "~/.pnpm-store", "~/Library/pnpm", "~/go/pkg/mod"], .systemData, .devCaches)
        add(["~/.cache/huggingface", "~/.ollama", "~/.lmstudio", "~/.cache/lm-studio", "~/.cache/torch",
             "~/.cache/whisper"], .systemData, .aiModels)
        add(["~/Library/Containers/com.docker.docker", "~/Library/Containers/com.utmapp.UTM",
             "~/Library/Group Containers/HUAQ24HBR6.dev.orbstack", "~/.orbstack", "~/.colima",
             "~/.local/share/containers"], .systemData, .virtualMachines)
        add(["~/Library/iTunes/*Software Updates"], .systemData, .deviceUpdates)
        add(["/Library/Developer", "/opt/homebrew", "/usr/local"], .systemData, .developerTools)
        add(["/private/var/folders"], .systemData, .tempFiles)
        return rules
    }
}
