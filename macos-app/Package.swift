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
                // The sherpa build links onnxruntime as a dylib whose install
                // name is @rpath-relative; it lives in the cargo target dir, so
                // add that dir to the executable's runtime search path. The
                // executable sits at macos-app/.build/<triple>/<config>/, four
                // levels below the package parent that holds rust-core/.
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../../../../rust-core/target/release"
                ]),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation")
            ]
        )
    ]
)
