// swift-tools-version: 5.10

import PackageDescription

// Shipyard: the pxlshpr apps' shared UI components (#3950), where what they ship gets built.
// It began as ChartKit, NutriKit's chart engine extracted so NutriKit, NK Insights and Overload
// share one copy (#3919); the charts are one family here now, beside the TimeSlider (NutriKit's
// day timeline with Overload's interval mode), EmojiCircle and DestructiveButton (from PxlKit,
// folded in and archived).
//
// Swift 5 language mode, like NutriKit's Features package, so the files are the same code NutriKit
// compiled; the value types are `Sendable` so Swift 6 apps can hold them in `static let`s and build
// series off the main actor. iOS only: UIKit underneath (CADisplayLink, UIFont metrics, gesture
// recognisers). What a host plugs in: ChartHooks.swift and TimeSliderHooks.swift.
let package = Package(
    name: "Shipyard",
    platforms: [
        .iOS("26.0")
    ],
    products: [
        .library(
            name: "Shipyard",
            targets: ["Shipyard"]
        ),
    ],
    targets: [
        .target(name: "Shipyard"),
        .testTarget(
            name: "ShipyardTests",
            dependencies: ["Shipyard"]
        ),
    ]
)
