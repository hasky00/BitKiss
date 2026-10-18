import SwiftUI
import CoreImage.CIFilterBuiltins

/// A pretty way to show something you want to receive on:
/// a QR code, a shortened copy of the text, and copy / share buttons.
struct ReceiveCard: View {
    let value: String
    let caption: String
    let accent: Color

    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            QRCodeView(text: value)
                .frame(width: 200, height: 200)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))

            Text(caption)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))

            Button {
                UIPasteboard.general.string = value
                copied = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                HStack {
                    Text(copied ? "Copied" : Self.shorten(value))
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .padding(12)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            .foregroundStyle(.white)

            ShareLink(item: value) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(accent)
        }
        .frame(maxWidth: .infinity)
    }

    /// "tb1qabcdef...u4ern" instead of 62 characters of soup.
    static func shorten(_ s: String, head: Int = 10, tail: Int = 6) -> String {
        guard s.count > head + tail + 3 else { return s }
        return s.prefix(head) + "…" + s.suffix(tail)
    }
}

/// Draws a QR code using the QR generator built into every iPhone.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.make(text) {
            Image(uiImage: image)
                .interpolation(.none)   // keeps the squares crisp
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "xmark.square")
        }
    }

    static func make(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        ReceiveCard(value: "tb1qexampleaddressthatisquitelong0123456789u4ern",
                    caption: "On-chain address",
                    accent: .orange)
            .padding()
    }
}
