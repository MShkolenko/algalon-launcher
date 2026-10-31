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
    NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
    throw AutomaticLoginError.targetChanged
  }
}

@MainActor func loginKey(_ code: CGKeyCode, pid: Int32, executable: String,
                                input: LoginInputGuard, flags: CGEventFlags = []) throws {
  try input.check()
  try assertLoginTarget(pid: pid, executable: executable)
  for down in [true, false] {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
      throw AutomaticLoginError.input
    }
    event.flags = flags
    input.tag(event)
    event.postToPid(pid)
  }
}

@MainActor func loginClick(_ point: CGPoint, windowID: CGWindowID, frame: CGRect,
                                  pid: Int32, executable: String,
                                  input: LoginInputGuard) async throws {
  try input.check()
  try assertLoginTarget(pid: pid, executable: executable)
  var count: UInt32 = 0
  guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
    throw AutomaticLoginError.notReady
  }
  var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
  guard CGGetActiveDisplayList(count, &displays, &count) == .success,
    displays.prefix(Int(count)).contains(where: { CGDisplayBounds($0).contains(point) }) else {
    throw AutomaticLoginError.notReady
  }
  // Route mouse movement through WindowServer; direct PID clicks retain WoW's old hit target.
  var mouseDownPosted = false
  defer {
    if mouseDownPosted, let release = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
      mouseCursorPosition: point, mouseButton: .left) {
      input.tag(release)
      release.post(tap: .cghidEventTap)
    }
  }
  for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    try input.check()
    try assertLoginTarget(pid: pid, executable: executable)
    guard loginWindowMatches(pid: pid, windowID: windowID, frame: frame, point: point) else {
      throw AutomaticLoginError.targetChanged
    }
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
      mouseCursorPosition: point, mouseButton: .left) else { throw AutomaticLoginError.input }
    event.flags = []
    input.tag(event)
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
    if type == .leftMouseDown { mouseDownPosted = true }
    if type == .leftMouseUp { mouseDownPosted = false }
    if type != .leftMouseUp { try await Task.sleep(nanoseconds: 100_000_000) }
  }
}

@MainActor func typeLoginText(_ value: String, pid: Int32,
                                    executable: String, input: LoginInputGuard,
                                    clear: Bool = true) async throws {
  if clear {
    try loginKey(CGKeyCode(kVK_ANSI_A), pid: pid, executable: executable, input: input,
                 flags: .maskCommand)
    try loginKey(CGKeyCode(kVK_Delete), pid: pid, executable: executable, input: input)
  }
  for scalar in value.unicodeScalars {
    try Task.checkCancellation()
    try input.check()
    try assertLoginTarget(pid: pid, executable: executable)
    let units = Array(String(scalar).utf16)
    for down in [true, false] {
      guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else {
        throw AutomaticLoginError.input
      }
      event.flags = []
      input.tag(event)
      if down {
        units.withUnsafeBufferPointer {
          event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
        }
      }
      event.postToPid(pid)
    }
    try await input.awaitDelivery()
    try await Task.sleep(nanoseconds: 20_000_000)
  }
}
