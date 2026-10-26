// ClientCopy.swift - the private sibling copy of the client, its ad-hoc re-sign, the config, and launch.
//
// Why a copy (operator 2026-10-11): our realm must never share the client cache with the official one
// (the official realm's WDB holds Blizzard Russian NPC names and quest lines we harvest; our answers
// overwrote them). The copy sits NEXT TO the official product folder, in the same "World of Warcraft"
// folder, so it finds the game data at the same relative path ../Data:
//     World of Warcraft/_forever_/           official, read only
//     World of Warcraft/_forever_<profile>_/   our copy, own Cache and WTF, no Data of its own
//     World of Warcraft/Data/                      shared game data and normal CASC metadata
// A copy elsewhere with a symlink to Data breaks the official game: the data store records the path it
// was opened through and refuses any other (Error 16, container locked). The sibling keeps that path.
//
// macOS adds a step the Windows version does not need: our copy's .app is re-signed ad-hoc with
// get-task-allow (so the launcher may attach under SIP) and disable-library-validation (so the hardened
// copy may load Blizzard's differently-signed nested code after an ad-hoc re-sign). The official .app is
// never re-signed and never modified; several guards below refuse to proceed if any path resolves into it.
import Foundation
import Security

struct Client {
    let wowFolder: URL        // the "World of Warcraft" folder, canonical path
    var officialProduct: URL { wowFolder.appendingPathComponent(C.officialProduct) }
    var privateProduct: URL { wowFolder.appendingPathComponent(C.privateProduct) }
    var officialApp: URL { officialProduct.appendingPathComponent(C.appName) }
    var privateApp: URL { privateProduct.appendingPathComponent(C.appName) }
    var privateBinary: URL { privateApp.appendingPathComponent(C.binaryInApp) }
    var officialBinary: URL { officialApp.appendingPathComponent(C.binaryInApp) }
    var stampFile: URL { privateProduct.appendingPathComponent(".\(C.id)-stamp") }
}

enum CopyError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let m) = self { return m }; return "copy error" }
}

func realPath(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

// Common install locations; the operator can override with FOREVER_WOW pointing at the "World of
// Warcraft" folder. The folder is resolved to a canonical path so later symlink guards are meaningful.
func locateClient() -> Client? {
    let fm = FileManager.default
    var candidates: [URL] = []
    if let env = ProcessInfo.processInfo.environment["FOREVER_WOW"] {
        candidates.append(URL(fileURLWithPath: env))
    }
    candidates.append(contentsOf: [
        "/Applications/World of Warcraft",
        "/Applications/Battle.net/World of Warcraft",
        NSString(string: "~/Applications/World of Warcraft").expandingTildeInPath,
    ].map { URL(fileURLWithPath: $0) })
    if let volumes = fm.mountedVolumeURLs(
      includingResourceValuesForKeys: nil, options: .skipHiddenVolumes
    ) {
      candidates.append(contentsOf: volumes.map {
        $0.appendingPathComponent("Applications/World of Warcraft")
      })
    }
    for c in candidates {
        let canonical = URL(fileURLWithPath: realPath(c))
        let product = canonical.appendingPathComponent(C.officialProduct).appendingPathComponent(C.appName)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: product.path, isDirectory: &isDir), isDir.boolValue {
            return Client(wowFolder: canonical)
        }
    }
    return nil
}

// Exclude official per-run state; preserve only the previous private copy's state.
private let skipEntries: Set<String> = ["Cache", "WTF", "Logs", "Errors", "Screenshots"]

// Refuse to continue if the private product is not a real, separate directory from the official one (e.g.
// it is a symlink to _forever_). Without this, a re-sign could modify Blizzard's signed app.
func assertPrivateIsolated(_ cl: Client) throws {
    let off = realPath(cl.officialProduct)
    let priv = realPath(cl.privateProduct)
    if priv == off || priv.hasPrefix(off + "/") || off.hasPrefix(priv + "/") {
        throw CopyError.message("refusing: the private copy path resolves into the official product (symlink?). Delete \(cl.privateProduct.path) and retry.")
    }
    if FileManager.default.fileExists(atPath: cl.privateApp.path) {
        if realPath(cl.privateApp) == realPath(cl.officialApp) {
            throw CopyError.message("refusing: the private .app resolves to the official .app (symlink?).")
        }
    }
    let privatePaths = [cl.privateBinary,
      cl.privateProduct.appendingPathComponent("WTF/" + C.configName),
      cl.privateProduct.appendingPathComponent("Logs/launcher-client.log"),
      cl.privateProduct.appendingPathComponent("Logs/Connection.log"),
      cl.privateProduct.appendingPathComponent("Logs/Previous")]
      + skipEntries.map { cl.privateProduct.appendingPathComponent($0) }
    for path in privatePaths {
      guard realPath(path).hasPrefix(priv + "/") else {
        throw CopyError.message("refusing: a private executable or state path escapes its product")
      }
    }
}

