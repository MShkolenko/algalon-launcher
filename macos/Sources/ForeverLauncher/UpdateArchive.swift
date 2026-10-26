import ArchiveCheck
import Foundation

// This intentionally accepts the bounded ASCII stored/deflate ZIP format emitted by our build.
// shortcut: ZIP64/non-ASCII/path overrides fail closed; extend only with new fixtures.
func validatedUpdateArchive(_ url: URL) throws -> String {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  guard attributes[.type] as? FileAttributeType == .typeRegular,
    let size = attributes[.size] as? NSNumber, size.intValue <= 52_428_800 else {
    throw UpdateError.archive
  }
  let data = try Data(contentsOf: url, options: .mappedIfSafe)
  return try UpdateZIP(data: data).validate()
}

private struct ZIPItem {
  enum Kind { case file, directory, link }
  let path: String
  let kind: Kind
  let target: String?
}

private struct UpdateZIP {
  let data: Data

  private func integer(_ offset: Int, _ count: Int) throws -> Int {
    guard offset >= 0, count > 0, offset <= data.count - count else { throw UpdateError.archive }
    var result = 0
    for byte in 0..<count { result |= Int(data[offset + byte]) << (8 * byte) }
    return result
  }

  private func extras(_ start: Int, _ length: Int) throws {
    guard start <= data.count - length else { throw UpdateError.archive }
    var cursor = start
    while cursor < start + length {
      guard cursor + 4 <= start + length else { throw UpdateError.archive }
      let tag = try integer(cursor, 2)
      let size = try integer(cursor + 2, 2)
      // Timestamp and UID/GID extras cannot replace paths or create hard links.
      guard [0x5855, 0x5455, 0x7875, 0x7855].contains(tag),
        size <= start + length - cursor - 4 else { throw UpdateError.archive }
      cursor += 4 + size
    }
  }

  private func path(_ bytes: Data) throws -> String {
    guard !bytes.isEmpty, bytes.count <= 1_024,
      bytes.allSatisfy({ $0 >= 32 && $0 < 127 && $0 != 92 && $0 != 58 }),
      var text = String(data: bytes, encoding: .utf8) else { throw UpdateError.archive }
    if text.hasSuffix("/") { text.removeLast() }
    guard text.components(separatedBy: "/").allSatisfy({
      !$0.isEmpty && $0 != "." && $0 != ".."
    }) else { throw UpdateError.archive }
    return text
  }

