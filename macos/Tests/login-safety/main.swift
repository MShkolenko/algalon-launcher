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
