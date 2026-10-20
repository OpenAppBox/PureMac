import Foundation
import Testing
@testable import PureMacKit

@Suite("Path tools")
struct PathToolsTests {
    @Test func normalizeRejectsTraversalAndRelativePaths() {
        #expect(PathTools.normalize("relative/path") == nil)
        #expect(PathTools.normalize("/Users/a/../b") == nil)
        #expect(PathTools.normalize("/Users/a/..") == nil)
        #expect(PathTools.normalize("/a/\0b") == nil)
        #expect(PathTools.normalize("/a//b/./c/") == "/a/b/c")
        #expect(PathTools.normalize("/") == "/")
    }

    @Test func insideIsComponentWiseNotStringPrefix() {
        #expect(PathTools.isStrictlyInside("/a/b/c", "/a/b"))
        #expect(!PathTools.isStrictlyInside("/a/bc", "/a/b"))
        #expect(!PathTools.isStrictlyInside("/a/b", "/a/b"))
        #expect(PathTools.isSameOrInside("/a/b", "/a/b"))
        #expect(PathTools.relativeComponents(of: "/a/b/c d/e", under: "/a/b") == ["c d", "e"])
    }

    @Test func dataVolumeFirmlinksAreCanonicalized() {
        #expect(PathTools.canonicalizingDataVolume("/System/Volumes/Data/Users/x/file") == "/Users/x/file")
        #expect(PathTools.canonicalizingDataVolume("/System/Volumes/Data/Applications/A.app") == "/Applications/A.app")
        #expect(PathTools.canonicalizingDataVolume("/System/Volumes/Data/.Spotlight-V100") == "/System/Volumes/Data/.Spotlight-V100")
        // A whole-disk scan stores its folders under these names.
        #expect(PathTools.canonicalizingDataVolume("/System/Volumes/Data/Users") == "/Users")
        #expect(PathTools.canonicalizingDataVolume("/System/Volumes/Data") == "/System/Volumes/Data")
        #expect(PathTools.canonicalizingDataVolume("/System/Volumes/Data/Usersx/a") == "/System/Volumes/Data/Usersx/a")
        #expect(PathTools.canonicalizingDataVolume("/Users/x") == "/Users/x")
    }

    @Test func firmlinksComeFromTheSystemList() {
        // macOS lists its firmlinks in /usr/share/firmlinks; the well-known ones are always there.
        let visible = Set(PathTools.firmlinks.map(\.visible))
        #expect(visible.isSuperset(of: ["/Users", "/Applications", "/Library", "/private", "/usr/local"]))
        #expect(PathTools.firmlinks.allSatisfy { $0.visible.hasPrefix("/") && !$0.data.hasPrefix("/") })
    }

    @Test func bundleIdentifierShape() {
        #expect(PathTools.looksLikeBundleIdentifier("com.example.App"))
        #expect(PathTools.looksLikeBundleIdentifier("org.mozilla.firefox"))
        #expect(PathTools.looksLikeBundleIdentifier("com.tinyspeck.slackmacgap"))
        #expect(!PathTools.looksLikeBundleIdentifier("Slack"))
        #expect(!PathTools.looksLikeBundleIdentifier("Google"))
        #expect(!PathTools.looksLikeBundleIdentifier("com.example"))
        #expect(!PathTools.looksLikeBundleIdentifier("my folder.with.dots"))
        #expect(!PathTools.looksLikeBundleIdentifier("2023.10.01"))
    }

    @Test func likeEscaping() {
        #expect(PathTools.likeEscaped("50%_off\\") == "50\\%\\_off\\\\")
    }
}

@Suite("Safety policy")
struct SafetyPolicyTests {
    let fixture: Fixture
    let policy: SafetyPolicy
    var home: String { policy.home }

