import AppKit
import Carbon
import CoreGraphics
import CryptoKit
import Darwin
import Foundation

let app = NSApplication.shared
let reportURL = URL(
  fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "AlgalonTestReport") as! String)
let libraryURL = URL(
  fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "AlgalonTestLibrary") as! String)
let targetExecutable = URL(fileURLWithPath:
  Bundle.main.object(forInfoDictionaryKey: "AlgalonTestTargetExecutable") as! String)
@MainActor var controllerWindow: NSWindow?

func controllerOwnHit(pid: Int32, point: CGPoint) -> Bool {
  let system = AXUIElementCreateSystemWide(), application = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(system, 0.1)
  AXUIElementSetMessagingTimeout(application, 0.1)
  var hit: AXUIElement?, owner: pid_t = 0
  guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
    let hit, AXUIElementGetPid(hit, &owner) == .success, owner == pid else { return false }
  var hitWindow: CFTypeRef?, mainWindow: CFTypeRef?
  guard AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &hitWindow) == .success,
    AXUIElementCopyAttributeValue(application, kAXMainWindowAttribute as CFString, &mainWindow)
      == .success, let hitWindow, let mainWindow else { return false }
  return CFEqual(hitWindow, mainWindow)
}

@MainActor func prepareControllerActivation() async throws {
  guard !NSApp.isActive, let window = controllerWindow else { return }
  window.orderFrontRegardless()
  window.makeMain()
  guard let frame = nativeBounds(window) else { throw FixtureFailure.failed("controller bounds") }
  let point = CGPoint(x: frame.midX, y: frame.minY + 80)
  let pid = getpid()
  var down = false
  defer {
    if down { CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
      mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap) }
  }
  for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    // Self-AX queries must leave this main actor free to answer the accessibility request.
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    var matches = false
    repeat {
      matches = await Task.detached {
        controllerOwnHit(pid: pid, point: point)
      }.value
      if matches { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    } while ProcessInfo.processInfo.systemUptime < deadline
    guard matches, window.isVisible, nativeBounds(window) == frame, CGPreflightPostEventAccess(),
      let event = CGEvent(mouseEventSource: nil, mouseType: type,
        mouseCursorPosition: point, mouseButton: .left) else {
      throw FixtureFailure.failed("controller hit target")
    }
    if type == .mouseMoved { _ = CGWarpMouseCursorPosition(point) }
    event.flags = []
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
    if type == .leftMouseDown { down = true }
    if type == .leftMouseUp { down = false }
    try await Task.sleep(nanoseconds: 100_000_000)
  }
  try assertLoginTarget(pid: pid,
    executable: Bundle.main.executableURL!.resolvingSymlinksInPath().path)
}

enum FixtureFailure: Error { case failed(String) }

func nativeBounds(_ window: NSWindow) -> CGRect? {
  let items = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
  guard
    let item = items?.first(where: {
      ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber
    }), let value = item[kCGWindowBounds as String] as? [String: Double]
  else { return nil }
  guard let rect = CGRect(dictionaryRepresentation: value as CFDictionary),
    rect.width > 0, rect.height > 0 else { return nil }
  return rect
}

final class World {
  let parent = Int64(getppid())
  var keys = 0, ups = 0, clears = 0, afterForeign = 0, foreign = 0, downs = 0, mouseUps = 0
  var switched = false, stalled = false
  var changed: (() -> Void)?
}

final class Sink: NSView {
  let world: World
  weak var other: Sink?
  init(frame: CGRect, world: World) {
    self.world = world
    super.init(frame: frame)
  }
  required init?(coder: NSCoder) { nil }
  override var acceptsFirstResponder: Bool { true }
  private func own(_ event: NSEvent) -> Bool {
    event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == world.parent
      && event.cgEvent?.getIntegerValueField(.eventSourceUserData) != 0
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 48 {
      world.foreign += 1
      world.switched = true
      if let other { window?.makeFirstResponder(other) }
    } else if own(event),
      (event.keyCode == 0 && event.modifierFlags.contains(.command)) || event.keyCode == 51
    {
      world.clears += 1
    } else if own(event), event.characters == "z" {
      world.keys += 1
      if world.switched { world.afterForeign += 1 }
    }
    world.changed?()
  }
  override func keyUp(with event: NSEvent) {
    if own(event), !event.modifierFlags.contains(.command) { world.ups += 1 }
    world.changed?()
  }
  override func mouseDown(with event: NSEvent) {
    world.downs += 1
    if !own(event) {
      world.foreign += 1
      world.switched = true
    }
    world.changed?()
  }
  override func mouseUp(with event: NSEvent) {
    world.mouseUps += 1
    world.changed?()
  }
  override func mouseMoved(with event: NSEvent) {
    if !own(event) {
      world.foreign += 1
      world.switched = true
      world.changed?()
    }
  }
}