// The official binary's identity when the copy was staged, so re-signing our own copy (which changes its
// binary) does not look like staleness. Fresh iff the stamp matches the official binary now.
private func officialStamp(_ cl: Client) -> String? {
    guard let a = try? FileManager.default.attributesOfItem(atPath: cl.officialBinary.path) else { return nil }
    let size = (a[.size] as? Int) ?? -1
    let mtime = ((a[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970
    return "\(size):\(Int(mtime))"
}

func privateCopyFresh(_ cl: Client) -> Bool {
    guard FileManager.default.fileExists(atPath: cl.privateBinary.path),
          let want = officialStamp(cl),
          let have = try? String(contentsOf: cl.stampFile, encoding: .utf8) else { return false }
    return have.trimmingCharacters(in: .whitespacesAndNewlines) == want
}

// Stage a fresh copy, swap it in with rollback, record the stamp, then re-sign and de-quarantine.
func ensurePrivateCopy(_ cl: Client, log: (String) -> Void) throws {
    if anotherWowRunning() {
      throw CopyError.message("quit the running WoW client before preparing a private copy")
    }
    try assertPrivateIsolated(cl)
    let fm = FileManager.default
    if privateCopyFresh(cl) {
        log("private copy is current")
        try resignPrivate(cl, log: log)
        return
    }

    let stage = cl.wowFolder.appendingPathComponent(C.privateProduct + ".stage")
    let old = cl.wowFolder.appendingPathComponent(C.privateProduct + ".old")
    try? fm.removeItem(at: stage)
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)

    let entries = try fm.contentsOfDirectory(atPath: cl.officialProduct.path).filter { !skipEntries.contains($0) }
    for name in entries {
        try fm.copyItem(at: cl.officialProduct.appendingPathComponent(name),
                        to: stage.appendingPathComponent(name))
    }
    // Preserve the player's private state when a Blizzard update refreshes the executable copy.
    for name in skipEntries {
      let previous = cl.privateProduct.appendingPathComponent(name)
      if fm.fileExists(atPath: previous.path) {
        try fm.copyItem(at: previous, to: stage.appendingPathComponent(name))
      }
    }
    log("staged \(entries.count) entries")
    let stagedBinary = stage.appendingPathComponent(C.appName).appendingPathComponent(C.binaryInApp)
    guard fm.fileExists(atPath: stagedBinary.path) else {
        try? fm.removeItem(at: stage)
        throw CopyError.message("stage is missing the client .app binary")
    }

    // swap with rollback: current -> .old, stage -> private; restore .old if the second move fails
    try? fm.removeItem(at: old)
    let hadPrivate = fm.fileExists(atPath: cl.privateProduct.path)
    if hadPrivate { try fm.moveItem(at: cl.privateProduct, to: old) }
    do {
        try fm.moveItem(at: stage, to: cl.privateProduct)
    } catch {
        if hadPrivate { try? fm.moveItem(at: old, to: cl.privateProduct) }
        try? fm.removeItem(at: stage)
        throw CopyError.message("swap failed, restored previous copy: \(error)")
    }
    log("private copy swapped in")

    // record the official stamp so the copy is not seen as stale after we re-sign it
    if let stamp = officialStamp(cl) { try? stamp.data(using: .utf8)!.write(to: cl.stampFile) }

    try resignPrivate(cl, log: log)
    try? fm.removeItem(at: old) // keep .old only until a good re-sign; drop it after
}

// Read permissions through Security.framework without parsing codesign's diagnostic output.
func signingEntitlements(_ url: URL) throws -> [String: Any] {
  var code: SecStaticCode?
  guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
        let code else {
    throw CopyError.message("cannot inspect code signature: \(url.path)")
  }
  var information: CFDictionary?
  let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
  guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
        let information = information as? [String: Any] else {
    throw CopyError.message("cannot read code signing information: \(url.path)")
  }
  return information[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
}

// Re-sign only our copy, preserving the game's permissions and adding debugger access.
func resignPrivate(_ cl: Client, log: (String) -> Void) throws {
    try assertPrivateIsolated(cl)

    // Rebuild from the official signature so copies made by older launchers are repaired too.
    var expected = try signingEntitlements(cl.officialApp)
    expected["com.apple.security.get-task-allow"] = true
    expected["com.apple.security.cs.disable-library-validation"] = true
    expected["com.apple.security.cs.allow-dyld-environment-variables"] = true
    let before = try? signingEntitlements(cl.privateApp)
    if let before, NSDictionary(dictionary: expected).isEqual(to: before) {
        log("private copy already carries the needed entitlements")
    } else {
        let ent = FileManager.default.temporaryDirectory
          .appendingPathComponent("WowDebug.\(UUID().uuidString).entitlements")
        try PropertyListSerialization.data(fromPropertyList: expected, format: .xml, options: 0)
          .write(to: ent, options: .atomic)
        defer { try? FileManager.default.removeItem(at: ent) }

        // Sign inside-out; helpers retain their own permissions rather than inheriting the debugger's.
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: cl.privateApp,
                                       includingPropertiesForKeys: [.isRegularFileKey]) else {
          throw CopyError.message("cannot enumerate private application code")
        }
        let items = walk.allObjects.compactMap { $0 as? URL }
        let bundles = [cl.privateApp] + items.filter { $0.pathExtension == "app" }
        let mainBinaries = Set(bundles.compactMap { Bundle(url: $0)?.executableURL }.map(realPath))
        let nested = items.filter { url in
          if url.pathExtension == "app" { return true }
          let regular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
          return regular && (url.pathExtension == "dylib" || url.pathExtension == "so"
            || (url.deletingLastPathComponent().lastPathComponent == "MacOS"
              && !mainBinaries.contains(realPath(url))))
        }.sorted { $0.pathComponents.count > $1.pathComponents.count }
        let root = realPath(cl.privateApp) + "/"
        for item in nested {
          guard realPath(item).hasPrefix(root) else {
            throw CopyError.message("nested code resolves outside the private application")
          }
          let signed = run("/usr/bin/codesign", ["--force", "--sign", "-",
            "--preserve-metadata=entitlements,flags", item.path])
          if signed.code != 0 {
            throw CopyError.message("nested codesign failed: \(signed.out)")
          }
        }
        let sign = run("/usr/bin/codesign",
                       ["--force", "--options", "runtime", "--sign", "-",
                        "--entitlements", ent.path, cl.privateApp.path])
        if sign.code != 0 { throw CopyError.message("codesign re-sign failed: \(sign.out)") }

        guard NSDictionary(dictionary: expected).isEqual(to: try signingEntitlements(cl.privateApp)) else {
          throw CopyError.message("re-signed copy does not preserve the required entitlements")
        }
        log("private copy re-signed; original permissions preserved, debugger access added")
    }

    let verify = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", cl.privateApp.path])
    if verify.code != 0 { throw CopyError.message("private copy failed codesign verification: \(verify.out)") }
    let xr = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", cl.privateApp.path])
    if xr.code != 0 { log("note: clearing quarantine returned \(xr.code): \(xr.out)") }
}

// Refuse to launch if a WoW client is already running: both copies share ../Data and its locks.
func anotherWowRunning() -> Bool {
    // match the client process name exactly (the binary is literally "World of Warcraft")
    return run("/usr/bin/pgrep", ["-x", "World of Warcraft"]).out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
}

private func configuredLocale(_ key: String, in text: String) -> String? {
  let pattern = "(?i:^\\s*SET\\s+" + key + #"\s+)"[a-z]{2}[A-Z]{2}"\s*$"#
  return text.components(separatedBy: .newlines).reversed().first {
    $0.range(of: pattern, options: .regularExpression) != nil
  }?.components(separatedBy: "\"")[1]
}

private func buildLocale(_ key: String, for cl: Client) -> String? {
  let url = cl.wowFolder.appendingPathComponent(".build.info")
  guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
  let rows = text.components(separatedBy: .newlines).map {
    $0.components(separatedBy: "|")
  }
  guard let first = rows.first else { return nil }
  let header = first.map { $0.components(separatedBy: "!")[0] }
  guard let product = header.firstIndex(of: "Product"),
        let tags = header.firstIndex(of: "Tags") else { return nil }
  let active = header.firstIndex(of: "Active")
  let row = rows.dropFirst().first { fields in
    guard fields.count == header.count, fields[product] == "wowf" else { return false }
    if let active { return fields[active] == "1" }
    return true
  }
  guard let row else { return nil }
  let flag = key == "textLocale" ? "text?" : "speech?"
  for tag in row[tags].components(separatedBy: ":") {
    let words = tag.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    if words.contains(flag), let locale = words.first(where: {
      $0.range(of: #"^[a-z]{2}[A-Z]{2}$"#, options: .regularExpression) != nil
    }) { return locale }
  }
  return nil
}

// Retain private settings and seed locales before first run: the region picker overwrites portal.
func privateConfiguration(_ cl: Client) throws -> String {
  let fm = FileManager.default
  let config = cl.privateProduct.appendingPathComponent("WTF/" + C.configName)
  let legacy = cl.wowFolder.appendingPathComponent("_classic_beta_\(C.id)_/WTF/" + C.configName)
  let existing = fm.fileExists(atPath: config.path)
    ? try String(contentsOf: config, encoding: .utf8)
    : ((try? String(contentsOf: legacy, encoding: .utf8)) ?? "")
  var lines = existing.components(separatedBy: .newlines).filter {
    !$0.isEmpty && $0.range(of: #"^\s*SET\s+(portal|textLocale|audioLocale)\b"#,
                            options: [.regularExpression, .caseInsensitive]) == nil
  }
  let official = cl.officialProduct.appendingPathComponent("WTF/Config.wtf")
  let defaults = (try? String(contentsOf: official, encoding: .utf8)) ?? ""
  for key in ["textLocale", "audioLocale"] {
    let locale = configuredLocale(key, in: existing) ?? configuredLocale(key, in: defaults)
      ?? buildLocale(key, for: cl) ?? "enUS"
    lines.append("SET \(key) \"\(locale)\"")
  }
  lines.append("SET portal \"\(C.portalLine)\"")
  return lines.joined(separator: "\n") + "\n"
}

// Write only private settings and launch the copy with its private configuration.

func launchClient(_ cl: Client, serverIP: String, resolverLibrary: URL,
                  log: (String) -> Void) throws -> (process: Process, guardLog: ConnectionGuard) {
    try assertPrivateIsolated(cl)
    if anotherWowRunning() {
        throw CopyError.message("a WoW client is already running. Quit it first: both clients share the game data folder.")
    }
    guard isIPv4(serverIP) else { throw CopyError.message("invalid realm IPv4 address") }
    let libraryCheck = run("/usr/bin/codesign", ["--verify", "--strict", resolverLibrary.path])
    guard libraryCheck.code == 0 else {
      throw CopyError.message("private DNS library failed signature verification: \(libraryCheck.out)")
    }
    let wtf = cl.privateProduct.appendingPathComponent("WTF")
    try FileManager.default.createDirectory(at: wtf, withIntermediateDirectories: true)
    let config = wtf.appendingPathComponent(C.configName)
    try Data(privateConfiguration(cl).utf8).write(to: config, options: .atomic)
    log("wrote \(C.configName): portal \(C.portalLine)")

    let game = Process()
    game.executableURL = cl.privateBinary
    game.currentDirectoryURL = cl.privateProduct
    game.arguments = ["-config", C.configName]
    var environment = ProcessInfo.processInfo.environment
    environment["DYLD_INSERT_LIBRARIES"] = resolverLibrary.path
    environment["FOREVER_SERVER_IPV4"] = serverIP
    environment["FOREVER_PRIVATE_EXECUTABLE"] = realPath(cl.privateBinary)
    game.environment = environment
    let logs = cl.privateProduct.appendingPathComponent("Logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let connectionURL = logs.appendingPathComponent("Connection.log")
    let connectionFile = try ConnectionGuard.prepare(connectionURL)
    let outputURL = logs.appendingPathComponent("launcher-client.log")
    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
      throw CopyError.message("cannot create the private client log")
    }
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    game.standardOutput = output
    game.standardError = output
    try game.run()
    let guardLog: ConnectionGuard
    do {
      guardLog = try ConnectionGuard(game: game, file: connectionFile, url: connectionURL)
    } catch {
      if game.isRunning { game.terminate() }
      game.waitUntilExit()
      throw error
    }
    log("client launched, pid \(game.processIdentifier)")
    return (game, guardLog)
}
