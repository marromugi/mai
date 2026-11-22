// Runs the snapshot tests on the one simulator the snapshots were recorded on.
// Another device or iOS version renders text differently, so every snapshot would differ.
//
//   swift scripts/snapshot-test.swift            compare, and record snapshots that are missing
//   swift scripts/snapshot-test.swift --record   record every snapshot again
//   swift scripts/snapshot-test.swift --diagnostics
//                                                also collect the simulator's diagnostics when a test
//                                                fails, for a crash or simulator fault with no known cause
//
// The simulator is booted before the tests and left booted after them, so the next run doesn't
// wait for it to start. Shut it down with `xcrun simctl shutdown mai-snapshots`.

import Foundation

let deviceName = "mai-snapshots"
let deviceType = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"

struct DeviceList: Decodable {
  struct Device: Decodable {
    let name: String
    let udid: String
  }
  let devices: [String: [Device]]
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

/// Runs xcrun and returns what it printed.
func capture(_ arguments: [String]) -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  process.arguments = arguments
  let pipe = Pipe()
  process.standardOutput = pipe
  do {
    try process.run()
  } catch {
    fail("Could not run xcrun \(arguments.joined(separator: " ")): \(error)")
  }
  let output = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    fail("xcrun \(arguments.joined(separator: " ")) failed.")
  }
  return String(decoding: output, as: UTF8.self)
}

/// Runs xcrun with its output going to this terminal, and returns its exit status.
func stream(_ arguments: [String], environment: [String: String]) -> Int32 {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  process.arguments = arguments
  process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
  do {
    try process.run()
  } catch {
    fail("Could not run xcrun \(arguments.joined(separator: " ")): \(error)")
  }
  process.waitUntilExit()
  return process.terminationStatus
}

func simulator() -> String {
  let json = capture(["simctl", "list", "devices", "--json"])
  guard let list = try? JSONDecoder().decode(DeviceList.self, from: Data(json.utf8)) else {
    fail("Could not read the list of simulators.")
  }
  if let device = list.devices[runtime]?.first(where: { $0.name == deviceName }) {
    return device.udid
  }
  return capture(["simctl", "create", deviceName, deviceType, runtime])
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

let options = Set(CommandLine.arguments.dropFirst())
let unknownOptions = options.subtracting(["--record", "--diagnostics"])
guard unknownOptions.isEmpty else {
  let names = unknownOptions.sorted().joined(separator: " ")
  fail("Unknown option \(names). Use --record or --diagnostics.")
}
let records = options.contains("--record")
let collectsDiagnostics = options.contains("--diagnostics")
let package = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .appendingPathComponent("../Packages/Modules")
  .standardized

FileManager.default.changeCurrentDirectoryPath(package.path)
let device = simulator()
// xcodebuild shuts down a simulator it boots itself when the tests end; one booted here stays up.
_ = capture(["simctl", "bootstatus", device, "-b"])
let status = stream(
  [
    "xcodebuild", "test", "-scheme", "Modules", "-destination", "id=\(device)", "-quiet",
    "-collect-test-diagnostics", collectsDiagnostics ? "on-failure" : "never",
  ],
  // xcodebuild hands variables starting with TEST_RUNNER_ to the tests, without the prefix.
  environment: ["TEST_RUNNER_SNAPSHOT_TESTING_RECORD": records ? "all" : "missing"])
if records {
  print("Each recorded snapshot shows as a failure. Look at the new images before committing.")
} else if status != 0 {
  print("A test with no snapshot yet records one and fails. Look at it, commit it, and run again.")
}
exit(status)
