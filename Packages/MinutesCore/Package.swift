// swift-tools-version: 6.2
import PackageDescription

// The meeting pipeline (transcribe → identify speakers → summarize → export) lives in this
// package rather than in the app target so the exact same code also runs on a Mac:
//
//     cd Packages/MinutesCore && swift run minutes-check ~/Desktop/meeting.m4a
//
// That is how the pipeline is verified end to end — the Simulator is unreliable for on-device
// speech and Core ML, and there is no other test harness.
let package = Package(
    name: "MinutesCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "MinutesCore", targets: ["MinutesCore"]),
    ],
    dependencies: [
        // Speaker diarization (pyannote community-1 on Core ML). Still 0.x, where minor
        // releases have changed the API, so stay on 0.18.x until a newer one is checked.
        // Only the Diarizer trait: the default traits also link its TTS engines and an ~8 MB
        // text-normalization staticlib that nothing here uses.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            .upToNextMinor(from: "0.18.2"),
            traits: ["Diarizer"]
        ),
    ],
    targets: [
        .target(
            name: "MinutesCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(
            name: "minutes-check",
            dependencies: ["MinutesCore"]
        ),
    ],
    // Swift 5 mode: Speech, AVFAudio and FluidAudio still hand out non-Sendable types
    // (AVAudioPCMBuffer, Core ML models) that Swift 6 mode turns into hard errors.
    swiftLanguageModes: [.v5]
)
