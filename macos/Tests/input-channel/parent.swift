import CoreGraphics
import Darwin
import Foundation

enum AutomaticLoginError: Error { case input, random, interrupted }
enum ParentCheckFailure: Error { case failed(String) }

// An independent socket peer exercises the production Swift receiver, without UI or TCC.
func readPacket() -> [UInt8]? {
  var packet: [UInt8] = []
  while packet.count < 48 {
    var chunk = [UInt8](repeating: 0, count: 48 - packet.count)
    let count = recv(STDIN_FILENO, &chunk, chunk.count, 0)
    if count <= 0 { return nil }
    packet.append(contentsOf: chunk.prefix(count))
  }
  return packet
}

func peer(_ mode: String) {
  var step = 0
  while var packet = readPacket() {
    step += 1
    let command = UInt16(packet[6]) | UInt16(packet[7]) << 8
    packet[7] |= 0x80
    packet.replaceSubrange(32..<48, with: repeatElement(UInt8(0), count: 16))
    if mode == "timeout", step == 2 {
      usleep(1_500_000)
      exit(0)
    }
    if step == 1 {
      switch mode {
      case "magic": packet[0] ^= 1
      case "version": packet[4] = 2
      case "nonce": packet[8] ^= 1
      case "kind": packet[6] = 2
      case "sequence": packet[24] ^= 1
      case "value": packet[32] = 1
      case "detail": packet[40] = 1
      case "partial EOF":
        _ = send(STDIN_FILENO, packet, 19, 0)
        exit(0)
      default: break
      }
    }
    if mode == "fragmented" {
      for byte in packet {
        var part = byte
        if send(STDIN_FILENO, &part, 1, 0) != 1 { exit(0) }
        usleep(500)
      }
    } else {
      if send(STDIN_FILENO, packet, packet.count, 0) != packet.count { exit(0) }
    }
    if command == 4 { exit(0) }
    // Invalid replies remain connected: refusal must come from validation, not EOF.
    if step == 1, !["valid", "fragmented", "timeout"].contains(mode) {
      _ = readPacket()
      exit(0)
    }
  }
  exit(0)
}

@main struct ParentChecks {
  @MainActor static func main() async {
    if CommandLine.arguments.count == 3 { peer(CommandLine.arguments[2]) }
    do {
      for mode in [
        "valid", "fragmented", "magic", "version", "nonce", "kind",
        "sequence", "value", "detail", "partial EOF", "timeout",
      ] {
        let channel = try LoginInputChannel()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--peer", mode]
        process.standardInput = channel.childInput
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        channel.closeChildInput()
        var accepted = false
        do {
          try await channel.start()
          try await channel.arm(windowID: 123)
          try await channel.finish()
          accepted = true
        } catch {}
        channel.abort()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        guard accepted == ["valid", "fragmented"].contains(mode) else {
          throw ParentCheckFailure.failed(mode)
        }
        print("PASS: Swift input channel \(mode)")
      }
    } catch {
      fputs("FAIL: \(error)\n", stderr)
      exit(1)
    }
  }
}
