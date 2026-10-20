import Foundation
import Security

/// Reads code-signing metadata with the public Security framework. Signature *resources* are not
/// re-hashed (fast); the requirement checks only evaluate the certificate chain.
public enum CodeSigningInspector {
    public struct Info: Sendable, Hashable {
        public var kind: SigningKind
        public var teamIdentifier: String?
        public var applicationGroups: [String]
    }

    private static let fastFlags = SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSDoNotValidateExecutable)

    public static func inspect(bundlePath: String) -> Info {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: bundlePath) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return Info(kind: .unknown, teamIdentifier: nil, applicationGroups: [])
        }
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &infoRef) == errSecSuccess, let info = infoRef as? [String: Any] else {
            return Info(kind: .unsigned, teamIdentifier: nil, applicationGroups: [])
        }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = (entitlements?["com.apple.security.application-groups"] as? [String]) ?? []
        guard info[kSecCodeInfoIdentifier as String] != nil else {
            return Info(kind: .unsigned, teamIdentifier: nil, applicationGroups: [])
        }
        let codeFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let adHocFlag: UInt32 = 0x0002 // kSecCodeSignatureAdhoc
        let kind: SigningKind
        if codeFlags & adHocFlag != 0 {
            kind = .adHoc
        } else if satisfies(code, "anchor apple") {
            kind = .apple
        } else if satisfies(code, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9]") {
            kind = .appStore
        } else if satisfies(code, "anchor apple generic") {
            kind = .developer
        } else {
            kind = .unknown
        }
        return Info(kind: kind, teamIdentifier: team, applicationGroups: groups)
    }

    private static func satisfies(_ code: SecStaticCode, _ requirementText: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(code, fastFlags, requirement) == errSecSuccess
    }
}
