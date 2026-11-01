import AppKit
import Darwin
import Foundation

enum CheckFailure: Error { case failed(String) }

func frame(
  kind: UInt64 = 1, sequence: UInt64 = 1, nonce: [UInt64] = [17, 29],
  value: UInt64 = UInt64(getpid()), detail: UInt64 = 0,
  magic: UInt64 = 0x414c_4749, version: UInt64 = 1
) -> [UInt8] {
  let words = [
    magic | (version << 32) | (kind << 48), nonce[0], nonce[1],
    sequence, value, detail,
  ]
  return words.flatMap { word in
    stride(from: 0, to: 64, by: 8).map { UInt8(truncatingIfNeeded: word >> $0) }
  }
}

final class Host {
  let process = Process()
  let descriptor: Int32
  init(scope: Bool = true) throws {
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
      throw CheckFailure.failed("socketpair")
    }
    descriptor = pair[0]
    var one: Int32 = 1
    _ = setsockopt(
      descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one,
      socklen_t(MemoryLayout.size(ofValue: one)))
    _ = fcntl(pair[0], F_SETFD, FD_CLOEXEC)
    _ = fcntl(pair[1], F_SETFD, FD_CLOEXEC)
    let input = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--host"]
    let ready = Pipe()
    var environment = ProcessInfo.processInfo.environment
    environment["FOREVER_INPUT_CHANNEL"] = "1"
    environment["FOREVER_INPUT_FIXTURE"] = scope ? "1" : "0"
    environment["DYLD_INSERT_LIBRARIES"] = CommandLine.arguments[1]
    process.environment = environment
    process.standardInput = input
    process.standardOutput = ready
    process.standardError = FileHandle.nullDevice
    try process.run()
    try input.close()
    var item = pollfd(
      fd: ready.fileHandleForReading.fileDescriptor,
      events: Int16(POLLIN), revents: 0)
    guard poll(&item, 1, 3000) > 0,
      ready.fileHandleForReading.readData(ofLength: 1) == Data([1])
    else {
      throw CheckFailure.failed("host run-loop readiness")
    }
  }
  deinit {
    close(descriptor)
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
  }
  func write(_ bytes: [UInt8]) throws {
    guard send(descriptor, bytes, bytes.count, MSG_DONTWAIT) == bytes.count else {
      throw CheckFailure.failed("write")
    }
  }
  func read(timeout: Int32 = 1500) throws -> [UInt64]? {
    var bytes: [UInt8] = []
    while bytes.count < 48 {
      var item = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
      guard poll(&item, 1, timeout) > 0 else { throw CheckFailure.failed("response timeout") }
      var buffer = [UInt8](repeating: 0, count: 48 - bytes.count)
      let count = recv(descriptor, &buffer, buffer.count, MSG_DONTWAIT)
      if count == 0 {
        usleep(20_000)
        guard process.isRunning else {
          throw CheckFailure.failed("host crashed instead of closing")
        }
        return nil
      }
      if count < 0 { throw CheckFailure.failed("read") }
      bytes.append(contentsOf: buffer.prefix(count))
    }
    return stride(from: 0, to: 48, by: 8).map { offset in
      (0..<8).reduce(UInt64(0)) { $0 | (UInt64(bytes[offset + $1]) << ($1 * 8)) }
    }
  }
  func hello() throws {
    try write(frame())
    guard let reply = try read(), reply[0] >> 48 == 0x8001,
      reply[1] == 17, reply[2] == 29, reply[3] == 1
    else {
      throw CheckFailure.failed("hello contract")
    }
  }
}

@main struct InputChannelChecks {
  @MainActor static func main() {
    if CommandLine.arguments.contains("--host") {
      let app = NSApplication.shared
      app.setActivationPolicy(.prohibited)
      DispatchQueue.main.async { FileHandle.standardOutput.write(Data([1])) }
      app.run()
      return
    }
    do {
      do {
        let host = try Host()
        let bytes = frame()
        try host.write(Array(bytes.prefix(19)))
        usleep(10_000)
        try host.write(Array(bytes.dropFirst(19)))
        guard let response = try host.read(), response[0] >> 48 == 0x8001 else {
          throw CheckFailure.failed("fragmented hello")
        }
        print("PASS: native input channel reassembles fragmented frames")
      }
      do {
        let host = try Host()
        try host.write(frame() + frame(kind: 123, sequence: 2, value: 0))
        guard let first = try host.read(), first[0] >> 48 == 0x8001,
          let second = try host.read(), second[0] >> 48 == 0xffff,
          try host.read() == nil
        else { throw CheckFailure.failed("coalesced frames") }
        print("PASS: native input channel orders coalesced frames")
      }
      for (name, packet) in [
        ("bad magic", frame(magic: 0)), ("bad version", frame(version: 2)),
        ("bad first sequence", frame(sequence: 2)), ("zero nonce", frame(nonce: [0, 0])),
        ("wrong parent", frame(value: UInt64(getpid()) + 1)),
      ] {
        let host = try Host()
        try host.write(packet)
        guard try host.read() == nil else { throw CheckFailure.failed(name) }
        print("PASS: input channel rejects \(name)")
      }
      for (name, packet) in [
        ("nonce change", frame(kind: 2, sequence: 2, nonce: [17, 30], value: 0)),
        ("replayed sequence", frame(kind: 2, sequence: 1, value: 0)),
        ("second hello", frame(sequence: 2)),
        ("missing target window", frame(kind: 2, sequence: 2, value: 0)),
        ("permit before arm", frame(kind: 3, sequence: 2, value: 43)),
        ("secure before arm", frame(kind: 5, sequence: 2, value: 0)),
        ("finish before arm", frame(kind: 4, sequence: 2, value: 0)),
        ("unknown command", frame(kind: 123, sequence: 2, value: 0)),
      ] {
        let host = try Host()
        try host.hello()
        try host.write(packet)
        guard let reply = try host.read(), reply[0] >> 48 == 0xffff else {
          throw CheckFailure.failed(name)
        }
        guard try host.read() == nil else { throw CheckFailure.failed("abort did not close") }
        print("PASS: input channel rejects \(name)")
      }
      do {
        let host = try Host()
        try host.write(Array(frame().prefix(19)))
        _ = shutdown(host.descriptor, SHUT_WR)
        guard try host.read() == nil else { throw CheckFailure.failed("partial EOF") }
        print("PASS: input channel closes on partial-frame EOF")
      }
      do {
        let host = try Host(scope: false)
        try host.write(frame())
        var item = pollfd(fd: host.descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&item, 1, 250) == 0 else { throw CheckFailure.failed("scope isolation") }
        print("PASS: input channel inactive outside private-process scope")
      }
    } catch {
      fputs("FAIL: \(error)\n", stderr)
      exit(1)
    }
  }
}
