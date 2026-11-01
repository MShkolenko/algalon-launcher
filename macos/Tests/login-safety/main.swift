import CoreGraphics
import CoreText
import Foundation

func frame(_ text: String, fontName: String = "Georgia", caret: Bool = true,
           width: Int = 320) -> MaskedLoginField {
  let context = CGContext(data: nil, width: width, height: 40, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(red: 0.04, green: 0.08, blue: 0.1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: 40))
  let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
    NSAttributedString.Key(kCTFontAttributeName as String):
      CTFontCreateWithName(fontName as CFString, 22, nil),
    NSAttributedString.Key(kCTForegroundColorAttributeName as String):
      CGColor(gray: 1, alpha: 1),
  ]))
  context.textPosition = CGPoint(x: 20, y: 10)
  CTLineDraw(line, context)
  if caret {
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 19 + CTLineGetTypographicBounds(line, nil, nil, nil),
                        y: 7, width: 1, height: 25))
  }
  return MaskedLoginField(image: context.makeImage()!,
    region: CGRect(x: 0, y: 0, width: 1, height: 1))!
}

let empty = frame("")
precondition(MaskedLoginField.confirms(empty: empty, wide: frame("*"),
  pair: frame("**"), erased: frame("", caret: false)), "masked field must be admitted")
for font in ["Georgia", "Menlo", "Helvetica"] {
  precondition(!MaskedLoginField.confirms(empty: empty, wide: frame("W", fontName: font),
    pair: frame("Wi", fontName: font), erased: empty), "clear text must refuse, including monospace")
}
precondition(!MaskedLoginField.confirms(empty: empty, wide: empty, pair: empty, erased: empty),
  "dead-area clicks must refuse even when account text stays unchanged")
precondition(!MaskedLoginField.confirms(empty: empty, wide: frame("*"), pair: frame("**"),
  erased: frame("*")), "failed probe removal must refuse")
precondition(!MaskedLoginField.confirms(empty: frame("*"), wide: frame("**"),
  pair: frame("***"), erased: frame("*")), "pre-existing content must refuse")
precondition(!MaskedLoginField.confirms(empty: empty, wide: frame("*"),
  pair: frame("**", width: 321), erased: empty), "resized captures must refuse")
precondition(!MaskedLoginField.confirms(empty: empty, wide: frame("*"),
  pair: frame("*i"), erased: empty), "unequal glyphs must refuse")
print("PASS: native CoreText masked/clear/monospace/dead-area/erasure/pre-existing/resize controls")

// Independently measured 1280x776 login geometry; stone and frame are outside the textbox interior.
let size = CGSize(width: 1280, height: 776)
func normalized(_ rect: CGRect) -> CGRect {
  CGRect(x: rect.minX / size.width, y: rect.minY / size.height,
    width: rect.width / size.width, height: rect.height / size.height)
}
let layout = LoginLayout(labels: [
  .account: [normalized(CGRect(x: 551, y: 382, width: 178, height: 22))],
  .password: [normalized(CGRect(x: 585, y: 460, width: 110, height: 20))],
  .remember: [normalized(CGRect(x: 538, y: 548, width: 245, height: 24))],
  .login: [normalized(CGRect(x: 595, y: 594, width: 90, height: 24))],
])!
func screenProbe(_ masks: Int) -> MaskedLoginField {
  let width = Int(size.width), height = Int(size.height)
  var pixels = [UInt8](repeating: 20, count: width * height * 4)
  for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
  func white(_ x: Int, _ y: Int) {
    for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = 255 }
  }
  let mask = ["..#..", "#.#.#", ".###.", "#####", ".###.", "#.#.#", "..#.."]
  for origin in (0..<masks).map({ 504 + $0 * 8 }) + [800] {
    for (y, row) in mask.enumerated() {
      for (x, value) in row.enumerated() where value == "#" { white(origin + x, 496 + y) }
    }
  }
  for x in 494..<786 { white(x, 520) }
  let provider = CGDataProvider(data: Data(pixels) as CFData)!
  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  return MaskedLoginField(image: image, region: layout.passwordBand)!
}
precondition(MaskedLoginField.confirms(empty: screenProbe(0), wide: screenProbe(1),
  pair: screenProbe(2), erased: screenProbe(0)),
  "measured layout must include whole masks and exclude static frame/stone")
print("PASS: measured login geometry excludes frame/stone without clipping probe masks")
