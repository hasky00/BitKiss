import SwiftUI

/// Confirmation screen for an invoice another app sent to BitKiss.
///
/// Shows the amount and memo, then pays on tap. Nothing is sent until the
/// user presses Pay, so a wrong tap in the other app costs nothing.
struct PayRequestSheet: View {
    let request: PaymentRequest
    let manager: NodeManager
    let onDone: () -> Void

    @State private var paying = false
    @State private var paid = false
    @State private var error = ""

    private let plum = Color(red: 0x1E/255, green: 0x12/255, blue: 0x30/255)
    private let pink = Color(red: 0xFF/255, green: 0x5C/255, blue: 0x8A/255)
    private let orange = Color(red: 0xF7/255, green: 0x93/255, blue: 0x1A/255)

    var body: some View {
        ZStack {
            plum.ignoresSafeArea()
            VStack(spacing: 24) {
                Text(paid ? "Sent" : "Pay with BitKiss")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(pink)

                VStack(spacing: 6) {
                    Text(amountText)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                    if !request.memo.isEmpty {
                        Text(request.memo)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                    }
                }

                Text("You have \(manager.lightningSats) sats on Lightning")
                    .font(.footnote)
                    .foregroundStyle(orange)

                if paying {
                    Text(manager.message)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                }

                if !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(orange)
                        .multilineTextAlignment(.center)
                }

                if paid {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                    Button("Done") { onDone() }
                        .buttonStyle(.borderedProminent).tint(pink)
                } else {
                    HStack(spacing: 12) {
                        Button("Cancel") { onDone() }
                            .buttonStyle(.bordered).tint(orange)
                            .disabled(paying)
                        Button(paying ? "Paying…" : "Pay") { Task { await pay() } }
                            .buttonStyle(.borderedProminent).tint(pink)
                            .disabled(paying || !canPay)
                    }
                }
            }
            .padding(24)
            .foregroundStyle(.white)
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(paying)
    }

    private var amountText: String {
        guard let sats = request.amountSats else { return "Any amount" }
        return "\(sats) sats"
    }

    /// Invoices without an amount need one from us, which BitKiss does not ask for yet.
    private var canPay: Bool {
        request.amountSats != nil
    }

    private func pay() async {
        paying = true
        error = ""
        let ok = await manager.payInvoice(request.invoice)
        paying = false
        if ok {
            paid = true
            await manager.refresh()
        } else {
            error = manager.message
        }
    }
}
