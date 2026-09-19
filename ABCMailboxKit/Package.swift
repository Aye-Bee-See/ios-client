// swift-tools-version: 5.10
import PackageDescription

// Everything in the iOS app that is not SwiftUI lives here, so it can be built and
// tested on the development machine with `swift test`: no simulator needed.
//
// - ABCCrypto: the only code that talks to libsodium. Mirrors Android's `:crypto` module.
// - ABCCore:   API client, session, repositories, domain models. Mirrors Android's `data/` and `domain/`.
let package = Package(
  name: "ABCMailboxKit",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "ABCCrypto", targets: ["ABCCrypto"]),
    .library(name: "ABCCore", targets: ["ABCCore"]),
  ],
  dependencies: [
    // Ships libsodium as a prebuilt XCFramework (the `Clibsodium` product). See docs/DECISIONS.md.
    .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.9.1"),
  ],
  targets: [
    .target(name: "ABCCrypto", dependencies: [.product(name: "Clibsodium", package: "swift-sodium")]),
    .target(name: "ABCCore", dependencies: ["ABCCrypto"]),
    .testTarget(name: "ABCCryptoTests", dependencies: ["ABCCrypto"], resources: [.copy("Fixtures")]),
    .testTarget(name: "ABCCoreTests", dependencies: ["ABCCore", "ABCCrypto"], resources: [.copy("Fixtures")]),
  ]
)
