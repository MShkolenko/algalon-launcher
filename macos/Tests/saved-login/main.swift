import Foundation
import Security

// Exercise the real OS store with disposable, fictional credentials, without a UI prompt.
let service = "org.algalon.launcher.tests.\(UUID().uuidString)"
var interaction: DarwinBoolean = true
precondition(SecKeychainGetUserInteractionAllowed(&interaction) == errSecSuccess)
precondition(SecKeychainSetUserInteractionAllowed(false) == errSecSuccess)
defer { SecKeychainSetUserInteractionAllowed(interaction.boolValue) }
defer {
  try? forgetSavedLogin(service: service)
  try? forgetSavedLogin(service: service + ".other")
  try? forgetSavedLogin(service: service + ".malformed")
}

func check(_ value: Bool) {
  precondition(value, "saved-login contract failed")
}

let labels: [LoginLabel: [CGRect]] = [
  .account: [CGRect(x: 0.4, y: 0.27, width: 0.2, height: 0.025)],
  .password: [CGRect(x: 0.46, y: 0.34, width: 0.08, height: 0.025)],
  .remember: [CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.025)],
  .login: [CGRect(x: 0.46, y: 0.46, width: 0.08, height: 0.025)],
]
let layout = LoginLayout(labels: labels)
check(layout != nil && abs(layout!.account.y - 0.3175) < 0.00001)
check(abs(layout!.password.y - 0.3825) < 0.00001)
let offsetFrame = CGRect(x: -1200, y: 90, width: 1000, height: 700)
let content = offsetFrame
let screen = layout!.screenPoint(layout!.password, frame: offsetFrame, content: content)
check(screen != nil && abs(screen!.x + 700) < 0.00001
  && abs(screen!.y - 357.75) < 0.00001)
check(layout!.screenPoint(layout!.password, frame: offsetFrame,
  content: CGRect(x: -1200, y: 90, width: 1001.1, height: 700)) == nil)
// Native windowed Retina capture: contentRect and frame have the same screen origin.
let windowed = CGRect(x: 704, y: 382, width: 640, height: 388)
check(layout!.screenPoint(CGPoint(x: 0.5, y: 0.5), frame: windowed, content: windowed)
  == CGPoint(x: 1024, y: 576))
let fullscreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
check(layout!.screenPoint(CGPoint(x: 0.5, y: 0.5), frame: fullscreen, content: fullscreen)
  == CGPoint(x: 960, y: 540))
for bad in [CGRect(x: 0, y: 0, width: 640, height: 388),
            CGRect(x: 704, y: 382, width: 0, height: 388),
            CGRect(x: CGFloat.infinity, y: 382, width: 640, height: 388)] {
  check(layout!.screenPoint(layout!.password, frame: windowed, content: bad) == nil)
}
check(layout!.screenPoint(CGPoint(x: .nan, y: 0.5), frame: windowed, content: windowed) == nil)
check(layout!.screenPoint(CGPoint(x: 0.5, y: 0.5),
  frame: CGRect(x: -500, y: -200, width: 1280, height: 800),
  content: CGRect(x: 0, y: 0, width: 700, height: 500)) == nil)
for edge in 0..<4 {
  for delta in [-1.1, -1.0, 1.0, 1.1] {
    var capture = windowed
    switch edge {
    case 0:
      capture.origin.x += delta
      capture.size.width -= delta
    case 1: capture.size.width += delta
    case 2:
      capture.origin.y += delta
      capture.size.height -= delta
    default: capture.size.height += delta
    }
    let point = layout!.screenPoint(CGPoint(x: 0.5, y: 0.5), frame: windowed, content: capture)
    check((point != nil) == (abs(delta) <= 1))
  }
}
for kind in LoginLabel.allCases {
  var missing = labels
  missing[kind] = []
  check(LoginLayout(labels: missing) == nil)
  missing[kind] = [labels[kind]![0], labels[kind]![0]]
  check(LoginLayout(labels: missing) == nil)
}
var wrong = labels
wrong[.password] = labels[.login]
check(LoginLayout(labels: wrong) == nil)
wrong = labels
wrong[.password] = [CGRect(x: 0.1, y: 0.34, width: 0.08, height: 0.025)]
check(LoginLayout(labels: wrong) == nil)
wrong = labels
wrong[.account] = [CGRect(x: 0.4, y: 0.27, width: CGFloat.infinity, height: 0.025)]
check(LoginLayout(labels: wrong) == nil)
check(LoginLabel(text: "Email or Phone") == .account && LoginLabel(text: "Пароль") == .password)
check(LoginLabel(text: "Character Selection") == nil)

let first = SavedLogin(account: "fictional@example.invalid", password: "Ab12\"\\.é")
let second = SavedLogin(account: "other@example.invalid", password: "Replacement.")
check(first.isValid && second.isValid)
check(SavedLogin(account: "fake", password: String(repeating: "x", count: 128)).isValid)
check(!SavedLogin(account: "fake", password: String(repeating: "x", count: 129)).isValid)
for bad in [
  SavedLogin(account: "", password: "abc"),
  SavedLogin(account: "fake", password: ""),
  SavedLogin(account: "fake", password: "abc\n"),
  SavedLogin(account: "fake", password: "abc\0"),
  SavedLogin(account: "fake\t", password: "abc"),
  SavedLogin(account: "fake", password: String(repeating: "é", count: 513)),
] { check(!bad.isValid) }

do {
  check(try readSavedLogin(service: service) == nil)
  try writeSavedLogin(first, service: service)
  try writeSavedLogin(first, service: service + ".other")
  check(try readSavedLogin(service: service) == first)
  try writeSavedLogin(second, service: service)
  check(try readSavedLogin(service: service) == second)
  check(try readSavedLogin(service: service + ".other") == first)
  let malformed: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service + ".malformed",
    kSecAttrAccount as String: "saved-login",
    kSecValueData as String: Data("{}".utf8),
  ]
  check(SecItemAdd(malformed as CFDictionary, nil) == errSecSuccess)
  do {
    _ = try readSavedLogin(service: service + ".malformed")
    preconditionFailure("malformed credential was accepted")
  } catch SavedLoginError.invalid {}
  do {
    try writeSavedLogin(SavedLogin(account: "fake", password: "bad\n"), service: service)
    preconditionFailure("invalid login was saved")
  } catch SavedLoginError.invalid {}
  check(try readSavedLogin(service: service) == second)
  try forgetSavedLogin(service: service)
  try forgetSavedLogin(service: service)
  check(try readSavedLogin(service: service) == nil)
  print("PASS: real Keychain CRUD, exact Unicode/password punctuation, validation, realm isolation, layout admission")
} catch SavedLoginError.keychain(let status) {
  fputs("Keychain test unavailable without interaction (status \(status)); not a pass.\n", stderr)
  exit(2)
}
