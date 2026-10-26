import SwiftUI

/// The home screen: balance, three buttons, recent activity. Nothing else.
/// Everything about the node lives behind the gear (AdvancedView).
struct ContentView: View {
    let manager: NodeManager

    @State private var showReceive = false
    @State private var showSend = false
    @State private var showScanner = false
    @State private var showAdvanced = false
    /// An invoice the scanner found, handed to the Send sheet.
    @State private var scannedInvoice: ScannedInvoice? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                BK.plum.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 22) {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(BK.orange)
                            Text("BitKiss")
                                .font(.system(size: 30, weight: .heavy, design: .rounded))
                                .foregroundStyle(BK.pink)
                            Spacer()
                        }
                        .padding(.top, 4)
                        balanceCard
                        actionRow
                        if !manager.message.isEmpty || manager.startFailed {
                            statusLine
                        }
                        activityList
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
                .refreshable { await manager.refresh() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdvanced = true } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(BK.muted)
                    }
                }
            }
            .toolbarBackground(BK.plum, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .foregroundStyle(.white)
        .task { await manager.start() }
        .sheet(isPresented: $showReceive) { ReceiveSheet(manager: manager) }
        .sheet(isPresented: $showSend) { SendSheet(manager: manager, initialInvoice: nil) }
        .sheet(item: $scannedInvoice) { inv in SendSheet(manager: manager, initialInvoice: inv.text) }
        .fullScreenCover(isPresented: $showScanner) {
            ScannerView { code in
                showScanner = false
                if let inv = SendSheet.invoice(in: code) {
                    scannedInvoice = ScannedInvoice(text: inv)
                } else {
                    manager.message = "That code is not a Lightning invoice."
                }
            }
        }
        .sheet(isPresented: $showAdvanced) { AdvancedView(manager: manager) }
    }

    // MARK: - Pieces

    private var balanceCard: some View {
        VStack(spacing: 6) {
            Text("BALANCE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BK.muted)
                .padding(.top, 6)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(satsText(manager.totalSats))
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("sats")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(BK.muted)
            }
            Text(manager.euros(for: manager.totalSats) ?? " ")
                .font(.subheadline)
                .foregroundStyle(BK.muted)
            HStack(spacing: 14) {
                Label("\(satsText(manager.lightningSats)) Lightning", systemImage: "bolt.fill")
                Label("\(satsText(manager.onchainSats)) on-chain", systemImage: "link")
            }
            .font(.caption)
            .foregroundStyle(BK.muted)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(BK.card, in: RoundedRectangle(cornerRadius: 22))
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            actionButton("Receive", icon: "arrow.down.left") { showReceive = true }
            Button { showScanner = true } label: {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(BK.plum)
                    .frame(width: 60, height: 60)
                    .background(BK.orange, in: Circle())
            }
            actionButton("Send", icon: "arrow.up.right") { showSend = true }
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14, weight: .bold))
                Text(title).font(.system(size: 17, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(BK.card, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(manager.startFailed ? manager.status : manager.message)
                .font(.footnote)
                .foregroundStyle(BK.orange)
            if manager.startFailed {
                Button("Retry") { Task { await manager.start() } }
                    .buttonStyle(.borderedProminent).tint(BK.pink)
                    .disabled(manager.isBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activityList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RECENT ACTIVITY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BK.muted)
            if manager.activity.isEmpty {
                Text(manager.status.hasPrefix("Running") ? "No payments yet. Receive your first BitKiss." : "Starting your wallet...")
                    .font(.subheadline)
                    .foregroundStyle(BK.muted)
                    .padding(.vertical, 10)
            }
            ForEach(manager.activity.prefix(20)) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.incoming ? "arrow.down.left" : "arrow.up.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(item.failed ? BK.orange : (item.incoming ? BK.green : .white))
                        .frame(width: 36, height: 36)
                        .background(BK.card, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label(for: item))
                            .font(.system(size: 16, weight: .semibold))
                        Text(item.date, style: .relative)
                            .font(.caption)
                            .foregroundStyle(BK.muted)
                    }
                    Spacer()
                    Text((item.incoming ? "+" : "-") + satsText(item.sats))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(item.failed ? BK.muted : (item.incoming ? BK.green : .white))
                }
                .padding(12)
                .background(BK.card, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func label(for item: ActivityItem) -> String {
        if item.failed { return "Failed" }
        let what = item.onchain ? "on-chain" : "Lightning"
        let verb = item.incoming ? "Received" : "Sent"
        return item.pending ? "\(verb) \(what) (pending)" : "\(verb) \(what)"
    }
}

/// Wrapper so a scanned invoice can drive a sheet.
struct ScannedInvoice: Identifiable {
    let text: String
    var id: String { text }
}

#Preview {
    ContentView(manager: NodeManager())
}
