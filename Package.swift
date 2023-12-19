// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "UtilityFeatures",
  platforms: [.macOS(.v14),],

  products: [
    .library(name: "DaxRxAudioPlayer", targets: ["DaxRxAudioPlayer"]),
    .library(name: "OpusEncoder", targets: ["OpusEncoder"]),
    .library(name: "RingBuffer", targets: ["RingBuffer"]),
    .library(name: "RxAudioPlayer", targets: ["RxAudioPlayer"]),
    .library(name: "RxAVAudioPlayer", targets: ["RxAVAudioPlayer"]),
    .library(name: "SecureStorage", targets: ["SecureStorage"]),
    .library(name: "XCGWrapper", targets: ["XCGWrapper"]),
  ],
  
  dependencies: [
    // ----- K3TZR -----
    .package(url: "https://github.com/K3TZR/CommonFeatures.git", branch: "main"),
    // ----- OTHER -----
    .package(url: "https://github.com/DaveWoodCom/XCGLogger.git", from: "7.0.1"),
  ],
  
  targets: [
    // --------------- Modules ---------------
    // DaxRxAudioPlayer
    .target( name: "DaxRxAudioPlayer", dependencies: [
      "RingBuffer",
      "XCGWrapper",
      .product(name: "SharedModel", package: "CommonFeatures"),
    ]),
    
    // OpusEncoder
    .target( name: "OpusEncoder", dependencies: [
      "RingBuffer",
      "XCGWrapper",
      .product(name: "SharedModel", package: "CommonFeatures"),
    ]),
    
    // RingBuffer
    .target( name: "RingBuffer", dependencies: []),
    
    // RxAudioPlayer
    .target( name: "RxAudioPlayer", dependencies: [
      "RingBuffer",
      "XCGWrapper",
    ]),
    
    // RxAVAudioPlayer
    .target( name: "RxAVAudioPlayer", dependencies: [
      "RingBuffer",
      "XCGWrapper",
    ]),
    
    // SecureStorage
    .target( name: "SecureStorage", dependencies: []),

    // XCGWrapper
    .target( name: "XCGWrapper", dependencies: [
      .product(name: "XCGLogger", package: "XCGLogger"),
      .product(name: "ObjcExceptionBridging", package: "XCGLogger"),
      .product(name: "SharedModel", package: "CommonFeatures"),
    ]),
  ]
  
  // --------------- Tests ---------------
)
