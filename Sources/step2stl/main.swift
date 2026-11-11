import Foundation
import SwiftSTEP

// Converts STEP files to binary STL using the library's own tessellator.
//   step2stl <file-or-folder> [<output-folder>] [--chord <mm>]
// A folder converts every .step / .stp inside it. Output goes next to each input unless an output
// folder is given.

var arguments = Array(CommandLine.arguments.dropFirst())
var chord = 0.02
if let flag = arguments.firstIndex(of: "--chord"), flag + 1 < arguments.count, let value = Double(arguments[flag + 1]) {
    chord = value
    arguments.removeSubrange(flag...(flag + 1))
}
guard let input = arguments.first else {
    FileHandle.standardError.write(Data("usage: step2stl <file-or-folder> [<output-folder>] [--chord <mm>]\n".utf8))
    exit(2)
}

let fileManager = FileManager.default
let inputURL = URL(fileURLWithPath: input)
var isDirectory: ObjCBool = false
guard fileManager.fileExists(atPath: input, isDirectory: &isDirectory) else {
    FileHandle.standardError.write(Data("step2stl: no such file: \(input)\n".utf8))
    exit(2)
}
let sources: [URL] = isDirectory.boolValue
    ? ((try? fileManager.contentsOfDirectory(at: inputURL, includingPropertiesForKeys: nil)) ?? [])
        .filter { ["step", "stp"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    : [inputURL]
let outputFolder = arguments.count > 1 ? URL(fileURLWithPath: arguments[1], isDirectory: true) : nil
if let outputFolder { try? fileManager.createDirectory(at: outputFolder, withIntermediateDirectories: true) }

var failures = 0
for source in sources {
    let name = source.deletingPathExtension().lastPathComponent + ".stl"
    let destination = (outputFolder ?? source.deletingLastPathComponent()).appendingPathComponent(name)
    do {
        var options = STEP.Options()
        options.chordToleranceMM = chord
        let assembly = try await STEP.loadAssembly(contentsOf: source, options: options)
        guard assembly.triangleCount > 0 else {
            print("SKIP \(source.lastPathComponent): no triangles (\(assembly.diagnostics.count) notes)")
            failures += 1
            continue
        }
        let data = STL.binaryData(for: assembly)
        try data.write(to: destination)
        print("OK   \(source.lastPathComponent) -> \(name): \(assembly.triangleCount) triangles, \(data.count / 1024) KB")
    } catch {
        print("FAIL \(source.lastPathComponent): \(error)")
        failures += 1
    }
}
exit(failures == 0 ? 0 : 1)
