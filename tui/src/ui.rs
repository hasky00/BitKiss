//! Everything that is drawn. No node calls here: the screens only read `App`.

use qrcode::QrCode;
use qrcode::render::unicode::Dense1x2;
use ratatui::Frame;
use ratatui::layout::{Alignment, Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Paragraph, Wrap};

use crate::wallet::{self, ActivityRow};
use crate::{App, Screen, SendStage};

const PINK: Color = Color::Rgb(236, 96, 140);
const ORANGE: Color = Color::Rgb(240, 160, 64);
const GREEN: Color = Color::Rgb(120, 210, 130);
const DIM: Color = Color::DarkGray;

/// 21886 -> "21,886"
pub fn sats(value: u64) -> String {
    let digits = value.to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    out
}

/// "38 secs", "1 min, 11 secs", "2 days, 11 hrs"
fn ago(timestamp: u64, now: u64) -> String {
    let secs = now.saturating_sub(timestamp);
    let unit = |n: u64, name: &str| format!("{n} {name}{}", if n == 1 { "" } else { "s" });
    match secs {
        0..60 => unit(secs, "sec"),
        60..3600 => format!("{}, {}", unit(secs / 60, "min"), unit(secs % 60, "sec")),
        3600..86400 => format!("{}, {}", unit(secs / 3600, "hr"), unit(secs % 3600 / 60, "min")),
        _ => format!("{}, {}", unit(secs / 86400, "day"), unit(secs % 86400 / 3600, "hr")),
    }
}

fn card(title: &str) -> Block<'_> {
    Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(DIM))
        .title(Span::styled(format!(" {title} "), Style::default().fg(DIM)))
}

fn keys(pairs: &[(&str, &str)]) -> Line<'static> {
    let mut spans = Vec::new();
    for (key, label) in pairs {
        spans.push(Span::styled(format!(" {key} "), Style::default().fg(ORANGE).add_modifier(Modifier::BOLD)));
        spans.push(Span::styled(format!("{label}  "), Style::default().fg(DIM)));
    }
    Line::from(spans)
}

pub fn draw(frame: &mut Frame, app: &App) {
    let area = frame.area();
    // Keep the wallet a comfortable column instead of stretching across a wide terminal.
    let width = area.width.min(96);
    let area = Rect { x: area.x + (area.width - width) / 2, width, ..area };
    let [header, body, message, footer] =
        Layout::vertical([Constraint::Length(2), Constraint::Min(0), Constraint::Length(2), Constraint::Length(1)])
            .areas(area);

    let title = Line::from(vec![
        Span::styled("ϟ ", Style::default().fg(ORANGE).add_modifier(Modifier::BOLD)),
        Span::styled("BitKiss", Style::default().fg(PINK).add_modifier(Modifier::BOLD)),
    ]);
    frame.render_widget(Paragraph::new(title), header);
    let status_color = if app.start_failed { ORANGE } else { DIM };
    frame.render_widget(
        Paragraph::new(Span::styled(app.status.clone(), Style::default().fg(status_color))).alignment(Alignment::Right),
        header,
    );
    frame.render_widget(
        Paragraph::new(Span::styled(app.message.clone(), Style::default().fg(ORANGE))).wrap(Wrap { trim: true }),
        message,
    );

    let footer_keys = match app.screen {
        Screen::Welcome => draw_welcome(frame, body, app),
        Screen::Home => draw_home(frame, body, app),
        Screen::Receive => draw_receive(frame, body, app),
        Screen::Send => draw_send(frame, body, app),
        Screen::Address => draw_address(frame, body, app),
        Screen::Advanced => draw_advanced(frame, body, app),
    };
    frame.render_widget(Paragraph::new(footer_keys), footer);
}

fn draw_welcome(frame: &mut Frame, area: Rect, app: &App) -> Line<'static> {
    let mut lines = vec![
        Line::from(""),
        Line::from("BitKiss is a Lightning wallet that only you hold the keys to."),
        Line::from(""),
        Line::from("These 12 words are the only way to get your sats back if this"),
        Line::from("computer is lost. Write them down on paper and keep them private."),
        Line::from(""),
    ];
    let words: Vec<&str> = app.words.split_whitespace().collect();
    for (row, chunk) in words.chunks(3).enumerate() {
        let text = chunk.iter().enumerate().map(|(i, w)| format!("{:>2}. {:<12}", row * 3 + i + 1, w)).collect::<String>();
        lines.push(Line::from(Span::styled(text, Style::default().fg(PINK).add_modifier(Modifier::BOLD))));
    }
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        "Never type these words into another wallet while this one is in use.",
        Style::default().fg(ORANGE),
    )));
    frame.render_widget(Paragraph::new(lines).block(card("Welcome")).wrap(Wrap { trim: false }), area);
    keys(&[("Enter", "I wrote them down")])
}

