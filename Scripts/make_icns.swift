import Foundation

struct IconSlot {
    let type: String
    let filename: String
}

let slots = [
    IconSlot(type: "icp4", filename: "icon_16x16.png"),
    IconSlot(type: "ic11", filename: "icon_16x16@2x.png"),
    IconSlot(type: "icp5", filename: "icon_32x32.png"),
    IconSlot(type: "ic12", filename: "icon_32x32@2x.png"),
    IconSlot(type: "icp6", filename: "icon_32x32@2x.png"),
    IconSlot(type: "ic07", filename: "icon_128x128.png"),
    IconSlot(type: "ic13", filename: "icon_128x128@2x.png"),
    IconSlot(type: "ic08", filename: "icon_256x256.png"),
    IconSlot(type: "ic14", filename: "icon_256x256@2x.png"),
    IconSlot(type: "ic09", filename: "icon_512x512.png"),
    IconSlot(type: "ic10", filename: "icon_512x512@2x.png"),
]

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: make_icns.swift <iconset-dir> <output.icns>\n", stderr)
    exit(2)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
var body = Data()

func appendUInt32(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

for slot in slots {
    let url = iconsetURL.appendingPathComponent(slot.filename)
    let pngData = try Data(contentsOf: url)
    guard let typeData = slot.type.data(using: .ascii), typeData.count == 4 else {
        fputs("Invalid ICNS type \(slot.type)\n", stderr)
        exit(1)
    }
    body.append(typeData)
    appendUInt32(UInt32(pngData.count + 8), to: &body)
    body.append(pngData)
}

var output = Data("icns".utf8)
appendUInt32(UInt32(body.count + 8), to: &output)
output.append(body)
try output.write(to: outputURL, options: .atomic)
