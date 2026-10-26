import Foundation
import Security

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("AlgalonCheck-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

func check(_ condition: Bool, _ message: String) {
  guard condition else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
  print("PASS: \(message)")
}

func write(_ text: String, _ url: URL) throws {
  try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(text.utf8).write(to: url)
}

func snapshot(_ url: URL) throws -> [String: Data] {
  var files: [String: Data] = [:]
  let entries = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])!
  for case let entry as URL in entries {
    if try entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
      files[String(entry.path.dropFirst(url.path.count))] = try Data(contentsOf: entry)
    }
  }
  return files
}

func permissions(_ app: URL) throws -> [String: Any] {
  let text = run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app.path]).out
  let start = text.range(of: "<?xml")!.lowerBound
  return try PropertyListSerialization.propertyList(
    from: Data(text[start...].utf8), options: [], format: nil) as! [String: Any]
}

print("Detected installed client: \(locateClient()?.wowFolder.path ?? "none")")
check(isIPv4("192.0.2.1"), "IPv4 accepts a valid address")
for invalid in ["127.0.0.01", "256.0.0.1", "1.2.3", "1.2.3.4\n", "::1"] {
  check(!isIPv4(invalid), "IPv4 rejects \(invalid.debugDescription)")
}
check(hexToBytes("00fFa1", 3) == [0, 255, 161], "hex decoding preserves bytes")
check(hexToBytes("0g", 1) == nil, "invalid hex is rejected")
check(try caFingerprintSha1() == "9CD0509C3B0707141C4E04E93EE044DF9BF477CA",
      "embedded CA fingerprint matches the supplied certificate")

let realmTrust: [String: Any] = [
  kSecTrustSettingsPolicy as String: SecPolicyCreateSSL(true, C.hostName as CFString),
  kSecTrustSettingsPolicyString as String: C.hostName,
]
check(realmTrustConfigured([realmTrust]), "scoped SSL trust is recognized")
check(!realmTrustConfigured([]), "empty settings do not count as scoped trust")
for (key, value) in [
  (kSecTrustSettingsPolicyString as String, "other.example" as Any),
  (kSecTrustSettingsResult as String, NSNumber(value: 3) as Any),
  (kSecTrustSettingsAllowedError as String, NSNumber(value: -1) as Any),
  (kSecTrustSettingsPolicy as String, SecPolicyCreateBasicX509() as Any),
] {
  var changed = realmTrust
  changed[key] = value
  check(!realmTrustConfigured([changed]), "incompatible certificate setting is rejected: \(key)")
}

let client = Client(wowFolder: root.appendingPathComponent("World of Warcraft"))
check(client.officialProduct.lastPathComponent == "_forever_"
      && client.privateProduct.lastPathComponent == "_forever_algalon_"
      && client.officialApp.lastPathComponent == "World of Warcraft.app",
      "release product and native application are selected explicitly")
try fm.createDirectory(at: client.officialBinary.deletingLastPathComponent(),
                       withIntermediateDirectories: true)
let fixtureBinary = URL(fileURLWithPath: CommandLine.arguments[2])
try fm.copyItem(at: fixtureBinary, to: client.officialBinary)
let info: [String: String] = [
  "CFBundleExecutable": "World of Warcraft",
  "CFBundleIdentifier": "com.algaloncore.fixture",
  "CFBundlePackageType": "APPL",
]
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
  .write(to: client.officialApp.appendingPathComponent("Contents/Info.plist"))
try write("SET textLocale \"enUS\"\nSET audioLocale \"enUS\"\nSET portal \"test\"\n",
          client.officialProduct.appendingPathComponent("WTF/Config.wtf"))
try write("official cache", client.officialProduct.appendingPathComponent("Cache/official"))
let resource = "Contents/Resources/fixture.txt"
try write("sealed resource", client.officialApp.appendingPathComponent(resource))
let helperRelative = "Contents/Helpers/Voice.app"
let helper = client.officialApp.appendingPathComponent(helperRelative)
try fm.createDirectory(at: helper.appendingPathComponent("Contents/MacOS"),
                       withIntermediateDirectories: true)
