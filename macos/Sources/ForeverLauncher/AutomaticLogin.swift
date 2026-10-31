import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit
import Vision

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
  let accessibility = AXIsProcessTrusted()
  let capture = CGPreflightScreenCaptureAccess()
  if !input { _ = CGRequestPostEventAccess() }
  if !accessibility {
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  }
  if !capture { _ = CGRequestScreenCaptureAccess() }
  while true {
    let inputAllowed = CGPreflightPostEventAccess()
    let accessibilityAllowed = AXIsProcessTrusted()
    let captureAllowed = CGPreflightScreenCaptureAccess()
    log("automatic filling permissions: input=\(inputAllowed), "
      + "accessibility=\(accessibilityAllowed), capture=\(captureAllowed)")
    if inputAllowed && accessibilityAllowed && captureAllowed { return .automatic }
    let alert = NSAlert()
    alert.messageText = "Allow automatic login filling"
    alert.informativeText = "Accessibility: \(accessibilityAllowed ? "allowed" : "not available to this process"). "
      + "Native input: \(inputAllowed ? "allowed" : "not available to this process"). "
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

#if compiler(>=6.2)
@concurrent
#endif
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
      NSApplication.shared.yieldActivation(to: app)
      _ = app.activate()
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
      let input = try LoginInputGuard(pid: pid, windowID: window.windowID,
                                     frame: window.frame, anchor: passwordPoint)
      defer { input.finish() }
      try input.check()
      try assertLoginTarget(pid: pid, executable: executable)
      log("automatic filling: login layout admitted; interruption guard active")
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
          try loginKey(CGKeyCode(kVK_ANSI_A), pid: pid, executable: executable, input: input, flags: .maskCommand)
          try loginKey(CGKeyCode(kVK_Delete), pid: pid, executable: executable, input: input)
          throw AutomaticLoginError.input
        }
      }
      if !accountMatches(initial.accounts) {
        try await loginClick(accountPoint, windowID: window.windowID, frame: window.frame,
                             pid: pid, executable: executable, input: input)
        try await typeLoginText("AlgalonFocus", pid: pid, executable: executable, input: input)
        try await verifyAccount("AlgalonFocus")
        try await typeLoginText(login.account, pid: pid, executable: executable, input: input)
        try await verifyAccount(login.account)
        log("automatic filling: account input verified")
      } else {
        log("automatic filling: remembered account retained")
      }
      try await loginClick(passwordPoint, windowID: window.windowID, frame: window.frame,
                           pid: pid, executable: executable, input: input)
      try await Task.sleep(nanoseconds: 100_000_000)
      try loginKey(CGKeyCode(kVK_ANSI_A), pid: pid, executable: executable, input: input,
                   flags: .maskCommand)
      try loginKey(CGKeyCode(kVK_Delete), pid: pid, executable: executable, input: input)
      func probeFrame() async throws -> MaskedLoginField {
        try await Task.sleep(nanoseconds: 180_000_000)
        try input.check()
        try assertLoginTarget(pid: pid, executable: executable)
        guard let (current, capture, rect) = try await captureLoginWindow(pid: pid),
          current.windowID == window.windowID, current.frame == window.frame,
          rect == contentRect,
          let band = MaskedLoginField(image: capture, region: layout.passwordBand) else {
          throw AutomaticLoginError.targetChanged
        }
        return band
      }
      let empty = try await probeFrame()
      try await typeLoginText("W", pid: pid, executable: executable, input: input, clear: false)
      let wide = try await probeFrame()
      try await typeLoginText("i", pid: pid, executable: executable, input: input, clear: false)
      let pair = try await probeFrame()
      try loginKey(CGKeyCode(kVK_Delete), pid: pid, executable: executable, input: input)
      try loginKey(CGKeyCode(kVK_Delete), pid: pid, executable: executable, input: input)
      let erased = try await probeFrame()
      guard MaskedLoginField.confirms(empty: empty, wide: wide, pair: pair, erased: erased) else {
        throw AutomaticLoginError.input
      }
      try await verifyAccount(login.account)
      try input.requireLiveTaps()
      log("automatic filling: masked password focus and probe removal confirmed")
      try await typeLoginText(login.password, pid: pid, executable: executable, input: input)
      try await verifyAccount(login.account)
      return // Filling is automatic; submitting Log In stays an explicit action.
    }
    try await Task.sleep(nanoseconds: 750_000_000)
  }
  throw AutomaticLoginError.notReady
}
