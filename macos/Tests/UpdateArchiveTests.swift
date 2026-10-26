import Foundation

@main
struct UpdateArchiveTests {
  enum Failure: Error { case expectedRejection }

  static func main() throws {
    let accepted = CommandLine.arguments[1] == "accept"
    if accepted {
      let manager = FileManager.default
      let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let app = temporary.appendingPathComponent("Fixture.app")
      try manager.createDirectory(at: app, withIntermediateDirectories: true)
      defer { try? manager.removeItem(at: temporary) }
      let outside = temporary.appendingPathComponent("outside")
      try Data("sentinel".utf8).write(to: outside)
      try manager.createSymbolicLink(atPath: app.appendingPathComponent("escape").path,
        withDestinationPath: "../outside")
      do {
        try validateExtractedUpdate(app)
        throw Failure.expectedRejection
      } catch UpdateError.archive {
        guard try Data(contentsOf: outside) == Data("sentinel".utf8) else {
          throw Failure.expectedRejection
        }
        print("PASS: post-extraction symlink escape refused; outside sentinel unchanged")
      }
    }
    for argument in CommandLine.arguments.dropFirst(2) {
      let url = URL(fileURLWithPath: argument)
      do {
        let root = try validatedUpdateArchive(url)
        guard accepted else { throw Failure.expectedRejection }
        let temporary = FileManager.default.temporaryDirectory
          .appendingPathComponent("archive-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        extract.arguments = ["-x", "-k", url.path, temporary.path]
        try extract.run()
        extract.waitUntilExit()
        guard extract.terminationStatus == 0 else { throw Failure.expectedRejection }
        try validateExtractedUpdate(temporary.appendingPathComponent(root))
      } catch UpdateError.archive {
        guard !accepted else { throw Failure.expectedRejection }
      }
      print("PASS: \(accepted ? "accepted/extracted" : "refused") \(url.lastPathComponent)")
    }
  }
}
