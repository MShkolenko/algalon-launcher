import CoreFoundation
import CryptoKit
import Foundation

enum UpdateError: Error {
  case signature
  case manifest
  case download
  case archive
  case installation
  case recovery
}

struct UpdateRelease {
  let version: String
  let url: URL
  let sha256: String
  let size: Int
}

func verifyUpdateSignature(_ manifest: Data, _ encoded: Data, publicKey: String) throws {
  guard manifest.count <= 65_536, encoded.count <= 1_024,
    let coordinates = hexToBytes(publicKey, 64),
    let text = String(data: encoded, encoding: .utf8),
    let bytes = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
    bytes.count == 64 else { throw UpdateError.signature }
  let key = try P256.Signing.PublicKey(x963Representation: Data([0x04] + coordinates))
  let signature = try P256.Signing.ECDSASignature(rawRepresentation: bytes)
  guard key.isValidSignature(signature, for: manifest) else { throw UpdateError.signature }
}

private func fullMatch(_ text: String, _ pattern: String) -> Bool {
  text.range(of: pattern, options: .regularExpression) == text.startIndex..<text.endIndex
}

private func updateVersion(_ text: String) throws -> [Int] {
  guard fullMatch(text, #"(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})"#)
  else { throw UpdateError.manifest }
  let values = text.split(separator: ".").compactMap { Int($0) }
  guard values.count == 3, values.allSatisfy({ $0 <= 65_535 }) else {
    throw UpdateError.manifest
  }
  return values
}

private func manifestInteger(_ value: Any?) -> Int? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID(),
    !["f", "d"].contains(String(cString: number.objCType)),
    number.int64Value >= 0, number.int64Value <= 52_428_800 else { return nil }
  return number.intValue
}

func updateRelease(
  manifest: Data, signature: Data, realm: String, repository: String,
  publicKey: String, currentVersion: String
) throws -> UpdateRelease? {
  try verifyUpdateSignature(manifest, signature, publicKey: publicKey)
  guard String(data: manifest, encoding: .utf8) != nil else { throw UpdateError.manifest }
  var duplicateCheck = JSONKeyCheck(bytes: Array(manifest))
  try duplicateCheck.validate()
  guard let root = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
    manifestInteger(root["schema"]) == 1, root["realm"] as? String == realm,
    let platforms = root["platforms"] as? [String: Any], !platforms.isEmpty else {
    throw UpdateError.manifest
  }
  if let published = root["published"] {
    guard let text = published as? String,
      fullMatch(text, #"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"#) else {
      throw UpdateError.manifest
    }
  }
  let current = try updateVersion(currentVersion)
  let prefix = "https://github.com/\(repository)/releases/download/"
  var selected: UpdateRelease?
  for (platform, value) in platforms {
    guard ["windows-x64", "macos-universal"].contains(platform),
      let fields = value as? [String: Any], let version = fields["version"] as? String,
      let location = fields["url"] as? String, location.hasPrefix(prefix),
      let hash = fields["sha256"] as? String, fullMatch(hash, "[0-9a-f]{64}"),
      let size = manifestInteger(fields["size"]), size > 0 else { throw UpdateError.manifest }
    let parts = location.dropFirst(prefix.count)
      .split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, parts.allSatisfy({
      $0 != "." && $0 != ".." && fullMatch(String($0), "[A-Za-z0-9._-]+")
    }), let url = URL(string: location) else { throw UpdateError.manifest }
    let candidate = try updateVersion(version)
    if platform == "macos-universal" && current.lexicographicallyPrecedes(candidate) {
      selected = UpdateRelease(version: version, url: url, sha256: hash, size: size)
    }
  }
  return selected
}

// Foundation JSON decoding collapses duplicate keys. Check every object before decoding values.
private struct JSONKeyCheck {
  let bytes: [UInt8]
  private var index = 0

  init(bytes: [UInt8]) { self.bytes = bytes }

  mutating func validate() throws {
    try value(depth: 0)
    whitespace()
    guard index == bytes.count else { throw UpdateError.manifest }
  }

  private mutating func whitespace() {
    while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
  }

  private mutating func consume(_ byte: UInt8) throws {
    whitespace()
    guard index < bytes.count, bytes[index] == byte else { throw UpdateError.manifest }
    index += 1
  }

  private mutating func string() throws -> String {
    whitespace()
    let start = index
    try consume(34)
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      if byte == 92 {
        guard index < bytes.count else { throw UpdateError.manifest }
        index += 1
      } else if byte == 34 {
        guard let text = try JSONSerialization.jsonObject(
          with: Data(bytes[start..<index]), options: .fragmentsAllowed
        ) as? String else { throw UpdateError.manifest }
        return text
      }
    }
    throw UpdateError.manifest
  }

  private mutating func value(depth: Int) throws {
    whitespace()
    guard index < bytes.count, depth <= 64 else { throw UpdateError.manifest }
    switch bytes[index] {
    case 123:
      index += 1
      var keys = Set<String>()
      whitespace()
      if index < bytes.count && bytes[index] == 125 {
        index += 1
        return
      }
      while true {
        guard keys.insert(try string()).inserted else { throw UpdateError.manifest }
        try consume(58)
        try value(depth: depth + 1)
        whitespace()
        if index < bytes.count && bytes[index] == 125 {
          index += 1
          return
        }
        try consume(44)
      }
    case 91:
      index += 1
      whitespace()
      if index < bytes.count && bytes[index] == 93 {
        index += 1
        return
      }
      while true {
        try value(depth: depth + 1)
        whitespace()
        if index < bytes.count && bytes[index] == 93 {
          index += 1
          return
        }
        try consume(44)
      }
    case 34:
      _ = try string()
    default:
      let start = index
      while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) {
        index += 1
      }
      guard index > start else { throw UpdateError.manifest }
    }
  }
}
