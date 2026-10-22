import SwiftUI

@main struct MyApp: App {
    /// One node for the whole app, so a pay request from another app and the
    /// main screen talk to the same wallet.
    @State private var manager = NodeManager()
    /// An invoice handed over by another app, waiting for the user's yes.
    @State private var pendingRequest: PaymentRequest? = nil

    var body: some Scene {
        WindowGroup {
            ContentView(manager: manager)
                .onOpenURL { url in handle(url) }
                .sheet(item: $pendingRequest) { request in
                    PayRequestSheet(request: request, manager: manager) {
                        pendingRequest = nil
                    }
                }
        }
    }

    /// Accepts the ways other apps hand us an invoice:
    ///   bitkiss:lightning:lnbc...   (Damus "Find a Wallet" style)
    ///   bitkiss:lnbc...
    ///   bitkiss://pay?invoice=lnbc...
    ///   lightning:lnbc...
    private func handle(_ url: URL) {
        guard let invoice = Self.invoice(from: url),
              let request = NodeManager.describe(invoice: invoice) else {
            manager.message = "That link did not contain a Lightning invoice."
            return
        }
        pendingRequest = request
    }

    /// Pulls the `lnbc...` string out of any of the supported URL shapes.
    static func invoice(from url: URL) -> String? {
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let item = query.first(where: { $0.name == "invoice" }), let value = item.value {
            return value
        }

        var text = url.absoluteString
        for prefix in ["bitkiss://", "bitkiss:", "lightning://", "lightning:"] {
            while text.lowercased().hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
            }
        }
        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard cleaned.lowercased().hasPrefix("ln") else { return nil }
        return cleaned
    }
}
