import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import Security

enum AutomaticLoginError: String, Error {
  case permission, unsupported, targetChanged, notReady, input, interrupted
  case accessibility, secureInput, random, sessionTap, processTap, tapSource, tapDisabled
}

private func loginAXValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
  var value: CFTypeRef?
  return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    ? value : nil
}

func loginWindowMatches(pid: Int32, windowID: CGWindowID, frame: CGRect, point: CGPoint) -> Bool {
  let system = AXUIElementCreateSystemWide()
  let target = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(system, 0.05)
  AXUIElementSetMessagingTimeout(target, 0.05)
  var element: AXUIElement?
  var owner: pid_t = 0
  // Drawing rectangles include click-through system overlays; AX uses the effective hit target.
  guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
    == .success, let element, AXUIElementGetPid(element, &owner) == .success,
    owner == pid,
    let focusedApp = loginAXValue(system, kAXFocusedApplicationAttribute),
    CFGetTypeID(focusedApp) == AXUIElementGetTypeID(),
    AXUIElementGetPid(focusedApp as! AXUIElement, &owner) == .success, owner == pid,
    let focused = loginAXValue(target, kAXFocusedWindowAttribute),
    let hitWindow = loginAXValue(element, kAXWindowAttribute)
      ?? (loginAXValue(element, kAXRoleAttribute) as? String == kAXWindowRole ? element : nil),
    CFEqual(focused, hitWindow) else { return false }
  let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID) as? [[String: Any]]
  for item in windows ?? [] {
    guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
      (item[kCGWindowAlpha as String] as? Double ?? 0) > 0,
      let bounds = item[kCGWindowBounds as String] as? [String: Double],
      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
      rect.contains(point) else { continue }
    return (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
      && abs(rect.minX - frame.minX) <= 1 && abs(rect.minY - frame.minY) <= 1
      && abs(rect.width - frame.width) <= 1 && abs(rect.height - frame.height) <= 1
  }
  return false
}

// Short-lived native taps; store only cancellation, never key values or event contents.
final class LoginInputGuard {
  private let lock = NSLock()
  private var interrupted = false
  private var closed = false
  private var keysPosted = 0
  private var keysSeen = 0
  private var clicksSeen = 0
  private var taps: [CFMachPort] = []
  private var sources: [CFRunLoopSource] = []
  private let nonce: Int64
  private let pid: Int32
  private let windowID: CGWindowID
  private let frame: CGRect
  private let anchor: CGPoint

  init(pid: Int32, windowID: CGWindowID, frame: CGRect, anchor: CGPoint) throws {
    var value: Int64 = 0
    guard AXIsProcessTrusted() else { throw AutomaticLoginError.accessibility }
    guard !IsSecureEventInputEnabled() else { throw AutomaticLoginError.secureInput }
    guard SecRandomCopyBytes(kSecRandomDefault, MemoryLayout.size(ofValue: value), &value)
      == errSecSuccess, value != 0 else { throw AutomaticLoginError.random }
    nonce = value
    self.pid = pid
    self.windowID = windowID
    self.frame = frame
    self.anchor = anchor
    var events: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved,
      .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
      .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
      .tabletPointer, .tabletProximity]
    if let systemDefined = CGEventType(rawValue: 14) { events.append(systemDefined) }
    let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    let callback: CGEventTapCallBack = { _, type, event, context in
      guard let context else { return nil }
      let guardInput = Unmanaged<LoginInputGuard>.fromOpaque(context).takeUnretainedValue()
      return guardInput.observe(type, event: event, session: true)
        ? Unmanaged.passUnretained(event) : nil
    }
    let processCallback: CGEventTapCallBack = { _, type, event, context in
      guard let context else { return nil }
      let guardInput = Unmanaged<LoginInputGuard>.fromOpaque(context).takeUnretainedValue()
      return guardInput.observe(type, event: event, session: false)
        ? Unmanaged.passUnretained(event) : nil
    }
    let context = Unmanaged.passUnretained(self).toOpaque()
    // Filtering taps use the existing Accessibility grant; no Input Monitoring grant or key logger.
    guard let session = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
      options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: context) else {
      throw AutomaticLoginError.sessionTap
    }
    taps.append(session)
    // PID-posted events bypass the session tap: this second tap drops queued own key-downs on abort.
    guard let process = CGEvent.tapCreateForPid(pid: pid, place: .headInsertEventTap,
      options: .defaultTap, eventsOfInterest: mask, callback: processCallback, userInfo: context) else {
      stop()
      throw AutomaticLoginError.processTap
    }
    taps.append(process)
    for tap in taps {
      guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
        stop()
        throw AutomaticLoginError.tapSource
      }
      sources.append(source)
      CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
      CGEvent.tapEnable(tap: tap, enable: true)
    }
  }

  private func observe(_ type: CGEventType, event: CGEvent, session: Bool) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      interrupted = true
      return true
    }
    let own = event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
      && event.getIntegerValueField(.eventSourceUserData) == nonce
    if !own { interrupted = true }
    if own && !session && type == .keyDown { keysSeen += 1 }
    if own && session && type == .leftMouseDown { clicksSeen += 1 }
    // Always pass foreign input and releases; only our remaining input is cancelled.
    return !own || (!interrupted && !closed) || type == .keyUp || type == .leftMouseUp
  }

  func check() throws {
    lock.lock()
    let cancelled = interrupted || closed
    lock.unlock()
    guard !cancelled else { throw AutomaticLoginError.interrupted }
    guard !IsSecureEventInputEnabled() else { cancel(); throw AutomaticLoginError.secureInput }
    guard taps.count == 2, taps.allSatisfy({ CGEvent.tapIsEnabled(tap: $0) }) else {
      cancel()
      throw AutomaticLoginError.tapDisabled
    }
    guard matchesWindow() else {
      cancel()
      throw AutomaticLoginError.targetChanged
    }
  }

  private func cancel() {
    lock.lock()
    interrupted = true
    lock.unlock()
  }

  func requireLiveTaps() throws {
    try check()
    lock.lock()
    defer { lock.unlock() }
    guard clicksSeen > 0 else { throw AutomaticLoginError.sessionTap }
    guard keysPosted > 0, keysSeen == keysPosted else { throw AutomaticLoginError.processTap }
  }

  @MainActor func awaitDelivery() async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 0.25
    while true {
      try Task.checkCancellation()
      let state = deliveryState()
      guard !state.cancelled else { throw AutomaticLoginError.interrupted }
      if state.delivered { return }
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        cancel()
        throw AutomaticLoginError.processTap
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  private func deliveryState() -> (cancelled: Bool, delivered: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (interrupted || closed, keysSeen == keysPosted)
  }

  private func matchesWindow() -> Bool {
    loginWindowMatches(pid: pid, windowID: windowID, frame: frame, point: anchor)
  }

  func tag(_ event: CGEvent) {
    lock.lock()
    if event.type == .keyDown { keysPosted += 1 }
    lock.unlock()
    event.setIntegerValueField(.eventSourceUserData, value: nonce)
  }

  @MainActor func finish() {
    lock.lock()
    guard !closed else { lock.unlock(); return }
    closed = true
    lock.unlock()
    // Retain the filtering taps for queued input; this task does not inherit cancellation.
    Task { @MainActor [self] in
      try? await Task.sleep(nanoseconds: 250_000_000)
      stop()
    }
  }

  func stop() {
    for source in sources { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    for tap in taps { CFMachPortInvalidate(tap) }
    sources.removeAll()
    taps.removeAll()
  }

  deinit { stop() }
}