try fm.copyItem(at: fixtureBinary,
                to: helper.appendingPathComponent("Contents/MacOS/Voice"))
try PropertyListSerialization.data(fromPropertyList: [
  "CFBundleExecutable": "Voice", "CFBundleIdentifier": "com.algaloncore.voice.fixture",
  "CFBundlePackageType": "APPL"], format: .xml, options: 0)
  .write(to: helper.appendingPathComponent("Contents/Info.plist"))
let helperEntitlements = root.appendingPathComponent("helper.entitlements")
try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.device.audio-input": true],
                                   format: .xml, options: 0).write(to: helperEntitlements)
check(run("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements",
                             helperEntitlements.path, helper.path]).code == 0,
      "fixture helper has distinct permissions")
let originalEntitlements: [String: Bool] = [
  "com.apple.security.cs.allow-jit": true,
  "com.apple.security.cs.allow-unsigned-executable-memory": true,
  "com.apple.security.cs.disable-executable-page-protection": true,
]
let sourceEntitlements = root.appendingPathComponent("source.entitlements")
try PropertyListSerialization.data(fromPropertyList: originalEntitlements, format: .xml, options: 0)
  .write(to: sourceEntitlements)
check(run("/usr/bin/codesign", ["--force", "--options", "runtime", "--sign", "-",
                             "--entitlements", sourceEntitlements.path,
                             client.officialApp.path]).code == 0,
      "fixture carries the game's original memory permissions")
let original = try snapshot(client.officialProduct)

try fm.createDirectory(at: client.wowFolder.appendingPathComponent(
  "_classic_beta_/World of Warcraft Beta.app"), withIntermediateDirectories: true)
let oldOverride = ProcessInfo.processInfo.environment["FOREVER_WOW"]
setenv("FOREVER_WOW", client.wowFolder.path, 1)
check(locateClient().map { realPath($0.officialApp) } == realPath(client.officialApp),
      "explicit release client takes priority even when the old beta application remains")
if let oldOverride { setenv("FOREVER_WOW", oldOverride, 1) } else { unsetenv("FOREVER_WOW") }

try ensurePrivateCopy(client, log: { print($0) })
let signed = try permissions(client.privateApp)
for (key, value) in originalEntitlements {
  check(signed[key] as? Bool == value, "private signature preserves \(key)")
}
let helperPermissions = try permissions(client.privateApp.appendingPathComponent(helperRelative))
check(helperPermissions["com.apple.security.device.audio-input"] as? Bool == true,
      "nested helper retains its own permissions")
check(helperPermissions["com.apple.security.get-task-allow"] == nil,
      "nested helper does not inherit debugger access")
check(try snapshot(client.officialProduct) == original, "copy and signing preserve official files")
check(!fm.fileExists(atPath: client.privateProduct.appendingPathComponent("Cache/official").path),
      "official cache is not copied into the private client")
check(run("/usr/bin/codesign", ["--verify", "--deep", "--strict", client.privateApp.path]).code == 0,
      "private fixture passes strict signature verification")
let brokenEntitlements = root.appendingPathComponent("broken.entitlements")
try PropertyListSerialization.data(fromPropertyList: [
  "com.apple.security.get-task-allow": true,
  "com.apple.security.cs.disable-library-validation": true], format: .xml, options: 0)
  .write(to: brokenEntitlements)
check(run("/usr/bin/codesign", ["--force", "--options", "runtime", "--sign", "-",
                             "--entitlements", brokenEntitlements.path,
                             client.privateApp.path]).code == 0,
      "simulate a copy signed by the old launcher")
try ensurePrivateCopy(client, log: { print($0) })
check(try permissions(client.privateApp)["com.apple.security.cs.allow-jit"] as? Bool == true,
      "a fresh copy with old permissions is repaired")
