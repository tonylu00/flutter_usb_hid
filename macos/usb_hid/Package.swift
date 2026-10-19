// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "usb_hid",
  platforms: [
    .macOS("10.15"),
  ],
  products: [
    .library(name: "usb-hid", targets: ["usb_hid"]),
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
  ],
  targets: [
    .target(
      name: "usb_hid",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
      ],
      path: "Sources/usb_hid",
      resources: [
        .process("Resources"),
      ],
      linkerSettings: [
        .linkedFramework("IOKit"),
      ]
    ),
  ]
)
