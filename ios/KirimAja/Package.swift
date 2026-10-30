// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KirimAja",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "KirimAja",
            targets: ["KirimAja"]
        ),
    ],
    targets: [
        .target(
            name: "KirimAja",
            path: ".",
            sources: [
                "App",
                "Services",
                "Views",
            ]
        ),
    ]
)