fn draw_home(frame: &mut Frame, area: Rect, app: &App) -> Line<'static> {
    let [balance, activity] = Layout::vertical([Constraint::Length(7), Constraint::Min(0)]).areas(area);

    let total = app.snap.onchain_sats + app.snap.lightning_sats;
    let show = |value: u64| if app.hide_balance { "•••••".to_string() } else { sats(value) };
    let fiat = match (app.eur_per_btc, app.hide_balance) {
        (Some(price), false) => format!("€{:.2}", total as f64 / 100_000_000.0 * price),
        _ => String::new(),
    };
    let lines = vec![
        Line::from(""),
        Line::from(vec![
            Span::styled(show(total), Style::default().add_modifier(Modifier::BOLD)),
            Span::styled(" sats", Style::default().fg(DIM)),
        ]),
        Line::from(Span::styled(fiat, Style::default().fg(DIM))),
        Line::from(""),
        Line::from(Span::styled(
            format!("ϟ {} Lightning     ⛓ {} on-chain", show(app.snap.lightning_sats), show(app.snap.onchain_sats)),
            Style::default().fg(DIM),
        )),
    ];
    frame.render_widget(Paragraph::new(lines).alignment(Alignment::Center).block(card("Balance")), balance);

    let now = wallet::now();
    let inner_width = activity.width.saturating_sub(4) as usize;
    let rows: Vec<Line> = if app.snap.activity.is_empty() {
        let text = if app.node.is_none() { "" } else { "Nothing yet. Press r to receive your first sats." };
        vec![Line::from(Span::styled(text, Style::default().fg(DIM)))]
    } else {
        app.snap.activity.iter().map(|row| activity_line(row, now, inner_width, app.hide_balance)).collect()
    };
    frame.render_widget(Paragraph::new(rows).block(card("Recent activity")), activity);

    if app.start_failed {
        return keys(&[("t", "Try again"), ("q", "Quit")]);
    }
    keys(&[("r", "Receive"), ("s", "Send"), ("a", "Address"), ("u", "Refresh"), ("h", "Hide"), ("v", "Advanced"), ("q", "Quit")])
}

fn activity_line(row: &ActivityRow, now: u64, width: usize, hide: bool) -> Line<'static> {
    let rail = if row.onchain { "on-chain" } else { "Lightning" };
    let label = if row.failed {
        "Failed".to_string()
    } else {
        let verb = if row.incoming { "Received" } else { "Sent" };
        format!("{verb} {rail}{}", if row.pending { " (pending)" } else { "" })
    };
    let arrow = if row.incoming { "↙" } else { "↗" };
    let amount = if hide { "•••".to_string() } else { format!("{}{}", if row.incoming { "+" } else { "-" }, sats(row.sats)) };
    let when = ago(row.timestamp, now);
    let left = format!(" {arrow} {label:<28}{when}");
    let gap = width.saturating_sub(left.chars().count() + amount.chars().count()).max(1);
    let amount_color = if row.failed {
        DIM
    } else if row.incoming {
        GREEN
    } else {
        Color::Reset
    };
    Line::from(vec![
        Span::styled(format!(" {arrow} "), Style::default().fg(if row.incoming { GREEN } else { ORANGE })),
        Span::raw(format!("{label:<28}")),
        Span::styled(when, Style::default().fg(DIM)),
        Span::raw(" ".repeat(gap)),
        Span::styled(amount, Style::default().fg(amount_color).add_modifier(Modifier::BOLD)),
    ])
}

