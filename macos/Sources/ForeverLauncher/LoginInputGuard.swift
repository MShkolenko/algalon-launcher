import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import Security

enum AutomaticLoginError: String, Error {
  case permission, unsupported, targetChanged, notReady, input, interrupted
  case accessibility, random, sessionTap, tapSource, tapDisabled
}

private func loginAXValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
  var value: CFTypeRef?
  return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    ? value : nil
}

func loginWindowMatches(
  pid: Int32, windowID: CGWindowID, frame: CGRect, point: CGPoint,
  requireFocus: Bool = true
) -> Bool {
  let system = AXUIElementCreateSystemWide()
  let target = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(system, 0.05)
  AXUIElementSetMessagingTimeout(target, 0.05)
  var element: AXUIElement?
  var owner: pid_t = 0
  // Drawing rectangles include click-through system overlays; AX uses the effective hit target.
  guard
    AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
      == .success, let element, AXUIElementGetPid(element, &owner) == .success,
    owner == pid,
    let hitWindow = loginAXValue(element, kAXWindowAttribute)
      ?? (loginAXValue(element, kAXRoleAttribute) as? String == kAXWindowRole ? element : nil)
  else { return false }
  if requireFocus {
    guard let focusedApp = loginAXValue(system, kAXFocusedApplicationAttribute),
      CFGetTypeID(focusedApp) == AXUIElementGetTypeID(),
      AXUIElementGetPid(focusedApp as! AXUIElement, &owner) == .success, owner == pid,
      let focused = loginAXValue(target, kAXFocusedWindowAttribute),
      CFEqual(focused, hitWindow)
    else { return false }
  }
  let windows =
    CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID) as? [[String: Any]]
  for item in windows ?? [] {
    guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
      (item[kCGWindowAlpha as String] as? Double ?? 0) > 0,
      let bounds = item[kCGWindowBounds as String] as? [String: Double],
      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
      rect.contains(point)
    else { continue }
    return (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
      && abs(rect.minX - frame.minX) <= 1 && abs(rect.minY - frame.minY) <= 1
      && abs(rect.width - frame.width) <= 1 && abs(rect.height - frame.height) <= 1
  }
  return false
}

private final class LoginMouseTapState: @unchecked Sendable {
  let channel: LoginInputChannel
  private let lock = NSLock()
  private var values: [Int64] = []
  init(channel: LoginInputChannel) { self.channel = channel }
  func add(_ value: Int64) {
    lock.lock()
    values.append(value)
    if values.count > 8 { values.removeFirst() }
    lock.unlock()
  }
  func contains(_ value: Int64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return values.contains(value)
  }
}

// The private process filters queued keys; this short-lived mouse tap also sees outside clicks.
@MainActor final class LoginInputGuard {
  private let channel: LoginInputChannel
  private let pid: Int32
  private let windowID: CGWindowID
  private let frame: CGRect
  private let anchor: CGPoint
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var finished = false
  private let mouseState: LoginMouseTapState

  init(
    pid: Int32, windowID: CGWindowID, frame: CGRect, anchor: CGPoint,
    channel: LoginInputChannel
  ) throws {
    guard AXIsProcessTrusted() else { throw AutomaticLoginError.accessibility }
    self.pid = pid
    self.windowID = windowID
    self.frame = frame
    self.anchor = anchor
    self.channel = channel
    mouseState = LoginMouseTapState(channel: channel)
    let events: [CGEventType] = [
      .mouseMoved, .leftMouseDown, .leftMouseUp,
      .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
      .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
      .tabletPointer, .tabletProximity,
    ]
    let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    let context = Unmanaged.passUnretained(mouseState).toOpaque()
    let callback: CGEventTapCallBack = { _, type, event, pointer in
      guard let pointer else { return Unmanaged.passUnretained(event) }
      let state = Unmanaged<LoginMouseTapState>.fromOpaque(pointer).takeUnretainedValue()
      let input = state.channel
      let own =
        event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
        && state.contains(event.getIntegerValueField(.eventSourceUserData))
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput || !own {
        input.abort()
      }
      return Unmanaged.passUnretained(event)
    }
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap,
        options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: context)
    else {
      throw AutomaticLoginError.sessionTap
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      CFMachPortInvalidate(tap)
      throw AutomaticLoginError.tapSource
    }
    self.tap = tap
    self.source = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  func arm() async throws {
    guard (0..<128).allSatisfy({ !CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) })
    else {
      channel.abort()
      throw AutomaticLoginError.interrupted
    }
    try await channel.arm(windowID: windowID)
    try check()
  }

  func check() throws {
    try channel.check()
    guard !finished, let tap, CGEvent.tapIsEnabled(tap: tap) else {
      channel.abort()
      throw AutomaticLoginError.tapDisabled
    }
    guard loginWindowMatches(pid: pid, windowID: windowID, frame: frame, point: anchor) else {
      channel.abort()
      throw AutomaticLoginError.targetChanged
    }
  }

  func post(_ events: [CGEvent], deliver: (CGEvent) -> Void) async throws {
    _ = try await channel.post(
      events, beforePost: { try self.check() },
      deliver: { event in
        self.mouseState.add(event.getIntegerValueField(.eventSourceUserData))
        deliver(event)
      })
  }

  func requireDeliveryProof() throws { try channel.requireDeliveryProof() }

  func requireSecureField() async throws { try await channel.requireSecureField() }

  func complete() async throws {
    try await channel.finish()
    finished = true
    stopTap()
  }

  func finish() {
    if !finished { channel.abort() }
    stopTap()
  }

  private func stopTap() {
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    if let tap { CFMachPortInvalidate(tap) }
    source = nil
    tap = nil
  }
}
