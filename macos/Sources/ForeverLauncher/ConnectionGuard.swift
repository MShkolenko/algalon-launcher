import Darwin
import Foundation

// All mutable state and file access are confined to queue; finish synchronously joins the last tick.
final class ConnectionGuard {
  private let queue = DispatchQueue(label: "org.forever.connection-guard")
  private let timer: DispatchSourceTimer
  private let game: Process
  private let file: FileHandle
  private let url: URL
  private let device: dev_t
  private let inode: ino_t
  private var pending = Data()
  private var offset: Int64 = 0
  private var stopped = false
  private var blocked = false

  static func prepare(_ url: URL) throws -> FileHandle {
    let fm = FileManager.default
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fm.fileExists(atPath: url.path) {
      let previous = url.deletingLastPathComponent().appendingPathComponent("Previous")
      try fm.createDirectory(at: previous, withIntermediateDirectories: true)
      try fm.moveItem(at: url, to: previous.appendingPathComponent(
        "Connection.\(UUID().uuidString).log"))
    }
    let descriptor = open(url.path, O_CREAT | O_EXCL | O_NOFOLLOW | O_RDONLY, 0o600)
    guard descriptor >= 0 else { throw CopyError.message("cannot create a fresh connection log") }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  init(game: Process, file: FileHandle, url: URL) throws {
    var info = stat()
    guard fstat(file.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_nlink == 1 else {
      throw CopyError.message("connection log must be a separate regular file")
    }
    self.game = game
    self.file = file
    self.url = url
    device = info.st_dev
    inode = info.st_ino
    timer = DispatchSource.makeTimerSource(queue: queue)
    timer.setEventHandler { [weak self] in self?.check() }
    timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
    timer.resume()
  }

  private func check() {
    guard !stopped, game.isRunning else { return }
    do {
      var info = stat()
      guard lstat(url.path, &info) == 0, info.st_dev == device, info.st_ino == inode,
            info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
        throw CopyError.message("connection log replaced")
      }
      if info.st_size < offset {
        try file.seek(toOffset: 0)
        offset = 0
        pending.removeAll(keepingCapacity: true)
      }
      let bytes = try file.read(upToCount: 65_536) ?? Data()
      offset += Int64(bytes.count)
      pending.append(bytes)
      while let newline = pending.firstIndex(of: 10) {
        let line = pending[..<newline]
        guard line.count <= 8192, let text = String(data: line, encoding: .utf8) else {
          throw CopyError.message("invalid connection log line")
        }
        pending.removeSubrange(...newline)
        if text.contains("Battle.net logon requested") {
          let expected = "Battle.net logon requested host=\"\(C.hostName)\" port=\"1120\""
          guard text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasSuffix(expected.lowercased()) else {
            throw CopyError.message("unexpected login endpoint")
          }
        }
      }
      guard pending.count <= 8192 else { throw CopyError.message("connection log line too long") }
    } catch {
      blocked = true
      stopped = true
      // shortcut: log monitoring reacts after an endpoint is logged; this is not a network firewall.
      var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
      if game.isRunning, let executable = game.executableURL,
         proc_pidpath(game.processIdentifier, &path, UInt32(path.count)) > 0,
         realPath(URL(fileURLWithPath: String(cString: path))) == realPath(executable) {
        // WoW handles SIGTERM without exiting; an endpoint violation must stop the owned child.
        kill(game.processIdentifier, SIGKILL)
      }
    }
  }

  func finish() -> Bool {
    queue.sync {
      stopped = true
      timer.cancel()
      try? file.close()
      return blocked
    }
  }
}
