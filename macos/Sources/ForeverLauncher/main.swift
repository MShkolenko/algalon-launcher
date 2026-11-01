// main.swift - the Forever launcher for macOS. See README.md.
//
// Prepares and verifies a separate client, configures scoped user certificate trust, then launches
// with a process-local DNS override and patches the realm key after Login. SIP stays enabled.
import AppKit
import Darwin
import Foundation

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

Task { @MainActor in
  let session: (process: Process, guardLog: ConnectionGuard, exited: AsyncStream<Void>,
                input: LoginInputChannel?)
  var loginForLaunch: SavedLogin?
  switch await chooseSavedLogin(service: "com.algaloncore.launcher.login.\(C.id).\(C.hostName)",
                         realm: C.longName) {
  case .fill(let login):
      switch await automaticLoginPermissions(log: log) {
      case .automatic:
          log("automatic filling selected")
          loginForLaunch = login
      case .manual:
          log("manual filling selected after permission check")
          break
      case .cancel:
          log("cancelled at permission check")
          exit(0)
      }
  case .manual:
      log("manual login selected")
      break
  case .cancel:
      log("login cancelled")
      exit(0)
  }
  do {
      let library = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Frameworks/libRealmDNS.dylib")
      session = try launchClient(client, serverIP: ip, resolverLibrary: library,
        automaticInput: loginForLaunch != nil, log: log)
  } catch { fail("Launching the client failed: \(error)") }

  let game = session.process
  let keys: RegionKeyMonitor
  do {
    keys = try RegionKeyMonitor(game: game, executable: realPath(client.privateBinary),
                               log: { message in log(message) })
    log("region-key monitoring started independently of automatic filling")
  } catch { fail("Region-key monitoring could not start; check the launcher profile.") }
  if loginForLaunch == nil,
    let running = NSRunningApplication(processIdentifier: game.processIdentifier) {
    if #available(macOS 14, *) { NSApplication.shared.yieldActivation(to: running) }
    _ = running.activate(options: .activateAllWindows)
    NSApplication.shared.hide(nil)
  }
  if let login = loginForLaunch {
      do {
          guard let input = session.input else { throw AutomaticLoginError.input }
          try await input.start()
          log("native input channel handshake acknowledged")
          try await fillPrivateLogin(login, pid: game.processIdentifier,
            executable: realPath(client.privateBinary), channel: input, log: log)
          log("automatic login fields filled; Log In remains an explicit action")
      } catch {
        session.input?.abort()
        let reason = (error as? AutomaticLoginError)?.rawValue ?? "native capture error"
        log("automatic login filling did not complete (\(reason)); saved entry retained")
        if game.isRunning {
          NSApplication.shared.unhide(nil)
          NSApplication.shared.activate(ignoringOtherApps: true)
          let alert = NSAlert()
          alert.messageText = "Automatic filling stopped"
          alert.informativeText = "The saved login was retained. Fields may be partially filled. "
            + "Review both fields before Log In. Details are in the launcher log."
          _ = await presentLoginAlert(alert)
          NSApplication.shared.hide(nil)
        }
      }
  }
  loginForLaunch = nil
  NSApplication.shared.hide(nil)
  // Native exit notification keeps the UI/taps responsive without an idle polling loop.
  for await _ in session.exited {}
  game.waitUntilExit()
  let outcome = await keys.finish()
  log("client exited")
  if outcome.failure != nil {
    fail("Region-key monitoring failed. Check the launcher log for the reason.")
  }
  if session.guardLog.finish() {
      fail("Stopped the private client: its login endpoint changed or the fresh connection log "
        + "could not be monitored. Check the private portal before retrying.")
  }
  if !outcome.confirmed {
      log("client exited without a completed realm login; no region-key installation confirmed")
  }
  if game.terminationReason != .exit || game.terminationStatus != 0 {
      fail("The private client exited abnormally. Check its Connection.log and crash report.")
  }
  log("done")

  exit(0)
}
NSApplication.shared.run()
