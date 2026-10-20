import Foundation

// MARK: - Installed applications

/// How an application bundle is code signed, determined with the Security framework.
public enum SigningKind: String, Codable, Sendable, Hashable {
    /// Signed by Apple as part of macOS or an Apple app.
    case apple
    /// Signed with a Mac App Store certificate.
    case appStore
    /// Signed with a Developer ID or other Apple-issued developer certificate.
    case developer
    /// Ad-hoc signature (no identity).
    case adHoc
    case unsigned
    case unknown

    public var displayName: String {
        switch self {
        case .apple: String(localized: "Apple", bundle: .module)
        case .appStore: String(localized: "Mac App Store", bundle: .module)
        case .developer: String(localized: "Identified developer", bundle: .module)
        case .adHoc: String(localized: "Ad-hoc signed", bundle: .module)
        case .unsigned: String(localized: "Not signed", bundle: .module)
        case .unknown: String(localized: "Unknown", bundle: .module)
        }
    }
}

public enum AppSource: String, Codable, Sendable, Hashable {
    case appStore
    case installerPackage
    case dragAndDrop
    case system
    case unknown

    public var displayName: String {
        switch self {
        case .appStore: String(localized: "Mac App Store", bundle: .module)
        case .installerPackage: String(localized: "Installer package", bundle: .module)
        case .dragAndDrop: String(localized: "Copied into Applications", bundle: .module)
        case .system: String(localized: "Part of macOS", bundle: .module)
        case .unknown: String(localized: "Unknown", bundle: .module)
        }
    }
}

public struct InstalledApp: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var bundleIdentifier: String?
    public var version: String?
    public var build: String?
    public var teamIdentifier: String?
    public var signingKind: SigningKind
    public var source: AppSource
    /// Package receipt identifiers that list this bundle (from `/var/db/receipts`).
    public var packageIdentifiers: [String]
    /// Bundle identifiers of embedded helpers (login items, XPC services, nested apps).
    public var helperBundleIdentifiers: [String]
    /// App group identifiers declared in the code-signing entitlements.
    public var applicationGroups: [String]
    /// Apple system apps and apps on the sealed system volume are never removable.
    public var isProtected: Bool
    public var protectionReason: String?
    public var executableName: String?

    public init(path: String, name: String, bundleIdentifier: String?, version: String?, build: String?,
                teamIdentifier: String?, signingKind: SigningKind, source: AppSource,
                packageIdentifiers: [String], helperBundleIdentifiers: [String], applicationGroups: [String],
                isProtected: Bool, protectionReason: String?, executableName: String?) {
        self.path = path
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.teamIdentifier = teamIdentifier
        self.signingKind = signingKind
        self.source = source
        self.packageIdentifiers = packageIdentifiers
        self.helperBundleIdentifiers = helperBundleIdentifiers
        self.applicationGroups = applicationGroups
        self.isProtected = isProtected
        self.protectionReason = protectionReason
        self.executableName = executableName
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// The main bundle identifier plus all helper identifiers, lowercased.
    public var allBundleIdentifiers: Set<String> {
        var ids = Set(helperBundleIdentifiers.map { $0.lowercased() })
        if let bundleIdentifier { ids.insert(bundleIdentifier.lowercased()) }
        return ids
    }
}

// MARK: - Associations

/// What role an associated item plays for its application.
public enum AssociationKind: String, Codable, Sendable, Hashable, CaseIterable {
    case appBundle
    case cache
    case preferences
    case applicationSupport
    case container
    case groupContainer
    case logs
    case savedState
    case httpStorage
    case webKitData
    case cookies
    case applicationScripts
    case launchAgent
    case systemLevel
    case other

    public var displayName: String {
        switch self {
        case .appBundle: String(localized: "Application", bundle: .module)
        case .cache: String(localized: "Caches", bundle: .module)
        case .preferences: String(localized: "Preferences", bundle: .module)
        case .applicationSupport: String(localized: "Application Support", bundle: .module)
        case .container: String(localized: "Sandbox Container", bundle: .module)
        case .groupContainer: String(localized: "Shared Group Container", bundle: .module)
        case .logs: String(localized: "Logs", bundle: .module)
        case .savedState: String(localized: "Saved Window State", bundle: .module)
        case .httpStorage: String(localized: "HTTP Storage", bundle: .module)
        case .webKitData: String(localized: "Web Data", bundle: .module)
        case .cookies: String(localized: "Cookies", bundle: .module)
        case .applicationScripts: String(localized: "Application Scripts", bundle: .module)
        case .launchAgent: String(localized: "Launch Agents & Services", bundle: .module)
        case .systemLevel: String(localized: "System-level Files", bundle: .module)
        case .other: String(localized: "Other", bundle: .module)
        }
    }

    /// Whether the item normally holds data the user created or configured (as opposed to
    /// regenerable caches). Personal-data kinds are kept by "Remove app, keep personal data".
    public var holdsPersonalData: Bool {
        switch self {
        case .preferences, .applicationSupport, .container, .groupContainer, .cookies, .webKitData, .httpStorage:
            true
        case .appBundle, .cache, .logs, .savedState, .applicationScripts, .launchAgent, .systemLevel, .other:
            false
        }
    }
}

