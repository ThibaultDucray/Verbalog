import Dispatch
import Foundation
import VerbalogCaptureKit

// Standalone capture helper. The app links the same code in process, so that
// macOS attributes the microphone and screen permissions to Verbalog.

func usage() -> Never {
    print("""
    usage: verbalog-capture --out DIR [--mic NAME_OR_UID] [--system-source BUNDLE_ID|all|none] [--seconds N]
           verbalog-capture --list-devices
    """)
    exit(2)
}

setbuf(stdout, nil)
var arguments = Array(CommandLine.arguments.dropFirst())
var options: [String: String] = [:]
var listDevices = false
while let argument = arguments.first {
    arguments.removeFirst()
    if argument == "--list-devices" {
        listDevices = true
    } else if argument.hasPrefix("--"), let value = arguments.first {
        options[String(argument.dropFirst(2))] = value
        arguments.removeFirst()
    } else {
        usage()
    }
}

if listDevices {
    for device in AudioDevices.inputs() { print("\(device.name)\t\(device.uid)") }
    exit(0)
}
guard let out = options["out"] else { usage() }

let source = options["system-source"] ?? "all"
let session = CaptureSession(configuration: .init(
    directory: URL(fileURLWithPath: out),
    micDevice: options["mic"],
    captureSystem: source != "none",
    systemSource: source == "all" || source == "none" ? nil : source
))
session.onLevels = { levels in
    print("LEVEL mic=\(Int(levels.mic)) system=\(Int(levels.system))")
}
session.onWarning = { message in
    FileHandle.standardError.write(Data("WARNING \(message)\n".utf8))
}

func finish() {
    Task {
        await session.stop()
        print("STOPPED")
        exit(0)
    }
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signalSources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { finish() }
    source.resume()
    return source
}

Task {
    do {
        let started = try await session.start()
        print("STARTED \(started.epochMs)")
        if let error = started.systemError {
            FileHandle.standardError.write(Data("WARNING \(error.localizedDescription)\n".utf8))
        }
        if let seconds = options["seconds"].flatMap(Double.init) {
            try await Task.sleep(for: .seconds(seconds))
            finish()
        }
    } catch {
        FileHandle.standardError.write(Data("ERROR \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
withExtendedLifetime(signalSources) { dispatchMain() }
