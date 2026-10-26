import SwiftUI

/// Receive sats: a Lightning invoice for an amount, or an on-chain address.
struct ReceiveSheet: View {
    let manager: NodeManager
    @Environment(\.dismiss) private var dismiss

    @State private var mode = 0           // 0 = Lightning, 1 = On-chain
    @State private var amount = "1000"

    var body: some View {
        NavigationStack {
            ZStack {
                BK.plum.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        Picker("", selection: $mode) {
                            Text("Lightning").tag(0)
                            Text("On-chain").tag(1)
                        }
                        .pickerStyle(.segmented)

                        if mode == 0 { lightning } else { onchain }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Receive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(BK.pink)
                }
            }
            .toolbarBackground(BK.plum, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .foregroundStyle(.white)
        .onAppear { if manager.address.isEmpty { manager.newAddress() } }
    }

    private var canReceive: UInt64 {
        manager.channels.filter(\.isReady).map(\.canReceiveSats).reduce(0, +)
    }

    private var lightning: some View {
        VStack(spacing: 16) {
            if canReceive == 0 {
                Text("Your wallet can't receive over Lightning yet. It can once you've sent a few sats out, or use On-chain.")
                    .font(.footnote)
                    .foregroundStyle(BK.orange)
                    .multilineTextAlignment(.center)
            } else {
                Text("You can receive up to \(satsText(canReceive)) sats")
                    .font(.footnote)
                    .foregroundStyle(BK.muted)
            }
            HStack {
                TextField("Amount", text: $amount)
                    .keyboardType(.numberPad)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("sats").foregroundStyle(BK.muted)
            }
            .padding(14)
            .background(BK.card, in: RoundedRectangle(cornerRadius: 16))

            Button {
                manager.createInvoice(amountSats: UInt64(amount) ?? 0)
            } label: {
                Text("Create invoice")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity).frame(height: 52)
            }
            .buttonStyle(.borderedProminent).tint(BK.pink)
            .disabled((UInt64(amount) ?? 0) == 0)

            if !manager.invoice.isEmpty {
                ReceiveCard(value: manager.invoice,
                            caption: "Lightning invoice",
                            accent: BK.orange)
            }
        }
    }

    private var onchain: some View {
        VStack(spacing: 16) {
            Text("Send bitcoin to this address. It shows up after one confirmation.")
                .font(.footnote)
                .foregroundStyle(BK.muted)
                .multilineTextAlignment(.center)
            if !manager.address.isEmpty {
                ReceiveCard(value: manager.address,
                            caption: "Bitcoin address",
                            accent: BK.orange)
            }
            Button("Use a fresh address") { manager.newAddress() }
                .buttonStyle(.bordered).tint(BK.orange)
        }
    }
}