@MainActor final class Target {
  let window = NSWindow(
    contentRect: CGRect(x: 160, y: 160, width: 640, height: 420),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
  let world = World()
  let stateURL: URL
  var commands = 0
  var secure = false
  var other: NSWindow?
  let input = FileHandle(fileDescriptor: STDOUT_FILENO, closeOnDealloc: false)
  init() {
    stateURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let left = Sink(frame: CGRect(x: 0, y: 0, width: 640, height: 420), world: world)
    let right = Sink(frame: CGRect(x: 320, y: 0, width: 320, height: 420), world: world)
    left.other = right
    left.addSubview(right)
    window.contentView = left
    window.title = "Algalon fictional input target"
    window.acceptsMouseMovedEvents = true
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(left)
    world.changed = { [weak self] in self?.save() }
    input.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      Task { @MainActor in for byte in data { self?.command(byte) } }
    }
    Task { @MainActor [self] in
      let deadline = ProcessInfo.processInfo.systemUptime + 3
      while nativeBounds(window) == nil, ProcessInfo.processInfo.systemUptime < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
      }
      save()
    }
  }
  func save() {
    guard let rect = nativeBounds(window) else { return }
    let values: [String: Any] = [
      "window": window.windowNumber,
      "frame": [rect.minX, rect.minY, rect.width, rect.height], "commands": commands,
      "keys": world.keys, "ups": world.ups, "clears": world.clears,
      "afterForeign": world.afterForeign,
      "foreign": world.foreign, "downs": world.downs, "mouseUps": world.mouseUps,
      "stalled": world.stalled, "pid": getpid(), "secure": secure,
    ]
    try? JSONSerialization.data(withJSONObject: values).write(to: stateURL, options: .atomic)
  }
  func command(_ byte: UInt8) {
    commands += 1
    switch byte {
    case 82:
      world.keys = 0
      world.ups = 0
      world.clears = 0
      world.afterForeign = 0
      world.foreign = 0
      world.downs = 0
      world.mouseUps = 0
      world.switched = false
      if let sink = window.contentView { window.makeFirstResponder(sink) }
    case 69:
      if !secure, EnableSecureEventInput() == noErr { secure = true }
    case 87:
      let next = NSWindow(
        contentRect: window.frame, styleMask: .titled,
        backing: .buffered, defer: false)
      next.title = "Algalon other fictional window"
      next.contentView = Sink(frame: CGRect(x: 0, y: 0, width: 640, height: 420), world: world)
      next.makeKeyAndOrderFront(nil)
      other = next
    case 77:
      window.setFrameOrigin(CGPoint(x: window.frame.minX + 25, y: window.frame.minY + 25))
    case 68:
      if secure, DisableSecureEventInput() == noErr { secure = false }
    case 83, 84, 85:
      world.stalled = true
      save()
      Thread.sleep(forTimeInterval: byte == 83 ? 1 : byte == 84 ? 0.4 : 0.15)
      world.stalled = false
    default: break
    }
    save()
  }
}

