// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "HermesAirPods",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "AirPodsCore"),
    .executableTarget(name: "HermesAirPods", dependencies: ["AirPodsCore"]),
    .testTarget(name: "AirPodsCoreTests", dependencies: ["AirPodsCore"], resources: [.copy("Fixtures")]),
  ]
)
