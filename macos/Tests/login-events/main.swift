import AppKit
import Carbon
import CoreGraphics
import Foundation

let app = NSApplication.shared
let reportURL = URL(fileURLWithPath:
  Bundle.main.object(forInfoDictionaryKey: "AlgalonTestReport") as! String)
let stateURL = reportURL.deletingLastPathComponent().appendingPathComponent("target.json")

final class Sink: NSView {
  var received = 0
  var afterForeign = 0
  var switched = false
  var mouseDowns = 0
  var mouseUps = 0
  var changed: (() -> Void)?
  override var acceptsFirstResponder: Bool { true }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 48 { switched = true }
    if event.characters == "z" {
      received += 1
      if switched { afterForeign += 1 }
    }
    changed?()
  }
  override func mouseDown(with event: NSEvent) {
    mouseDowns += 1
    switched = true
    changed?()
  }
  override func mouseUp(with event: NSEvent) { mouseUps += 1; changed?() }
}

func nativeBounds(_ window: NSWindow) -> CGRect? {
  let items = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
  guard let item = items?.first(where: {
    ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber
  }), let value = item[kCGWindowBounds as String] as? [String: Double] else { return nil }
  return CGRect(dictionaryRepresentation: value as CFDictionary)
}

@MainActor final class Target: NSObject {
  let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 640, height: 420),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
  let sink = Sink(frame: CGRect(x: 0, y: 0, width: 640, height: 420))
  let status = NSTextField(labelWithString: "Fictional input only. Click Run, then leave input alone.")
  var other: NSWindow?
  var controller: Process?
  var commands: Pipe?
  var secureInput = false

  override init() {
    super.init()
    window.title = "Algalon input safety fixture — fictional input only"
    window.contentView = sink
    sink.changed = { [weak self] in self?.save() }
    let button = NSButton(title: "Run fictional checks", target: self, action: #selector(run))
    button.frame = CGRect(x: 30, y: 30, width: 220, height: 40)
    status.frame = CGRect(x: 30, y: 95, width: 580, height: 50)
    sink.addSubview(button)
    sink.addSubview(status)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(sink)
    save()
  }

  func save() {
    guard let frame = nativeBounds(window) else { return }
    let second = other?.contentView as? Sink
    let state: [String: Any] = ["window": window.windowNumber,
      "frame": [frame.minX, frame.minY, frame.width, frame.height],
      "first": sink.received, "second": second?.received ?? 0,
      "afterForeign": sink.afterForeign + (second?.afterForeign ?? 0),
      "mouseDowns": sink.mouseDowns, "mouseUps": sink.mouseUps]
    try? JSONSerialization.data(withJSONObject: state).write(to: stateURL, options: .atomic)
  }

  func command(_ byte: UInt8) {
    switch byte {
    case 66: // Back to the original key window.
      other?.orderOut(nil)
      other = nil
      window.makeKeyAndOrderFront(nil)
      window.makeFirstResponder(sink)
      fallthrough
    case 82: // Reset counters after our own harmless mouse click.
      sink.received = 0
      sink.afterForeign = 0
      sink.switched = false
      sink.mouseDowns = 0
      sink.mouseUps = 0
    case 67, 78: // Covering or small non-overlapping key window in the same target process.
      let rect = byte == 67 ? window.frame : CGRect(x: 800, y: 100, width: 180, height: 100)
      let next = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
      let second = Sink(frame: CGRect(origin: .zero, size: rect.size))
      second.changed = { [weak self] in self?.save() }
      next.contentView = second
      next.makeKeyAndOrderFront(nil)
      next.makeFirstResponder(second)
      other = next
    case 83: // Only the target stalls; the controller's event tap must remain responsive.
      Thread.sleep(forTimeInterval: 1)
    case 69:
      if !secureInput, EnableSecureEventInput() == noErr {
        secureInput = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
          _ = DisableSecureEventInput()
          secureInput = false
        }
      }
    default: break
    }
    save()
  }

  @objc func run() {
    guard controller?.isRunning != true else { return }
    status.stringValue = "Starting in two seconds. Keep hands off until the result appears."
    let process = Process(), pipe = Pipe()
    process.executableURL = Bundle.main.executableURL
    process.arguments = ["--controller"]
    process.standardOutput = pipe
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let bytes = handle.availableData
      Task { @MainActor in for byte in bytes { self?.command(byte) } }
    }
    process.terminationHandler = { [weak self] process in
      Task { @MainActor in
        self?.status.stringValue = process.terminationStatus == 0
          ? "PASS: native own/foreign input, window focus, drain and secure-input controls."
          : "STOPPED: see the private JSON report. No credentials were used."
        self?.commands?.fileHandleForReading.readabilityHandler = nil
      }
    }
    commands = pipe
    controller = process
    window.makeFirstResponder(sink)
    do { try process.run() }
    catch { status.stringValue = "Could not start the native test controller." }
  }
}

