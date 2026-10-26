import Foundation

@main
struct UpdateDownloadTests {
  enum Failure: Error { case expectedRejection }

  static func main() throws {
    let manager = FileManager.default
    let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: temporary) }
    let app = temporary.appendingPathComponent("Fixture.app")
    let bad = URL(fileURLWithPath: app.path + ".bad")
    try manager.createDirectory(at: bad, withIntermediateDirectories: false)
    let lock = try LauncherLock(url: temporary.appendingPathComponent("fixture.lock"))
    guard lock.acquire(), try !checkLauncherUpdate(app: app, lock: lock, log: { _ in }),
      manager.fileExists(atPath: bad.path) else { throw Failure.expectedRejection }
    print("PASS: failed bundle without archive identity suspends update before network access")
    for location in [
      "http://localhost/manifest.json", "file:///etc/hosts", CommandLine.arguments[1],
    ] {
      do {
        _ = try fetchUpdateFile(URL(string: location)!, maximum: 65_536, timeout: 10)
        throw Failure.expectedRejection
      } catch UpdateError.download {
        print("PASS: HTTP, file access or untrusted local TLS refused")
      }
    }
    // Read-only public production-key proof, including GitHub's HTTPS asset redirects.
    let prefix = "https://github.com/\(C.updateRepository)/releases/download/v1.1.0/"
    let bytes = try fetchUpdateFile(
      URL(string: prefix + "manifest.json")!, maximum: 65_536, timeout: 10
    )
    let signature = try fetchUpdateFile(
      URL(string: prefix + "manifest.json.sig")!, maximum: 1_024, timeout: 10
    )
    try verifyUpdateSignature(bytes, signature, publicKey: C.updatePublicKey)
    print("PASS: real GitHub HTTPS redirect and owner-signed release manifest")
    do {
      _ = try fetchUpdateFile(URL(string: prefix + "manifest.json")!, maximum: 1, timeout: 10)
      throw Failure.expectedRejection
    } catch UpdateError.download {
      print("PASS: real HTTP download size bound")
    }
  }
}
