// swift-tools-version:5.7
import PackageDescription

let package = Package(
  name: "ForeverLauncher",
  platforms: [.macOS(.v12)],
  targets: [
    .target(name: "MachKeyStore", path: "Sources/MachKeyStore"),
    .target(name: "ArchiveCheck", path: "Sources/ArchiveCheck", linkerSettings: [.linkedLibrary("z")]),
    .executableTarget(
      name: "ForeverLauncher",
      dependencies: ["MachKeyStore", "ArchiveCheck"],
      path: ".",
      exclude: ["Tests", "packaging", "profiles", "Sources/MachKeyStore", "Sources/RealmDNS",
        "Sources/ArchiveCheck", "README.md", "validation.json", "dist", "Generated/RealmProfile.h",
        "Generated/bundle.json"],
      sources: ["Sources/ForeverLauncher", "Generated/RealmProfile.swift"]
    ),
  ]
)
