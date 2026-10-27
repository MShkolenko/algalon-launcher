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

let first = SavedLogin(account: "fictional@example.invalid", password: "Ab12\"\\.é")
let second = SavedLogin(account: "other@example.invalid", password: "Replacement.")
check(first.isValid && second.isValid)
check(SavedLogin(account: "fake", password: String(repeating: "x", count: 128)).isValid)
check(!SavedLogin(account: "fake", password: String(repeating: "x", count: 129)).isValid)
let script = try loginGlueScript(SavedLogin(account: "Ab12", password: "'\\é."))
check(script.contains("local account, password = '\\065\\098\\049\\050', '\\039\\092\\195\\169\\046'"))
check(!script.contains("@@") && !script.contains("\""))
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
  print("PASS: real Keychain CRUD, exact Unicode/password punctuation, validation, realm isolation, Lua escaping")
} catch SavedLoginError.keychain(let status) {
  fputs("Keychain test unavailable without interaction (status \(status)); not a pass.\n", stderr)
  exit(2)
}