/// A QR code drawn with half-block characters, or a hint when the window is too small for it.
fn qr_lines(data: &str, area: Rect) -> Vec<Line<'static>> {
    let Ok(code) = QrCode::new(data.as_bytes()) else { return Vec::new() };
    // Light modules are drawn as blocks, dark ones left empty: on the
    // white-on-black style below that gives a normal (not inverted) code.
    let image =
        code.render::<Dense1x2>().dark_color(Dense1x2::Light).light_color(Dense1x2::Dark).quiet_zone(true).build();
    let rows: Vec<&str> = image.lines().collect();
    let too_tall = rows.len() + 6 > area.height as usize;
    let too_wide = rows.first().map(|r| r.chars().count()).unwrap_or(0) + 4 > area.width as usize;
    if too_tall || too_wide {
        return vec![Line::from(Span::styled(
            "(Make the window bigger to see the QR code, or press c to copy.)",
            Style::default().fg(DIM),
        ))];
    }
    // Force white on black so the code scans whatever the terminal theme is.
    let style = Style::default().fg(Color::White).bg(Color::Black);
    rows.iter().map(|row| Line::from(Span::styled(row.to_string(), style))).collect()
}

fn shorten(text: &str, head: usize, tail: usize) -> String {
    if text.len() <= head + tail + 1 { text.to_string() } else { format!("{}…{}", &text[..head], &text[text.len() - tail..]) }
}

fn draw_receive(frame: &mut Frame, area: Rect, app: &App) -> Line<'static> {
    if let Some(invoice) = &app.invoice {
        // Uppercase invoices make a smaller QR code and wallets accept both.
        let mut lines = qr_lines(&invoice.to_uppercase(), area);
        lines.push(Line::from(""));
        lines.push(Line::from(format!("Lightning invoice for {} sats", sats(app.input.parse().unwrap_or(0)))));
        lines.push(Line::from(Span::styled(shorten(invoice, 14, 10), Style::default().fg(DIM))));
        lines.push(Line::from(Span::styled("Keep BitKiss open until the payment arrives.", Style::default().fg(DIM))));
        frame.render_widget(Paragraph::new(lines).alignment(Alignment::Center).block(card("Receive")), area);
        return keys(&[("c", "Copy invoice"), ("Esc", "Back")]);
    }
    let amount: u64 = app.input.parse().unwrap_or(0);
    let mut lines = vec![
        Line::from(""),
        Line::from("How many sats do you want to receive?"),
        Line::from(""),
        Line::from(vec![
            Span::styled(format!("  {}▏", app.input), Style::default().fg(PINK).add_modifier(Modifier::BOLD)),
            Span::styled(" sats", Style::default().fg(DIM)),
        ]),
        Line::from(""),
    ];
    if amount > app.snap.can_receive_sats() {
        let first = app.snap.channels.is_empty();
        lines.push(Line::from(Span::styled(
            if first {
                "You have no Lightning channel yet. This payment will open one"
            } else {
                "This is more than your channel can take in. This payment will grow it"
            },
            Style::default().fg(ORANGE),
        )));
        lines.push(Line::from(Span::styled(
            "through Megalith, which keeps a fee from it (about 2,500 sats or 1.4%).",
            Style::default().fg(ORANGE),
        )));
        if amount < wallet::MIN_FIRST_PAYMENT_SATS {
            lines.push(Line::from(Span::styled(
                format!("Ask for at least {} sats so something is left after the fee.", sats(wallet::MIN_FIRST_PAYMENT_SATS)),
                Style::default().fg(ORANGE),
            )));
        }
    }
    frame.render_widget(Paragraph::new(lines).block(card("Receive")).wrap(Wrap { trim: false }), area);
    keys(&[("Enter", "Make invoice"), ("Esc", "Back")])
}

