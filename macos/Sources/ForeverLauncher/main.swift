// main.swift - the Forever launcher for macOS. See README.md.
//
// Prepares and verifies a separate client, configures scoped user certificate trust, then launches
// with a process-local DNS override and patches the realm key after Login. SIP stays enabled.
import Foundation
import Darwin
import MachKeyStore

// ---- logging ----------------------------------------------------------------------------------------
let logURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/\(C.longName)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("launcher.log")
}()
let logHandle: FileHandle? = {
    // The old and new process overlap during activation; separate seek offsets lose log lines.
    let descriptor = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return nil }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == getuid(), status.st_nlink == 1 else {
        close(descriptor)
        return nil
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
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
let updateAttempt = UpdateAttempt(arguments: CommandLine.arguments)
guard CommandLine.arguments.count == 1 || updateAttempt != nil else {
    fail("Invalid launcher update arguments.")
}

log("\(C.longName) launcher starting")
let launcherLock: LauncherLock
let launcherApp = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
do {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/\(C.longName)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    guard directory.resolvingSymlinksInPath().path == directory.path else {
        throw UpdateError.installation
    }
    launcherLock = try LauncherLock(url: directory.appendingPathComponent("launcher.lock"))
    guard launcherLock.acquire() else {
        log("another launcher is already running")
        exit(0)
    }
    if let updateAttempt {
        guard logHandle != nil else { throw UpdateError.installation }
        try acceptLauncherUpdate(updateAttempt, app: launcherApp)
        log("launcher update activation completed")
    } else {
        do {
            if try checkLauncherUpdate(app: launcherApp, lock: launcherLock, log: log) { exit(0) }
        } catch UpdateError.recovery {
            fail("Automatic launcher recovery could not finish. Close other launchers and rename "
              + "\(launcherApp.path).old back to \(launcherApp.lastPathComponent). "
              + "The retained launcher was not deleted.")
        } catch {
            log("no verified launcher update available; continuing with this version")
        }
    }
} catch {
    fail("Launcher startup or update activation failed. Any retained .old launcher was preserved.")
}
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
