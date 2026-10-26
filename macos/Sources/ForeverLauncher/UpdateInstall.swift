import Darwin
import Foundation
import Security

// These helpers operate only on this user's launcher files, never on the game or system trust.
func updateFileExists(_ url: URL) -> Bool {
  var status = stat()
  return lstat(url.path, &status) == 0
}

func updateRegularFile(_ url: URL, maximum: Int) throws -> Data {
  let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
  guard descriptor >= 0 else { throw UpdateError.installation }
  defer { close(descriptor) }
  var status = stat()
  guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
    status.st_uid == getuid(), status.st_nlink == 1, status.st_size >= 0,
    status.st_size <= maximum else { throw UpdateError.installation }
  let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
  let data = try handle.read(upToCount: maximum + 1) ?? Data()
  guard data.count <= maximum else { throw UpdateError.installation }
  return data
}

func writeUpdateFile(_ data: Data, to url: URL) throws {
  let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
  guard descriptor >= 0 else { throw UpdateError.installation }
  defer { close(descriptor) }
  do {
    try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
    guard fsync(descriptor) == 0 else { throw UpdateError.installation }
  } catch {
    unlink(url.path)
    throw error
  }
}

final class LauncherLock {
  private let descriptor: Int32
  private(set) var held = false

  init(url: URL) throws {
    descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw UpdateError.installation }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == getuid(), status.st_nlink == 1 else {
      close(descriptor)
      throw UpdateError.installation
    }
  }

  func acquire() -> Bool {
    if held { return true }
    held = flock(descriptor, LOCK_EX | LOCK_NB) == 0
    return held
  }

  func release() {
    if held { flock(descriptor, LOCK_UN) }
    held = false
  }

  deinit { close(descriptor) }
}

struct UpdateBundleIdentity: Equatable {
  let identifier: String
  let certificate: Data?
}

func checkedUpdateBundle(_ app: URL) throws -> (UpdateBundleIdentity, String, URL) {
  try validateExtractedUpdate(app)
  var code: SecStaticCode?
  guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
    throw UpdateError.installation
  }
  let flags = SecCSFlags(
    rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
  )
  guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
    throw UpdateError.installation
  }
  var information: CFDictionary?
  guard SecCodeCopySigningInformation(
    code, SecCSFlags(rawValue: kSecCSSigningInformation), &information
  ) == errSecSuccess, let information = information as? [String: Any],
    let identifier = information[kSecCodeInfoIdentifier as String] as? String,
    let dictionary = try PropertyListSerialization.propertyList(
      from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil
    ) as? [String: Any], dictionary["CFBundleIdentifier"] as? String == identifier,
    let version = dictionary["CFBundleShortVersionString"] as? String,
    let executable = dictionary["CFBundleExecutable"] as? String,
    !executable.isEmpty, executable != ".", executable != "..",
    !executable.contains("/"), !executable.contains("\\") else { throw UpdateError.installation }
  let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
  let certificate = certificates.first.map { SecCertificateCopyData($0) as Data }
  let signatureFlags = (information[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
  guard certificate != nil || signatureFlags & SecCodeSignatureFlags.adhoc.rawValue != 0 else {
    throw UpdateError.installation
  }
  let binary = app.appendingPathComponent("Contents/MacOS/" + executable)
  guard binary.resolvingSymlinksInPath().path.hasPrefix(app.path + "/"),
    FileManager.default.isExecutableFile(atPath: binary.path) else {
    throw UpdateError.installation
  }
  return (UpdateBundleIdentity(identifier: identifier, certificate: certificate), version, binary)
}

struct UpdateAttempt {
  let parent: Int32
  let token: String

  init?(arguments: [String]) {
    guard arguments.count == 5, arguments[1] == "--updated-from",
      let parent = Int32(arguments[2]), parent > 1,
      arguments[3] == "--update-token", arguments[4].utf8.count == 32,
      arguments[4].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      return nil
    }
    self.parent = parent
    token = arguments[4]
  }

  func signal(_ app: URL, _ phase: String) -> URL {
    URL(fileURLWithPath: app.path + "." + phase + "-" + token)
  }

  func hasSignal(_ app: URL, _ phase: String) -> Bool {
    (try? updateRegularFile(signal(app, phase), maximum: 32)) == Data(token.utf8)
  }
}