fn draw_send(frame: &mut Frame, area: Rect, app: &App) -> Line<'static> {
    let (lines, footer) = match &app.send {
        SendStage::Entering => (
            vec![
                Line::from(""),
                Line::from("Paste a Lightning invoice (lnbc...)."),
                Line::from(Span::styled("Paste with Ctrl+Shift+V.", Style::default().fg(DIM))),
                Line::from(""),
                Line::from(Span::styled(
                    format!("  {}▏", shorten(&app.input, 30, 20)),
                    Style::default().fg(PINK).add_modifier(Modifier::BOLD),
                )),
            ],
            keys(&[("Enter", "Continue"), ("Esc", "Back")]),
        ),
        SendStage::Confirm(request) => {
            let mut lines = vec![
                Line::from(""),
                Line::from(vec![
                    Span::raw("Pay "),
                    Span::styled(sats(request.amount_sats), Style::default().fg(PINK).add_modifier(Modifier::BOLD)),
                    Span::raw(" sats?"),
                ]),
            ];
            if !request.memo.is_empty() {
                lines.push(Line::from(Span::styled(format!("For: {}", request.memo), Style::default().fg(DIM))));
            }
            let can_send: u64 = app.snap.channels.iter().filter(|c| c.ready).map(|c| c.can_send_sats).sum();
            if request.amount_sats > can_send {
                lines.push(Line::from(""));
                lines.push(Line::from(Span::styled(
                    format!("You can send {} sats on Lightning right now. This will likely fail.", sats(can_send)),
                    Style::default().fg(ORANGE),
                )));
            }
            (lines, keys(&[("Enter", "Pay"), ("Esc", "Cancel")]))
        },
        SendStage::Paying { sats: amount } => (
            vec![
                Line::from(""),
                Line::from(format!("Paying {} sats...", sats(*amount))),
                Line::from(Span::styled("Connecting and finding a route. This can take a moment.", Style::default().fg(DIM))),
            ],
            Line::from(""),
        ),
        SendStage::Done { ok, text } => (
            vec![
                Line::from(""),
                Line::from(Span::styled(
                    text.clone(),
                    Style::default().fg(if *ok { GREEN } else { ORANGE }).add_modifier(Modifier::BOLD),
                )),
            ],
            keys(&[("Enter", "Done")]),
        ),
    };
    frame.render_widget(Paragraph::new(lines).block(card("Send")).wrap(Wrap { trim: false }), area);
    footer
}

fn draw_address(frame: &mut Frame, area: Rect, app: &App) -> Line<'static> {
    let address = app.address.clone().unwrap_or_default();
    let mut lines = qr_lines(&format!("bitcoin:{address}"), area);
    lines.push(Line::from(""));
    lines.push(Line::from("On-chain bitcoin address"));
    lines.push(Line::from(Span::styled(address, Style::default().fg(PINK))));
    frame.render_widget(Paragraph::new(lines).alignment(Alignment::Center).block(card("Address")), area);
    keys(&[("c", "Copy address"), ("Esc", "Back")])
}

