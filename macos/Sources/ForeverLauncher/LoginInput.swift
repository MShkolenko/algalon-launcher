import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Darwin
import Foundation

func loginProcessMatches(pid: Int32, executable: String) -> Bool {
  var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
  guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
  return URL(fileURLWithPath: String(cString: path))
    .resolvingSymlinksInPath().standardizedFileURL.path == executable
}

@MainActor func assertLoginTarget(pid: Int32, executable: String) throws {
  guard CGPreflightPostEventAccess(), CGPreflightScreenCaptureAccess() else {
    throw AutomaticLoginError.permission
  }
  guard AXIsProcessTrusted() else { throw AutomaticLoginError.accessibility }
  guard loginProcessMatches(pid: pid, executable: executable),
    let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
    app.executableURL?.resolvingSymlinksInPath().path == executable,
    NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
  else {
    throw AutomaticLoginError.targetChanged
  }
}

@MainActor func loginKey(
  _ code: CGKeyCode, pid: Int32, executable: String,
  input: LoginInputGuard, flags: CGEventFlags = []
) async throws {
  try input.check()
  try assertLoginTarget(pid: pid, executable: executable)
  var events: [CGEvent] = []
  for down in [true, false] {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
      throw AutomaticLoginError.input
    }
    event.flags = flags
    events.append(event)
  }
  try await input.post(events) { $0.postToPid(pid) }
}

// Initial activation is a nonsecret click in an independently recognized, exact owned window.
@MainActor func activateLoginWindow(
  _ point: CGPoint, windowID: CGWindowID, frame: CGRect,
  pid: Int32, executable: String
) async throws {
  let application = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(application, 0.05)
  var value: CFTypeRef?
  if AXUIElementCopyAttributeValue(application, kAXMainWindowAttribute as CFString, &value)
    == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID()
  {
    _ = AXUIElementPerformAction(value as! AXUIElement, kAXRaiseAction as CFString)
  }
  var downPosted = false
  defer {
    if downPosted,
      let up = CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseUp,
        mouseCursorPosition: point, mouseButton: .left)
    {
      up.flags = []
      up.setIntegerValueField(.mouseEventClickState, value: 1)
      up.post(tap: .cghidEventTap)
    }
  }
  for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    guard CGPreflightPostEventAccess(), AXIsProcessTrusted(),
      loginProcessMatches(pid: pid, executable: executable),
      loginWindowMatches(
        pid: pid, windowID: windowID, frame: frame, point: point,
        requireFocus: false),
      let event = CGEvent(
        mouseEventSource: nil, mouseType: type,
        mouseCursorPosition: point, mouseButton: .left)
    else {
      throw AutomaticLoginError.targetChanged
    }
    if type == .mouseMoved, CGWarpMouseCursorPosition(point) != .success {
      throw AutomaticLoginError.input
    }
    event.flags = []
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
    if type == .leftMouseDown { downPosted = true }
    if type == .leftMouseUp { downPosted = false }
    try await Task.sleep(nanoseconds: 100_000_000)
  }
  try assertLoginTarget(pid: pid, executable: executable)
}

@MainActor func loginClick(
  _ point: CGPoint, windowID: CGWindowID, frame: CGRect,
  pid: Int32, executable: String,
  input: LoginInputGuard
) async throws {
  try input.check()
  try assertLoginTarget(pid: pid, executable: executable)
  var count: UInt32 = 0
  guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
    throw AutomaticLoginError.notReady
  }
  var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
  guard CGGetActiveDisplayList(count, &displays, &count) == .success,
    displays.prefix(Int(count)).contains(where: { CGDisplayBounds($0).contains(point) })
  else {
    throw AutomaticLoginError.notReady
  }
  var mouseDownPosted = false
  var downTag: Int64 = 0
  defer {
    if mouseDownPosted,
      let release = CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseUp,
        mouseCursorPosition: point, mouseButton: .left)
    {
      release.flags = []
      release.setIntegerValueField(.mouseEventClickState, value: 1)
      release.setIntegerValueField(.eventSourceUserData, value: downTag)
      release.post(tap: .cghidEventTap)
    }
  }
  for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    try input.check()
    try assertLoginTarget(pid: pid, executable: executable)
    guard loginWindowMatches(pid: pid, windowID: windowID, frame: frame, point: point) else {
      throw AutomaticLoginError.targetChanged
    }
    guard
      let event = CGEvent(
        mouseEventSource: nil, mouseType: type,
        mouseCursorPosition: point, mouseButton: .left)
    else { throw AutomaticLoginError.input }
    event.flags = []
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    try await input.post([event]) { posted in
      if type == .leftMouseDown {
        mouseDownPosted = true
        downTag = posted.getIntegerValueField(.eventSourceUserData)
      }
      posted.post(tap: .cghidEventTap)
    }
    if type == .leftMouseUp { mouseDownPosted = false }
    if type != .leftMouseUp { try await Task.sleep(nanoseconds: 100_000_000) }
  }
}

@MainActor func typeLoginText(
  _ value: String, pid: Int32, executable: String,
  input: LoginInputGuard, clear: Bool = true
) async throws {
  if clear {
    try await loginKey(
      CGKeyCode(kVK_ANSI_A), pid: pid, executable: executable, input: input,
      flags: .maskCommand)
    try await loginKey(CGKeyCode(kVK_Delete), pid: pid, executable: executable, input: input)
  }
  for scalar in value.unicodeScalars {
    try Task.checkCancellation()
    try input.check()
    try assertLoginTarget(pid: pid, executable: executable)
    let units = Array(String(scalar).utf16)
    var events: [CGEvent] = []
    for down in [true, false] {
      guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else {
        throw AutomaticLoginError.input
      }
      event.flags = []
      if down {
        units.withUnsafeBufferPointer {
          event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
        }
      }
      events.append(event)
    }
    try await input.post(events) { $0.postToPid(pid) }
    try await Task.sleep(nanoseconds: 20_000_000)
  }
}
