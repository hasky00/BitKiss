//! BitKiss for the terminal: a self-custody Lightning wallet.
//!
//! One screen thread draws and reads keys. Anything that talks to the
//! network (starting the node, paying, syncing) runs on its own thread and
//! reports back through a channel, so the screen never freezes.

mod ui;
mod wallet;

use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::{Duration, Instant};

use ldk_node::lightning::events::PaymentFailureReason;
use ldk_node::lightning::ln::channelmanager::PaymentId;
use ldk_node::{Event, Node};
use ratatui::crossterm::event::{
    self, DisableBracketedPaste, EnableBracketedPaste, Event as TermEvent, KeyCode, KeyEvent, KeyEventKind,
    KeyModifiers,
};
use ratatui::crossterm::execute;

use wallet::{PayRequest, Snapshot};

/// Which screen is showing.
#[derive(PartialEq)]
pub enum Screen {
    Welcome,
    Home,
    Receive,
    Send,
    Address,
    Advanced,
}

/// Where a payment is on its way from pasted invoice to result.
pub enum SendStage {
    /// Waiting for an invoice to be pasted or typed.
    Entering,
    /// Invoice read; showing amount and memo, waiting for a yes.
    Confirm(PayRequest),
    /// On its way. Keys are ignored so it cannot be sent twice.
    Paying { sats: u64 },
    /// Finished, one way or the other.
    Done { ok: bool, text: String },
}

/// What background threads report back to the screen thread.
enum Msg {
    Started(Result<Arc<Node>, String>),
    Node(Event),
    PayStarted(Result<PaymentId, String>),
    Synced(Result<(), String>),
    InvoiceMade(Result<String, String>),
    Price(f64),
}

pub struct App {
    pub dir: PathBuf,
    pub words: String,
    pub node: Option<Arc<Node>>,
    pub node_id: String,
    pub status: String,
    pub start_failed: bool,
    pub snap: Snapshot,
    pub eur_per_btc: Option<f64>,
    pub message: String,
    pub hide_balance: bool,
    pub busy: bool,
    pub screen: Screen,
    /// Text being typed on the Receive (amount) or Send (invoice) screen.
    pub input: String,
    pub invoice: Option<String>,
    pub send: SendStage,
    pub address: Option<String>,
    pub log: Vec<String>,
    pub show_words: bool,
    /// The payment we are waiting on, once the node has accepted it.
    paying: Option<PaymentId>,
    /// Final results of payments, by id, as reported by node events.
    outcomes: HashMap<PaymentId, Result<(), String>>,
    tx: Sender<Msg>,
    quit: bool,
}

impl App {
    fn start_node(&mut self) {
        self.status = "Starting node...".into();
        self.start_failed = false;
        self.busy = true;
        let (dir, words, tx) = (self.dir.clone(), self.words.clone(), self.tx.clone());
        thread::spawn(move || {
            // The chain server sometimes answers slowly; one slow answer
            // should not leave the wallet empty.
            let mut result = Err(String::new());
            for attempt in 0..3 {
                if attempt > 0 {
                    thread::sleep(Duration::from_secs(3));
                }
                result = wallet::start(&dir, &words);
                if result.is_ok() {
                    break;
                }
            }
            let _ = tx.send(Msg::Started(result));
        });
    }

    fn fetch_price(&self) {
        let tx = self.tx.clone();
        thread::spawn(move || {
            let reply = ureq::get("https://mempool.space/api/v1/prices").timeout(Duration::from_secs(10)).call();
            if let Ok(json) = reply.and_then(|r| r.into_json::<serde_json::Value>().map_err(Into::into)) {
                if let Some(eur) = json.get("EUR").and_then(|v| v.as_f64()) {
                    let _ = tx.send(Msg::Price(eur));
                }
            }
        });
    }

    fn sync(&mut self) {
        let Some(node) = self.node.clone() else { return };
        self.busy = true;
        self.message = "Refreshing...".into();
        self.fetch_price();
        let tx = self.tx.clone();
        thread::spawn(move || {
            wallet::reconnect_peers(&node);
            let _ = tx.send(Msg::Synced(node.sync_wallets().map_err(wallet::plain)));
        });
    }

    fn refresh_snapshot(&mut self) {
        if let Some(node) = &self.node {
            self.snap = wallet::snapshot(node);
        }
    }