    init() throws {
        fixture = try Fixture("home")
        for dir in ["Library/Caches/com.example.app", "Library/Preferences", "Library/Keychains", "Documents/Project",
                    "Desktop", "Downloads", "Applications/Tool.app", "Library/Application Support/MobileSync/Backup",
                    "Library/Containers/com.apple.Notes", "Library/Mail", "Pictures/Photos Library.photoslibrary/database",
                    ".ssh", ".Trash", "Library/Application Support/PureMacData", "Library/Developer/Xcode/Archives",
                    "Library/Developer/Xcode/DerivedData/Proj-abc", "Library/Group Containers/group.com.apple.notes",
                    "Library/Mobile Documents/com~apple~CloudDocs", ".npm/_cacache"] {
            try fixture.dir(dir)
        }
        policy = SafetyPolicy(homeDirectory: fixture.path, ownPaths: [fixture.path("Library/Application Support/PureMacData")],
                              applicationRoots: ["/Applications", fixture.path("Applications")])
    }

    func p(_ relative: String) -> String { home + "/" + relative }

    @Test func protectedSystemLocationsAreDeniedForEveryIntent() {
        let system = ["/", "/System", "/System/Library/CoreServices", "/usr/bin/true", "/bin", "/sbin/mount", "/private/var/db",
                      "/private/etc/hosts", "/var/log", "/etc/hosts", "/dev/null", "/Library/Preferences", "/opt/homebrew",
                      "/Users", "/cores"]
        for path in system {
            for intent in [SafetyIntent.ruleCleanup, .orphanRemoval, .appDataRemoval, .userSelected] {
                #expect(!policy.evaluate(path, intent: intent, allowedRoots: ["/"]).isAllowed, "\(path) must be denied for \(intent)")
            }
        }
    }

    @Test func homeAndItsAncestorsAreNeverRemovable() {
        for intent in [SafetyIntent.ruleCleanup, .userSelected, .appDataRemoval] {
            #expect(!policy.evaluate(home, intent: intent).isAllowed)
            #expect(!policy.evaluate((home as NSString).deletingLastPathComponent, intent: intent).isAllowed)
        }
    }

    @Test func standardFoldersThemselvesAreProtected() {
        for folder in ["Documents", "Desktop", "Downloads", "Library", "Pictures", "Applications", "Library/Caches",
                       "Library/Preferences", "Library/Application Support", "Library/Containers"] {
            #expect(!policy.evaluate(p(folder), intent: .userSelected).isAllowed, "\(folder)")
            #expect(!policy.evaluate(p(folder), intent: .appDataRemoval).isAllowed, "\(folder)")
        }
    }

    @Test func keychainsMailCloudAndCredentialsAreAlwaysProtected() {
        for relative in ["Library/Keychains", "Library/Keychains/login.keychain-db", "Library/Mail/V10", ".ssh/id_ed25519",
                         "Library/Mobile Documents/com~apple~CloudDocs", "Library/Containers/com.apple.Notes",
                         "Library/Group Containers/group.com.apple.notes", "Library/Preferences/com.apple.finder.plist"] {
            for intent in [SafetyIntent.userSelected, .appDataRemoval, .orphanRemoval] {
                #expect(!policy.evaluate(p(relative), intent: intent).isAllowed, "\(relative) / \(intent)")
            }
        }
    }

    @Test func pureMacOwnDataIsProtected() {
        #expect(!policy.evaluate(p("Library/Application Support/PureMacData"), intent: .appDataRemoval).isAllowed)
        #expect(!policy.evaluate(p("Library/Application Support/PureMacData/db.sqlite"), intent: .userSelected).isAllowed)
    }

    @Test func personalFilesAreUserSelectableButNeverAutomatic() {
        let doc = p("Documents/Project")
        #expect(policy.evaluate(doc, intent: .userSelected).isAllowed)
        #expect(!policy.evaluate(doc, intent: .ruleCleanup, allowedRoots: [p("Documents")]).isAllowed)
        #expect(!policy.evaluate(doc, intent: .orphanRemoval).isAllowed)
        #expect(!policy.evaluate(doc, intent: .appDataRemoval).isAllowed)
    }

    @Test func iosBackupsAndArchivesRequireExplicitSelection() {
        let backup = p("Library/Application Support/MobileSync/Backup")
        #expect(policy.evaluate(backup, intent: .userSelected).isAllowed)
        #expect(!policy.evaluate(backup, intent: .ruleCleanup, allowedRoots: [p("Library/Application Support/MobileSync")]).isAllowed)
        let archives = p("Library/Developer/Xcode/Archives/2026-01-01")
        #expect(!policy.evaluate(archives, intent: .ruleCleanup, allowedRoots: [p("Library/Developer/Xcode/Archives")]).isAllowed)
    }

