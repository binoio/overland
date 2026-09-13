import Foundation
import Security

/// Code-signing checks the helper performs before trusting anyone or running
/// anything. Everything hinges on the helper's own Team ID: an ad-hoc or
/// unsigned helper has none and therefore refuses every connection.
enum CodeSignature {
    enum Failure: Error, LocalizedError {
        case notSigned
        case invalidRequirement(String)
        case check(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .notSigned: return "the helper is not signed with a Team ID; refusing to operate"
            case .invalidRequirement(let r): return "bad code requirement: \(r)"
            case .check(let what, let status):
                let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "\(what): \(msg)"
            }
        }
    }

    /// Team identifier from the running helper's own signature.
    static func selfTeamIdentifier() throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw Failure.notSigned }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else {
            throw Failure.notSigned
        }
        return team
    }

    static func requirement(_ text: String) throws -> SecRequirement {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else {
            throw Failure.invalidRequirement(text)
        }
        return req
    }

    /// Requirement a connecting app must satisfy: same team, the app's bundle id.
    static func clientRequirement(teamID: String, bundleID: String) throws -> SecRequirement {
        try requirement("anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\"")
    }

    /// Requirement for binaries the helper executes: same team.
    static func teamRequirement(teamID: String) throws -> SecRequirement {
        try requirement("anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"")
    }

    /// Validate the process on the other end of `connection`.
    static func connectionSatisfies(_ requirement: SecRequirement, connection: NSXPCConnection) -> Bool {
        var attributes: [CFString: Any] = [:]
        // The audit token is the reliable identity; NSXPCConnection exposes it
        // through KVC only.
        if let token = connection.value(forKey: "auditToken") as? NSValue {
            var audit = audit_token_t()
            token.getValue(&audit, size: MemoryLayout<audit_token_t>.size)
            attributes[kSecGuestAttributeAudit] = Data(bytes: &audit, count: MemoryLayout<audit_token_t>.size)
        } else {
            attributes[kSecGuestAttributePid] = connection.processIdentifier
        }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess, let code else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// Validate a file on disk (a binary, or a bundle with its sealed
    /// resources) against `requirement`.
    static func pathSatisfies(_ requirement: SecRequirement, path: String) throws {
        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        let created = SecStaticCodeCreateWithPath(url, [], &staticCode)
        guard created == errSecSuccess, let staticCode else { throw Failure.check("reading signature of \(path)", created) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard status == errSecSuccess else { throw Failure.check("signature of \(path)", status) }
    }
}
