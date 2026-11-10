import Foundation
import Security

enum BundleSignature {
    /// The running copy's own requirement as text, read before any swap can change what is on disk.
    static func runningRequirement() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
            let requirement,
            SecRequirementCopyString(requirement, [], &text) == errSecSuccess
        else { return nil }
        return text as String?
    }

    /// Returned so the swap at quit can pin the exact bytes that were verified.
    static func trustedHash(of bundleURL: URL, requirement text: String) -> Data? {
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
            let requirement,
            SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
            let staticCode,
            SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
        else { return nil }
        return uniqueHash(of: staticCode)
    }

    /// An unsealed bundle can claim any identity, and a nested helper is where one hides.
    private static let flags = SecCSFlags(
        rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)

    private static func uniqueHash(of staticCode: SecStaticCode) -> Data? {
        var information: CFDictionary?
        let options = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, options, &information) == errSecSuccess
        else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
    }
}
