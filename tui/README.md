# BitKiss for the terminal

BitKiss as a terminal app (TUI) for Linux. Built for Omarchy, runs in any
terminal. Same engine as the iPhone app (LDK Node), same look in spirit:
one balance, Receive, Send, recent activity. The node plumbing sits behind
an Advanced screen.

A computer can stay online, so this wallet keeps its Lightning connection
open as long as the app runs.

## Build and run

On Omarchy / Arch:

```sh
sudo pacman -S --needed rust base-devel
cd tui
cargo run --release
```

The first build takes a while (it compiles the Lightning node). To install
it as a command:

```sh
cargo install --path .
bitkiss
```

## Keys

| Key | What it does |
| --- | --- |
| `r` | Receive: type an amount, get an invoice and QR code |
| `s` | Send: paste an invoice (Ctrl+Shift+V), check it, Enter to pay |
| `a` | New on-chain address |
| `u` | Refresh now |
| `h` | Hide or show the balance |
| `v` | Advanced: node ID, channels, recovery words, node log |
| `q` | Quit |

## Good to know

- **This is its own wallet.** It creates its own 12 recovery words on first
  run. Do not type the words from the iPhone app (or any other wallet) into
  it: two running wallets on the same words can lose the channel's sats.
- **Mainnet, real sats.** Start small.
- **Where things live:** `~/.local/share/bitkiss/`. The recovery words are
  in `seed.words` there, readable only by you. Anyone who can read that
  file can take the sats, so treat the computer accordingly.
- **Backup:** the 12 words bring back on-chain sats. The Lightning channel
  state lives only in that folder for now (no remote backup yet), so do
  not delete it while a channel is open.
- **First sats:** with no channel yet, the first incoming payment opens one
  through Megalith, which keeps a fee from it (about 2,500 sats or 1.4%).
  Ask for at least 10,000 sats.
- Only one BitKiss can run at a time on the same data folder.

## Tests

```sh
cargo test
```

Made by Hasky Labs, Copenhagen. MIT license.
