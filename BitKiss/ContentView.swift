import SwiftUI

struct ContentView: View {
    /// Shared with MyApp, which also uses it to pay invoices other apps send in.
    let manager: NodeManager
    @State private var copied = ""
    @State private var connection = ""
    @State private var channelSats = "50000"
    @State private var giftSats = "10000"
    @State private var invoiceSats = "1000"
    @State private var payText = ""
    @State private var showWords = false
    @State private var showLog = false
    @State private var nodeLog = ""

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
                        Text(manager.nodeId.isEmpty ? "..." : ReceiveCard.shorten(manager.nodeId, head: 12, tail: 8))
                            .font(.system(.footnote, design: .monospaced))
                        copyButton("Copy node ID", value: manager.nodeId)
                    }

                    card(title: "Recovery words") {
                        if showWords {
                            Text(manager.mnemonic)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                            Text("Write these 12 words down and keep them private. They are the only way to get your sats back if you lose this phone.")
                                .font(.footnote)
                                .foregroundStyle(orange)
                        }
                        Button(showWords ? "Hide words" : "Show words") {
                            showWords.toggle()
                        }
                        .buttonStyle(.bordered).tint(orange)
                        .disabled(manager.mnemonic.isEmpty)
                    }

                    card(title: "Receive on-chain") {
                        if !manager.address.isEmpty {
                            ReceiveCard(value: manager.address,
                                        caption: "Bitcoin address",
                                        accent: orange)
                        }
                        Button(manager.address.isEmpty ? "New address" : "Another address") {
                            manager.newAddress()
                        }
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
                                if let txid = ch.fundingTxid {
                                    Text("Funding tx: \(ReceiveCard.shorten(txid, head: 10, tail: 8))")
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.7))
                                    copyButton("Copy funding tx id", value: txid)
                                } else {
                                    Text("No funding transaction yet (still negotiating with the peer)")
                                        .font(.footnote)
                                        .foregroundStyle(.white.opacity(0.7))
                                }
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
                            ReceiveCard(value: manager.invoice,
                                        caption: "Lightning invoice for \(invoiceSats) sats",
                                        accent: orange)
                        }
                    }

                    card(title: "Send a BitKiss (pay invoice)") {
                        field("lnbc...", text: $payText)
                        HStack {
                            Button("Paste") { payText = UIPasteboard.general.string ?? "" }
                                .buttonStyle(.bordered).tint(orange)
                            Button("Pay") { Task { await manager.payInvoice(payText) } }
                                .buttonStyle(.borderedProminent).tint(pink)
                        }
                    }

                    card(title: "Node log") {
                        if showLog {
                            ScrollView(.horizontal) {
                                Text(nodeLog.isEmpty ? "No log yet." : nodeLog)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 260)
                        }
                        HStack {
                            Button(showLog ? "Hide log" : "Show log") {
                                nodeLog = manager.recentLog()
                                showLog.toggle()
                            }
                            .buttonStyle(.bordered).tint(orange)
                            if showLog {
                                copyButton("Copy log", value: nodeLog)
                            }
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
    ContentView(manager: NodeManager())
}
