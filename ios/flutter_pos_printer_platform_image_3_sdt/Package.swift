// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    // TODO: Update your plugin name.
    name: "flutter_pos_printer_platform_image_3_sdt",
    platforms: [
        // TODO: Update the platforms your plugin supports.
        // If your plugin only supports iOS, remove `.macOS(...)`.
        // If your plugin only supports macOS, remove `.iOS(...)`.
        .iOS("13.0"),
        .macOS("10.15")
    ],
    products: [
        // TODO: Update your library and target names.
        // If the plugin name contains "_", replace with "-" for the library name
        .library(name: "flutter-pos-printer-platform-image-3-sdt", targets: ["flutter_pos_printer_platform_image_3_sdt"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            // TODO: Update your target name.
            name: "flutter_pos_printer_platform_image_3_sdt",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                "ObjCSupport"
            ],
            resources: [
                // TODO: If your plugin requires a privacy manifest
                // (e.g. if it uses any required reason APIs), update the PrivacyInfo.xcprivacy file
                // to describe your plugin's privacy impact, and then uncomment this line.
                // For more information, see:
                // https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
                // .process("PrivacyInfo.xcprivacy"),

                // TODO: If you have other resources that need to be bundled with your plugin, refer to
                // the following instructions to add them:
                // https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package
            ],
            cSettings: [
                // TODO: Update your plugin name.
                .headerSearchPath("include/flutter_pos_printer_platform_image_3_sdt")
            ]
        ),
        
        // 2. Internal Objective-C compilation target wrapping your loose .m code
        .target(
            name: "ObjCSupport",
            dependencies: [
                "GSDKLibrary" // Links the .m file logic directly with the binary library
            ],
            path: "Sources/ObjCSupport",
            publicHeadersPath: "include" // Points to the internal public headers directory
        ),

        // Declaring the local .xcframework correctly as a binary target
        .binaryTarget(
            name: "GSDKLibrary",
            path: "libGSDK.xcframework"
        )
    ]
)
