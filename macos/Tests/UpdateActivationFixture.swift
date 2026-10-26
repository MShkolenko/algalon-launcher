import Darwin
import Foundation

@main
struct UpdateActivationFixture {
  static func main() throws {
    let arguments = CommandLine.arguments
    if let attempt = UpdateAttempt(arguments: arguments) {
      let app = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
      let folder = app.deletingLastPathComponent()
      let behavior = Bundle.main.object(forInfoDictionaryKey: "FixtureBehavior") as? String
      if behavior == "crash" { exit(23) }
      if behavior == "hang" {
        sleep(40)
        exit(33)
      }
      let lock = try LauncherLock(url: folder.appendingPathComponent("fixture.lock"))
      guard lock.acquire() else { exit(24) }
      // The production handshake runs only after a real log and real lock have opened.
      let log = try FileHandle(forWritingTo: folder.appendingPathComponent("fixture.log"))
      defer { try? log.close() }
      do {
        try acceptLauncherUpdate(attempt, app: app)
        try writeUpdateFile(Data("activated".utf8), to: folder.appendingPathComponent("activated"))
      } catch {
        try writeUpdateFile(Data("refused".utf8), to: folder.appendingPathComponent("refused"))
        exit(25)
      }
      return
    }
    guard arguments.count == 3 else { exit(26) }
    let folder = URL(fileURLWithPath: arguments[2], isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    let app = folder.appendingPathComponent("Fixture.app")
    let staged = folder.appendingPathComponent("new/Fixture.app")
    let lock = try LauncherLock(url: folder.appendingPathComponent("fixture.lock"))
    guard lock.acquire() else { exit(27) }
    if arguments[1] == "no-accept" {
      // Independently reproduce the owner's late-ready hazard: no parent acceptance is sent.
      let token = String(repeating: "a", count: 32)
      let child = Process()
      child.executableURL = app.appendingPathComponent("Contents/MacOS/Fixture")
      child.arguments = ["--updated-from", String(getpid()), "--update-token", token]
      lock.release()
      try child.run()
      let ready = URL(fileURLWithPath: app.path + ".started-" + token)
      let deadline = ProcessInfo.processInfo.systemUptime + 5
      while !updateFileExists(ready) {
        guard child.isRunning, ProcessInfo.processInfo.systemUptime < deadline else { exit(28) }
        usleep(10_000)
      }
      // Leave the complete .old in place; the child must refuse cleanup after this parent exits.
      exit(0)
    }
    let release = UpdateRelease(
      version: "1.0.4",
      url: URL(string: "https://github.com/example/example/releases/download/v1/a.zip")!,
      sha256: String(repeating: "a", count: 64), size: 1
    )
    do {
      let result = try activateLauncherUpdate(
        staged: staged, app: app, release: release, lock: lock, log: { _ in }
      )
      if arguments[1] == "success" {
        guard result, !lock.held else { exit(29) }
        exit(0)
      }
      guard ["crash", "hang"].contains(arguments[1]), !result, lock.held else { exit(30) }
      guard try checkedUpdateBundle(app).1 == "1.0.3",
        try checkedUpdateBundle(URL(fileURLWithPath: app.path + ".bad")).1 == "1.0.4",
        try updateRegularFile(URL(fileURLWithPath: app.path + ".bad.sha256"), maximum: 64)
          == Data(release.sha256.utf8), !updateFileExists(URL(fileURLWithPath: app.path + ".old"))
      else { exit(31) }
      print("PASS: failed native child restores the previous app and persists the failed ZIP hash")
    } catch UpdateError.installation {
      guard ["reject", "retained-old"].contains(arguments[1]),
        updateFileExists(app), updateFileExists(staged),
        updateFileExists(URL(fileURLWithPath: app.path + ".old"))
          == (arguments[1] == "retained-old") else { exit(32) }
      print("PASS: bundle validation refused activation before any rename")
    }
  }
}