@MainActor final class Host {
  let process = Process()
  let channel: LoginInputChannel
  let commands: FileHandle
  let stateURL: URL
  var sent = 0
  var windowID: CGWindowID = 0
  var frame = CGRect.zero
  var anchor = CGPoint.zero
  var phase = "created"
  init(statePath: String? = nil) throws {
    channel = try LoginInputChannel()
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
      throw FixtureFailure.failed("commands")
    }
    _ = fcntl(pair[0], F_SETFD, FD_CLOEXEC)
    _ = fcntl(pair[1], F_SETFD, FD_CLOEXEC)
    commands = FileHandle(fileDescriptor: pair[0], closeOnDealloc: true)
    let child = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
    stateURL =
      statePath.map { URL(fileURLWithPath: $0) }
      ?? reportURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".json")
    process.executableURL = targetExecutable
    process.arguments = ["--target", stateURL.path]
    var environment = ProcessInfo.processInfo.environment
    environment["FOREVER_INPUT_CHANNEL"] = "1"
    environment["FOREVER_INPUT_FIXTURE"] = "1"
    environment["DYLD_INSERT_LIBRARIES"] = libraryURL.path
    process.environment = environment
    process.standardInput = channel.childInput
    process.standardOutput = child
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch {
      channel.abort()
      try? child.close()
      throw error
    }
    channel.closeChildInput()
    try child.close()
  }
  func state() -> [String: Any] {
    guard let data = try? Data(contentsOf: stateURL),
      let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return values
  }
  func wait(_ predicate: ([String: Any]) -> Bool, seconds: Double = 3) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !predicate(state()) {
      guard process.isRunning, ProcessInfo.processInfo.systemUptime < deadline else {
        throw FixtureFailure.failed("target condition timeout")
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }
  func command(_ code: UInt8) throws {
    try commands.write(contentsOf: Data([code]))
    sent += 1
  }
  func ready() async throws {
    phase = "handshake"
    try await channel.start()
    if let running = NSRunningApplication(processIdentifier: process.processIdentifier) {
      if #available(macOS 14, *) {
        NSApplication.shared.yieldActivation(to: running)
        _ = running.activate(from: .current, options: .activateAllWindows)
      } else { _ = running.activate(options: .activateAllWindows) }
    }
    phase = "window readiness"
    try await wait { $0["window"] != nil }
    let values = state()
    windowID = CGWindowID(values["window"] as! Int)
    let rect = values["frame"] as! [Double]
    frame = CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
    anchor = CGPoint(x: frame.minX + 100, y: frame.minY + 150)
    let executable = targetExecutable.resolvingSymlinksInPath().path
    phase = "initial activation"
    try await activateLoginWindow(
      anchor, windowID: windowID, frame: frame,
      pid: process.processIdentifier, executable: executable)
    try command(82)
    try command(69)
    phase = "target command acknowledgement"
    try await wait { ($0["commands"] as? Int ?? 0) == self.sent }
  }
  func prepareNative() async throws {
    try await ready()
    try await channel.arm(windowID: windowID)
    try await channel.requireSecureField()
  }
  func prepare() async throws -> LoginInputGuard {
    try await ready()
    let guardInput = try LoginInputGuard(
      pid: process.processIdentifier,
      windowID: windowID, frame: frame, anchor: anchor, channel: channel)
    do {
      try await guardInput.arm()
      try await guardInput.requireSecureField()
    } catch {
      guardInput.finish()
      throw error
    }
    return guardInput
  }
  func settle() async throws {
    try await Task.sleep(nanoseconds: 250_000_000)
    try command(66)
    try await wait { ($0["commands"] as? Int ?? 0) == self.sent }
  }
  func waitForAbort() async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 0.2
    repeat {
      do { try channel.check() } catch { return }
      try await Task.sleep(nanoseconds: 2_000_000)
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw FixtureFailure.failed("foreign input did not abort before delivery timeout")
  }
  func changeBeforePosting(_ code: UInt8, condition: ([String: Any]) -> Bool) throws {
    try command(code)
    let deadline = ProcessInfo.processInfo.systemUptime + 0.25
    while !condition(state()), ProcessInfo.processInfo.systemUptime < deadline {
      Thread.sleep(forTimeInterval: 0.002)
    }
    guard condition(state()) else { throw FixtureFailure.failed("native change not admitted") }
  }
  func inject(_ kind: String, point: CGPoint? = nil) async throws {
    let injector = Process()
    injector.executableURL = Bundle.main.executableURL
    let location = point ?? anchor
    injector.arguments = [
      "--foreign", kind, String(Double(location.x)), String(Double(location.y)),
    ]
    injector.standardOutput = FileHandle.nullDevice
    injector.standardError = FileHandle.nullDevice
    try injector.run()
    while injector.isRunning { try await Task.sleep(nanoseconds: 5_000_000) }
    guard injector.terminationStatus == 0 else {
      throw FixtureFailure.failed("foreign input delivery")
    }
  }
  func stop() {
    channel.abort()
    try? commands.close()
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
  }
}

func foreignInput() {
  guard CGPreflightPostEventAccess() else { exit(2) }
  let kind = CommandLine.arguments[2]
  let point = CGPoint(x: Double(CommandLine.arguments[3])!, y: Double(CommandLine.arguments[4])!)
  if kind == "tab" {
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: down)!
      event.flags = []
      event.post(tap: .cghidEventTap)
    }
  } else {
    let types: [CGEventType] =
      kind == "move" ? [.mouseMoved] : [.mouseMoved, .leftMouseDown, .leftMouseUp]
    for type in types {
      let event = CGEvent(
        mouseEventSource: nil, mouseType: type,
        mouseCursorPosition: point, mouseButton: .left)!
      event.flags = []
      event.setIntegerValueField(.mouseEventClickState, value: 1)
      event.post(tap: .cghidEventTap)
      usleep(20_000)
    }
  }
  usleep(30_000)
  exit(0)
}

func fixtureKeys() -> [CGEvent] {
  [true, false].map { down in
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)!
    event.flags = []
    if down {
      var unit: UniChar = 122
      event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
    }
    return event
  }
}

