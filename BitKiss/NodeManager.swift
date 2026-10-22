import Foundation
import LDKNode
import Observation

/// One Lightning channel, in simple words for the screen.
struct ChannelSummary: Identifiable {
    let id: String
    let peer: String
    let capacitySats: UInt64
    let canSendSats: UInt64
    let canReceiveSats: UInt64
    let isReady: Bool
    let confirmations: UInt32
}

/// A Lightning invoice someone asked BitKiss to pay, decoded for the screen.
///
/// Another app (Damus, say) hands this over through the `bitkiss:` URL scheme;
/// the user then sees the amount and memo and decides whether to pay.
struct PaymentRequest: Identifiable, Equatable {
    var id: String { invoice }
    let invoice: String
    /// Nil when the invoice lets the payer choose the amount.
    let amountSats: UInt64?
    let memo: String
}

/// Runs the Lightning node that lives inside BitKiss.
/// Mainnet: real sats. Handle with care.
@Observable
final class NodeManager {
    var status = "Not started"
    var nodeId = ""
    var onchainSats: UInt64 = 0
    var lightningSats: UInt64 = 0
    var address = ""
    var channels: [ChannelSummary] = []
    var invoice = ""
    var message = ""
    var isBusy = false
    /// The 12 recovery words. Shown once so the user can write them down.
    var mnemonic = ""

    private var node: Node?

    // Blockstream's public Esplora server for mainnet.
    private let esploraURL = "https://blockstream.info/api"
    // Rapid Gossip Sync: a compressed snapshot of the Lightning network,
    // so the phone can find payment routes right away.
    private let rgsURL = "https://rapidsync.lightningdevkit.org/snapshot"

    func start() async {
        guard node == nil else { return }
        status = "Starting node..."
        isBusy = true
        defer { isBusy = false }
        do {
            let dir = try Self.storageDir()
            let url = esploraURL
            let rgs = rgsURL
            let words = try SeedStore.loadOrCreate()
            mnemonic = words
            let started = try await Task.detached { () throws -> Node in
                let builder = Builder()
                builder.setNetwork(network: .bitcoin)
                builder.setEntropyBip39Mnemonic(mnemonic: words, passphrase: nil)
                builder.setGossipSourceRgs(rgsServerUrl: rgs)
                builder.setStorageDirPath(storageDirPath: dir)
                builder.setChainSourceEsplora(serverUrl: url, config: nil)
                let node = try builder.build()
                try node.start()
                return node
            }.value
            node = started
            nodeId = started.nodeId()
            status = "Running on mainnet"
            await refresh()
        } catch {
            status = "Error: \(error)"
        }
    }

    func refresh() async {
        guard let node else { return }
        isBusy = true
        defer { isBusy = false }
        _ = try? await Task.detached { try node.syncWallets() }.value
        let balances = node.listBalances()
        onchainSats = balances.totalOnchainBalanceSats
        lightningSats = balances.totalLightningBalanceSats
        channels = node.listChannels().map {
            ChannelSummary(
                id: $0.userChannelId,
                peer: String($0.counterpartyNodeId.prefix(12)) + "...",
                capacitySats: $0.channelValueSats,
                canSendSats: $0.outboundCapacityMsat / 1000,
                canReceiveSats: $0.inboundCapacityMsat / 1000,
                isReady: $0.isChannelReady,
                confirmations: $0.confirmations ?? 0)
        }
    }

    func newAddress() {
        guard let node else { return }
        do {
            address = try node.onchainPayment().newAddress()
        } catch {
            message = "Error: \(error)"
        }
    }

    /// Opens a channel. `connection` looks like: pubkey@host:port
    /// `giftSats` is pushed to the other side, so we can also RECEIVE that much.
    func openChannel(connection: String, amountSats: UInt64, giftSats: UInt64) async {
        guard let node else { return }
        let parts = connection.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            message = "That doesn't look like pubkey@host:port"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let push: UInt64? = giftSats > 0 ? giftSats * 1000 : nil
            _ = try await Task.detached {
                try node.openChannel(
                    nodeId: parts[0], address: parts[1],
                    channelAmountSats: amountSats,
                    pushToCounterpartyMsat: push, channelConfig: nil)
            }.value
            message = "Channel opening. It needs a few blocks to be ready."
        } catch {
            message = "Could not open channel: \(error)"
        }
        await refresh()
    }

    /// Makes a Lightning invoice so someone can pay BitKiss.
    func createInvoice(amountSats: UInt64) {
        guard let node else { return }
        do {
            let inv = try node.bolt11Payment().receive(
                amountMsat: amountSats * 1000,
                description: .direct(description: "A BitKiss"),
                expirySecs: 3600)
            invoice = inv.description
        } catch {
            message = "Could not make invoice: \(error)"
        }
    }

    /// Pays a Lightning invoice (lnbc...). Returns true when the payment was sent.
    @discardableResult
    func payInvoice(_ text: String) async -> Bool {
        guard let node else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let inv = try Bolt11Invoice.fromStr(
                invoiceStr: text.trimmingCharacters(in: .whitespacesAndNewlines))
            _ = try await Task.detached {
                try node.bolt11Payment().send(invoice: inv, routeParameters: nil)
            }.value
            message = "Payment sent. Tap Refresh in a moment."
            return true
        } catch {
            message = "Could not pay: \(error)"
            return false
        }
    }

    /// Reads an invoice so the screen can show what it asks for before paying.
    /// Returns nil when the text is not a valid invoice.
    static func describe(invoice text: String) -> PaymentRequest? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let inv = try? Bolt11Invoice.fromStr(invoiceStr: cleaned) else { return nil }
        let sats = inv.amountMilliSatoshis().map { $0 / 1000 }
        let memo: String
        switch inv.invoiceDescription() {
        case .direct(let text): memo = text
        case .hash: memo = ""
        }
        return PaymentRequest(invoice: cleaned, amountSats: sats, memo: memo)
    }

    /// Where the node keeps its data (and its seed) on the phone.
    private static func storageDir() throws -> String {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        // One folder per network, so test data never mixes with real data.
        let dir = base.appendingPathComponent("ldk-node/bitcoin", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}
