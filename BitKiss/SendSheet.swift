import SwiftUI

/// Send sats: paste or scan a Lightning invoice, see the amount, pay.
struct SendSheet: View {
    let manager: NodeManager
    let initialInvoice: String?
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var request: PaymentRequest? = nil
    @State private var paying = false
    @State private var paid = false
    @State private var error = ""

    var body: some View {
        NavigationStack {
            ZStack {
                BK.plum.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        if paid {
                            success
                        } else if let request {
                            confirm(request)
                        } else {
                            entry
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(paid ? "Done" : "Cancel") { dismiss() }.foregroundStyle(BK.pink)
                }
            }
            .toolbarBackground(BK.plum, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .foregroundStyle(.white)
        .onAppear {
            if let initialInvoice { use(initialInvoice) }
        }
    }

    /// Pulls an invoice out of pasted or scanned text ("lightning:lnbc..." etc).
    static func invoice(in raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["lightning://", "lightning:", "bitkiss://", "bitkiss:"] {
            while t.lowercased().hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        }
        return t.lowercased().hasPrefix("ln") ? t : nil
    }

    private func use(_ raw: String) {
        error = ""
        guard let inv = Self.invoice(in: raw) else {
            error = "That doesn't look like a Lightning invoice."
            return
        }
        guard let r = NodeManager.describe(invoice: inv) else {
            error = "Couldn't read that invoice."
            return
        }
        text = inv
        request = r
    }

    private var entry: some View {
        VStack(spacing: 16) {
            Text("Paste a Lightning invoice, or scan one from the home screen.")
                .font(.footnote)
                .foregroundStyle(BK.muted)
                .multilineTextAlignment(.center)
            TextField("lnbc...", text: $text, axis: .vertical)
                .lineLimit(3...6)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.footnote, design: .monospaced))
                .padding(12)
                .background(BK.card, in: RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 12) {
                Button("Paste") {
                    if let s = UIPasteboard.general.string { use(s) }
                }
                .buttonStyle(.bordered).tint(BK.orange)
                Button("Continue") { use(text) }
                    .buttonStyle(.borderedProminent).tint(BK.pink)
                    .disabled(text.isEmpty)
            }
            if !error.isEmpty {
                Text(error).font(.footnote).foregroundStyle(BK.orange)
            }
        }
    }

    private func confirm(_ r: PaymentRequest) -> some View {
        VStack(spacing: 18) {
            Text(r.amountSats.map { "\(satsText($0)) sats" } ?? "Any amount")
                .font(.system(size: 44, weight: .bold, design: .rounded))
            if let a = r.amountSats, let eur = manager.euros(for: a) {
                Text(eur).foregroundStyle(BK.muted)
            }
            if !r.memo.isEmpty {
                Text(r.memo)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            Text("You have \(satsText(manager.lightningSats)) sats on Lightning")
                .font(.footnote)
                .foregroundStyle(BK.muted)
            if paying {
                ProgressView().tint(BK.pink)
                Text(manager.message).font(.footnote).foregroundStyle(BK.muted)
            }
            if !error.isEmpty {
                Text(error).font(.footnote).foregroundStyle(BK.orange).multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Back") { request = nil; error = "" }
                    .buttonStyle(.bordered).tint(BK.orange)
                    .disabled(paying)
                Button("Pay") { Task { await pay() } }
                    .buttonStyle(.borderedProminent).tint(BK.pink)
                    .disabled(paying || r.amountSats == nil)
            }
            if r.amountSats == nil {
                Text("Invoices without an amount aren't supported yet.")
                    .font(.caption).foregroundStyle(BK.orange)
            }
        }
        .padding(.top, 20)
    }

    private var success: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(BK.green)
            Text("Sent")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(BK.pink)
            if let a = request?.amountSats {
                Text("\(satsText(a)) sats")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
            }
        }
        .padding(.top, 40)
    }

    private func pay() async {
        paying = true
        error = ""
        let ok = await manager.payInvoice(text)
        paying = false
        if ok {
            paid = true
            await manager.refresh()
        } else {
            error = manager.message
        }
    }
}