func queuedKey(pid: Int32, input: LoginInputGuard? = nil, code: CGKeyCode = 0) {
  for down in [true, false] {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
    if input != nil && down {
      var value: UniChar = 122
      event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
    }
    event.flags = []
    input?.tag(event)
    if input != nil { event.postToPid(pid) }
    else { event.post(tap: .cghidEventTap) }
  }
}

@MainActor func control() async -> Never {
  var report: [String: Any] = [:]
  let pid = getppid()
  let executable = Bundle.main.executableURL!.resolvingSymlinksInPath().standardizedFileURL.path
  func command(_ code: UInt8) async throws {
    try FileHandle.standardOutput.write(contentsOf: Data([code]))
    try await Task.sleep(nanoseconds: 100_000_000)
  }
  func state() throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
  }
  do {
    try await Task.sleep(nanoseconds: 2_000_000_000)
    let cases = ["own"] + Array(repeating: ["tab", "click"], count: 5).flatMap { $0 }
      + ["cover", "nonoverlap", "stall", "stallOnly", "secure", "missingDelivery",
         "midString", "mouseRelease", "mouseTabRelease"]
    for (iteration, kind) in cases.enumerated() {
      report["stage"] = "\(iteration): \(kind) preparation"
      try await command(66)
      let initial = try state(), f = initial["frame"] as! [Double]
      let frame = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
      let windowID = CGWindowID(initial["window"] as! Int)
      let anchor = CGPoint(x: frame.midX, y: frame.midY)
      let input = try LoginInputGuard(pid: pid, windowID: windowID, frame: frame, anchor: anchor)
      defer { input.finish() }
      report["stage"] = "\(iteration): \(kind) production posting"
      if kind == "mouseRelease" || kind == "mouseTabRelease" {
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 150_000_000)
          if kind == "mouseTabRelease" { queuedKey(pid: pid, code: 48) }
          else {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
              mouseCursorPosition: anchor, mouseButton: .left)!.post(tap: .cghidEventTap)
          }
        }
        do {
          try await loginClick(anchor, windowID: windowID, frame: frame,
            pid: pid, executable: executable, input: input)
          throw AutomaticLoginError.notReady
        } catch AutomaticLoginError.interrupted {}
        input.finish()
        try await Task.sleep(nanoseconds: 400_000_000)
        let result = try state()
        guard result["mouseDowns"] as? Int == 1, result["mouseUps"] as? Int == 1,
          !CGEventSource.buttonState(.hidSystemState, button: .left),
          !CGEventSource.buttonState(.combinedSessionState, button: .left) else {
          throw AutomaticLoginError.input
        }
        report[kind] = 1
        continue
      }
      try await loginClick(anchor, windowID: windowID, frame: frame,
        pid: pid, executable: executable, input: input)
      try await command(82)
      try await typeLoginText("z", pid: pid, executable: executable, input: input, clear: false)
      try await Task.sleep(nanoseconds: 100_000_000)
      try input.requireLiveTaps()
      guard try state()["first"] as? Int == 1 else { throw AutomaticLoginError.input }
      report["stage"] = "\(iteration): \(kind) interruption"
      if kind == "midString" {
        try await command(82)
        let interrupt = Task { @MainActor in
          try? await Task.sleep(nanoseconds: 150_000_000)
          queuedKey(pid: pid, code: 48)
        }
        do {
          try await typeLoginText(String(repeating: "z", count: 40), pid: pid,
            executable: executable, input: input, clear: false)
          throw AutomaticLoginError.notReady
        } catch AutomaticLoginError.interrupted {}
        await interrupt.value
        for _ in 0..<5 { queuedKey(pid: pid, input: input) }
        input.finish()
        for _ in 0..<5 { queuedKey(pid: pid, input: input) }
        try await Task.sleep(nanoseconds: 600_000_000)
        let result = try state(), count = result["first"] as? Int ?? 0
        guard count > 0, count < 40, result["afterForeign"] as? Int == 0 else {
          throw AutomaticLoginError.input
        }
        report[kind] = true
        continue
      }
      if kind == "tab" { queuedKey(pid: pid, code: 48) }
      if kind == "click" {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
          CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: anchor,
            mouseButton: .left)!.post(tap: .cghidEventTap)
        }
      }
      if kind == "cover" { try await command(67) }
      if kind == "nonoverlap" { try await command(78) }
      if kind == "secure" { try await command(69) }
      if kind == "stall" || kind == "stallOnly" {
        try await command(83)
        if kind == "stall" { queuedKey(pid: pid, code: 48) }
      }
      if kind == "missingDelivery" {
        input.tag(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!)
        do { try input.requireLiveTaps(); throw AutomaticLoginError.notReady }
        catch AutomaticLoginError.processTap {}
        do { try await input.awaitDelivery(); throw AutomaticLoginError.notReady }
        catch AutomaticLoginError.processTap {}
      } else if kind != "own" {
        try await Task.sleep(nanoseconds: 100_000_000)
        let expected: AutomaticLoginError = kind == "secure" ? .secureInput
          : (["cover", "nonoverlap", "stallOnly"].contains(kind) ? .targetChanged : .interrupted)
        do { try input.check(); throw AutomaticLoginError.notReady }
        catch let error as AutomaticLoginError {
          guard error == expected else { throw error }
        }
      }
      if kind != "own" && kind != "secure" {
        for _ in 0..<5 { queuedKey(pid: pid, input: input) }
      }
      input.finish()
      if kind == "secure" {
        // Secure input bypasses taps: test the production refusal, never manufacture new packets.
        do {
          try await typeLoginText("zzzzz", pid: pid, executable: executable,
            input: input, clear: false)
          throw AutomaticLoginError.notReady
        } catch AutomaticLoginError.interrupted {} catch AutomaticLoginError.secureInput {}
      } else {
        for _ in 0..<5 { queuedKey(pid: pid, input: input) }
      }
      try await Task.sleep(nanoseconds: 1_200_000_000)
      let result = try state()
      guard result["first"] as? Int == 1, result["second"] as? Int == 0,
        result["afterForeign"] as? Int == 0 else {
        throw AutomaticLoginError.input
      }
      report[kind] = (report[kind] as? Int ?? 0) + 1
    }
    report["passed"] = true
  } catch {
    report["passed"] = false
    report["failure"] = (error as? AutomaticLoginError)?.rawValue ?? "native fixture failed"
  }
  try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
    .write(to: reportURL, options: .atomic)
  exit(report["passed"] as? Bool == true ? 0 : 1)
}

@main struct FixtureEntry {
  @MainActor static func main() {
    if CommandLine.arguments.contains("--controller") {
      app.setActivationPolicy(.prohibited)
      Task { @MainActor in await control() }
      app.run()
    } else {
      app.setActivationPolicy(.regular)
      let target = Target()
      app.activate(ignoringOtherApps: true)
      withExtendedLifetime(target) { app.run() }
    }
  }
}
