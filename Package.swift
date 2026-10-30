// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Launchpad",
    platforms: [.macOS(.v14)],
    products: [
        // A droplet is a loadable bundle, so its product is a dynamic library.
        // Do not make it static: the app already carries DroppyKit, and a
        // second copy inside the droplet gives the same type two metadata
        // records, which fails every cast between them.
        .library(name: "Launchpad", type: .dynamic, targets: ["Launchpad"])
    ],
    dependencies: [
        // Shipping form (what `droppykit submit` expects):
        //   .package(url: "https://gitlab.com/droppyformac1/droppykit.git", from: "1.6.0")
        // This Mac's Command Line Tools lack the SwiftUIMacros plugin, so the
        // checkout carries a local workaround; build against it directly.
        .package(path: "/Users/gabrielquek/Documents/School/Droppy/droppykit")
    ],
    targets: [
        .target(
            name: "Launchpad",
            dependencies: [.product(name: "DroppyKit", package: "droppykit")]
        ),
        .executableTarget(
            name: "LaunchpadHarness",
            dependencies: [
                "Launchpad",
                .product(name: "DroppyKitHarness", package: "droppykit")
            ]
        )
    ]
)