try write("tampered", client.privateApp.appendingPathComponent(resource))
var rejected = false
do { try resignPrivate(client, log: { print($0) }) } catch { rejected = true }
check(rejected, "signature verification rejects tampering even with matching permissions")
try write("sealed resource", client.privateApp.appendingPathComponent(resource))
for state in ["WTF/settings", "Cache/private", "Screenshots/saved"] {
  try write("private data", client.privateProduct.appendingPathComponent(state))
}
try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 120)],
                     ofItemAtPath: client.officialBinary.path)
check(!privateCopyFresh(client), "an official update invalidates the private copy")
try ensurePrivateCopy(client, log: { print($0) })
for state in ["WTF/settings", "Cache/private", "Screenshots/saved"] {
  let content = try? String(contentsOf: client.privateProduct.appendingPathComponent(state),
                            encoding: .utf8)
  check(content == "private data", "refresh preserves \(state)")
}
check(try snapshot(client.officialProduct) == original, "refresh preserves official file contents")
let resolver = URL(fileURLWithPath: CommandLine.arguments[1])
let session = try launchClient(client, serverIP: "203.0.113.7", resolverLibrary: resolver,
                              log: { print($0) })
let process = session.process
process.waitUntilExit()
check(!session.guardLog.finish(), "ordinary child exit does not report an endpoint violation")
check(process.terminationStatus == 0, "private fixture launches successfully")
for endpoint in [
  "host=\"eu.actual.battle.net\" port=\"1119\"",
  "host=\"algalon.actual.battle.net\" port=\"1119\"",
  "host=\"algalon.actual.battle.net.evil.example\" port=\"1120\"",
  "host=\"algalon.actual.battle.net\"",
] {
  setenv("FOREVER_FIXTURE_ENDPOINT", endpoint, 1)
  let wrongEndpoint = try launchClient(client, serverIP: "203.0.113.7", resolverLibrary: resolver,
                                     log: { _ in })
  wrongEndpoint.process.waitUntilExit()
  check(wrongEndpoint.guardLog.finish() && wrongEndpoint.process.terminationStatus != 0
        && !fm.fileExists(atPath: client.privateProduct.appendingPathComponent(
          "Logs/credentials-stage").path),
        "unexpected endpoint stops the owned child before its credentials stage: \(endpoint)")
}
setenv("FOREVER_FIXTURE_ENDPOINT", "host=\"ALGALON.actual.battle.net\" port=\"1120\"", 1)
let allowedEndpoint = try launchClient(client, serverIP: "203.0.113.7", resolverLibrary: resolver,
                                     log: { _ in })
allowedEndpoint.process.waitUntilExit()
unsetenv("FOREVER_FIXTURE_ENDPOINT")
check(!allowedEndpoint.guardLog.finish() && allowedEndpoint.process.terminationStatus == 0
      && fm.fileExists(atPath: client.privateProduct.appendingPathComponent(
        "Logs/credentials-stage").path),
      "expected endpoint proceeds despite an unexpected endpoint in the previous run's log")
check(try fm.contentsOfDirectory(atPath: client.privateProduct.appendingPathComponent(
  "Logs/Previous").path).count == 5, "prior connection logs are retained separately from the fresh run")
let privateConfig = client.privateProduct.appendingPathComponent("WTF/Algalon.wtf")
let firstConfig = try String(contentsOf: privateConfig, encoding: .utf8)
check(firstConfig.contains("SET portal \"algalon:1120\""), "private portal is configured")
check(firstConfig.contains("SET textLocale \"enUS\""), "private configuration includes an initial text locale")
try write("SET portal \"test\"\nSET gxWindow \"1\"\nSET textLocale \"ruRU\"\n", privateConfig)
let nextConfig = try privateConfiguration(client)
check(nextConfig.contains("SET gxWindow \"1\"") && nextConfig.contains("SET textLocale \"ruRU\""),
      "private settings and language survive the next launch")
