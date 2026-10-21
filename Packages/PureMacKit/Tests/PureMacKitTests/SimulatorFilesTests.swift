import Foundation
import Testing
@testable import PureMacKit

/// Simulator devices read from CoreSimulator's files (the App Sandbox can't run `simctl`).
@Suite("Simulators from files")
struct SimulatorFilesTests {
    func plist(_ object: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    func device(_ f: Fixture, _ udid: String, runtime: String, deleted: Bool = false) throws {
        try f.file("Devices/\(udid)/device.plist", data: try plist(["UDID": udid, "name": "Phone \(udid)", "runtime": runtime, "isDeleted": deleted, "state": 1]))
    }

    @Test func devicesAndUnavailableRuntimesAreCounted() throws {
        let f = try Fixture()
        try device(f, "A", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        try device(f, "B", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        try device(f, "C", runtime: "com.apple.CoreSimulator.SimRuntime.watchOS-12-0")   // runtime from a bundle
        try device(f, "D", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-17-2")       // runtime gone
        try device(f, "E", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-17-2", deleted: true)
        try f.file("Devices/.DS_Store", size: 4)
        try f.file("images.plist", data: try plist(["images": [["runtimeInfo": ["bundleIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0"]]]]))
        try f.file("Runtimes/watchOS 12.0.simruntime/Contents/Info.plist", data: try plist(["CFBundleIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-12-0"]))

        let summary = try #require(DeveloperStorageInspector.simulatorSummaryFromFiles(
            devicesFolder: f.path("Devices"), imagesPlist: f.path("images.plist"), runtimeFolders: [f.path("Runtimes")]))
        #expect(summary.totalDevices == 4)                        // the deleted device is not counted
        #expect(summary.unavailableDevices == 1)
        #expect(summary.availabilityKnown)
        #expect(summary.runtimes == ["iOS-17-2", "iOS-27-0", "watchOS-12-0"])
    }

    @Test func unreadableRuntimesMeanUnknownAvailability() throws {
        let f = try Fixture()
        try device(f, "A", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        let summary = try #require(DeveloperStorageInspector.simulatorSummaryFromFiles(
            devicesFolder: f.path("Devices"), imagesPlist: f.path("missing.plist"), runtimeFolders: [f.path("missing")]))
        #expect(summary.totalDevices == 1)
        #expect(summary.unavailableDevices == 0)
        #expect(!summary.availabilityKnown)
    }

    @Test func noSimulatorFolderMeansNoSummary() throws {
        let f = try Fixture()
        #expect(DeveloperStorageInspector.simulatorSummaryFromFiles(devicesFolder: f.path("none"), imagesPlist: f.path("x"), runtimeFolders: []) == nil)
    }
}
