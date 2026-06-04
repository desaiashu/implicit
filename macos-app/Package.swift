// swift-tools-version:5.9
import PackageDescription

// Build prerequisite: from ../rust-core run `cargo build --release` (add
// `--features sherpa` once a model is installed). That produces
// ../rust-core/target/release/libswearcore.a, which the linker flags below
// pick up. Paths are relative to this package dir; adjust if you relocate.
let rustLib = "../rust-core/target/release"
let rustHeader = "../rust-core/include"

let package = Package(
    name: "SwearFilter",
    platforms: [.macOS("14.4")], // Core Audio process taps require macOS 14.4+
    targets: [
        .systemLibrary(name: "CSwearCore", path: "Sources/CSwearCore"),
        .executableTarget(
            name: "SwearFilter",
            dependencies: ["CSwearCore"],
            cSettings: [
                .unsafeFlags(["-I", rustHeader])
            ],
            linkerSettings: [
                .unsafeFlags(["-L", rustLib, "-lswearcore"]),
                // No runtime rpath here on purpose: the native dylibs
                // (libswearcore + sherpa + onnxruntime) all use @rpath install
                // names, and run.sh bundles them into Contents/Frameworks and
                // adds @executable_path/../Frameworks as the only rpath. Pointing
                // at the build tree here would mask a missing-dylib bundling bug
                // (the app would silently resolve from rust-core/target on this
                // machine but crash on anyone else's).
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation")
            ]
        )
    ]
)
