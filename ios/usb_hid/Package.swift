// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "usb_hid",
  platforms: [
    .iOS("16.0"),
  ],
  products: [
    .library(name: "usb-hid", targets: ["usb_hid"]),
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
  ],
  targets: [
    .target(
      name: "DriverKitHidClient",
      path: "Sources/DriverKitHidClient",
      publicHeadersPath: "include",
      linkerSettings: [
        .linkedFramework("IOKit"),
      ]
    ),
    .target(
      name: "usb_hid",
      dependencies: [
        "DriverKitHidClient",
        .product(name: "FlutterFramework", package: "FlutterFramework"),
      ],
      path: "Sources/usb_hid",
      resources: [
        .process("Resources"),
      ]
    ),
  ]
)
