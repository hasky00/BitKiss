import SwiftUI

struct ContentView: View {
    @State private var manager = NodeManager()
    @State private var copied = ""
    @State private var connection = ""
    @State private var channelSats = "50000"
    @State private var giftSats = "10000"
    @State private var invoiceSats = "1000"
    @State private var payText = ""

    private let plum = Color(red: 0x1E/255, green: 0x12/255, blue: 0x30/255)
    private let pink = Color(red: 0xFF/255, green: 0x5C/255, blue: 0x8A/255)
    private let orange = Color(red: 0xF7/255, green: 0x93/255, blue: 0x1A/255)

    var body: some View {
        ZStack {
            plum.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("BitKiss")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(pink)

                    Label(manager.status, systemImage: "bolt.fill")
                        .foregroundStyle(orange)

                    if !manager.message.isEmpty {
                        Text(manager.message)
                            .font(.footnote)
                            .foregroundStyle(orange)
                    }

                    card(title: "Balance") {
                        Text("\(manager.onchainSats) sats on-chain")
                        Text("\(manager.lightningSats) sats on Lightning")
                    }

                    card(title: "Node ID") {
                        Text(manager.nodeId.isEmpty ? "..." : manager.nodeId)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        copyButton("Copy node ID", value: manager.nodeId)
                    }

                    card(title: "Receive on-chain (test sats)") {
                        if !manager.address.isEmpty {
                            Text(manager.address)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                            copyButton("Copy address", value: manager.address)
                        }
                        Button("New address") { manager.newAddress() }
                            .buttonStyle(.borderedProminent).tint(pink)
                    }

                    card(title: "Channels") {
                        if manager.channels.isEmpty {
                            Text("No channels yet").foregroundStyle(.white.opacity(0.7))
                        }
                        ForEach(manager.channels) { ch in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(ch.capacitySats) sats with \(ch.peer)")
                                Text(ch.isReady
                                     ? "Ready. Send \(ch.canSendSats), receive \(ch.canReceiveSats)"
                                     : "Waiting for blocks (\(ch.confirmations) so far)")
                                    .font(.footnote)
                                    .foregroundStyle(ch.isReady ? .green : orange)
                            }
                        }
                    }

                    card(title: "Open a channel") {
                        field("pubkey@host:port", text: $connection)
                        field("Channel size (sats)", text: $channelSats, numbers: true)
                        field("Gift to other side (sats)", text: $giftSats, numbers: true)
                        Button("Open channel") {
                            Task {
                                await manager.openChannel(
                                    connection: connection,
                                    amountSats: UInt64(channelSats) ?? 0,
                                    giftSats: UInt64(giftSats) ?? 0)
                            }
                        }
                        .buttonStyle(.borderedProminent).tint(pink)
                    }

                    card(title: "Receive a BitKiss (Lightning)") {
                        field("Amount (sats)", text: $invoiceSats, numbers: true)
                        Button("Make invoice") {
                            manager.createInvoice(amountSats: UInt64(invoiceSats) ?? 0)
                        }
                        .buttonStyle(.borderedProminent).tint(pink)
                        if !manager.invoice.isEmpty {
                            Text(manager.invoice)
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(3)
                            copyButton("Copy invoice", value: manager.invoice)
                        }
                    }

                    card(title: "Send a BitKiss (pay invoice)") {
                        field("lntb...", text: $payText)
                        HStack {
                            Button("Paste") { payText = UIPasteboard.general.string ?? "" }
                                .buttonStyle(.bordered).tint(orange)
                            Button("Pay") { Task { await manager.payInvoice(payText) } }
                                .buttonStyle(.borderedProminent).tint(pink)
                        }
                    }

                    Button("Refresh") { Task { await manager.refresh() } }
                        .buttonStyle(.borderedProminent)
                        .tint(orange)
                }
                .padding(24)
                .disabled(manager.isBusy)
            }
        }
        .foregroundStyle(.white)
        .task { await manager.start() }
    }

    private func copyButton(_ label: String, value: String) -> some View {
        Button(copied == value ? "Copied" : label) {
            UIPasteboard.general.string = value
            copied = value
        }
        .buttonStyle(.bordered)
        .tint(orange)
    }

    private func field(_ placeholder: String, text: Binding<String>, numbers: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(numbers ? .numberPad : .default)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.footnote, design: .monospaced))
            .padding(10)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    ContentView()
}