/// Qualitative association strength. PureMac deliberately does not invent percentages.
public enum AssociationConfidence: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    /// Exact identifier evidence (bundle ID, container metadata, program path inside the bundle).
    case confirmed
    /// Strong but indirect evidence (bundle-ID prefix, curated vendor path).
    case likely
    /// Weak evidence such as a name match only. Never preselected.
    case ambiguous
    /// Used by more than one application or the system. Never removed with an app.
    case shared
    /// Protected by macOS or PureMac policy. Never removable here.
    case protected

    public var displayName: String {
        switch self {
        case .confirmed: String(localized: "Confirmed", bundle: .module)
        case .likely: String(localized: "Likely", bundle: .module)
        case .ambiguous: String(localized: "Ambiguous", bundle: .module)
        case .shared: String(localized: "Shared", bundle: .module)
        case .protected: String(localized: "Protected", bundle: .module)
        }
    }

    private var rank: Int {
        switch self {
        case .confirmed: 0
        case .likely: 1
        case .ambiguous: 2
        case .shared: 3
        case .protected: 4
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// Whether the user may select an item with this confidence for removal.
    public var isSelectable: Bool { self == .confirmed || self == .likely || self == .ambiguous }
}

/// One piece of evidence for (or against) an association.
public struct Evidence: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case exactBundleIdentifier
        case bundleIdentifierPrefix
        case helperBundleIdentifier
        case containerMetadata
        case applicationGroupEntitlement
        case launchAgentProgramInBundle
        case launchAgentLabel
        case curatedVendorPath
        /// The app itself is in the Trash: uninstalled, its leftovers not yet.
        case appInTrash
        case nameMatchOnly
        case packageReceipt
        case sharedByMultipleApps
        case systemOwned
        case appleComponent
        case appInstalledElsewhere
        case vendorStillInstalled
        case recentlyModified
        case runningProcess
        case knownNonAppComponent
        case noInstalledOwner
        case notRegisteredWithLaunchServices
        case staleModification
        case userIgnored
        case contentHashMatch
    }

    public var kind: Kind
    public var detail: String
    /// `false` when this evidence argues *against* removal.
    public var supportsRemoval: Bool

    public init(_ kind: Kind, _ detail: String, supportsRemoval: Bool = true) {
        self.kind = kind
        self.detail = detail
        self.supportsRemoval = supportsRemoval
    }
}

/// A filesystem item associated with an installed application.
public struct AppAssociation: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var kind: AssociationKind
    public var confidence: AssociationConfidence
    public var evidence: [Evidence]
    public var logicalSize: Int64?
    public var allocatedSize: Int64?
    public var modified: Date?
    public var identity: FileIdentity?
    /// The item exists but needs administrator rights to remove (e.g. `/Library`).
    public var requiresAdministrator: Bool
    public var isReadable: Bool
    /// Set when the item is known to hold critical data (browser profiles, VM disks). Such items are
    /// never preselected, even for complete removal.
    public var warning: String?
    /// Some contents could not be read, so the size is a lower bound.
    public var isPartiallyMeasured: Bool = false

    public init(path: String, kind: AssociationKind, confidence: AssociationConfidence, evidence: [Evidence],
                logicalSize: Int64? = nil, allocatedSize: Int64? = nil, modified: Date? = nil,
                identity: FileIdentity? = nil, requiresAdministrator: Bool = false, isReadable: Bool = true,
                warning: String? = nil) {
        self.warning = warning
        self.path = path
        self.kind = kind
        self.confidence = confidence
        self.evidence = evidence
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modified = modified
        self.identity = identity
        self.requiresAdministrator = requiresAdministrator
        self.isReadable = isReadable
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { (path as NSString).lastPathComponent }
}

/// A probable remnant of an application that is no longer installed.
public struct OrphanCandidate: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var inferredBundleIdentifier: String
    public var kind: AssociationKind
    /// `likely` when all evidence converges; `ambiguous` otherwise. Never `confirmed`.
    public var confidence: AssociationConfidence
    public var evidence: [Evidence]
    public var logicalSize: Int64?
    public var allocatedSize: Int64?
    public var modified: Date?
    public var identity: FileIdentity?
    /// The app's name when known (from PureMac's catalog or the app in the Trash).
    public var appName: String?

    public init(path: String, inferredBundleIdentifier: String, kind: AssociationKind,
                confidence: AssociationConfidence, evidence: [Evidence], logicalSize: Int64? = nil,
                allocatedSize: Int64? = nil, modified: Date? = nil, identity: FileIdentity? = nil) {
        self.path = path
        self.inferredBundleIdentifier = inferredBundleIdentifier
        self.kind = kind
        self.confidence = confidence
        self.evidence = evidence
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modified = modified
        self.identity = identity
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { (path as NSString).lastPathComponent }
}
