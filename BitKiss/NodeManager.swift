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
    /// Transaction id of the channel's funding, once it exists. Look it up on
    /// mempool.space to watch confirmations.
    let fundingTxid: String?
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

/// What finally happened to a payment, as reported by the node's events.
enum PaymentOutcome: Equatable {
    case succeeded
    case failed(String)
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
    /// Listens for node events (payment results, channel changes) while running.
    private var eventTask: Task<Void, Never>?
    /// Final results of payments we sent, by payment id, filled in by the event loop.
    private var outcomes: [PaymentId: PaymentOutcome] = [:]

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
            listenForEvents(on: started)
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
                confirmations: $0.confirmations ?? 0,
                fundingTxid: $0.fundingTxo?.txid)
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

    /// Pays a Lightning invoice (lnbc...) and waits for the node to report the
    /// real result. Returns true only when the payment actually succeeded.
    @discardableResult
    func payInvoice(_ text: String) async -> Bool {
        guard let node else { return false }
        isBusy = true
        defer { isBusy = false }

        let paymentId: PaymentId
        do {
            let inv = try Bolt11Invoice.fromStr(
                invoiceStr: text.trimmingCharacters(in: .whitespacesAndNewlines))
            paymentId = try await Task.detached {
                try node.bolt11Payment().send(invoice: inv, routeParameters: nil)
            }.value
        } catch {
            message = "Could not pay: \(error)"
            return false
        }

        message = "Finding a route..."
        switch await waitForOutcome(of: paymentId) {
        case .succeeded:
            message = "Payment sent."
            return true
        case .failed(let reason):
            message = "Payment failed: \(reason)"
            return false
        case nil:
            message = "Still trying to pay. Check your balance in a moment."
            return false
        }
    }

    /// Waits up to `timeout` seconds for the event loop to record the payment's
    /// outcome. Nil means the node had not decided yet.
    private func waitForOutcome(of paymentId: PaymentId, timeout: TimeInterval = 90) async -> PaymentOutcome? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let outcome = outcomes[paymentId] { return outcome }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    /// Pulls events off the node for as long as it runs. Payment results are
    /// stored for ``payInvoice(_:)``; channel changes trigger a balance refresh.
    private func listenForEvents(on node: Node) {
        eventTask?.cancel()
        eventTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let event = await node.nextEventAsync()
                await self?.handle(event)
                try? node.eventHandled()
            }
        }
    }

    @MainActor
    private func handle(_ event: Event) async {
        switch event {
        case .paymentSuccessful(let paymentId, _, _, _):
            if let paymentId { outcomes[paymentId] = .succeeded }
            await refresh()
        case .paymentFailed(let paymentId, _, let reason):
            if let paymentId { outcomes[paymentId] = .failed(Self.describe(reason)) }
        case .paymentReceived:
            message = "Payment received."
            await refresh()
        case .channelReady:
            message = "Channel is ready. You can send and receive on Lightning."
            await refresh()
        case .channelClosed:
            message = "A channel was closed. Funds return on-chain after a while."
            await refresh()
        default:
            break
        }
    }

    /// Plain words for LDK's failure reasons.
    private static func describe(_ reason: PaymentFailureReason?) -> String {
        guard let reason else { return "unknown reason" }
        switch reason {
        case .routeNotFound: return "no route to the receiver"
        case .recipientRejected: return "the receiver rejected it"
        case .paymentExpired: return "the invoice expired"
        case .retriesExhausted: return "every route attempt failed"
        case .userAbandoned: return "cancelled"
        default: return "\(reason)"
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

    /// The last lines of the node's own log, for seeing what it is doing
    /// when something stalls. Empty when no log has been written yet.
    func recentLog(lines: Int = 60) -> String {
        guard let dir = try? Self.storageDir() else { return "" }
        let candidates = [
            "\(dir)/logs/ldk_node_latest.log",
            "\(dir)/ldk_node.log",
        ]
        for path in candidates {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let all = text.split(separator: "\n", omittingEmptySubsequences: true)
            return all.suffix(lines).joined(separator: "\n")
        }
        return ""
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
