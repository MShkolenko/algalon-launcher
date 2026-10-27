import AppKit
import Carbon
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit
import Vision

enum AutomaticLoginError: String, Error {
  case permission, unsupported, targetChanged, notReady, input
}

private func loginProcessMatches(pid: Int32, executable: String) -> Bool {
  var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
  return proc_pidpath(pid, &path, UInt32(path.count)) > 0
    && realPath(URL(fileURLWithPath: String(cString: path))) == executable
}

enum LoginPermission {
  case automatic, manual, cancel
}

@MainActor func automaticLoginPermissions(log: (String) -> Void) async -> LoginPermission {
  guard #available(macOS 14, *) else {
    let alert = NSAlert()
    alert.messageText = "Automatic filling requires macOS 14 or later"
    alert.informativeText = "Choose Manual Login to use this launcher on macOS 12 or 13."
    _ = await presentLoginAlert(alert)
    return .manual
  }
  let input = CGPreflightPostEventAccess()
  let capture = CGPreflightScreenCaptureAccess()
  if !input { _ = CGRequestPostEventAccess() }
  if !capture { _ = CGRequestScreenCaptureAccess() }
  while true {
    let inputAllowed = CGPreflightPostEventAccess()
    let captureAllowed = CGPreflightScreenCaptureAccess()
    log("automatic filling permissions: input=\(inputAllowed), capture=\(captureAllowed)")
    if inputAllowed && captureAllowed { return .automatic }
    let alert = NSAlert()
    alert.messageText = "Allow automatic login filling"
    alert.informativeText = "Accessibility: \(inputAllowed ? "allowed" : "not available to this process"). "
      + "Screen Recording: \(captureAllowed ? "allowed" : "not available to this process").\n\n"
      + "macOS requires Accessibility for native input and Screen Recording "
      + "to recognize only the private WoW login window. Images are processed on this Mac, "
      + "never saved or sent. Grant these to Algalon Launcher in System Settings, then "
      + "try again. If macOS requires a restart, cancel and reopen the launcher once. "
      + "Manual Login works without these permissions."
    alert.addButton(withTitle: "Try Again")
    alert.addButton(withTitle: "Manual Login")
    alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
    switch await presentLoginAlert(alert) {
    case .alertFirstButtonReturn: continue
    case .alertSecondButtonReturn: return .manual
    default: return .cancel
    }
  }
}

private func recognizedLoginScreen(_ image: CGImage, account: String) async throws
  -> (labels: [LoginLabel: [CGRect]], accounts: [CGRect]) {
  // Only fixed labels and exact expected-account matches cross back to the UI actor.
  let request = VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  request.usesLanguageCorrection = false
  let supported = try request.supportedRecognitionLanguages()
  request.recognitionLanguages = ["en-US", "ru-RU"].filter { supported.contains($0) }
  try VNImageRequestHandler(cgImage: image).perform([request])
  var labels: [LoginLabel: [CGRect]] = [:]
  var accounts: [CGRect] = []
  for observation in request.results ?? [] {
    guard let text = observation.topCandidates(1).first, text.confidence >= 0.75 else { continue }
    let b = observation.boundingBox
    let rect = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
    if let kind = LoginLabel(text: text.string) { labels[kind, default: []].append(rect) }
    if text.string.caseInsensitiveCompare(account) == .orderedSame { accounts.append(rect) }
  }
  return (labels, accounts)
}

@MainActor private func assertLoginTarget(pid: Int32, executable: String) throws {
  guard CGPreflightPostEventAccess(), CGPreflightScreenCaptureAccess() else {
    throw AutomaticLoginError.permission
  }
  guard loginProcessMatches(pid: pid, executable: executable),
    let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
    app.executableURL?.resolvingSymlinksInPath().path == executable,
    NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
    throw AutomaticLoginError.targetChanged
  }
}

@MainActor private func loginKey(_ code: CGKeyCode, pid: Int32, executable: String,
                                flags: CGEventFlags = []) throws {
  try assertLoginTarget(pid: pid, executable: executable)
  for down in [true, false] {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
      throw AutomaticLoginError.input
    }
    event.flags = flags
    event.postToPid(pid)
  }
}

@MainActor private func loginClick(_ point: CGPoint, windowID: CGWindowID, frame: CGRect,
                                  pid: Int32, executable: String) async throws {
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
  guard CGWarpMouseCursorPosition(point) == .success else { throw AutomaticLoginError.input }
  for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    try assertLoginTarget(pid: pid, executable: executable)
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID) as? [[String: Any]]
    let top = windows?.first { item in
      guard (item[kCGWindowAlpha as String] as? Double ?? 0) > 0,
        let bounds = item[kCGWindowBounds as String] as? [String: Double],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
      return rect.contains(point)
    }
    guard (top?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
      (top?[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID,
      let bounds = top?[kCGWindowBounds as String] as? [String: Double],
      let current = CGRect(dictionaryRepresentation: bounds as CFDictionary),
      abs(current.minX - frame.minX) <= 1, abs(current.minY - frame.minY) <= 1,
      abs(current.width - frame.width) <= 1, abs(current.height - frame.height) <= 1 else {
      throw AutomaticLoginError.targetChanged
    }
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
      mouseCursorPosition: point, mouseButton: .left) else { throw AutomaticLoginError.input }
    event.flags = []
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
    if type != .leftMouseUp { try await Task.sleep(nanoseconds: 100_000_000) }
  }
}

