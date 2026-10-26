import CryptoKit
import Darwin
import Foundation

// URLSession owns DNS, proxies and TLS. Every mutable delegate field is protected by condition.
private final class UpdateDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let condition = NSCondition()
  private let maximum: Int
  private var bytes = Data()
  private var responded = false
  private var complete = false
  private var failed = false

  init(maximum: Int) { self.maximum = maximum }

  func fetch(_ url: URL, timeout: TimeInterval) throws -> Data {
    guard url.scheme == "https", url.user == nil, url.password == nil else {
      throw UpdateError.download
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = timeout
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: url)
    let started = ProcessInfo.processInfo.systemUptime
    task.resume()
    condition.lock()
    defer { condition.unlock() }
    while !complete && !failed {
      let elapsed = ProcessInfo.processInfo.systemUptime - started
      // Requiring response headers within five seconds is stricter than the connect-only bound.
      let remaining = min(timeout - elapsed, responded ? timeout : 5 - elapsed)
      guard remaining > 0 else { throw UpdateError.download }
      _ = condition.wait(until: Date(timeIntervalSinceNow: min(remaining, 0.25)))
    }
    guard complete, !failed else { throw UpdateError.download }
    return bytes
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    let secure = request.url?.scheme == "https" && request.url?.user == nil
      && request.url?.password == nil
    completionHandler(secure ? request : nil)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    condition.lock()
    responded = true
    let valid = (response as? HTTPURLResponse)?.statusCode == 200
      && response.url?.scheme == "https" && response.expectedContentLength <= maximum
    failed = !valid
    condition.broadcast()
    condition.unlock()
    completionHandler(valid ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    condition.lock()
    if data.count > maximum - bytes.count {
      failed = true
    } else if !failed {
      bytes.append(data)
    }
    condition.broadcast()
    let cancel = failed
    condition.unlock()
    if cancel { dataTask.cancel() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    condition.lock()
    failed = failed || error != nil
    complete = true
    condition.broadcast()
    condition.unlock()
  }
}

func fetchUpdateFile(_ url: URL, maximum: Int, timeout: TimeInterval) throws -> Data {
  try UpdateDownload(maximum: maximum).fetch(url, timeout: timeout)
}

func checkLauncherUpdate(app: URL, lock: LauncherLock, log: (String) -> Void) throws -> Bool {
  guard !C.updatePublicKey.isEmpty, !C.updateRepository.isEmpty else { return false }
  let manager = FileManager.default
  if updateFileExists(URL(fileURLWithPath: app.path + ".old")) {
    log("retained .old launcher found; automatic update skipped until manual recovery")
    return false
  }
  let badHash = URL(fileURLWithPath: app.path + ".bad.sha256")
  if updateFileExists(URL(fileURLWithPath: app.path + ".bad")) && !updateFileExists(badHash) {
    log("failed launcher has no archive identity; automatic update skipped until manual recovery")
    return false
  }
  let identity = try checkedUpdateBundle(app)
  let prefix = "https://github.com/\(C.updateRepository)/releases/latest/download/"
  guard let manifestURL = URL(string: prefix + "manifest.json"),
    let signatureURL = URL(string: prefix + "manifest.json.sig") else {
    throw UpdateError.download
  }
  let manifest = try fetchUpdateFile(manifestURL, maximum: 65_536, timeout: 10)
  let signature = try fetchUpdateFile(signatureURL, maximum: 1_024, timeout: 10)
  guard let release = try updateRelease(
    manifest: manifest, signature: signature, realm: C.id, repository: C.updateRepository,
    publicKey: C.updatePublicKey, currentVersion: identity.1
  ) else { return false }
  if updateFileExists(badHash),
    try updateRegularFile(badHash, maximum: 64) == Data(release.sha256.utf8) {
    log("previously failed launcher archive skipped")
    return false
  }
  let stage = app.deletingLastPathComponent()
    .appendingPathComponent(".forever-update-" + UUID().uuidString)
  guard mkdir(stage.path, 0o700) == 0 else { throw UpdateError.installation }
  defer { try? manager.removeItem(at: stage) }
  let archive = stage.appendingPathComponent("update.zip")
  let bytes = try fetchUpdateFile(release.url, maximum: release.size, timeout: 120)
  let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  guard bytes.count == release.size, hash == release.sha256 else { throw UpdateError.download }
  try writeUpdateFile(bytes, to: archive)
  let root = try validatedUpdateArchive(archive)
  let extract = run("/usr/bin/ditto", ["-x", "-k", archive.path, stage.path])
  guard extract.code == 0 else { throw UpdateError.archive }
  return try activateLauncherUpdate(
    staged: stage.appendingPathComponent(root), app: app, release: release, lock: lock, log: log
  )
}