    @Test func ruleCleanupIsConfinedToItsApprovedRoots() {
        let cache = p("Library/Caches/com.example.app")
        #expect(policy.evaluate(cache, intent: .ruleCleanup, allowedRoots: [p("Library/Caches")]).isAllowed)
        #expect(!policy.evaluate(cache, intent: .ruleCleanup, allowedRoots: [p("Library/Logs")]).isAllowed)
        #expect(!policy.evaluate(cache, intent: .ruleCleanup, allowedRoots: []).isAllowed)
        // The approved root itself is never a candidate.
        #expect(!policy.evaluate(p("Library/Caches"), intent: .ruleCleanup, allowedRoots: [p("Library/Caches")]).isAllowed)
        // Roots outside home are rejected.
        #expect(!policy.evaluate("/tmp/x", intent: .ruleCleanup, allowedRoots: ["/tmp"]).isAllowed)
        // Hidden tool caches are allowed only when explicitly approved.
        #expect(policy.evaluate(p(".npm/_cacache"), intent: .ruleCleanup, allowedRoots: [p(".npm")]).isAllowed)
    }

    @Test func traversalInRequestedPathIsRejected() {
        #expect(!policy.evaluate(p("Library/Caches/../../Documents"), intent: .userSelected).isAllowed)
        #expect(!policy.evaluate("Library/Caches/x", intent: .userSelected).isAllowed)
    }

    @Test func symlinkedParentCannotRedirectIntoProtectedArea() throws {
        // ~/Library/Caches/evil -> ~/Library/Keychains ; target "evil/login.keychain-db" resolves into Keychains.
        try fixture.symlink("Library/Caches/evil", to: fixture.path("Library/Keychains"))
        try fixture.file("Library/Keychains/login.keychain-db")
        let verdict = policy.evaluate(p("Library/Caches/evil/login.keychain-db"), intent: .ruleCleanup, allowedRoots: [p("Library/Caches")])
        #expect(!verdict.isAllowed)
    }

    @Test func insideAppBundlesAndPhotoLibrariesIsDenied() {
        #expect(!policy.evaluate(p("Applications/Tool.app/Contents/MacOS/Tool"), intent: .userSelected).isAllowed)
        #expect(!policy.evaluate(p("Pictures/Photos Library.photoslibrary/database"), intent: .userSelected).isAllowed)
    }

    @Test func appBundleRemovalOnlyFromApplicationsFolders() {
        #expect(policy.evaluate(p("Applications/Tool.app"), intent: .appBundleRemoval).isAllowed)
        #expect(policy.evaluate("/Applications/Some.app", intent: .appBundleRemoval).isAllowed)
        #expect(!policy.evaluate("/System/Applications/Calculator.app", intent: .appBundleRemoval).isAllowed)
        #expect(!policy.evaluate(p("Downloads/Tool.app"), intent: .appBundleRemoval).isAllowed)
        #expect(!policy.evaluate("/Applications", intent: .appBundleRemoval).isAllowed)
        #expect(!policy.evaluate("/Applications/Utilities", intent: .appBundleRemoval).isAllowed)
    }

    @Test func trashAndUserExclusionsAreDenied() {
        #expect(!policy.evaluate(p(".Trash/old"), intent: .userSelected).isAllowed)
        let excluding = SafetyPolicy(homeDirectory: fixture.path, userExclusions: [p("Library/Caches/com.example.app")])
        #expect(!excluding.evaluate(p("Library/Caches/com.example.app"), intent: .ruleCleanup, allowedRoots: [p("Library/Caches")]).isAllowed)
    }

    @Test func volumesAreNeverAutomaticTargets() {
        // A missing enclosing folder is always denied (stale plan / unmounted volume).
        #expect(!policy.evaluate("/Volumes/PureMacMissingVolume/Movies/big.mov", intent: .userSelected).isAllowed)
        #expect(!policy.evaluate("/Volumes/PureMacMissingVolume", intent: .ruleCleanup, allowedRoots: ["/Volumes"]).isAllowed)
        #expect(!policy.evaluate("/Volumes/PureMacMissingVolume/x", intent: .appDataRemoval).isAllowed)
    }
}
