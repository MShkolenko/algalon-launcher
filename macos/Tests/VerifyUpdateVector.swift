import CryptoKit
import Foundation

enum VectorError: Error {
  case malformedKey
  case malformedSignature
  case unexpectedVerification
}

let vector = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let hex = try String(contentsOf: vector.appendingPathComponent("pubkey.hex"), encoding: .utf8)
  .trimmingCharacters(in: .whitespacesAndNewlines)
guard hex.utf8.count == 128 else { throw VectorError.malformedKey }
var point = Data([0x04])
var offset = hex.startIndex
while offset < hex.endIndex {
  let next = hex.index(offset, offsetBy: 2)
  guard let byte = UInt8(hex[offset..<next], radix: 16) else {
    throw VectorError.malformedKey
  }
  point.append(byte)
  offset = next
}
let key = try P256.Signing.PublicKey(x963Representation: point)
for (name, expected) in [("manifest", true), ("manifest-tampered", false)] {
  let message = try Data(contentsOf: vector.appendingPathComponent(name + ".json"))
  let encoded = try String(
    contentsOf: vector.appendingPathComponent(name + ".json.sig"), encoding: .utf8
  ).trimmingCharacters(in: .whitespacesAndNewlines)
  guard let bytes = Data(base64Encoded: encoded), bytes.count == 64 else {
    throw VectorError.malformedSignature
  }
  let signature = try P256.Signing.ECDSASignature(rawRepresentation: bytes)
  guard key.isValidSignature(signature, for: message) == expected else {
    throw VectorError.unexpectedVerification
  }
  print(name + ": " + (expected ? "ACCEPTED" : "REJECTED"))
  if expected {
    guard !key.isValidSignature(signature, for: Data(SHA256.hash(data: message))) else {
      throw VectorError.unexpectedVerification
    }
    print("prehashed-data-control: REJECTED")
  }
}
print("CryptoKit P-256 exact-byte cross-platform test vector: PASS")
