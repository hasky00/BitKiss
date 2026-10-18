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

/// Runs the Lightning node that lives inside BitKiss.
/// Test network only for now (Mutinynet = signet with play money).
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

    // Mutinynet: a test network with fast blocks and a free faucet.
    private let esploraURL = "https://mutinynet.com/api"

    func start() async {
        guard node == nil else { return }
        status = "Starting node..."
        isBusy = true
        defer { isBusy = false }
        do {
            let dir = try Self.storageDir()
            let url = esploraURL
            let words = try SeedStore.loadOrCreate()
            mnemonic = words
            let started = try await Task.detached { () throws -> Node in
                let builder = Builder()
                builder.setNetwork(network: .signet)
                builder.setEntropyBip39Mnemonic(mnemonic: words, passphrase: nil)
                builder.setStorageDirPath(storageDirPath: dir)
                builder.setChainSourceEsplora(serverUrl: url, config: nil)
                let node = try builder.build()
                try node.start()
                return node
            }.value
            node = started
            nodeId = started.nodeId()
            status = "Running on Mutinynet (test sats)"
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

    /// Pays a Lightning invoice (lntb...).
    func payInvoice(_ text: String) async {
        guard let node else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let inv = try Bolt11Invoice.fromStr(
                invoiceStr: text.trimmingCharacters(in: .whitespacesAndNewlines))
            _ = try await Task.detached {
                try node.bolt11Payment().send(invoice: inv, routeParameters: nil)
            }.value
            message = "Payment sent. Tap Refresh in a moment."
        } catch {
            message = "Could not pay: \(error)"
        }
    }

    /// Where the node keeps its data (and its seed) on the phone.
    private static func storageDir() throws -> String {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        // One folder per network. The old "ldk-node" folder belonged to the
        // random seed we no longer use, so it is simply left behind.
        let dir = base.appendingPathComponent("ldk-node/signet", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}
