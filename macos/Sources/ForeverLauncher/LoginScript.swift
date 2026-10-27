import Foundation

func loginGlueScript(_ login: SavedLogin) throws -> String {
  guard login.isValid else { throw SavedLoginError.invalid }
  // Decimal UTF-8 escapes preserve every byte without allowing Lua or argument injection.
  func literal(_ text: String) -> String {
    "'" + text.utf8.map { String(format: "\\%03u", $0) }.joined() + "'"
  }
  return C.loginScriptTemplate
    .replacingOccurrences(of: "@@ACCOUNT@@", with: literal(login.account))
    .replacingOccurrences(of: "@@PASSWORD@@", with: literal(login.password))
}
