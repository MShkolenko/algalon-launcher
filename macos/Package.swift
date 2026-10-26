// swift-tools-version:5.7
import PackageDescription

let package = Package(
  name: "ForeverLauncher",
  platforms: [.macOS(.v12)],
  targets: [
    .target(name: "MachKeyStore", path: "Sources/MachKeyStore"),
    .executableTarget(
      name: "ForeverLauncher",
      dependencies: ["MachKeyStore"],
      path: ".",
      exclude: ["Tests", "packaging", "profiles", "Sources/MachKeyStore", "Sources/RealmDNS",
        "README.md", "validation.json", "dist", "Generated/RealmProfile.h",
        "Generated/bundle.json"],
      sources: ["Sources/ForeverLauncher", "Generated/RealmProfile.swift"]
    ),
  ]
)
