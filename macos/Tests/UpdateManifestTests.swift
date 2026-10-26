import CryptoKit
import Foundation

@main
struct UpdateManifestTests {
  static func main() throws {
    let vector = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let publicKey = try String(
      contentsOf: vector.appendingPathComponent("pubkey.hex"), encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let good = try Data(contentsOf: vector.appendingPathComponent("manifest.json"))
    let signature = try Data(contentsOf: vector.appendingPathComponent("manifest.json.sig"))
    try verifyUpdateSignature(good, signature, publicKey: publicKey)
    try denied("supplied tampered cross-platform vector") {
      try verifyUpdateSignature(
        Data(contentsOf: vector.appendingPathComponent("manifest-tampered.json")),
        signature, publicKey: publicKey
      )
    }
    try denied("prehashed Data is not the signed manifest") {
      try verifyUpdateSignature(Data(SHA256.hash(data: good)), signature, publicKey: publicKey)
    }
    print("PASS: production verifier accepts the cross-platform exact-byte P-256 vector")

    // Test-only signing key stays in memory and has no relationship to the owner's release key.
    let key = P256.Signing.PrivateKey()
    let testPublic = key.publicKey.x963Representation.dropFirst()
      .map { String(format: "%02x", $0) }.joined()
    let asset: [String: Any] = [
      "version": "1.0.4", "size": 20, "sha256": String(repeating: "a", count: 64),
      "url": "https://github.com/example/example/releases/download/v1.0.4/launcher.zip",
    ]
    let root: [String: Any] = [
      "schema": 1, "realm": "example", "published": "2026-10-26T12:00:00Z",
      "platforms": ["macos-universal": asset],
    ]
    func select(_ bytes: Data, current: String = "1.0.3") throws -> UpdateRelease? {
      let signature = try key.signature(for: bytes).rawRepresentation.base64EncodedData()
      return try updateRelease(
        manifest: bytes, signature: signature, realm: "example", repository: "example/example",
        publicKey: testPublic, currentVersion: current
      )
    }
    func encode(_ value: [String: Any]) throws -> Data {
      try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
    }
    let encoded = try encode(root)
    let release = try select(encoded)
    guard release?.version == "1.0.4", release?.size == 20 else { throw Failure.check }
    guard try select(encoded, current: "1.0.4") == nil,
      try select(encoded, current: "2.0.0") == nil else { throw Failure.check }
    print("PASS: only a strictly newer semantic version is selected")

    for (field, value) in [
      ("version", "01.0.4"), ("version", "1.0.65536"), ("version", "1.0.4\n"),
      ("version", "1.0.4.0"), ("url", "https://github.com/other/example/releases/download/v1/a.zip"),
      ("url", "https://github.com/example/example/releases/download/../a.zip"),
      ("url", "https://github.com/example/example/releases/download/v1/a.zip?x=1"),
      ("url", "https://github.com/example/example/releases/download/v1/%2e%2e"),
      ("sha256", String(repeating: "A", count: 64)),
    ] {
      var bad = root
      var changed = asset
      changed[field] = value
      bad["platforms"] = ["macos-universal": changed]
      try denied("signed invalid asset " + field) { _ = try select(encode(bad)) }
    }
    for value: Any in [true, 0, -1, 52_428_801, "20", 20.5] {
      var bad = root
      var changed = asset
      changed["size"] = value
      bad["platforms"] = ["macos-universal": changed]
      try denied("signed invalid size type or bound") { _ = try select(encode(bad)) }
    }
    for (field, value): (String, Any) in [
      ("schema", true), ("schema", 2), ("realm", "another"),
      ("published", "yesterday"), ("platforms", [:]), ("platforms", ["unknown": asset]),
    ] {
      var bad = root
      bad[field] = value
      try denied("signed invalid root " + field) { _ = try select(encode(bad)) }
    }
    let text = String(decoding: encoded, as: UTF8.self)
    for bad in [
      text.replacingOccurrences(of: #""schema":1"#, with: #""schema":1,"schema":1"#),
      text.replacingOccurrences(of: #""schema":1"#, with: #""schema":1.0"#),
      text.replacingOccurrences(of: #""size":20"#, with: #""size":2e1"#),
      text.replacingOccurrences(of: #""size":20"#, with: #""size":20,"\u0073ize":20"#),
      text.dropLast() + #", "ignored":[{"x":1,"x":2}]}"#,
    ] {
      guard bad != text else { throw Failure.check }
      try denied("signed lexical integer or nested/escaped duplicate") {
        _ = try select(Data(bad.utf8))
      }
    }
    try denied("signature has a strict decoded size") {
      try verifyUpdateSignature(good, Data("AA==".utf8), publicKey: publicKey)
    }
    try denied("manifest download bound") {
      _ = try select(Data(repeating: 32, count: 65_537))
    }
    print("All signed-manifest contract checks passed; no production private key or network used.")
  }

  enum Failure: Error { case check }

  static func denied(_ name: String, _ action: () throws -> Void) throws {
    do {
      try action()
    } catch {
      print("PASS: refused " + name)
      return
    }
    throw Failure.check
  }
}