check(!nextConfig.contains("SET portal \"test\"")
      && nextConfig.contains("SET portal \"algalon:1120\""), "realm portal replaces the region default")

try write("set portal \"EU\"\nSET portal \"test\"\nSET gxWindow \"1\"\n"
          + "SET textLocale \"enUS\"\nset textLocale \"ruRU\"\n"
          + "SET audioLocale \"invalid\"\nSET audioLocale \"enUS\"\n", privateConfig)
let normalized = try privateConfiguration(client)
for key in ["portal", "textLocale", "audioLocale"] {
  let count = normalized.components(separatedBy: .newlines).filter {
    $0.range(of: "(?i)^\\s*SET\\s+" + key + "\\s", options: .regularExpression) != nil
  }.count
  check(count == 1, "private configuration normalizes duplicate \(key) settings")
}
check(normalized.contains("SET textLocale \"ruRU\"")
      && normalized.contains("SET gxWindow \"1\""),
      "last valid private locale and unrelated player settings survive normalization")

let localeClient = Client(wowFolder: root.appendingPathComponent("LocaleFixture"))
try write("Product!STRING:0|Tags!STRING:0\n"
          + "wow|OSX enUS speech?:OSX enUS text?\n"
          + "wowf|OSX ruRU speech?:OSX deDE text?\n",
          localeClient.wowFolder.appendingPathComponent(".build.info"))
let buildConfig = try privateConfiguration(localeClient)
check(buildConfig.contains("SET textLocale \"deDE\"")
      && buildConfig.contains("SET audioLocale \"ruRU\""),
      "missing locales use the wowf build tags rather than the retail product")
try write("SET gxWindow \"1\"\nSET textLocale \"frFR\"\n",
          localeClient.wowFolder.appendingPathComponent("_classic_beta_algalon_/WTF/Algalon.wtf"))
let migrated = try privateConfiguration(localeClient)
check(migrated.contains("SET gxWindow \"1\"") && migrated.contains("SET textLocale \"frFR\""),
      "first release configuration preserves existing private beta preferences")
try write("SET gxWindow \"0\"\nSET textLocale \"enGB\"\n",
          localeClient.privateProduct.appendingPathComponent("WTF/Algalon.wtf"))
let preferred = try privateConfiguration(localeClient)
check(preferred.contains("SET gxWindow \"0\"") && preferred.contains("SET textLocale \"enGB\""),
      "existing release settings take priority over legacy private preferences")

let privateCache = client.privateProduct.appendingPathComponent("Cache")
let connectionLog = client.privateProduct.appendingPathComponent("Logs/Connection.log")
try fm.removeItem(at: connectionLog)
try fm.createSymbolicLink(at: connectionLog,
                         withDestinationURL: client.officialProduct.appendingPathComponent("WTF/Config.wtf"))
rejected = false
do { try assertPrivateIsolated(client) } catch { rejected = true }
check(rejected, "connection log cannot resolve into the official product")
try fm.removeItem(at: connectionLog)
try fm.removeItem(at: privateCache)
try fm.createSymbolicLink(at: privateCache,
                         withDestinationURL: client.officialProduct.appendingPathComponent("Cache"))
rejected = false
do { try assertPrivateIsolated(client) } catch { rejected = true }
check(rejected, "private cache cannot resolve to the official cache")
try fm.removeItem(at: privateCache)

try fm.removeItem(at: client.privateBinary)
try fm.createSymbolicLink(at: client.privateBinary, withDestinationURL: client.officialBinary)
rejected = false
do { try assertPrivateIsolated(client) } catch { rejected = true }
check(rejected, "private executable symlink cannot reach the official binary")
try fm.removeItem(at: client.privateProduct)
try fm.createSymbolicLink(at: client.privateProduct, withDestinationURL: client.officialProduct)
do {
  try assertPrivateIsolated(client)
  preconditionFailure("official-product symlink must be rejected")
} catch {
  print("PASS: symlink to official product is rejected")
}
print("All local smoke checks passed; no real game or system setup was run.")
