import Darwin
import Foundation
import MachKeyStore

enum RegionKeyError: Error { case configuration, write, target }

struct RegionKeyOutcome: Sendable {
  var confirmed = false
  var failure: RegionKeyError?
}

// All mutable state is confined to this queue, also serializing the C scanner's reused buffer.
final class RegionKeyMonitor: @unchecked Sendable {
  private static let queue = DispatchQueue(label: "org.forever.region-key")
  private let timer: DispatchSourceTimer
  private let game: Process
  private let executable: String
  private let log: @Sendable (String) -> Void
  private let known: [UInt8]
  private let replacement: [UInt8]
  private var task = task_t()
  private var warnedAttach = false
  private var outcome = RegionKeyOutcome()
  private var stopped = false

  init(game: Process, executable: String, log: @escaping @Sendable (String) -> Void) throws {
    let keys = C.knownHex.compactMap { hexToBytes($0, 32) }
    guard keys.count == 12, C.flags.count == 12, (1...12).contains(C.group),
      let replacement = hexToBytes(C.newKeyHex, 32) else {
      throw RegionKeyError.configuration
    }
    self.game = game
    self.executable = executable
    self.log = log
    known = keys.flatMap { $0 }
    self.replacement = replacement
    timer = DispatchSource.makeTimerSource(queue: Self.queue)
    timer.setEventHandler { [weak self] in self?.check() }
    timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(25))
    timer.resume()
  }

  private enum TargetState { case matching, exited, changed }

  private func targetState() -> TargetState {
    guard game.isRunning else { return .exited }
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    errno = 0
    guard proc_pidpath(game.processIdentifier, &path, UInt32(path.count)) > 0 else {
      // The process can disappear before Foundation delivers its termination notification.
      return errno == ESRCH || !game.isRunning ? .exited : .changed
    }
    return realPath(URL(fileURLWithPath: String(cString: path))) == executable
      ? .matching : .changed
  }

  private func check() {
    guard !stopped else { return }
    switch targetState() {
    case .matching: break
    case .exited:
      endedWithClient()
      return
    case .changed: stop(.target); return
    }
    if task == MACH_PORT_NULL {
      let result = ks_task_for_pid(game.processIdentifier, &task)
      if result == KERN_SUCCESS { log("attached to client task") }
      else {
        if !warnedAttach {
          log("task_for_pid not yet granted (kr=\(result)); allow the macOS developer-tools prompt")
          warnedAttach = true
        }
        return
      }
    }
    var result = ks_result()
    known.withUnsafeBufferPointer { keys in
      C.flags.withUnsafeBufferPointer { flags in
        replacement.withUnsafeBufferPointer { value in
          ks_scan_and_patch(task, keys.baseAddress, flags.baseAddress, value.baseAddress,
                            Int32(C.group), &result)
        }
      }
    }
    if result.write_errors > 0 {
      if targetState() == .exited { endedWithClient(after: .write) }
      else { stop(.write) }
      return
    }
    if result.patched_now > 0 {
      log("patched \(result.patched_now) key store(s) to the server key (sweep completed)")
      outcome.confirmed = true
    } else if result.already_patched > 0 && !outcome.confirmed {
      log("key store already carries the server key")
      outcome.confirmed = true
    }
    if outcome.confirmed {
      timer.schedule(deadline: .now() + .seconds(3), repeating: .seconds(3),
                     leeway: .milliseconds(100))
    }
  }

  private func stop(_ failure: RegionKeyError) {
    if targetState() == .exited { endedWithClient(after: failure); return }
    log("region-key monitoring failure: \(failure)")
    outcome.failure = failure
    stopped = true
    timer.cancel()
    // A failed validated write cannot leave this owned client attempting an unpatched realm login.
    if targetState() == .matching { kill(game.processIdentifier, SIGKILL) }
  }

  private func endedWithClient(after failure: RegionKeyError? = nil) {
    log("region-key monitoring ended with client exit"
      + (failure.map { " after \($0)" } ?? ""))
    stopped = true
    timer.cancel()
  }

  func finish() async -> RegionKeyOutcome {
    await withCheckedContinuation { continuation in
      Self.queue.async {
        self.stopped = true
        self.timer.cancel()
        if self.task != MACH_PORT_NULL {
          mach_port_deallocate(mach_task_self_, self.task)
          self.task = 0
        }
        continuation.resume(returning: self.outcome)
      }
    }
  }
}
