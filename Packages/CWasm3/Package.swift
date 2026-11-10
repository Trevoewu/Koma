// swift-tools-version: 6.0

import PackageDescription

/// The wasm3 WebAssembly interpreter (MIT, see LICENSE), vendored as C source.
/// Koma uses it to run source plugins. The Swift glue is in the app
/// (Features/Sources/Runtime/WasmInstance.swift).
let package = Package(
    name: "CWasm3",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CWasm3", targets: ["CWasm3"])
    ],
    targets: [
        .target(
            name: "CWasm3",
            cSettings: [
                .define("APPLICATION_EXTENSION_API_ONLY", to: "YES"),
                .define("d_m3MaxDuplicateFunctionImpl", to: "10"),
                .unsafeFlags(["-Wno-shorten-64-to-32", "-Wno-unused-function"])
            ]
        )
    ]
)
