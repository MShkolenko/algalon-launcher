import AppKit
import CoreGraphics
import Darwin
import Foundation
import Security

// An inherited anonymous socket carries permits, never account/password text.
final class LoginInputChannel: @unchecked Sendable {
  let childInput: FileHandle
  private let descriptor: Int32
  private let nonce: [UInt64]
  private let queue = DispatchQueue(label: "org.forever.input-channel")
  private let lock = NSLock()
  private let source: DispatchSourceRead
  private var bytes: [UInt8] = []
  private var frames: [[UInt64]] = []
  private var waiter: CheckedContinuation<[UInt64], Error>?
  private var waiterID: UInt64 = 0
  private var failed = false
  private var sequence: UInt64 = 0
  private var keysDelivered = 0
  private var clicksDelivered = 0

  init() throws {
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
      throw AutomaticLoginError.input
    }
    var words = [UInt64](repeating: 0, count: 2)
    let random = words.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
    }
    var one: Int32 = 1
    guard random == errSecSuccess, words.contains(where: { $0 != 0 }),
      fcntl(pair[0], F_SETFD, FD_CLOEXEC) == 0,
      fcntl(pair[1], F_SETFD, FD_CLOEXEC) == 0,
      fcntl(pair[0], F_SETFL, O_NONBLOCK) == 0,
      setsockopt(
        pair[0], SOL_SOCKET, SO_NOSIGPIPE, &one,
        socklen_t(MemoryLayout.size(ofValue: one))) == 0
    else {
      close(pair[0])
      close(pair[1])
      throw AutomaticLoginError.input
    }
    nonce = words
    descriptor = pair[0]
    childInput = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
    source = DispatchSource.makeReadSource(fileDescriptor: pair[0], queue: queue)
    let fd = pair[0]
    let closeLock = lock
    source.setCancelHandler {
      closeLock.lock()
      close(fd)
      closeLock.unlock()
    }
    source.setEventHandler { [weak self] in self?.readAvailable() }
    source.resume()
  }

  deinit { abort() }

  func closeChildInput() { try? childInput.close() }

  func check() throws {
    lock.lock()
    let stopped = failed
    lock.unlock()
    guard !stopped else { throw AutomaticLoginError.interrupted }
  }

  func abort() {
    lock.lock()
    guard !failed else {
      lock.unlock()
      return
    }
    failed = true
    let continuation = waiter
    waiter = nil
    frames.removeAll()
    lock.unlock()
    source.cancel()
    continuation?.resume(throwing: AutomaticLoginError.interrupted)
  }

  private func readAvailable() {
    for _ in 0..<8 {
      var chunk = [UInt8](repeating: 0, count: 48)
      let count = recv(descriptor, &chunk, chunk.count, MSG_DONTWAIT)
      if count == 0 {
        abort()
        return
      }
      if count < 0 {
        if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { abort() }
        return
      }
      bytes.append(contentsOf: chunk.prefix(count))
      while bytes.count >= 48 {
        let packet = Array(bytes.prefix(48))
        bytes.removeFirst(48)
        var words: [UInt64] = []
        for offset in stride(from: 0, to: 48, by: 8) {
          var value: UInt64 = 0
          for index in 0..<8 { value |= UInt64(packet[offset + index]) << (index * 8) }
          words.append(value)
        }
        guard words[0] & 0xffff_ffff == 0x414c_4749,
          (words[0] >> 32) & 0xffff == 1, words[1] == nonce[0], words[2] == nonce[1],
          words[0] >> 48 != 0xffff
        else {
          abort()
          return
        }
        lock.lock()
        if failed {
          lock.unlock()
          return
        }
        let continuation = waiter
        waiter = nil
        if continuation == nil {
          guard frames.count < 2 else {
            lock.unlock()
            abort()
            return
          }
          frames.append(words)
        }
        lock.unlock()
        continuation?.resume(returning: words)
        if words[0] >> 48 == 0x8004 {
          source.cancel()
          return
        }
      }
    }
  }

  private func receive(timeout: Double) async throws -> [UInt64] {
    try await withTaskCancellationHandler(
      operation: {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          lock.lock()
          if failed {
            lock.unlock()
            continuation.resume(throwing: AutomaticLoginError.interrupted)
          } else if !frames.isEmpty {
            let frame = frames.removeFirst()
            lock.unlock()
            continuation.resume(returning: frame)
          } else if waiter != nil {
            lock.unlock()
            continuation.resume(throwing: AutomaticLoginError.input)
          } else {
            waiterID &+= 1
            let id = waiterID
            waiter = continuation
            lock.unlock()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
              guard let self else { return }
              self.lock.lock()
              let expired = self.waiter != nil && self.waiterID == id
              self.lock.unlock()
              if expired { self.abort() }
            }
          }
        }
      }, onCancel: { self.abort() })
  }

  @MainActor private func send(
    _ kind: UInt64, value: UInt64 = 0,
    detail: UInt64 = 0
  ) throws -> UInt64 {
    try check()
    sequence += 1
    let words = [
      UInt64(0x414c_4749) | (1 << 32) | (kind << 48),
      nonce[0], nonce[1], sequence, value, detail,
    ]
    var packet: [UInt8] = []
    for word in words {
      for shift in stride(from: 0, to: 64, by: 8) {
        packet.append(UInt8(truncatingIfNeeded: word >> shift))
      }
    }
    lock.lock()
    guard !failed else {
      lock.unlock()
      throw AutomaticLoginError.interrupted
    }
    let count = Darwin.send(descriptor, packet, packet.count, MSG_DONTWAIT)
    lock.unlock()
    guard count == packet.count else {
      abort()
      throw AutomaticLoginError.input
    }
    return sequence
  }

  @MainActor private func acknowledge(
    _ kind: UInt64, sequence: UInt64,
    value: UInt64 = 0, timeout: Double = 0.5
  ) async throws {
    let frame = try await receive(timeout: timeout)
    guard frame[0] >> 48 == kind, frame[3] == sequence,
      frame[4] == value, frame[5] == 0
    else {
      abort()
      throw AutomaticLoginError.input
    }
  }

  @MainActor func start() async throws {
    let seq = try send(1, value: UInt64(getpid()))
    try await acknowledge(0x8001, sequence: seq, timeout: 30)
  }

  @MainActor func arm(windowID: CGWindowID) async throws {
    let seq = try send(2, value: UInt64(windowID))
    try await acknowledge(0x8002, sequence: seq)
  }

  @MainActor func requireSecureField() async throws {
    let seq = try send(5)
    try await acknowledge(0x8005, sequence: seq)
  }

  @MainActor func post(
    _ events: [CGEvent], beforePost: () throws -> Void,
    deliver: (CGEvent) -> Void
  ) async throws -> Int64 {
    guard let first = events.first, (1...2).contains(events.count) else {
      throw AutomaticLoginError.input
    }
    var completed = false
    defer { if !completed { abort() } }
    var tag: Int64 = 0
    guard
      SecRandomCopyBytes(kSecRandomDefault, MemoryLayout.size(ofValue: tag), &tag)
        == errSecSuccess, tag != 0
    else { throw AutomaticLoginError.random }
    let detail = (UInt64(first.type.rawValue) << 32) | UInt64(events.count)
    let seq = try send(3, value: UInt64(bitPattern: tag), detail: detail)
    try await acknowledge(0x8003, sequence: seq)
    try beforePost()
    try check()
    for event in events {
      event.setIntegerValueField(.eventSourceUserData, value: tag)
      deliver(event)
    }
    try await acknowledge(
      0x9000, sequence: seq,
      value: UInt64(events[events.count - 1].type.rawValue))
    if first.type == .keyDown { keysDelivered += 1 }
    if first.type == .leftMouseDown { clicksDelivered += 1 }
    completed = true
    return tag
  }

  @MainActor func requireDeliveryProof() throws {
    try check()
    guard keysDelivered > 0, clicksDelivered > 0 else { throw AutomaticLoginError.input }
  }

  @MainActor func finish() async throws {
    let seq = try send(4)
    try await acknowledge(0x8004, sequence: seq)
    abort()
  }
}
