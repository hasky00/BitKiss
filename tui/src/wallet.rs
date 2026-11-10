//! The Lightning node that lives inside BitKiss, and the few things the
//! screens need from it. Mainnet: real sats. Handle with care.

use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use ldk_node::bip39::Mnemonic;
use ldk_node::bitcoin::Network;
use ldk_node::bitcoin::secp256k1::PublicKey;
use ldk_node::config::{AnchorChannelsConfig, BackgroundSyncConfig, Config, EsploraSyncConfig};
use ldk_node::lightning::ln::channelmanager::PaymentId;
use ldk_node::lightning::ln::msgs::SocketAddress;
use ldk_node::lightning_invoice::{Bolt11Invoice, Bolt11InvoiceDescription, Description};
use ldk_node::payment::{PaymentDirection, PaymentKind, PaymentStatus};
use ldk_node::{Builder, Node, WordCount};

/// Blockstream's public Esplora. (mempool.space's API differs just enough
/// that the on-chain wallet sync fails against it.)
const ESPLORA_URL: &str = "https://blockstream.info/api";
/// Rapid Gossip Sync: a compressed snapshot of the Lightning network, so the
/// wallet can find payment routes right away.
const RGS_URL: &str = "https://rapidsync.lightningdevkit.org/snapshot";
/// Megalith, the LSP that opens a channel to a new wallet out of its first
/// incoming payment (LSPS2 "just-in-time" channels). No account needed.
pub const LSP_NODE_ID: &str = "034066e29e402d9cf55af1ae1026cc5adf92eed1e0e421785442f53717ad1453b0";
pub const LSP_ADDRESS: &str = "64.23.159.177:9735";
const LSP_TOKEN: &str = "bitkiss";
/// What we tell people to ask for at minimum, so the LSP fee leaves something.
pub const MIN_FIRST_PAYMENT_SATS: u64 = 10_000;

/// One Lightning channel, in simple words for the screen.
#[derive(Clone)]
pub struct ChannelRow {
    pub peer: String,
    pub capacity_sats: u64,
    pub can_send_sats: u64,
    pub can_receive_sats: u64,
    pub ready: bool,
    pub usable: bool,
}

/// One line of payment history.
#[derive(Clone)]
pub struct ActivityRow {
    pub incoming: bool,
    pub sats: u64,
    pub onchain: bool,
    pub pending: bool,
    pub failed: bool,
    pub timestamp: u64,
}

/// Everything the home screen shows, read from the node in one go.
#[derive(Clone, Default)]
pub struct Snapshot {
    pub onchain_sats: u64,
    pub lightning_sats: u64,
    pub channels: Vec<ChannelRow>,
    pub activity: Vec<ActivityRow>,
    pub peers_connected: usize,
    pub peers_known: usize,
}

impl Snapshot {
    /// How much the open channels can still take in.
    pub fn can_receive_sats(&self) -> u64 {
        self.channels.iter().filter(|c| c.ready).map(|c| c.can_receive_sats).sum()
    }
}

/// A Lightning invoice someone wants paid, decoded for the screen.
pub struct PayRequest {
    pub invoice: Bolt11Invoice,
    pub amount_sats: u64,
    pub memo: String,
}

/// Where BitKiss keeps its data: `$XDG_DATA_HOME/bitkiss`, else `~/.local/share/bitkiss`.
pub fn data_dir() -> Result<PathBuf, String> {
    let base = match std::env::var_os("XDG_DATA_HOME") {
        Some(dir) if !dir.is_empty() => PathBuf::from(dir),
        _ => {
            let home = std::env::var_os("HOME").ok_or("HOME is not set")?;
            PathBuf::from(home).join(".local/share")
        },
    };
    let dir = base.join("bitkiss");
    fs::create_dir_all(&dir).map_err(|e| format!("could not create {}: {e}", dir.display()))?;
    // Only the owner may look inside: the recovery words live here.
    let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));
    Ok(dir)
}

