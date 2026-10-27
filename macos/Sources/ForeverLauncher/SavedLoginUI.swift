import AppKit

enum LoginChoice {
  case fill(SavedLogin)
  case manual
  case cancel
}

@MainActor func presentLoginAlert(_ alert: NSAlert) async -> NSApplication.ModalResponse {
  let app = NSApplication.shared
  alert.layout()
  let session = app.beginModalSession(for: alert.window)
  defer {
    app.endModalSession(session)
    alert.window.orderOut(nil)
  }
  while !Task.isCancelled {
    let response = app.runModalSession(session)
    if response != .continue { return response }
    // A blocking runModal inside the async entry point prevents main-queue accessibility work.
    do { try await Task.sleep(nanoseconds: 50_000_000) } catch { break }
  }
  return .abort
}

@MainActor func chooseSavedLogin(service: String, realm: String) async -> LoginChoice {
  let app = NSApplication.shared
  app.setActivationPolicy(.regular)
  if app.mainMenu == nil {
    let menu = NSMenu()
    let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let commands = NSMenu(title: "Edit")
    for (title, action, key) in [
      ("Cut", #selector(NSText.cut(_:)), "x"),
      ("Copy", #selector(NSText.copy(_:)), "c"),
      ("Paste", #selector(NSText.paste(_:)), "v"),
      ("Select All", #selector(NSText.selectAll(_:)), "a"),
    ] { commands.addItem(withTitle: title, action: action, keyEquivalent: key) }
    edit.submenu = commands
    menu.addItem(edit)
    app.mainMenu = menu
  }
  app.activate(ignoringOtherApps: true)

  var stored: SavedLogin?
  do {
    stored = try readSavedLogin(service: service)
  } catch {
    let alert = NSAlert()
    alert.messageText = "Saved login is unavailable"
    alert.informativeText = "Keychain access failed. You can continue with manual game login. "
      + "The saved entry has not been removed."
    _ = await presentLoginAlert(alert)
    return .manual
  }

  let account = NSTextField(string: stored?.account ?? "")
  account.placeholderString = "Server account"
  account.setAccessibilityLabel("Server account")
  let password = NSSecureTextField(string: stored?.password ?? "")
  password.placeholderString = "Server password"
  password.setAccessibilityLabel("Server password")
  let remember = NSButton(checkboxWithTitle: "Remember on this Mac (Keychain)", target: nil, action: nil)
  remember.state = stored == nil ? .off : .on
  let fields = NSStackView(views: [
    NSTextField(labelWithString: "Server account"), account,
    NSTextField(labelWithString: "Server password"), password, remember,
  ])
  fields.orientation = .vertical
  fields.alignment = .leading
  fields.spacing = 8
  fields.setFrameSize(NSSize(width: 330, height: 160))
  account.widthAnchor.constraint(equalToConstant: 330).isActive = true
  password.widthAnchor.constraint(equalToConstant: 330).isActive = true
  account.nextKeyView = password
  password.nextKeyView = remember

  while true {
    let alert = NSAlert()
    alert.messageText = "\(realm) login"
    alert.informativeText = "The launcher fills the private WoW login screen automatically. "
      + "Wait for filling to finish, then click Log In in WoW. Use only your server account."
    alert.accessoryView = fields
    alert.addButton(withTitle: "Play")
    alert.addButton(withTitle: "Manual Login")
    alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
    if stored != nil { alert.addButton(withTitle: "Forget Saved Login") }
    alert.window.initialFirstResponder = account
    let response = await presentLoginAlert(alert)
    if response == .alertSecondButtonReturn { return .manual }
    if response == .alertThirdButtonReturn || response == .abort { return .cancel }
    if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3 {
      do {
        try forgetSavedLogin(service: service)
        stored = nil
        account.stringValue = ""
        password.stringValue = ""
        remember.state = .off
      } catch {
        let error = NSAlert()
        error.messageText = "Could not remove the saved login"
        error.informativeText = "Keychain did not permit this operation. The entry has been retained."
        _ = await presentLoginAlert(error)
      }
      continue
    }
    let login = SavedLogin(account: account.stringValue, password: password.stringValue)
    guard login.isValid else {
      let error = NSAlert()
      error.messageText = "Check the server account and password"
      error.informativeText = "Both fields are required. Account: up to 320 characters; "
        + "password: up to 128. Line breaks and control characters are not accepted."
      _ = await presentLoginAlert(error)
      continue
    }
    do {
      if remember.state == .on {
        try writeSavedLogin(login, service: service)
      } else if stored != nil {
        try forgetSavedLogin(service: service)
      }
      return .fill(login)
    } catch {
      let error = NSAlert()
      error.messageText = "Could not update the saved login"
      error.informativeText = "Keychain did not permit this operation. You can retry or choose Manual Login."
      _ = await presentLoginAlert(error)
    }
  }
}