@MainActor func fixtureMouse(_ host: Host, _ type: CGEventType) -> CGEvent {
  let event = CGEvent(
    mouseEventSource: nil, mouseType: type,
    mouseCursorPosition: host.anchor, mouseButton: .left)!
  event.flags = []
  event.setIntegerValueField(.mouseEventClickState, value: 1)
  return event
}

@MainActor func orphanParent() async {
  var current: Host?
  do {
    let host = try Host(statePath: CommandLine.arguments[2])
    current = host
    try await host.prepareNative()
    _ = try await host.channel.post(
      [fixtureMouse(host, .leftMouseDown)], beforePost: {},
      deliver: { $0.post(tap: .cghidEventTap) })
    _ = try await host.channel.post(
      [fixtureMouse(host, .leftMouseUp)],
      beforePost: {
        try host.changeBeforePosting(85) { $0["stalled"] as? Bool == true }
      },
      deliver: {
        $0.post(tap: .cghidEventTap)
        kill(getpid(), SIGKILL)
      })
  } catch { current?.stop() }
  exit(2)
}

@MainActor func runChecks() async {
  var passed: [String] = []
  var current: Host?
  var input: LoginInputGuard?
  let executable = targetExecutable.resolvingSymlinksInPath().path
  func cleanup() {
    input?.finish()
    current?.stop()
    input = nil
    current = nil
  }
  func begin() async throws -> (Host, LoginInputGuard) {
    cleanup()
    try await prepareControllerActivation()
    let host = try Host()
    current = host
    let guardInput = try await host.prepare()
    input = guardInput
    return (host, guardInput)
  }
  func native() async throws -> Host {
    cleanup()
    try await prepareControllerActivation()
    let host = try Host()
    current = host
    try await host.prepareNative()
    return host
  }
  do {
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), CGPreflightScreenCaptureAccess()
    else {
      throw FixtureFailure.failed("fixture requires its existing Accessibility and capture grants")
    }
    do {
      let (host, guardInput) = try await begin()
      try await loginClick(
        host.anchor, windowID: host.windowID, frame: host.frame,
        pid: host.process.processIdentifier, executable: executable, input: guardInput)
      try await typeLoginText(
        "zz", pid: host.process.processIdentifier,
        executable: executable, input: guardInput, clear: true)
      try await host.settle()
      guard (host.state()["keys"] as? Int) == 2, (host.state()["ups"] as? Int) == 3,
        (host.state()["clears"] as? Int) == 2,
        (host.state()["downs"] as? Int) == 1, (host.state()["mouseUps"] as? Int) == 1
      else {
        throw FixtureFailure.failed("secure input clear and paired keys")
      }
      try guardInput.requireDeliveryProof()
      try await guardInput.complete()
      passed.append("secure-input click, Cmd-A clear and paired text delivery")
    }
    do {
      let (host, guardInput) = try await begin()
      let clicking = Task { @MainActor in
        try await loginClick(
          host.anchor, windowID: host.windowID, frame: host.frame,
          pid: host.process.processIdentifier, executable: executable, input: guardInput)
      }
      try await host.wait { ($0["downs"] as? Int ?? 0) == 1 }
      host.channel.abort()
      var stopped = false
      do { try await clicking.value } catch { stopped = true }
      try await host.settle()
      guard stopped, (host.state()["downs"] as? Int) == 1,
        (host.state()["mouseUps"] as? Int) == 1
      else { throw FixtureFailure.failed("production click fallback release") }
      passed.append("production click abort posts one paired fallback release")
    }
    do {
      cleanup()
      try await prepareControllerActivation()
      let host = try Host()
      current = host
      try await host.ready()
      func hit(_ id: CGWindowID, _ frame: CGRect, _ point: CGPoint) -> Bool {
        loginWindowMatches(
          pid: host.process.processIdentifier, windowID: id, frame: frame, point: point)
      }
      guard hit(host.windowID, host.frame, host.anchor),
        !hit(host.windowID &+ 1, host.frame, host.anchor),
        !hit(host.windowID, host.frame.offsetBy(dx: 10, dy: 0), host.anchor),
        !hit(host.windowID, host.frame,
          CGPoint(x: host.frame.minX - 30, y: host.frame.minY - 30))
      else { throw FixtureFailure.failed("target window negatives") }
      try host.command(87)
      let deadline = ProcessInfo.processInfo.systemUptime + 1
      while hit(host.windowID, host.frame, host.anchor),
        ProcessInfo.processInfo.systemUptime < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      guard !hit(host.windowID, host.frame, host.anchor) else {
        throw FixtureFailure.failed("other key window targeting")
      }
      passed.append("parent refuses wrong window, frame, point and changed key window")
    }
    for kind in ["tab", "click", "move"] {
      for trial in 1...3 {
        let (host, guardInput) = try await begin()
        let typing = Task { @MainActor in
          try await typeLoginText(
            String(repeating: "z", count: 40),
            pid: host.process.processIdentifier, executable: executable,
            input: guardInput, clear: false)
        }
        try await host.wait { ($0["keys"] as? Int ?? 0) > 0 }
        try host.channel.check()
        try await host.inject(kind)
        var stopped = false
        do { try await typing.value } catch { stopped = true }
        try await host.wait { ($0["foreign"] as? Int ?? 0) > 0 }
        try await host.settle()
        guard stopped, (host.state()["afterForeign"] as? Int) == 0,
          (host.state()["keys"] as? Int ?? 40) < 40
        else {
          throw FixtureFailure.failed("foreign \(kind) did not stop remaining input")
        }
        passed.append("foreign \(kind) \(trial): interrupted with zero later keys")
      }
    }
    // Exercise the local monitor independently of the parent's mouse tap.
    for kind in ["tab", "click", "move"] {
      let host = try await native()
      let typing = Task { @MainActor in
        for _ in 0..<40 {
          _ = try await host.channel.post(
            fixtureKeys(), beforePost: {},
            deliver: { $0.postToPid(host.process.processIdentifier) })
          try await Task.sleep(nanoseconds: 20_000_000)
        }
      }
      try await host.wait { ($0["keys"] as? Int ?? 0) > 0 }
      try host.channel.check()
      try await host.inject(kind)
      var refused = false
      do { try await typing.value } catch { refused = true }
      try await host.wait { ($0["foreign"] as? Int ?? 0) > 0 }
      try await host.settle()
      guard refused, (host.state()["afterForeign"] as? Int) == 0,
        (host.state()["keys"] as? Int ?? 40) < 40
      else {
        throw FixtureFailure.failed("native-only \(kind)")
      }
      passed.append("native-only \(kind) cancels with no later keys")
    }
    do {
      cleanup()
      try await prepareControllerActivation()
      let host = try Host()
      current = host
      try await host.ready()  // No native arm/filter: the outside-mouse tap must own this refusal.
      let guardInput = try LoginInputGuard(
        pid: host.process.processIdentifier,
        windowID: host.windowID, frame: host.frame, anchor: host.anchor, channel: host.channel)
      input = guardInput
      try guardInput.check()
      try await host.inject(
        "move", point: CGPoint(x: host.frame.minX - 30, y: host.frame.minY - 30))
      var refused = false
      do { try host.channel.check() } catch { refused = true }
      try await host.settle()
      guard refused else { throw FixtureFailure.failed("outside mouse tap") }
      passed.append("outside-window movement cancels through parent tap alone")
    }
    for (name, code) in [
      ("other key window", UInt8(87)), ("window movement", UInt8(77)),
      ("Secure Input loss", UInt8(68)),
    ] {
      let host = try await native()
      var changed = false
      var posted = 0
      var refused = false
      do {
        _ = try await host.channel.post(
          fixtureKeys(), beforePost: {},
          deliver: { event in
            if posted == 0 {
              do {
                try host.changeBeforePosting(code) {
                  ($0["commands"] as? Int) == host.sent
                }
                changed = code != 68 || !IsSecureEventInputEnabled()
              } catch {}
            }
            posted += 1
            event.postToPid(host.process.processIdentifier)
          })
      } catch { refused = true }
      try await host.settle()
      guard changed, posted == 2, refused, (host.state()["keys"] as? Int) == 0,
        (host.state()["ups"] as? Int) == 0
      else { throw FixtureFailure.failed(name) }
      passed.append("native \(name) drops already permitted queued keys")
    }
    do {
      let host = try await native()
      let tag = try await host.channel.post(
        [fixtureMouse(host, .leftMouseDown)], beforePost: {},
        deliver: { $0.post(tap: .cghidEventTap) })
      try await host.inject("tab")
      try await host.wait { ($0["foreign"] as? Int ?? 0) > 0 }
      try await host.waitForAbort()
      let release = fixtureMouse(host, .leftMouseUp)
      release.setIntegerValueField(.eventSourceUserData, value: tag)
      release.post(tap: .cghidEventTap)
      try await host.settle()
      guard (host.state()["downs"] as? Int) == 1, (host.state()["mouseUps"] as? Int) == 1 else {
        throw FixtureFailure.failed("deterministic interrupted mouse release")
      }
      release.post(tap: .cghidEventTap)
      try await host.settle()
      guard (host.state()["mouseUps"] as? Int) == 1 else {
        throw FixtureFailure.failed("duplicate mouse release")
      }
      passed.append("interruption retains one paired mouse release and drops a duplicate")
    }
    do {
      let host = try await native()
      var savedUp: CGEvent?
      let posting = Task { @MainActor in
        try await host.channel.post(
          fixtureKeys(), beforePost: {},
          deliver: { event in
            if event.type == .keyUp {
              savedUp = event
            } else {
              event.postToPid(host.process.processIdentifier)
            }
          })
      }
      try await host.wait { ($0["keys"] as? Int ?? 0) == 1 }
      try await host.inject("tab")
      try await host.wait { ($0["foreign"] as? Int ?? 0) > 0 }
      try await host.waitForAbort()
      do { _ = try await posting.value } catch {}
      savedUp?.postToPid(host.process.processIdentifier)
      try await host.settle()
      guard (host.state()["ups"] as? Int) == 1,
        (host.state()["afterForeign"] as? Int) == 0
      else { throw FixtureFailure.failed("key release") }
      savedUp?.postToPid(host.process.processIdentifier)
      try await host.settle()
      guard (host.state()["ups"] as? Int) == 1 else {
        throw FixtureFailure.failed("duplicate key release")
      }
      passed.append("abort retains one empty key release and drops its duplicate")
    }
    do {
      let host = try await native()
      let initialDowns = host.state()["downs"] as? Int ?? -1
      var originalTag: Int64 = 0
      var refused = false
      var posted = 0
      var changedTag = false
      do {
        _ = try await host.channel.post(
          [fixtureMouse(host, .leftMouseDown)], beforePost: {},
          deliver: { event in
            originalTag = event.getIntegerValueField(.eventSourceUserData)
            let forged = fixtureMouse(host, .leftMouseDown)
            forged.setIntegerValueField(.eventSourceUserData, value: originalTag ^ 1)
            changedTag = forged.getIntegerValueField(.eventSourceUserData) == originalTag ^ 1
            posted += 1
            forged.post(tap: .cghidEventTap)
          })
      } catch { refused = true }
      let release = fixtureMouse(host, .leftMouseUp)
      release.setIntegerValueField(.eventSourceUserData, value: originalTag)
      release.post(tap: .cghidEventTap)
      try await host.settle()
      guard refused, posted == 1, originalTag != 0, changedTag, initialDowns == 0,
        (host.state()["downs"] as? Int) == 0, (host.state()["mouseUps"] as? Int) == 0
      else {
        throw FixtureFailure.failed("mouse drop: refused=\(refused), posted=\(posted), "
          + "tagChanged=\(changedTag), initialDowns=\(initialDowns), "
          + "downs=\(host.state()["downs"] ?? -1), ups=\(host.state()["mouseUps"] ?? -1)")
      }
      passed.append("dropped own mouse down also drops its fallback release")
    }
    do {
      let host = try await native()
      let events = fixtureKeys()
      let tag = try await host.channel.post(
        events, beforePost: {},
        deliver: { $0.postToPid(host.process.processIdentifier) })
      for event in events {
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        event.postToPid(host.process.processIdentifier)
      }
      try await host.settle()
      var refused = false
      do { try host.channel.check() } catch { refused = true }
      guard refused, (host.state()["keys"] as? Int) == 1,
        (host.state()["ups"] as? Int) == 1
      else {
        throw FixtureFailure.failed("used permit replay")
      }
      passed.append("replayed exhausted permit delivers no additional key pair")
    }
    do {
      let host = try await native()
      var refused = false
      var posted = 0
      do {
        _ = try await host.channel.post(
          fixtureKeys(), beforePost: {},
          deliver: { event in
            if event.type == .keyDown {
              let up = fixtureKeys()[1]
              up.setIntegerValueField(
                .eventSourceUserData,
                value: event.getIntegerValueField(.eventSourceUserData))
              posted += 1
              up.postToPid(host.process.processIdentifier)
            }
          })
      } catch { refused = true }
      try await host.settle()
      guard refused, posted == 1, (host.state()["keys"] as? Int) == 0,
        (host.state()["ups"] as? Int) == 0
      else {
        throw FixtureFailure.failed("wrong event type")
      }
      passed.append("wrong event type is dropped before responder delivery")
    }
    for mode in ["wrong", "reused"] {
      let host = try await native()
      var oldTag: Int64 = 0
      if mode == "reused" {
        oldTag = try await host.channel.post(
          fixtureKeys(), beforePost: {},
          deliver: { $0.postToPid(host.process.processIdentifier) })
      }
      var refused = false
      var posted = 0
      var forgedTags = true
      do {
        _ = try await host.channel.post(
          fixtureKeys(), beforePost: {},
          deliver: { event in
            let tag =
              mode == "reused" ? oldTag : event.getIntegerValueField(.eventSourceUserData) ^ 1
            let forged = fixtureKeys()[event.type == .keyDown ? 0 : 1]
            forged.setIntegerValueField(.eventSourceUserData, value: tag)
            forgedTags = forgedTags
              && forged.getIntegerValueField(.eventSourceUserData) == tag
              && tag != event.getIntegerValueField(.eventSourceUserData)
            posted += 1
            forged.postToPid(host.process.processIdentifier)
          })
      } catch { refused = true }
      try await host.settle()
      let expected = mode == "reused" ? 1 : 0
      guard refused, posted == 2, forgedTags, (host.state()["keys"] as? Int) == expected,
        (host.state()["ups"] as? Int) == expected
      else { throw FixtureFailure.failed("\(mode) tag") }
      passed.append("\(mode) event tag drops down without orphan up")
    }
    for mode in ["secure", "finish", "key permit", "unpaired up"] {
      let host = try await native()
      var downTag: Int64 = 0
      if mode != "unpaired up" {
        downTag = try await host.channel.post(
          [fixtureMouse(host, .leftMouseDown)], beforePost: {},
          deliver: { $0.post(tap: .cghidEventTap) })
      }
      var refused = false
      do {
        if mode == "secure" {
          try await host.channel.requireSecureField()
        } else if mode == "finish" {
          try await host.channel.finish()
        } else if mode == "key permit" {
          _ = try await host.channel.post(
            fixtureKeys(), beforePost: {},
            deliver: { $0.postToPid(host.process.processIdentifier) })
        } else {
          _ = try await host.channel.post(
            [fixtureMouse(host, .leftMouseUp)], beforePost: {},
            deliver: { $0.post(tap: .cghidEventTap) })
        }
      } catch { refused = true }
      if downTag != 0 {
        let release = fixtureMouse(host, .leftMouseUp)
        release.setIntegerValueField(.eventSourceUserData, value: downTag)
        release.post(tap: .cghidEventTap)
      }
      try await host.settle()
      guard refused, (host.state()["keys"] as? Int) == 0,
        (host.state()["mouseUps"] as? Int) == (downTag == 0 ? 0 : 1)
      else {
        throw FixtureFailure.failed("held input \(mode)")
      }
      passed.append("native release discipline rejects \(mode)")
    }
    do {
      let host = try await native()
      let tag = try await host.channel.post(
        [fixtureMouse(host, .leftMouseDown)], beforePost: {},
        deliver: { $0.post(tap: .cghidEventTap) })
      try host.channel.check()
      let release = fixtureMouse(host, .leftMouseUp)
      release.setIntegerValueField(.eventSourceUserData, value: tag)
      release.post(tap: .cghidEventTap)
      try await host.settle()
      var stopped = false
      do { try host.channel.check() } catch { stopped = true }
      guard stopped, (host.state()["downs"] as? Int) == 1,
        (host.state()["mouseUps"] as? Int) == 1
      else { throw FixtureFailure.failed("unaborted paired release") }
      passed.append("unaborted fallback release passes once and aborts the channel")
    }
    for (name, code) in [("expiry", UInt8(84)), ("EOF", UInt8(85))] {
      let host = try await native()
      var admitted = false
      var posted = 0
      var refused = false
      do {
        _ = try await host.channel.post(
          fixtureKeys(),
          beforePost: {
            try host.changeBeforePosting(code) { $0["stalled"] as? Bool == true }
            admitted = true
          },
          deliver: {
            posted += 1
            $0.postToPid(host.process.processIdentifier)
            if name == "EOF", posted == 2 { host.channel.abort() }
          })
      } catch { refused = true }
      try await host.wait({ $0["stalled"] as? Bool == false }, seconds: 2)
      try await host.settle()
      guard admitted, posted == 2, refused, (host.state()["keys"] as? Int) == 0,
        (host.state()["ups"] as? Int) == 0
      else { throw FixtureFailure.failed("queued \(name)") }
      passed.append("native \(name) independently drops queued input")
    }
    do {
      let host = try await native()
      host.channel.abort()
      try await host.inject("tab")
      try await host.settle()
      guard (host.state()["foreign"] as? Int ?? 0) > 0,
        (host.state()["keys"] as? Int) == 0
      else { throw FixtureFailure.failed("manual after EOF") }
      passed.append("EOF leaves foreign/manual input usable")
    }
    do {
      cleanup()
      let stateURL = reportURL.deletingLastPathComponent()
        .appendingPathComponent("orphan-" + UUID().uuidString + ".json")
      let worker = Process()
      worker.executableURL = Bundle.main.executableURL
      worker.arguments = ["--orphan-parent", stateURL.path]
      worker.standardOutput = FileHandle.nullDevice
      worker.standardError = FileHandle.nullDevice
      try worker.run()
      defer {
        if worker.isRunning { worker.terminate() }
        if let values = (try? JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)))
          as? [String: Any], let number = values["pid"] as? NSNumber,
          loginProcessMatches(pid: number.int32Value, executable: executable)
        {
          kill(number.int32Value, SIGTERM)
        }
      }
      let deadline = ProcessInfo.processInfo.systemUptime + 15
      while worker.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      let first =
        try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
      guard let number = first["pid"] as? Int else {
        throw FixtureFailure.failed("target identity")
      }
      let pid = Int32(number)
      guard !worker.isRunning, worker.terminationReason == .uncaughtSignal,
        worker.terminationStatus == SIGKILL
      else { throw FixtureFailure.failed("real parent SIGKILL") }
      try await Task.sleep(nanoseconds: 700_000_000)
      let final =
        try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
      guard kill(pid, 0) == 0, loginProcessMatches(pid: pid, executable: executable),
        final["stalled"] as? Bool == false, final["downs"] as? Int == 1,
        final["mouseUps"] as? Int == 1
      else {
        throw FixtureFailure.failed("parent death drops permitted new-tag mouse release")
      }
      passed.append("actual parent SIGKILL retains queued permitted new-tag mouse release")
    }
    cleanup()
    try JSONSerialization.data(
      withJSONObject: ["passed": passed, "count": passed.count,
        "completedUTC": ISO8601DateFormatter().string(from: Date()),
        "sourceSHA256": Bundle.main.object(forInfoDictionaryKey: "AlgalonTestSourceSHA256") ?? "",
        "binarySHA256": SHA256.hash(data: try Data(contentsOf: Bundle.main.executableURL!))
          .map { String(format: "%02x", $0) }.joined()],
      options: .prettyPrinted
    ).write(to: reportURL, options: .atomic)
    print("PASS: \(passed.count) native multi-process cooperative input cases")
    exit(0)
  } catch {
    let state = current?.state() ?? [:]
    let targetRunning = current?.process.isRunning ?? false
    let phase = current?.phase ?? "no target"
    cleanup()
    let result: [String: Any] = [
      "passed": passed, "count": passed.count, "error": String(describing: error),
      "lastState": state, "targetRunning": targetRunning,
      "phase": phase,
    ]
    try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)
      .write(to: reportURL, options: .atomic)
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
  }
}