fn draw_advanced(frame: &mut Frame, area: Rect, app: &App) -> Line<'static> {
    let mut lines = vec![
        Line::from(Span::styled("The node under the hood. You never need this to send or receive.", Style::default().fg(DIM))),
        Line::from(""),
        Line::from(format!("Node ID   {}", app.node_id)),
        Line::from(format!("Peers     {} of {} connected", app.snap.peers_connected, app.snap.peers_known)),
        Line::from(format!("Data      {}", app.dir.display())),
        Line::from(""),
    ];
    if app.snap.channels.is_empty() {
        lines.push(Line::from(Span::styled("No channels yet", Style::default().fg(DIM))));
    }
    for channel in &app.snap.channels {
        lines.push(Line::from(format!("{} sats with {}", sats(channel.capacity_sats), channel.peer)));
        let (text, color) = if !channel.ready {
            ("Waiting for the channel to confirm".to_string(), ORANGE)
        } else if !channel.usable {
            ("Open, but the peer is not connected right now".to_string(), ORANGE)
        } else {
            (format!("Connected. Send {}, receive {}", sats(channel.can_send_sats), sats(channel.can_receive_sats)), GREEN)
        };
        lines.push(Line::from(Span::styled(format!("  {text}"), Style::default().fg(color))));
    }
    lines.push(Line::from(""));
    if app.show_words {
        lines.push(Line::from(Span::styled(app.words.clone(), Style::default().fg(PINK))));
        lines.push(Line::from(""));
    }
    let used = lines.len() + 3;
    let room = (area.height as usize).saturating_sub(used);
    lines.push(Line::from(Span::styled("Node log", Style::default().fg(DIM))));
    let start = app.log.len().saturating_sub(room);
    let width = area.width.saturating_sub(4) as usize;
    for entry in &app.log[start..] {
        let color = if entry.contains(" ERROR ") { ORANGE } else { DIM };
        lines.push(Line::from(Span::styled(entry.chars().take(width).collect::<String>(), Style::default().fg(color))));
    }
    frame.render_widget(Paragraph::new(lines).block(card("Advanced")), area);
    keys(&[("c", "Copy node ID"), ("w", if app.show_words { "Hide words" } else { "Show words" }), ("l", "Reload log"), ("Esc", "Back")])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wallet::{ChannelRow, Snapshot};
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    fn demo_app() -> App {
        let (tx, _rx) = std::sync::mpsc::channel();
        let now = wallet::now();
        let row = |incoming, sats, age, failed| ActivityRow { incoming, sats, onchain: false, pending: false, failed, timestamp: now - age };
        App {
            dir: "/home/demo/.local/share/bitkiss".into(),
            words: "abandon ability able about above absent absorb abstract absurd abuse access accident".into(),
            node: None,
            node_id: "02aa".repeat(16) + "aa",
            status: "Running on mainnet".into(),
            start_failed: false,
            snap: Snapshot {
                onchain_sats: 12_703,
                lightning_sats: 9_183,
                channels: vec![ChannelRow {
                    peer: "034066e29e40...".into(),
                    capacity_sats: 110_000,
                    can_send_sats: 6_954,
                    can_receive_sats: 100_740,
                    ready: true,
                    usable: true,
                }],
                activity: vec![row(true, 1000, 38, false), row(false, 100, 71, false), row(false, 21, 6 * 86400 + 3 * 3600, true)],
                peers_connected: 1,
                peers_known: 1,
            },
            eur_per_btc: Some(67_000.0),
            message: "Payment received: 1,000 sats.".into(),
            hide_balance: false,
            busy: false,
            screen: Screen::Home,
            input: String::new(),
            invoice: None,
            send: SendStage::Entering,
            address: None,
            log: vec!["2026-11-09 22:25:05.909 DEBUG [lightning::ln::channel:10097] Reconnected channel with no loss".into()],
            show_words: false,
            paying: None,
            outcomes: Default::default(),
            tx,
            quit: false,
        }
    }

    fn render(app: &App, width: u16, height: u16) -> String {
        let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
        terminal.draw(|frame| draw(frame, app)).unwrap();
        let buffer = terminal.backend().buffer().clone();
        (0..height)
            .map(|y| (0..width).map(|x| buffer[(x, y)].symbol().to_string()).collect::<String>().trim_end().to_string())
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn every_screen_draws() {
        let mut app = demo_app();
        let home = render(&app, 80, 22);
        println!("{home}\n");
        assert!(home.contains("21,886") && home.contains("Received Lightning") && home.contains("Failed"));

        app.hide_balance = true;
        assert!(!render(&app, 80, 22).contains("21,886"));
        app.hide_balance = false;

        app.screen = Screen::Welcome;
        assert!(render(&app, 80, 22).contains("12. accident"));

        app.screen = Screen::Receive;
        app.input = "500000".into();
        let receive = render(&app, 80, 22);
        println!("{receive}\n");
        assert!(receive.contains("Megalith"));
        app.input = "1000".into();
        app.invoice = Some(format!("lnbc10u1p{}", "qpzry9x8gf2tvdw0s3jn54khce6mua7l".repeat(10)));
        assert!(render(&app, 80, 22).contains("Make the window bigger"));
        let big = render(&app, 100, 60);
        println!("{big}\n");
        assert!(big.contains("█") && big.contains("Lightning invoice for 1,000 sats"));

        app.screen = Screen::Send;
        app.send = SendStage::Paying { sats: 100 };
        assert!(render(&app, 80, 22).contains("Paying 100 sats"));
        app.send = SendStage::Done { ok: false, text: "Payment failed: no route to the receiver".into() };
        assert!(render(&app, 80, 22).contains("no route"));

        app.screen = Screen::Advanced;
        let advanced = render(&app, 80, 22);
        println!("{advanced}");
        assert!(advanced.contains("Connected. Send 6,954, receive 100,740"));
    }

    #[test]
    fn numbers_and_times_read_well() {
        assert_eq!(sats(0), "0");
        assert_eq!(sats(999), "999");
        assert_eq!(sats(21_886), "21,886");
        assert_eq!(sats(1_000_000), "1,000,000");
        assert_eq!(ago(100, 138), "38 secs");
        assert_eq!(ago(0, 71), "1 min, 11 secs");
        assert_eq!(ago(0, 2 * 86400 + 11 * 3600), "2 days, 11 hrs");
    }
}
