// main.swift - the Forever launcher for macOS. See README.md.
//
// Prepares and verifies a separate client, configures scoped user certificate trust, then launches
// with a process-local DNS override and patches the realm key after Login. SIP stays enabled.
import Foundation
import MachKeyStore

// ---- logging ----------------------------------------------------------------------------------------
let logURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/\(C.longName)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("launcher.log")
}()
let logHandle: FileHandle? = {
    if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }
    let h = try? FileHandle(forWritingTo: logURL)
    _ = try? h?.seekToEnd()
    return h
}()
func log(_ s: String) {
    let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
    let line = "\(df.string(from: Date())) \(s)\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
    logHandle?.write(line.data(using: .utf8)!)
}

func dialog(_ message: String) {
    // a plain error dialog, like the Windows MessageBox; best-effort
    run("/usr/bin/osascript",
        ["-e", "display dialog \"\(message.replacingOccurrences(of: "\"", with: "'"))\" with title \"\(C.name) launcher\" buttons {\"OK\"} with icon stop"])
}

func fail(_ message: String) -> Never {
    log("ERROR: \(message)")
    dialog("\(message)\n\nDetails: \(logURL.path)")
    exit(1)
}

// ---- the runtime key patch loop ---------------------------------------------------------------------
// Returns true once the server key is confirmed in the client's key store. Scans every 500 ms until then
// (the store appears after Login), then every 3 s to re-patch if the client rebuilds it, as the Windows
// launcher does. A write that fails against a located store is a hard error.
func patchLoop(pid: Int32, game: Process) -> Bool {
    var knownFlat = [UInt8]()
    for hex in C.knownHex {
        guard let b = hexToBytes(hex, 32) else { fail("bad known key constant") }
        knownFlat += b
    }
    let flags = C.flags
    guard let newkey = hexToBytes(C.newKeyHex, 32) else { fail("bad server key constant") }

    var task = task_t()
    var haveTask = false
    var confirmed = false
    var warnedAttach = false
    var heartbeat = 0

    while game.isRunning {
        if !haveTask {
            let kr = ks_task_for_pid(pid, &task)
            if kr == KERN_SUCCESS {
                haveTask = true
                log("attached to client task")
            } else if !warnedAttach {
                warnedAttach = true
                log("task_for_pid not yet granted (kr=\(kr)); if macOS shows a developer-tools prompt, allow it")
            }
        }
        if haveTask {
            var res = ks_result()
            knownFlat.withUnsafeBufferPointer { kp in
                flags.withUnsafeBufferPointer { fp in
                    newkey.withUnsafeBufferPointer { np in
                        ks_scan_and_patch(task, kp.baseAddress, fp.baseAddress, np.baseAddress, Int32(C.group), &res)
                    }
                }
            }
            if res.write_errors > 0 {
                fail("A key store was found but could not be patched (\(res.write_errors) write error(s)). The client was left running; quit it and retry.")
            }
            if res.patched_now > 0 {
                log("patched \(res.patched_now) key store(s) to the server key")
                confirmed = true
            } else if res.already_patched > 0 && !confirmed {
                log("key store already carries the server key")
                confirmed = true
            }
        }
        heartbeat += 1
        if heartbeat % 60 == 0 { log("running; key installed=\(confirmed)") }
        usleep(confirmed ? 3_000_000 : 500_000)
    }
    log("client exited")
    return confirmed
}

// ---- entry ------------------------------------------------------------------------------------------
guard geteuid() != 0 else { fail("Run the launcher as your normal macOS user.") }
guard CommandLine.arguments.count == 1 else { fail("This launcher accepts no command-line options.") }

log("\(C.longName) launcher starting")
guard let client = locateClient() else {
    fail("Could not find the WoW client.\nExpected \(C.officialProduct)/\(C.appName) under /Applications/World of Warcraft (or set FOREVER_WOW).")
}
log("client at \(client.wowFolder.path)")

guard let ip = resolveServerIPv4() else { fail("Could not resolve \(C.server). Check your internet connection.") }
log("\(C.server) -> \(ip)")

do {
    try ensurePrivateCopy(client, log: log)
} catch { fail("Preparing the private client copy failed: \(error)") }

if setupNeeded() {
    log("requesting user certificate trust for \(C.hostName)")
    do { try installCA() } catch { fail("Certificate setup failed: \(error)") }
    if setupNeeded() { fail("Certificate trust was not saved. Check the macOS confirmation.") }
} else {
    log("realm CA already in place; DNS override is private to this client")
}

let session: (process: Process, guardLog: ConnectionGuard)
do {
    let library = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Frameworks/libRealmDNS.dylib")
    session = try launchClient(client, serverIP: ip, resolverLibrary: library, log: log)
} catch { fail("Launching the client failed: \(error)") }

let game = session.process
let patched = patchLoop(pid: game.processIdentifier, game: game)
game.waitUntilExit()
if session.guardLog.finish() {
    fail("Stopped the private client: its login endpoint changed or the fresh connection log "
      + "could not be monitored. Check the private portal before retrying.")
}
if !patched {
    fail("The client exited without a confirmed region-key installation. "
      + "A failed login ends before the realm-key stage; this message alone does not establish "
      + "key-table incompatibility. Check the private client's Connection.log for the first error.")
}
log("done")