    fn on_msg(&mut self, msg: Msg) {
        match msg {
            Msg::Started(Ok(node)) => {
                self.busy = false;
                self.status = "Running on mainnet".into();
                self.node_id = node.node_id().to_string();
                // Hand every node event to the screen thread.
                let (events, tx) = (node.clone(), self.tx.clone());
                thread::spawn(move || {
                    loop {
                        let event = events.wait_next_event();
                        if tx.send(Msg::Node(event)).is_err() {
                            break;
                        }
                        let _ = events.event_handled();
                    }
                });
                self.node = Some(node);
                self.refresh_snapshot();
                self.fetch_price();
            },
            Msg::Started(Err(error)) => {
                self.busy = false;
                self.start_failed = true;
                self.status = format!("Could not start: {error}");
            },
            Msg::Node(event) => self.on_node_event(event),
            Msg::PayStarted(Ok(id)) => {
                self.paying = Some(id);
                self.settle_payment();
            },
            Msg::PayStarted(Err(error)) => {
                self.send = SendStage::Done { ok: false, text: error };
                self.refresh_snapshot();
            },
            Msg::Synced(result) => {
                self.busy = false;
                self.message = match result {
                    Ok(()) => String::new(),
                    Err(error) => format!("Sync problem: {error}"),
                };
                self.refresh_snapshot();
            },
            Msg::InvoiceMade(result) => {
                self.busy = false;
                // Only show it if the user is still waiting on the Receive screen.
                if self.screen == Screen::Receive {
                    match result {
                        Ok(invoice) => {
                            self.invoice = Some(invoice);
                            self.message.clear();
                        },
                        Err(error) => self.message = format!("Could not make invoice: {error}"),
                    }
                }
            },
            Msg::Price(eur) => self.eur_per_btc = Some(eur),
        }
    }

    fn on_node_event(&mut self, event: Event) {
        match event {
            Event::PaymentSuccessful { payment_id: Some(id), .. } => {
                self.outcomes.insert(id, Ok(()));
            },
            Event::PaymentFailed { payment_id: Some(id), reason, .. } => {
                self.outcomes.insert(id, Err(describe_failure(reason)));
            },
            Event::PaymentReceived { amount_msat, .. } => {
                self.message = format!("Payment received: {} sats.", ui::sats(amount_msat / 1000));
            },
            Event::ChannelReady { .. } => {
                self.message = "Channel is ready. You can send and receive on Lightning.".into();
            },
            Event::ChannelClosed { reason, .. } => {
                let why = reason.map(|r| r.to_string()).unwrap_or_else(|| "no reason given".into());
                self.message = format!("Channel closed: {why}");
            },
            _ => {},
        }
        self.settle_payment();
        self.refresh_snapshot();
    }

    /// If the payment we are waiting on has a result, show it.
    fn settle_payment(&mut self) {
        let Some(id) = self.paying else { return };
        let Some(outcome) = self.outcomes.remove(&id) else { return };
        self.paying = None;
        self.send = match outcome {
            Ok(()) => SendStage::Done { ok: true, text: "Payment sent.".into() },
            Err(reason) => SendStage::Done { ok: false, text: format!("Payment failed: {reason}") },
        };
        self.refresh_snapshot();
    }

    fn go_home(&mut self) {
        self.screen = Screen::Home;
        self.input.clear();
        self.invoice = None;
        self.address = None;
        self.show_words = false;
        self.send = SendStage::Entering;
    }

    fn on_paste(&mut self, text: String) {
        let editing = match self.screen {
            Screen::Send => matches!(self.send, SendStage::Entering),
            Screen::Receive => self.invoice.is_none(),
            _ => false,
        };
        if editing {
            self.input.extend(text.chars().filter(|c| !c.is_control()));
        }
    }