@MainActor private func typeLoginText(_ value: String, pid: Int32,
                                    executable: String) async throws {
  try loginKey(CGKeyCode(kVK_ANSI_A), pid: pid, executable: executable, flags: .maskCommand)
  try loginKey(CGKeyCode(kVK_Delete), pid: pid, executable: executable)
  for scalar in value.unicodeScalars {
    try Task.checkCancellation()
    try assertLoginTarget(pid: pid, executable: executable)
    let units = Array(String(scalar).utf16)
    for down in [true, false] {
      guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else {
        throw AutomaticLoginError.input
      }
      event.flags = []
      units.withUnsafeBufferPointer {
        event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
      }
      event.postToPid(pid)
    }
    try await Task.sleep(nanoseconds: 20_000_000)
  }
}

@available(macOS 14, *)
@MainActor private func captureLoginWindow(pid: Int32) async throws -> (SCWindow, CGImage, CGRect)? {
  let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
  let windows = content.windows.filter {
    $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width >= 600
  }
  guard windows.count == 1, let window = windows.first,
    window.title == "World of Warcraft" else { return nil }
  let filter = SCContentFilter(desktopIndependentWindow: window)
  guard filter.contentRect.width.isFinite, filter.contentRect.height.isFinite,
    filter.contentRect.width > 0, filter.contentRect.height > 0,
    filter.pointPixelScale.isFinite, filter.pointPixelScale > 0 else { return nil }
  let config = SCStreamConfiguration()
  let scale = min(CGFloat(filter.pointPixelScale),
                  1600 / max(filter.contentRect.width, filter.contentRect.height))
  config.width = max(1, Int(filter.contentRect.width * scale))
  config.height = max(1, Int(filter.contentRect.height * scale))
  config.showsCursor = false
  config.ignoreShadowsSingleWindow = true
  config.scalesToFit = true
  let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
  return (window, image, filter.contentRect)
}

@MainActor func fillPrivateLogin(_ login: SavedLogin, pid: Int32, executable: String,
                               log: (String) -> Void) async throws {
  guard login.isValid else { throw SavedLoginError.invalid }
  guard #available(macOS 14, *) else { throw AutomaticLoginError.unsupported }
  let deadline = ProcessInfo.processInfo.systemUptime + 90
  var requestedFocus = false
  while ProcessInfo.processInfo.systemUptime < deadline {
    try Task.checkCancellation()
    guard loginProcessMatches(pid: pid, executable: executable) else {
      throw AutomaticLoginError.targetChanged
    }
    if !requestedFocus, let app = NSRunningApplication(processIdentifier: pid),
      app.isFinishedLaunching, app.executableURL?.resolvingSymlinksInPath().path == executable {
      // Play may start a background process. Request focus once, never steal it back later.
      _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
      requestedFocus = true
    }
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
      let (window, image, contentRect) = try await captureLoginWindow(pid: pid) {
      let initial = try await recognizedLoginScreen(image, account: login.account)
      guard let layout = LoginLayout(labels: initial.labels),
        let accountPoint = layout.screenPoint(layout.account, frame: window.frame,
          content: contentRect),
        let passwordPoint = layout.screenPoint(layout.password, frame: window.frame,
          content: contentRect) else {
        try await Task.sleep(nanoseconds: 750_000_000)
        continue
      }
      try assertLoginTarget(pid: pid, executable: executable)
      log("automatic filling: login layout admitted")
      func accountMatches(_ rects: [CGRect]) -> Bool {
        rects.filter { abs($0.midY - layout.account.y) < 0.04
          && abs($0.midX - layout.account.x) < 0.2 }.count == 1
      }
      func verifyAccount(_ expected: String) async throws {
        try await Task.sleep(nanoseconds: 250_000_000)
        guard let (current, capture, rect) = try await captureLoginWindow(pid: pid),
          current.windowID == window.windowID, current.frame == window.frame,
          rect == contentRect else { throw AutomaticLoginError.targetChanged }
        let result = try await recognizedLoginScreen(capture, account: expected)
        guard LoginLayout(labels: result.labels) != nil, accountMatches(result.accounts) else {
          // Clear a misplaced nonsecret probe; never leave a secret in the visible account field.
          try loginKey(CGKeyCode(kVK_ANSI_A), pid: pid, executable: executable, flags: .maskCommand)
          try loginKey(CGKeyCode(kVK_Delete), pid: pid, executable: executable)
          throw AutomaticLoginError.input
        }
      }
      if !accountMatches(initial.accounts) {
        try await loginClick(accountPoint, windowID: window.windowID, frame: window.frame,
                             pid: pid, executable: executable)
        try await typeLoginText("AlgalonFocus", pid: pid, executable: executable)
        try await verifyAccount("AlgalonFocus")
        try await typeLoginText(login.account, pid: pid, executable: executable)
        try await verifyAccount(login.account)
        log("automatic filling: account input verified")
      } else {
        log("automatic filling: remembered account retained")
      }
      try await loginClick(passwordPoint, windowID: window.windowID, frame: window.frame,
                           pid: pid, executable: executable)
      try await Task.sleep(nanoseconds: 100_000_000)
      try await typeLoginText("QQ", pid: pid, executable: executable)
      try await verifyAccount(login.account)
      log("automatic filling: password focus control passed")
      try await typeLoginText(login.password, pid: pid, executable: executable)
      try await verifyAccount(login.account)
      return // Filling is automatic; submitting Log In stays an explicit action.
    }
    try await Task.sleep(nanoseconds: 750_000_000)
  }
  throw AutomaticLoginError.notReady
}
