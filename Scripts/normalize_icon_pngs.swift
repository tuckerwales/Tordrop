import AppKit
import CoreGraphics
import Foundation
import ImageIO

let stripOnly = CommandLine.arguments.dropFirst().first == "--strip-only"
let paths = CommandLine.arguments.dropFirst(stripOnly ? 2 : 1)
let overscan: CGFloat = 1.035

guard !paths.isEmpty else {
    fputs("Usage: normalize_icon_pngs.swift [--strip-only] <png> [<png> ...]\n", stderr)
    exit(2)
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func bitmapData(for image: CGImage) -> (data: [UInt8], width: Int, height: Int)? {
    let width = image.width
    let height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &data,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (data, width, height)
}

func alphaBounds(in data: [UInt8], width: Int, height: Int) -> CGRect? {
    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1

    for y in 0..<height {
        for x in 0..<width {
            let alpha = data[(y * width + x) * 4 + 3]
            guard alpha > 4 else { continue }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }

    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(
        x: minX,
        y: minY,
        width: maxX - minX + 1,
        height: maxY - minY + 1
    )
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        )
    else {
        throw NSError(domain: "normalize_icon_pngs", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "normalize_icon_pngs", code: 2)
    }
    try stripMetadataChunks(from: url)
}

func appendUInt32(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

func crc32(_ bytes: Data) -> UInt32 {
    var crc: UInt32 = 0xffffffff
    for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            let mask = 0 &- (crc & 1)
            crc = (crc >> 1) ^ (0xedb88320 & mask)
        }
    }
    return crc ^ 0xffffffff
}

func stripMetadataChunks(from url: URL) throws {
    let input = try Data(contentsOf: url)
    let signature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    guard input.starts(with: signature) else { return }

    let keep: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "sRGB"]
    var output = signature
    var index = signature.count

    while index + 12 <= input.count {
        let length = input[index..<(index + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let typeStart = index + 4
        let typeEnd = typeStart + 4
        let dataStart = typeEnd
        let dataEnd = dataStart + Int(length)
        let crcEnd = dataEnd + 4
        guard crcEnd <= input.count else { break }

        let typeData = input[typeStart..<typeEnd]
        let type = String(decoding: typeData, as: UTF8.self)
        if keep.contains(type) {
            let payload = input[dataStart..<dataEnd]
            appendUInt32(length, to: &output)
            output.append(typeData)
            output.append(payload)
            var crcInput = Data()
            crcInput.append(typeData)
            crcInput.append(payload)
            appendUInt32(crc32(crcInput), to: &output)
        }

        index = crcEnd
        if type == "IEND" { break }
    }

    try output.write(to: url, options: .atomic)
}

for path in paths {
    let url = URL(fileURLWithPath: path)
    if stripOnly {
        try stripMetadataChunks(from: url)
        continue
    }

    guard
        let source = NSImage(contentsOf: url),
        let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
        let bitmap = bitmapData(for: cgImage),
        let bounds = alphaBounds(in: bitmap.data, width: bitmap.width, height: bitmap.height)
    else {
        fputs("Failed to read \(path)\n", stderr)
        exit(1)
    }

    let canvas = CGSize(width: bitmap.width, height: bitmap.height)
    let scale = min(canvas.width / bounds.width, canvas.height / bounds.height) * overscan
    let drawSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    let drawRect = CGRect(
        x: (canvas.width - drawSize.width) / 2,
        y: (canvas.height - drawSize.height) / 2,
        width: drawSize.width,
        height: drawSize.height
    )

    guard
        let cropped = cgImage.cropping(to: bounds),
        let context = CGContext(
            data: nil,
            width: bitmap.width,
            height: bitmap.height,
            bitsPerComponent: 8,
            bytesPerRow: bitmap.width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        fputs("Failed to normalize \(path)\n", stderr)
        exit(1)
    }

    context.clear(CGRect(origin: .zero, size: canvas))
    context.interpolationQuality = .high
    context.draw(cropped, in: drawRect)
    guard let output = context.makeImage() else {
        fputs("Failed to render \(path)\n", stderr)
        exit(1)
    }

    try writePNG(output, to: url)
}