// Called after opening the log and taking the lock, before any game-copy work or user prompts.
func acceptLauncherUpdate(_ attempt: UpdateAttempt, app: URL) throws {
  guard getppid() == attempt.parent else { throw UpdateError.installation }
  let old = URL(fileURLWithPath: app.path + ".old")
  let current = try checkedUpdateBundle(app)
  guard try checkedUpdateBundle(old).0 == current.0 else { throw UpdateError.installation }
  let ready = attempt.signal(app, "started")
  defer { try? FileManager.default.removeItem(at: ready) }
  try writeUpdateFile(Data(attempt.token.utf8), to: ready)
  let deadline = ProcessInfo.processInfo.systemUptime + 35
  while !attempt.hasSignal(app, "accepted") {
    guard ProcessInfo.processInfo.systemUptime < deadline, kill(attempt.parent, 0) == 0 else {
      throw UpdateError.installation
    }
    usleep(50_000)
  }
  // A late ready alone never authorizes deletion; the parent must accept, then actually exit.
  let exitDeadline = ProcessInfo.processInfo.systemUptime + 15
  while kill(attempt.parent, 0) == 0 {
    guard ProcessInfo.processInfo.systemUptime < exitDeadline else {
      throw UpdateError.installation
    }
    usleep(50_000)
  }
  guard errno == ESRCH, try checkedUpdateBundle(old).0 == current.0 else {
    throw UpdateError.installation
  }
  try FileManager.default.removeItem(at: old)
  try? FileManager.default.removeItem(at: attempt.signal(app, "accepted"))
}

// Returns true only after handing over. The caller must immediately exit in that case.
func activateLauncherUpdate(
  staged: URL, app: URL, release: UpdateRelease, lock: LauncherLock, log: (String) -> Void
) throws -> Bool {
  let manager = FileManager.default
  let old = URL(fileURLWithPath: app.path + ".old")
  let bad = URL(fileURLWithPath: app.path + ".bad")
  let badHash = URL(fileURLWithPath: app.path + ".bad.sha256")
  guard lock.held, !updateFileExists(old), app.path.hasSuffix(".app") else {
    throw UpdateError.installation
  }
  let current = try checkedUpdateBundle(app)
  let candidate = try checkedUpdateBundle(staged)
  guard current.0 == candidate.0, candidate.1 == release.version else {
    throw UpdateError.installation
  }
  var currentStatus = stat()
  var stagedStatus = stat()
  guard stat(app.path, &currentStatus) == 0, stat(staged.path, &stagedStatus) == 0,
    currentStatus.st_uid == getuid(), stagedStatus.st_uid == getuid(),
    currentStatus.st_dev == stagedStatus.st_dev else { throw UpdateError.installation }
  let files = try manager.contentsOfDirectory(
    at: app.deletingLastPathComponent(), includingPropertiesForKeys: nil
  )
  for file in files where file.lastPathComponent.hasPrefix(app.lastPathComponent + ".started-")
    || file.lastPathComponent.hasPrefix(app.lastPathComponent + ".accepted-") {
    _ = try updateRegularFile(file, maximum: 32)
    try manager.removeItem(at: file)
  }
  var random = [UInt8](repeating: 0, count: 16)
  guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
    throw UpdateError.installation
  }
  let token = random.map { String(format: "%02x", $0) }.joined()
  let arguments = ["--updated-from", String(getpid()), "--update-token", token]
  guard let attempt = UpdateAttempt(arguments: ["launcher"] + arguments) else {
    throw UpdateError.installation
  }
  defer {
    try? manager.removeItem(at: attempt.signal(app, "started"))
    // On success the accepted signal belongs to the child until it sees the parent exit.
  }
  try manager.moveItem(at: app, to: old)
  do { try manager.moveItem(at: staged, to: app) } catch {
    do { try manager.moveItem(at: old, to: app) } catch { throw UpdateError.recovery }
    throw UpdateError.installation
  }
  let child = Process()
  child.executableURL = app.appendingPathComponent(
    "Contents/MacOS/" + candidate.2.lastPathComponent
  )
  child.arguments = arguments
  lock.release()
  var started = false
  do {
    try child.run()
    started = true
    let deadline = ProcessInfo.processInfo.systemUptime + 30
    while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
      if attempt.hasSignal(app, "started") {
        try writeUpdateFile(Data(token.utf8), to: attempt.signal(app, "accepted"))
        log("launcher update accepted; handing over")
        return true
      }
      usleep(50_000)
    }
  } catch {
    log("updated launcher could not confirm startup")
  }
  if child.isRunning {
    // Only the Process launched above is ever signalled. Stop it before changing either bundle.
    kill(child.processIdentifier, SIGKILL)
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
    guard !child.isRunning else { throw UpdateError.recovery }
  }
  if started { child.waitUntilExit() }
  guard lock.acquire() else { throw UpdateError.recovery }
  do {
    if updateFileExists(bad) {
      guard try checkedUpdateBundle(bad).0 == current.0 else { throw UpdateError.recovery }
      try manager.removeItem(at: bad)
    }
    try manager.moveItem(at: app, to: bad)
    try manager.moveItem(at: old, to: app)
  } catch { throw UpdateError.recovery }
  // A bundle hash differs from the ZIP; retain the authenticated archive identity.
  if updateFileExists(badHash) {
    _ = try updateRegularFile(badHash, maximum: 64)
    try manager.removeItem(at: badHash)
  }
  try writeUpdateFile(Data(release.sha256.utf8), to: badHash)
  log("launcher update rolled back; failed archive will not be retried")
  return false
}