    fn on_key(&mut self, key: KeyEvent) {
        if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('c') {
            self.quit = true;
            return;
        }
        match self.screen {
            Screen::Welcome => {
                if key.code == KeyCode::Enter {
                    let _ = std::fs::write(self.dir.join("words_confirmed"), "yes");
                    self.go_home();
                }
            },
            Screen::Home => self.on_home_key(key.code),
            Screen::Receive => self.on_receive_key(key.code),
            Screen::Send => self.on_send_key(key.code),
            Screen::Address => match key.code {
                KeyCode::Esc => self.go_home(),
                KeyCode::Char('c') => self.copy(self.address.clone()),
                _ => {},
            },
            Screen::Advanced => match key.code {
                KeyCode::Esc => self.go_home(),
                KeyCode::Char('c') => self.copy(Some(self.node_id.clone())),
                KeyCode::Char('w') => self.show_words = !self.show_words,
                KeyCode::Char('l') => self.log = wallet::recent_log(&self.dir, 200),
                _ => {},
            },
        }
    }

    fn on_home_key(&mut self, code: KeyCode) {
        match code {
            KeyCode::Char('q') => self.quit = true,
            KeyCode::Char('h') => self.hide_balance = !self.hide_balance,
            KeyCode::Char('t') if self.start_failed => self.start_node(),
            _ if self.node.is_none() => {},
            KeyCode::Char('r') => self.screen = Screen::Receive,
            KeyCode::Char('s') => self.screen = Screen::Send,
            KeyCode::Char('u') if !self.busy => self.sync(),
            KeyCode::Char('a') => {
                if let Some(node) = &self.node {
                    match wallet::new_address(node) {
                        Ok(address) => {
                            self.address = Some(address);
                            self.screen = Screen::Address;
                        },
                        Err(error) => self.message = format!("Could not make an address: {error}"),
                    }
                }
            },
            KeyCode::Char('v') => {
                self.log = wallet::recent_log(&self.dir, 200);
                self.screen = Screen::Advanced;
            },
            _ => {},
        }
    }

    fn on_receive_key(&mut self, code: KeyCode) {
        if self.invoice.is_some() {
            match code {
                KeyCode::Esc => self.go_home(),
                KeyCode::Char('c') => self.copy(self.invoice.clone()),
                _ => {},
            }
            return;
        }
        match code {
            KeyCode::Esc => self.go_home(),
            KeyCode::Char(c) if c.is_ascii_digit() && self.input.len() < 9 => self.input.push(c),
            KeyCode::Backspace => {
                self.input.pop();
            },
            KeyCode::Enter => {
                let amount: u64 = self.input.parse().unwrap_or(0);
                let Some(node) = self.node.clone() else { return };
                if amount == 0 || self.busy {
                    return;
                }
                // Through the LSP this means a round trip to Megalith, so it
                // runs off the screen thread.
                let via_lsp = amount > self.snap.can_receive_sats();
                self.busy = true;
                self.message = "Making invoice...".into();
                let tx = self.tx.clone();
                thread::spawn(move || {
                    let _ = tx.send(Msg::InvoiceMade(wallet::make_invoice(&node, amount, via_lsp)));
                });
            },
            _ => {},
        }
    }

    fn on_send_key(&mut self, code: KeyCode) {
        match &self.send {
            SendStage::Entering => match code {
                KeyCode::Esc => self.go_home(),
                KeyCode::Char(c) => self.input.push(c),
                KeyCode::Backspace => {
                    self.input.pop();
                },
                KeyCode::Enter if !self.input.trim().is_empty() => match wallet::describe_invoice(&self.input) {
                    Ok(request) => {
                        self.message.clear();
                        self.send = SendStage::Confirm(request);
                    },
                    Err(error) => self.message = error,
                },
                _ => {},
            },
            SendStage::Confirm(request) => match code {
                KeyCode::Esc => self.go_home(),
                KeyCode::Enter => {
                    let Some(node) = self.node.clone() else { return };
                    let (invoice, sats) = (request.invoice.clone(), request.amount_sats);
                    // From here until the result, no key can start another payment.
                    self.send = SendStage::Paying { sats };
                    let tx = self.tx.clone();
                    thread::spawn(move || {
                        let _ = tx.send(Msg::PayStarted(wallet::pay(&node, &invoice)));
                    });
                },
                _ => {},
            },
            SendStage::Paying { .. } => {},
            SendStage::Done { .. } => {
                if matches!(code, KeyCode::Esc | KeyCode::Enter) {
                    self.go_home();
                }
            },
        }
    }

    fn copy(&mut self, text: Option<String>) {
        let Some(text) = text else { return };
        self.message = if copy_to_clipboard(&text) {
            "Copied.".into()
        } else {
            "Could not copy: install wl-clipboard (or xclip).".into()
        };
    }
}

