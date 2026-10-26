// SystemSetup.swift - install only the name-constrained realm CA; DNS stays process-local.
//
import Foundation
import CryptoKit
import Security

enum SetupError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let m) = self { return m }; return "setup error" }
}

// ---- small shell runner -----------------------------------------------------------------------------
@discardableResult
func run(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// ---- argument validation ----------------------------------------------------------------
func isIPv4(_ s: String) -> Bool {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    for part in parts {
        guard !part.isEmpty, part.count <= 3, part.allSatisfy({ ("0"..."9").contains($0) }),
              let v = Int(part), v <= 255 else { return false }
        if part.count > 1 && part.first == "0" { return false } // no leading zeros
    }
    return true
}

// ---- CA install -------------------------------------------------------------------------------------
// Decode the compiled-in PEM to DER, confirm its SHA-1 fingerprint matches the expected one, then add it
// to the login keychain with user trust restricted to SSL for the realm hostname.
func caDer() throws -> Data {
    let body = C.caPem
        .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
        .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
        .components(separatedBy: .whitespacesAndNewlines).joined()
    guard let der = Data(base64Encoded: body) else { throw SetupError.message("CA: bad base64 in compiled PEM") }
    return der
}

func caFingerprintSha1() throws -> String {
    let digest = Insecure.SHA1.hash(data: try caDer())
    return digest.map { String(format: "%02X", $0) }.joined()
}

// Presence in a keychain alone does not establish trust. Require our exact scoped user setting.
func realmTrustConfigured(_ settings: [[String: Any]]) -> Bool {
  guard settings.count == 1, let setting = settings.first,
        setting[kSecTrustSettingsPolicyString as String] as? String == C.hostName,
        setting[kSecTrustSettingsApplication as String] == nil,
        setting[kSecTrustSettingsAllowedError as String] == nil,
        ((setting[kSecTrustSettingsResult as String] as? NSNumber)?.uint32Value ?? 1) == 1,
        let policy = setting[kSecTrustSettingsPolicy as String],
        CFGetTypeID(policy as CFTypeRef) == SecPolicyGetTypeID() else { return false }
  guard let properties = SecPolicyCopyProperties(policy as! SecPolicy) as NSDictionary? else {
    return false
  }
  return properties[kSecPolicyOid] as? String == kSecPolicyAppleSSL as String
}

func caAlreadyTrusted() -> Bool {
  guard let der = try? caDer(),
        let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return false }
  var settings: CFArray?
  guard SecTrustSettingsCopyTrustSettings(certificate, .user, &settings) == errSecSuccess,
        let values = settings as? [[String: Any]] else { return false }
  return realmTrustConfigured(values)
}

func installCA() throws {
    guard try caFingerprintSha1() == C.caSha1 else {
        throw SetupError.message("CA: compiled cert SHA-1 does not match expected \(C.caSha1)")
    }
    if caAlreadyTrusted() { return }
    // A unique private file avoids a predictable-path symlink target.
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("ForeverCA.\(UUID().uuidString).pem")
    guard FileManager.default.createFile(
      atPath: tmp.path, contents: Data(C.caPem.utf8), attributes: [.posixPermissions: 0o600]) else {
      throw SetupError.message("CA: could not create temporary certificate")
    }
    defer { try? FileManager.default.removeItem(at: tmp) }
    let keychain = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Keychains/login.keychain-db")
    let r = run("/usr/bin/security", [
      "add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-s", C.hostName,
      "-k", keychain.path, tmp.path,
    ])
    if r.code != 0 { throw SetupError.message("CA: add-trusted-cert failed: \(r.out)") }
}

// Resolve the configured realm server to its current IPv4.
func resolveServerIPv4(_ name: String = C.server) -> String? {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                         ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(name, nil, &hints, &res) == 0, let first = res else { return nil }
    defer { freeaddrinfo(res) }
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard let sa = first.pointee.ai_addr else { return nil }
    var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
    return String(cString: buf)
}

func setupNeeded() -> Bool { !caAlreadyTrusted() }