/// Loads the 12 recovery words, creating them on first run.
/// Returns the words and whether they were just created.
pub fn load_or_create_words(dir: &Path) -> Result<(String, bool), String> {
    let path = dir.join("seed.words");
    if path.exists() {
        let words = fs::read_to_string(&path).map_err(|e| format!("could not read the recovery words: {e}"))?;
        let words = words.split_whitespace().collect::<Vec<_>>().join(" ");
        Mnemonic::from_str(&words).map_err(|e| format!("{} is not a valid set of recovery words: {e}", path.display()))?;
        return Ok((words, false));
    }
    let words = ldk_node::generate_entropy_mnemonic(Some(WordCount::Words12)).to_string();
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .map_err(|e| format!("could not save the recovery words: {e}"))?;
    use std::io::Write;
    file.write_all(words.as_bytes()).and_then(|_| file.sync_all()).map_err(|e| format!("could not save the recovery words: {e}"))?;
    Ok((words, true))
}

fn lsp() -> (PublicKey, SocketAddress) {
    (
        PublicKey::from_str(LSP_NODE_ID).expect("valid LSP node id"),
        SocketAddress::from_str(LSP_ADDRESS).expect("valid LSP address"),
    )
}

/// Builds and starts the node. Slow (it talks to the chain server), so call
/// it off the screen thread.
pub fn start(dir: &Path, words: &str) -> Result<Arc<Node>, String> {
    let storage = dir.join("ldk-node/bitcoin");
    fs::create_dir_all(&storage).map_err(|e| format!("could not create {}: {e}", storage.display()))?;
    let mnemonic = Mnemonic::from_str(words).map_err(|e| format!("bad recovery words: {e}"))?;
    let (lsp_id, lsp_address) = lsp();

    let mut config = Config::default();
    config.network = Network::Bitcoin;
    // Anchor channels are the modern channel type. LDK keeps a small on-chain
    // reserve per anchor channel so it can bump fees on a force close; the
    // LSP's channel must be acceptable with an empty on-chain wallet, so no
    // reserve is demanded for it.
    config.anchor_channels_config =
        Some(AnchorChannelsConfig { trusted_peers_no_reserve: vec![lsp_id], per_channel_reserve_sats: 25_000 });

    let mut builder = Builder::from_config(config);
    builder.set_entropy_bip39_mnemonic(mnemonic, None);
    builder.set_gossip_source_rgs(RGS_URL.to_string());
    builder.set_storage_dir_path(storage.to_string_lossy().into_owned());
    // Sync gently: Blockstream's public server allows ~700 requests an hour
    // per IP. Refresh on demand is still there.
    let sync = EsploraSyncConfig {
        background_sync_config: Some(BackgroundSyncConfig {
            onchain_wallet_sync_interval_secs: 600,
            lightning_wallet_sync_interval_secs: 180,
            fee_rate_cache_update_interval_secs: 1800,
        }),
    };
    builder.set_chain_source_esplora(ESPLORA_URL.to_string(), Some(sync));
    builder.set_liquidity_source_lsps2(lsp_id, lsp_address, Some(LSP_TOKEN.to_string()));

    let node = builder.build().map_err(plain)?;
    node.start().map_err(plain)?;
    Ok(Arc::new(node))
}

/// Short, human wording for the errors we actually see in the wild.
pub fn plain(error: impl std::fmt::Debug) -> String {
    let text = format!("{error:?}");
    if text.contains("FeerateEstimation") {
        return "the chain server was too slow. Check your connection and retry.".into();
    }
    if text.contains("ConnectionFailed") {
        return "could not reach Megalith, the channel provider. Check your connection and retry.".into();
    }
    if text.contains("WalletOperation") || text.contains("Esplora") {
        return "could not reach the chain server. Retry in a moment.".into();
    }
    text
}

