import Foundation
import Security

struct SavedLogin: Codable, Equatable {
  let account: String
  let password: String

  var isValid: Bool {
    !account.isEmpty && account.utf16.count <= 320
      && !password.isEmpty && password.utf16.count <= 128
      && !(account + password).unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) }
  }
}

enum SavedLoginError: Error {
  case invalid
  case keychain(OSStatus)
}

private func loginQuery(service: String) -> [String: Any] {
  // Ad-hoc desktop builds have no profile-authorized access group. Use the login
  // keychain through SecItem; never broaden its default application access list.
  [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: "saved-login",
  ]
}

func readSavedLogin(service: String) throws -> SavedLogin? {
  var query = loginQuery(service: service)
  query[kSecReturnData as String] = true
  query[kSecMatchLimit as String] = kSecMatchLimitOne
  var result: CFTypeRef?
  let status = SecItemCopyMatching(query as CFDictionary, &result)
  if status == errSecItemNotFound { return nil }
  guard status == errSecSuccess else { throw SavedLoginError.keychain(status) }
  guard let data = result as? Data,
    let login = try? JSONDecoder().decode(SavedLogin.self, from: data), login.isValid else {
    throw SavedLoginError.invalid
  }
  return login
}

func writeSavedLogin(_ login: SavedLogin, service: String) throws {
  guard login.isValid else { throw SavedLoginError.invalid }
  let query = loginQuery(service: service)
  let data = try JSONEncoder().encode(login)
  let attributes = [kSecValueData as String: data]
  var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
  if status == errSecItemNotFound {
    var item = query
    item[kSecValueData as String] = data
    status = SecItemAdd(item as CFDictionary, nil)
  }
  guard status == errSecSuccess else { throw SavedLoginError.keychain(status) }
}

func forgetSavedLogin(service: String) throws {
  let status = SecItemDelete(loginQuery(service: service) as CFDictionary)
  guard status == errSecSuccess || status == errSecItemNotFound else {
    throw SavedLoginError.keychain(status)
  }
}
