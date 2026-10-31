import Darwin
import Foundation

@main struct RegionMonitorTests {
  static func child(malformed: Bool) -> Never {
    _ = FileHandle.standardInput.readData(ofLength: 1)
    let table = UnsafeMutableRawPointer.allocate(byteCount: 480, alignment: 4)
    defer { table.deallocate() }
    table.initializeMemory(as: UInt8.self, repeating: 0, count: 480)
    for i in 0..<12 {
      table.storeBytes(of: UInt32(i + 1).littleEndian, toByteOffset: i * 40, as: UInt32.self)
      for (n, value) in hexToBytes(C.knownHex[i], 32)!.enumerated() {
        table.storeBytes(of: value, toByteOffset: i * 40 + 4 + n, as: UInt8.self)
      }
      table.storeBytes(of: C.flags[i], toByteOffset: i * 40 + 36, as: UInt8.self)
    }
    if malformed { table.storeBytes(of: UInt8(1), toByteOffset: 38, as: UInt8.self) }
    let expected = hexToBytes(C.newKeyHex, 32)!
    let deadline = ProcessInfo.processInfo.systemUptime + (malformed ? 2 : 8)
    repeat {
      let actual = Array(UnsafeBufferPointer(start:
        table.advanced(by: (C.group - 1) * 40 + 4).assumingMemoryBound(to: UInt8.self), count: 32))
      if actual == expected { exit(malformed ? 2 : 0) }
      usleep(50_000)
    } while ProcessInfo.processInfo.systemUptime < deadline
    exit(malformed ? 0 : 3)
  }

  static func main() async throws {
    if let index = CommandLine.arguments.firstIndex(of: "--exit-after-us") {
      usleep(UInt32(CommandLine.arguments[index + 1])!)
      exit(0)
    }
    if CommandLine.arguments.contains("--child") {
      child(malformed: CommandLine.arguments.contains("--malformed"))
    }
    for malformed in [false, true] {
      let game = Process(), input = Pipe()
      game.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
      game.arguments = ["--child"] + (malformed ? ["--malformed"] : [])
      game.standardInput = input
      try game.run()
      let monitor = try RegionKeyMonitor(game: game, executable: realPath(game.executableURL!),
        log: { _ in })
      // The UI is deliberately suspended: no fill completion or dialog dismissal may gate the key.
      try input.fileHandleForWriting.write(contentsOf: Data([1]))
      try await Task.sleep(nanoseconds: 3_000_000_000)
      let deadline = ProcessInfo.processInfo.systemUptime + 8
      while game.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      if game.isRunning { game.terminate(); throw RegionKeyError.target }
      game.waitUntilExit()
      let result = await monitor.finish()
      precondition(game.terminationStatus == 0 && result.failure == nil)
      precondition(result.confirmed == !malformed)
      print("PASS: real child table \(malformed ? "refused" : "patched") while UI completion is suspended")
    }
    var falseFailures = 0
    for delay in [0, 100, 500, 1_000, 5_000] {
      for _ in 0..<8 {
        let game = Process()
        game.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        game.arguments = ["--exit-after-us", String(delay)]
        try game.run()
        let monitor = try RegionKeyMonitor(game: game, executable: realPath(game.executableURL!),
          log: { _ in })
        game.waitUntilExit()
        let result = await monitor.finish()
        if result.failure != nil {
          falseFailures += 1
          print("Normal-exit monitor failure: \(String(describing: result.failure))")
        }
        precondition(game.terminationReason == .exit && game.terminationStatus == 0)
      }
    }
    precondition(falseFailures == 0, "normal child exit was misclassified as a monitor failure")
    print("PASS: 40 normal child exits across monitor admission and scans")
    let changed = Process()
    changed.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    changed.arguments = ["--exit-after-us", "2000000"]
    try changed.run()
    let monitor = try RegionKeyMonitor(game: changed,
      executable: changed.executableURL!.path + ".wrong", log: { _ in })
    try await Task.sleep(nanoseconds: 100_000_000)
    let outcome = await monitor.finish()
    precondition(changed.isRunning && outcome.failure == .target)
    changed.terminate()
    changed.waitUntilExit()
    print("PASS: live mismatched executable remains an error and is not killed")
  }
}
