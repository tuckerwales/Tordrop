import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

enum QRCode {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])
    private static var cache: (value: String, image: NSImage)?

    /// Renders `string` as a QR code bitmap. The last result is cached, since
    /// SwiftUI re-evaluates the view on every state change (e.g. log lines).
    static func image(from string: String, scale: CGFloat = 8) -> NSImage? {
        if let cache, cache.value == string { return cache.image }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache = (string, image)
        return image
    }
}

struct QRCodeView: View {
    let value: String
    let size: CGFloat
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white)
            if let img = QRCode.image(from: value) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(6)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
    }
}
