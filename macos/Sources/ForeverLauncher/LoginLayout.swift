import CoreGraphics
import Foundation

enum LoginLabel: String, CaseIterable, Sendable {
  case account, password, remember, login

  init?(text: String) {
    let normalized = text.lowercased().replacingOccurrences(of: "ё", with: "е")
      .filter { $0.isLetter }
    switch normalized {
    case "emailorphone", "электроннаяпочтаилителефон": self = .account
    case "password", "пароль": self = .password
    case "rememberaccount", "запомнитьучетнуюзапись": self = .remember
    case "login", "вход", "войти": self = .login
    default: return nil
    }
  }
}

struct LoginLayout: Sendable {
  let account: CGPoint
  let password: CGPoint

  func screenPoint(_ field: CGPoint, frame: CGRect, content: CGRect) -> CGPoint? {
    guard [frame.minX, frame.minY, frame.width, frame.height,
      content.minX, content.minY, content.width, content.height].allSatisfy(\.isFinite),
      frame.width > 0, frame.height > 0, content.width > 0, content.height > 0,
      content.minX >= 0, content.minY >= 0,
      content.maxX <= frame.width + 1, content.maxY <= frame.height + 1 else { return nil }
    return CGPoint(x: frame.minX + content.minX + field.x * content.width,
                   y: frame.minY + content.minY + field.y * content.height)
  }

  // Rectangles use normalized top-left coordinates, independent of Retina scale.
  init?(labels: [LoginLabel: [CGRect]]) {
    guard LoginLabel.allCases.allSatisfy({ labels[$0]?.count == 1 }),
      let a = labels[.account]?.first, let p = labels[.password]?.first,
      let r = labels[.remember]?.first, let l = labels[.login]?.first else { return nil }
    for rect in [a, p, r, l] {
      guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
        rect.minX >= 0, rect.maxX <= 1, rect.minY >= 0, rect.maxY <= 1,
        rect.width > 0.015, (0.008...0.06).contains(rect.height),
        abs(rect.midX - a.midX) < 0.1 else { return nil }
    }
    guard (0.35...0.65).contains(a.midX), (0.15...0.75).contains(a.minY),
      (0.005...0.15).contains(p.minY - a.maxY),
      (0.005...0.15).contains(r.minY - p.maxY),
      (0.005...0.15).contains(l.minY - r.maxY) else { return nil }
    account = CGPoint(x: a.midX, y: (a.maxY + p.minY) / 2)
    password = CGPoint(x: a.midX, y: (p.maxY + r.minY) / 2)
  }
}