/// Reads what the screens show. Cheap: nothing here touches the network.
pub fn snapshot(node: &Node) -> Snapshot {
    let balances = node.list_balances();
    let channels = node
        .list_channels()
        .into_iter()
        .map(|c| {
            let peer = c.counterparty_node_id.to_string();
            ChannelRow {
                peer: format!("{}...", &peer[..12]),
                capacity_sats: c.channel_value_sats,
                can_send_sats: c.outbound_capacity_msat / 1000,
                can_receive_sats: c.inbound_capacity_msat / 1000,
                ready: c.is_channel_ready,
                usable: c.is_usable,
            }
        })
        .collect();
    let mut activity: Vec<ActivityRow> = node
        .list_payments()
        .into_iter()
        .filter(|p| p.amount_msat.is_some())
        // An invoice nobody paid yet is not activity.
        .filter(|p| !(p.direction == PaymentDirection::Inbound && p.status == PaymentStatus::Pending))
        .map(|p| ActivityRow {
            incoming: p.direction == PaymentDirection::Inbound,
            sats: p.amount_msat.unwrap_or(0) / 1000,
            onchain: matches!(p.kind, PaymentKind::Onchain { .. }),
            pending: p.status == PaymentStatus::Pending,
            failed: p.status == PaymentStatus::Failed,
            timestamp: p.latest_update_timestamp,
        })
        .collect();
    activity.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
    activity.truncate(50);
    let peers = node.list_peers();
    Snapshot {
        onchain_sats: balances.total_onchain_balance_sats,
        lightning_sats: balances.total_lightning_balance_sats,
        channels,
        activity,
        peers_connected: peers.iter().filter(|p| p.is_connected).count(),
        peers_known: peers.len(),
    }
}

/// Reconnects to every channel peer that is not connected right now, so a
/// payment does not fail with "no route" just because the link dropped.
pub fn reconnect_peers(node: &Node) {
    let peers = node.list_peers();
    for peer in peers.iter().filter(|p| !p.is_connected) {
        let _ = node.connect(peer.node_id, peer.address.clone(), peer.is_persisted);
    }
    // The LSP holds our channel; make sure it is tried even if it was never
    // saved as a peer.
    let (lsp_id, lsp_address) = lsp();
    let has_lsp_channel = node.list_channels().iter().any(|c| c.counterparty_node_id == lsp_id);
    if has_lsp_channel && !peers.iter().any(|p| p.node_id == lsp_id) {
        let _ = node.connect(lsp_id, lsp_address, true);
    }
}

