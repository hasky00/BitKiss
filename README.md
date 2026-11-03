# BitKiss

A self-custody Lightning wallet for iPhone.

Your 12 recovery words are created on your phone and stay in its Keychain. A
real Lightning node ([LDK Node](https://github.com/lightningdevkit/ldk-node))
runs inside the app and opens its own channels. Nobody in the middle, not even
Hasky Labs.

Website: [bitkiss.eu](https://bitkiss.eu)

> BitKiss runs on **Bitcoin mainnet**. The sats are real. It is young software
> written by one person; use amounts you can afford to lose while it matures.

## Build it yourself

You need a Mac with Xcode 16 or newer, [Rust](https://rustup.rs), and an
iPhone. A free Apple ID is enough to run it on your own phone (the build
expires after 7 days; a paid developer account makes it a year).

```sh
git clone https://github.com/hasky00/BitKiss.git
cd BitKiss
bash scripts/build-ldk-node-0.7.1.sh   # compiles LDK Node for iPhone, 10-30 min
open BitKiss.xcodeproj
```

In Xcode: select the BitKiss target, **Signing & Capabilities**, choose your
own team. Plug in your iPhone, pick it as the destination, press **Run**.

Why the build script: LDK Node 0.7.1 fixes a bug that broke reconnects with
eclair peers such as ACINQ, but its prebuilt iOS framework was not published
yet. The script builds it from the tagged source and the project uses that
local package. Once LDK publishes the 0.7.1 framework, the project can point
back at the GitHub package.

## What it does today

- Send and receive over Lightning, receive on-chain
- Open a channel to a peer of your choice (Advanced)
- Pays invoices handed over by other apps (`bitkiss:` and `lightning:` links)
- Shows real reasons when a peer says no

## What it does not do yet

- Open a channel for you automatically (an LSP integration is planned)
- Back up channel state off the phone (VSS is planned); today, the 12 words
  recover on-chain funds, and channel funds only after the channel closes
- Nostr Wallet Connect

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Made with love by Hasky Labs, Copenhagen.
