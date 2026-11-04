// swift-tools-version: 5.10

import PackageDescription

// NutriKit's custom chart core (#2682), extracted so NutriKit, NK Insights and Overload share
// one copy (#3919). Swift 5 language mode, like NutriKit's Features package, so the files are
// the same code NutriKit compiled; the value types are `Sendable` so Swift 6 apps can hold them
// in `static let`s and build series off the main actor. iOS only: the engine is UIKit
// underneath (CADisplayLink, UIFont metrics, gesture recognisers). Host hooks: ChartHooks.swift.
let package = Package(
    name: "ChartKit",
    platforms: [
        .iOS("26.0")
    ],
    products: [
        .library(
            name: "ChartKit",
            targets: ["ChartKit"]
        ),
    ],
    targets: [
        .target(name: "ChartKit"),
    ]
)