/// After a reconnect the two nodes still exchange a short handshake before
/// the channel can carry payments. Waits for that, up to `timeout`.
fn wait_for_usable_channel(node: &Node, timeout: Duration) {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if node.list_channels().iter().any(|c| c.is_usable) {
            return;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
}

/// Reads an invoice so the screen can show what it asks for before paying.
pub fn describe_invoice(text: &str) -> Result<PayRequest, String> {
    let mut cleaned = text.trim();
    for prefix in ["lightning://", "lightning:", "LIGHTNING:"] {
        if let Some(rest) = cleaned.strip_prefix(prefix) {
            cleaned = rest;
        }
    }
    let invoice = Bolt11Invoice::from_str(cleaned).map_err(|_| "That is not a Lightning invoice.".to_string())?;
    if invoice.is_expired() {
        return Err("That invoice has expired. Ask for a new one.".into());
    }
    let amount_sats = invoice
        .amount_milli_satoshis()
        .ok_or("That invoice has no amount. BitKiss needs an invoice with an amount for now.")?
        / 1000;
    let memo = match invoice.description() {
        ldk_node::lightning_invoice::Bolt11InvoiceDescriptionRef::Direct(d) => d.to_string(),
        ldk_node::lightning_invoice::Bolt11InvoiceDescriptionRef::Hash(_) => String::new(),
    };
    Ok(PayRequest { invoice, amount_sats, memo })
}

/// Starts paying an invoice. The real result arrives later as a node event
/// carrying the returned payment id.
pub fn pay(node: &Node, invoice: &Bolt11Invoice) -> Result<PaymentId, String> {
    // A payment can only leave through a channel whose peer is connected.
    let channels = node.list_channels();
    if !channels.is_empty() && !channels.iter().any(|c| c.is_usable) {
        reconnect_peers(node);
        wait_for_usable_channel(node, Duration::from_secs(10));
    }
    node.bolt11_payment().send(invoice, None).map_err(|e| match format!("{e:?}").as_str() {
        "DuplicatePayment" => "That invoice was already paid or is being paid.".to_string(),
        "PaymentSendingFailed" => "No route to the receiver right now. Check the connection and try again.".to_string(),
        other => other.to_string(),
    })
}

/// Makes a Lightning invoice. When the channels cannot hold the amount, the
/// invoice goes through the LSP, which opens a channel out of the payment
/// itself and keeps its fee from it.
pub fn make_invoice(node: &Node, amount_sats: u64, via_lsp: bool) -> Result<String, String> {
    let description =
        Bolt11InvoiceDescription::Direct(Description::new("A BitKiss".to_string()).map_err(|e| e.to_string())?);
    let payments = node.bolt11_payment();
    let invoice = if via_lsp {
        payments.receive_via_jit_channel(amount_sats * 1000, &description, 3600, None)
    } else {
        payments.receive(amount_sats * 1000, &description, 3600)
    };
    invoice.map(|i| i.to_string()).map_err(plain)
}

pub fn new_address(node: &Node) -> Result<String, String> {
    node.onchain_payment().new_address().map(|a| a.to_string()).map_err(plain)
}

/// The last lines of the node's own log, for seeing what it is doing when
/// something stalls.
pub fn recent_log(dir: &Path, lines: usize) -> Vec<String> {
    let path = dir.join("ldk-node/bitcoin/ldk_node.log");
    let Ok(mut file) = fs::File::open(path) else { return Vec::new() };
    let len = file.metadata().map(|m| m.len()).unwrap_or(0);
    let tail = 256 * 1024;
    let _ = file.seek(SeekFrom::Start(len.saturating_sub(tail)));
    let mut bytes = Vec::new();
    let _ = file.read_to_end(&mut bytes);
    let text = String::from_utf8_lossy(&bytes);
    // Drop the chatty sync lines so channel and peer messages stay visible.
    let noise = ["Finished transaction sync", "Processing RGS update"];
    let kept: Vec<&str> = text.lines().filter(|l| !l.is_empty() && !noise.iter().any(|n| l.contains(n))).collect();
    kept[kept.len().saturating_sub(lines)..].iter().map(|l| l.to_string()).collect()
}

pub fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_are_created_once_and_kept_private() {
        let dir = std::env::temp_dir().join(format!("bitkiss-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let (first, created) = load_or_create_words(&dir).unwrap();
        assert!(created);
        assert_eq!(first.split_whitespace().count(), 12);
        let (second, created) = load_or_create_words(&dir).unwrap();
        assert!(!created);
        assert_eq!(first, second);
        let mode = fs::metadata(dir.join("seed.words")).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn invoices_are_read_or_refused_in_plain_words() {
        use ldk_node::bitcoin::hashes::{Hash, sha256};
        use ldk_node::bitcoin::secp256k1::{Secp256k1, SecretKey};
        use ldk_node::lightning::types::payment::PaymentSecret;
        use ldk_node::lightning_invoice::{Currency, InvoiceBuilder};

        assert!(describe_invoice("hello").is_err());

        // An invoice signed by a made-up key, so no real wallet is involved.
        let key = SecretKey::from_slice(&[42u8; 32]).unwrap();
        let invoice = InvoiceBuilder::new(Currency::Bitcoin)
            .description("A BitKiss".into())
            .amount_milli_satoshis(1_000_000)
            .payment_hash(sha256::Hash::hash(&[0u8; 32]))
            .payment_secret(PaymentSecret([1u8; 32]))
            .current_timestamp()
            .min_final_cltv_expiry_delta(144)
            .build_signed(|hash| Secp256k1::new().sign_ecdsa_recoverable(hash, &key))
            .unwrap();
        let request = describe_invoice(&format!("lightning:{invoice}")).unwrap();
        assert_eq!(request.amount_sats, 1000);
        assert_eq!(request.memo, "A BitKiss");
    }
}