@MainActor final class FixtureController: NSObject {
  var bootstrapError = ""
  var started = false
  let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 520, height: 170),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
  override init() {
    super.init()
    window.title = "Algalon fictional input control"
    controllerWindow = window
    let label = NSTextField(labelWithString: "Fictional input only. Checks run in separate processes.")
    label.frame = CGRect(x: 25, y: 105, width: 470, height: 24)
    let button = NSButton(title: "Run checks", target: self, action: #selector(start))
    button.frame = CGRect(x: 190, y: 40, width: 140, height: 35)
    window.contentView?.addSubview(label)
    window.contentView?.addSubview(button)
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    // Background AX presses are not an activation grant; exercise the same nonsecret native bootstrap.
    Task { @MainActor [self] in
      let deadline = ProcessInfo.processInfo.systemUptime + 3
      while nativeBounds(window) == nil, ProcessInfo.processInfo.systemUptime < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
      }
      guard let frame = nativeBounds(window) else { return }
      do {
        _ = frame
        try await prepareControllerActivation()
        start()
      } catch { bootstrapError = String(describing: error); recordControllerState() }
    }
  }
  func recordControllerState() {
    guard let frame = nativeBounds(window) else { return }
    let values: [String: Any] = ["active": NSApp.isActive, "bootstrapError": bootstrapError,
      "frame": [frame.minX, frame.minY, frame.width, frame.height]]
    try? JSONSerialization.data(withJSONObject: values).write(
      to: reportURL.deletingLastPathComponent().appendingPathComponent("controller.json"),
      options: .atomic)
  }
  @objc func start() {
    recordControllerState()
    guard NSApp.isActive, !started else { return }
    started = true
    Task { @MainActor in
      if CommandLine.arguments.contains("--orphan-parent") { await orphanParent() }
      else { await runChecks() }
    }
  }
}

@main struct InputChecks {
  @MainActor static func main() {
    if CommandLine.arguments.contains("--foreign") { foreignInput() }
    app.setActivationPolicy(.regular)
    if CommandLine.arguments.contains("--target") {
      let target = Target()
      withExtendedLifetime(target) { app.run() }
    } else {
      let controller = FixtureController()
      withExtendedLifetime(controller) { app.run() }
    }
  }
}
