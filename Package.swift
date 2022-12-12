// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "UtilityFeatures",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
  ],
  products: [
    .library(name: "FrequencyFormatter", targets: ["FrequencyFormatter"]),
    .library(name: "OpusEncoder", targets: ["OpusEncoder"]),
    .library(name: "OpusPlayer", targets: ["OpusPlayer"]),
    .library(name: "RingBuffer", targets: ["RingBuffer"]),
    .library(name: "SecureStorage", targets: ["SecureStorage"]),
    .library(name: "XCGWrapper", targets: ["XCGWrapper"]),
  ],
  dependencies: [
    .package(url: "https://github.com/K3TZR/SharedFeatures.git", from: "1.3.1"),
    .package(url: "https://github.com/DaveWoodCom/XCGLogger.git", from: "7.0.1"),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "0.42.0"),
  ],
  targets: [
    // --------------- Modules ---------------
    // FrequencyFormatter
    .target( name: "FrequencyFormatter", dependencies: []),

    // OpusEncoder
    .target( name: "OpusEncoder", dependencies: [
      "RingBuffer",
      "XCGWrapper",
      .product(name: "Shared", package: "SharedFeatures"),
    ]),
    
    // OpusPlayer
    .target( name: "OpusPlayer", dependencies: [
      "RingBuffer",
      "XCGWrapper",
      .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      .product(name: "Shared", package: "SharedFeatures"),
    ]),
    
    // RingBuffer
    .target( name: "RingBuffer", dependencies: []),
    
    // SecureStorage
    .target( name: "SecureStorage", dependencies: []),

    // XCGWrapper
    .target( name: "XCGWrapper", dependencies: [
      .product(name: "ObjcExceptionBridging", package: "XCGLogger"),
      .product(name: "Shared", package: "SharedFeatures"),
      .product(name: "XCGLogger", package: "XCGLogger"),
    ]),
  ]
)