  func validate() throws -> String {
    guard data.count >= 22, data.count <= 52_428_800 else { throw UpdateError.archive }
    var end: Int?
    for position in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
      if try integer(position, 4) == 0x06054b50,
        try position + 22 + integer(position + 20, 2) == data.count {
        end = position
        break
      }
    }
    guard let end, try integer(end + 4, 2) == 0, try integer(end + 6, 2) == 0 else {
      throw UpdateError.archive
    }
    let count = try integer(end + 10, 2)
    let centralSize = try integer(end + 12, 4)
    let centralOffset = try integer(end + 16, 4)
    guard count > 0, count <= 4_096, try integer(end + 8, 2) == count,
      centralOffset + centralSize == end else { throw UpdateError.archive }
    var cursor = centralOffset
    var items = [ZIPItem]()
    var ranges = [Range<Int>]()
    var names = Set<String>()
    var total = 0
    var root: String?
    for _ in 0..<count {
      guard cursor >= centralOffset, cursor + 46 <= end,
        try integer(cursor, 4) == 0x02014b50, try integer(cursor + 6, 2) <= 20,
        try integer(cursor + 34, 2) == 0 else { throw UpdateError.archive }
      let flags = try integer(cursor + 8, 2)
      let method = try integer(cursor + 10, 2)
      let checksum = try integer(cursor + 16, 4)
      let compressed = try integer(cursor + 20, 4)
      let uncompressed = try integer(cursor + 24, 4)
      let nameLength = try integer(cursor + 28, 2)
      let extraLength = try integer(cursor + 30, 2)
      let commentLength = try integer(cursor + 32, 2)
      let mode = try integer(cursor + 38, 4) >> 16
      let local = try integer(cursor + 42, 4)
      let next = cursor + 46 + nameLength + extraLength + commentLength
      guard flags & ~0x080e == 0, [0, 8].contains(method), next <= end,
        uncompressed <= 262_144_000 - total, compressed <= 52_428_800,
        local + 30 <= centralOffset else { throw UpdateError.archive }
      let rawName = data.subdata(in: cursor + 46..<cursor + 46 + nameLength)
      let name = try path(rawName)
      guard names.insert(name.lowercased()).inserted else { throw UpdateError.archive }
      let first = name.components(separatedBy: "/")[0]
      guard first.hasSuffix(".app"), first.count > 4, root == nil || root == first else {
        throw UpdateError.archive
      }
      root = first
      try extras(cursor + 46 + nameLength, extraLength)
      guard try integer(local, 4) == 0x04034b50, try integer(local + 6, 2) == flags,
        try integer(local + 8, 2) == method, try integer(local + 26, 2) == nameLength else {
        throw UpdateError.archive
      }
      let localExtra = try integer(local + 28, 2)
      let body = local + 30 + nameLength + localExtra
      guard body <= centralOffset, compressed <= centralOffset - body,
        data.subdata(in: local + 30..<local + 30 + nameLength) == rawName else {
        throw UpdateError.archive
      }
      try extras(local + 30 + nameLength, localExtra)
      var finish = body + compressed
      if flags & 8 != 0 {
        if try integer(finish, 4) == 0x08074b50 { finish += 4 }
        guard finish + 12 <= centralOffset, try integer(finish, 4) == checksum,
          try integer(finish + 4, 4) == compressed,
          try integer(finish + 8, 4) == uncompressed else {
          throw UpdateError.archive
        }
        finish += 12
      } else {
        guard try integer(local + 14, 4) == checksum, try integer(local + 18, 4) == compressed,
          try integer(local + 22, 4) == uncompressed else { throw UpdateError.archive }
      }
      let kind: ZIPItem.Kind
      switch mode & 0xf000 {
      case 0xa000: kind = .link
      case 0x4000: kind = .directory
      case 0x8000: kind = .file
      case 0: kind = rawName.last == 47 ? .directory : .file
      default: throw UpdateError.archive
      }
      guard (kind == .directory || rawName.last != 47),
        (name != first || kind == .directory),
        (kind != .directory || uncompressed == 0),
        (kind != .link || (uncompressed > 0 && uncompressed <= 1_024)) else {
        throw UpdateError.archive
      }
      var link = [UInt8](repeating: 0, count: kind == .link ? uncompressed : 0)
      let valid = data.withUnsafeBytes { raw in
        link.withUnsafeMutableBufferPointer { target in
          archive_check_entry(
            raw.baseAddress?.advanced(by: body).assumingMemoryBound(to: UInt8.self), compressed,
            UInt64(uncompressed), UInt32(checksum), UInt16(method),
            kind == .link ? target.baseAddress : nil, target.count
          )
        }
      }
      guard valid == 1 else { throw UpdateError.archive }
      let target: String?
      if kind == .link {
        guard link.allSatisfy({ $0 >= 32 && $0 < 127 && $0 != 92 && $0 != 58 }),
          let value = String(bytes: link, encoding: .utf8), !value.hasPrefix("/") else {
          throw UpdateError.archive
        }
        target = value
      } else { target = nil }
      items.append(ZIPItem(path: name, kind: kind, target: target))
      ranges.append(local..<finish)
      total += uncompressed
      cursor = next
    }
    guard cursor == end, let root else { throw UpdateError.archive }
    let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
    guard sorted.first?.lowerBound == 0, sorted.last?.upperBound == centralOffset else {
      throw UpdateError.archive
    }
    for position in 1..<sorted.count {
      guard sorted[position - 1].upperBound == sorted[position].lowerBound else {
        throw UpdateError.archive
      }
    }
    try validatePaths(items)
    return root
  }

  private func validatePaths(_ items: [ZIPItem]) throws {
    let entries = Dictionary(uniqueKeysWithValues: items.map { ($0.path.lowercased(), $0) })
    for item in items {
      let parts = item.path.components(separatedBy: "/")
      for end in 1..<parts.count {
        if let parent = entries[parts[..<end].joined(separator: "/").lowercased()],
          parent.kind != .directory { throw UpdateError.archive }
      }
      guard let target = item.target else { continue }
      var resolved = Array(parts.dropLast())
      var pending = target.components(separatedBy: "/")
      var steps = 0
      while !pending.isEmpty {
        steps += 1
        guard steps <= 4_096 else { throw UpdateError.archive }
        let next = pending.removeFirst()
        if next.isEmpty || next == "." { continue }
        if next == ".." {
          guard resolved.count > 1 else { throw UpdateError.archive }
          resolved.removeLast()
        } else {
          resolved.append(next)
          guard resolved.joined(separator: "/").utf8.count <= 1_024 else {
            throw UpdateError.archive
          }
          if let link = entries[resolved.joined(separator: "/").lowercased()]?.target {
            resolved.removeLast()
            pending = link.components(separatedBy: "/") + pending
          }
        }
      }
    }
  }
}

func validateExtractedUpdate(_ app: URL) throws {
  let manager = FileManager.default
  let root = app.resolvingSymlinksInPath().standardizedFileURL.path
  var enumerationFailed = false
  guard root == app.standardizedFileURL.path,
    try manager.attributesOfItem(atPath: app.path)[.type] as? FileAttributeType == .typeDirectory,
    let enumerator = manager.enumerator(
      at: app, includingPropertiesForKeys: nil, errorHandler: { _, _ in
        enumerationFailed = true
        return false
      }
    ) else {
    throw UpdateError.archive
  }
  for case let url as URL in enumerator {
    let attributes = try manager.attributesOfItem(atPath: url.path)
    guard let kind = attributes[.type] as? FileAttributeType,
      [.typeRegular, .typeDirectory, .typeSymbolicLink].contains(kind) else {
      throw UpdateError.archive
    }
    if kind == .typeSymbolicLink {
      let target = try manager.destinationOfSymbolicLink(atPath: url.path)
      let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
      guard !target.hasPrefix("/"), resolved == root || resolved.hasPrefix(root + "/"),
        manager.fileExists(atPath: resolved) else { throw UpdateError.archive }
    }
  }
  guard !enumerationFailed else { throw UpdateError.archive }
}