/// Plain words for LDK's failure reasons.
fn describe_failure(reason: Option<PaymentFailureReason>) -> String {
    match reason {
        Some(PaymentFailureReason::RouteNotFound) => "no route to the receiver".into(),
        Some(PaymentFailureReason::RecipientRejected) => "the receiver rejected it".into(),
        Some(PaymentFailureReason::PaymentExpired) => "the invoice expired".into(),
        Some(PaymentFailureReason::RetriesExhausted) => "every route attempt failed".into(),
        Some(PaymentFailureReason::UserAbandoned) => "cancelled".into(),
        Some(other) => format!("{other:?}"),
        None => "unknown reason".into(),
    }
}

/// Puts text on the clipboard with whichever tool the desktop has
/// (Wayland first, since that is what Omarchy runs).
fn copy_to_clipboard(text: &str) -> bool {
    for (tool, args) in [("wl-copy", &[][..]), ("xclip", &["-selection", "clipboard"][..]), ("pbcopy", &[][..])] {
        let child =
            Command::new(tool).args(args).stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
        let Ok(mut child) = child else { continue };
        let written = child.stdin.take().map(|mut stdin| stdin.write_all(text.as_bytes()).is_ok()).unwrap_or(false);
        if written && child.wait().map(|s| s.success()).unwrap_or(false) {
            return true;
        }
    }
    false
}

fn run(app: &mut App, rx: Receiver<Msg>) -> std::io::Result<()> {
    let mut terminal = ratatui::init();
    execute!(std::io::stdout(), EnableBracketedPaste)?;
    let mut last_snapshot = Instant::now();
    let result = loop {
        if let Err(error) = terminal.draw(|frame| ui::draw(frame, app)) {
            break Err(error);
        }
        match event::poll(Duration::from_millis(200)) {
            Ok(true) => match event::read() {
                Ok(TermEvent::Key(key)) if key.kind == KeyEventKind::Press => app.on_key(key),
                Ok(TermEvent::Paste(text)) => app.on_paste(text),
                Ok(_) => {},
                Err(error) => break Err(error),
            },
            Ok(false) => {},
            Err(error) => break Err(error),
        }
        while let Ok(msg) = rx.try_recv() {
            app.on_msg(msg);
        }
        if last_snapshot.elapsed() > Duration::from_secs(2) {
            app.refresh_snapshot();
            last_snapshot = Instant::now();
        }
        if app.quit {
            break Ok(());
        }
    };
    let _ = execute!(std::io::stdout(), DisableBracketedPaste);
    ratatui::restore();
    result
}

fn main() {
    let dir = match wallet::data_dir() {
        Ok(dir) => dir,
        Err(error) => return eprintln!("BitKiss: {error}"),
    };
    // Two wallets on the same data would corrupt the channel state, so only
    // one BitKiss may run at a time.
    let lock = match std::fs::File::create(dir.join("lock")) {
        Ok(file) => file,
        Err(error) => return eprintln!("BitKiss: could not open {}: {error}", dir.display()),
    };
    if lock.try_lock().is_err() {
        return eprintln!("BitKiss is already running.");
    }
    let (words, created) = match wallet::load_or_create_words(&dir) {
        Ok(found) => found,
        Err(error) => return eprintln!("BitKiss: {error}"),
    };
    let confirmed = dir.join("words_confirmed").exists();

    let (tx, rx) = mpsc::channel();
    let mut app = App {
        dir,
        words,
        node: None,
        node_id: String::new(),
        status: "Not started".into(),
        start_failed: false,
        snap: Snapshot::default(),
        eur_per_btc: None,
        message: String::new(),
        hide_balance: false,
        busy: false,
        screen: if created || !confirmed { Screen::Welcome } else { Screen::Home },
        input: String::new(),
        invoice: None,
        send: SendStage::Entering,
        address: None,
        log: Vec::new(),
        show_words: false,
        paying: None,
        outcomes: HashMap::new(),
        tx,
        quit: false,
    };
    app.start_node();

    let result = run(&mut app, rx);
    if let Some(node) = &app.node {
        println!("Stopping the node...");
        let _ = node.stop();
    }
    if let Err(error) = result {
        eprintln!("BitKiss: {error}");
    }
    drop(lock);
}
