import CoreGraphics
import Foundation

// Only the small, nonsecret probe band is retained; never capture a typed password for this proof.
struct MaskedLoginField {
  let width: Int
  let height: Int
  private let pixels: [UInt8]

  init?(image: CGImage, region: CGRect) {
    let rect = CGRect(x: region.minX * CGFloat(image.width),
      y: region.minY * CGFloat(image.height), width: region.width * CGFloat(image.width),
      height: region.height * CGFloat(image.height)).integral
    guard rect.minX >= 0, rect.minY >= 0, rect.maxX <= CGFloat(image.width),
      rect.maxY <= CGFloat(image.height), rect.width >= 30, rect.height >= 12,
      rect.width <= 800, rect.height <= 100,
      let crop = image.cropping(to: rect) else { return nil }
    let width = crop.width, height = crop.height
    self.width = width
    self.height = height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
      context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else { return nil }
    pixels = bytes
  }

  private struct Glyph {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let pixels: Set<Int>

    func matches(_ other: Glyph) -> Bool {
      guard abs(width - other.width) <= 1, height == other.height else { return false }
      // A caret can overlap the mask's last antialiased column; compare in one shared stride.
      let stride = max(width, other.width)
      let left = Set(pixels.map { ($0 / width) * stride + $0 % width })
      let right = Set(other.pixels.map { ($0 / other.width) * stride + $0 % other.width })
      return left.symmetricDifference(right).count * 8 <= max(1, left.union(right).count)
    }
  }

  private func glyphs() -> [Glyph]? {
    var ink = [Bool](repeating: false, count: width * height)
    for i in ink.indices {
      let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
      ink[i] = min(r, g, b) >= 145 && max(r, g, b) - min(r, g, b) <= 55
    }
    // Ignore blinking vertical caret/border columns; a password mask is a compact glyph.
    for x in 0..<width {
      if (0..<height).filter({ ink[$0 * width + x] }).count * 2 >= height {
        for y in 0..<height { ink[y * width + x] = false }
      }
    }
    var result: [Glyph] = []
    for start in ink.indices where ink[start] {
      var stack = [start], points: [(Int, Int)] = []
      ink[start] = false
      while let point = stack.popLast() {
        let x = point % width, y = point / width
        points.append((x, y))
        for yy in max(0, y - 1)...min(height - 1, y + 1) {
          for xx in max(0, x - 1)...min(width - 1, x + 1) where ink[yy * width + xx] {
            ink[yy * width + xx] = false
            stack.append(yy * width + xx)
          }
        }
      }
      guard let x0 = points.map({ $0.0 }).min(), let x1 = points.map({ $0.0 }).max(),
        let y0 = points.map({ $0.1 }).min(), let y1 = points.map({ $0.1 }).max() else { return nil }
      let w = x1 - x0 + 1, h = y1 - y0 + 1
      if points.count >= 6 && w >= 3 && h >= 3 && w <= height && h * 3 <= height * 2 {
        result.append(Glyph(x: x0, y: y0, width: w, height: h,
          pixels: Set(points.map { ($0.1 - y0) * w + $0.0 - x0 })))
      }
      if result.count > 2 { return nil }
    }
    return result.sorted { $0.x < $1.x }
  }

  static func confirms(empty: Self, wide: Self, pair: Self, erased: Self) -> Bool {
    guard [wide, pair, erased].allSatisfy({ $0.width == empty.width && $0.height == empty.height }),
      empty.glyphs()?.isEmpty == true, erased.glyphs()?.isEmpty == true,
      let first = wide.glyphs(), first.count == 1,
      let both = pair.glyphs(), both.count == 2 else { return false }
    let a = first[0], b = both[0], c = both[1]
    // Distinct W/i input must produce two equal, separately positioned masks, not merely no change.
    return abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1 && abs(b.y - c.y) <= 1
      && c.x > b.x + b.width && c.x - b.x <= 3 * b.width
      && a.matches(b) && b.matches(c)
  }
}
