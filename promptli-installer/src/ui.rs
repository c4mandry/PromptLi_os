//! Interactive guided installer UI (ratatui + crossterm).
//!
//! Modeled on archinstall: a single scrolling menu of steps you jump between
//! before hitting "Install". Every step has a sane default, so a fresh disk
//! installs end-to-end with basically Enter, Enter, Enter. The installer works
//! fully OFFLINE — the only network step (website enrollment) is best-effort
//! and non-fatal.

use crate::common::Disk;
use crate::config::{summary_rows, Config};
use crate::disk::PartitionScheme;
use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use crossterm::terminal::{self, EnterAlternateScreen, LeaveAlternateScreen};
use crossterm::ExecutableCommand;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::Terminal;
use std::io;

const ACCENT: Color = Color::Rgb(0xd9, 0x48, 0x00);
const AMBER: Color = Color::Rgb(0xfb, 0xbf, 0x24);
const DANGER: Color = Color::Rgb(0xf7, 0x76, 0x8e);

type Term = Terminal<CrosstermBackend<io::Stdout>>;

/// Append a line to /tmp/promptli-install-debug.log when PROMPTLI_TUI_DEBUG
/// is set (used to diagnose terminal input problems; inert otherwise).
fn tui_debug(msg: &str) {
    use std::io::Write;
    if std::env::var_os("PROMPTLI_TUI_DEBUG").is_none() {
        return;
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open("/tmp/promptli-install-debug.log")
    {
        let _ = writeln!(f, "{} {msg}", std::process::id());
    }
}

/// The high-level screens. Each `Settings*` screen edits one field; `Menu` is
/// the archinstall-style launcher list.
#[derive(Clone, Copy, PartialEq)]
enum Screen {
    Menu,
    Disk,
    Layout,
    Swap,
    Drivers,
    Hostname,
    Username,
    Password,
    RootPassword,
    Keymap,
    Timezone,
    Review,
    Done,
}

#[derive(Clone, Copy, PartialEq)]
enum MenuAction {
    Open,
    Install,
}

#[derive(Clone, Copy)]
struct MenuItem {
    label: &'static str,
    desc: &'static str,
    target: Screen,
    action: MenuAction,
}

/// Order matters — this is the visible step list.
static MENU: &[MenuItem] = &[
    MenuItem { label: "Disk", desc: "Pick the disk to install to. Its full contents will be erased.", target: Screen::Disk, action: MenuAction::Open },
    MenuItem { label: "Partitioning", desc: "UEFI/GPT (modern machines) or BIOS/MBR (legacy).", target: Screen::Layout, action: MenuAction::Open },
    MenuItem { label: "Swap", desc: "Optional auto-sized swap partition, sized from the disk.", target: Screen::Swap, action: MenuAction::Open },
    MenuItem { label: "Drivers", desc: "Hardware driver groups: wifi, bluetooth, audio. Deselected groups are removed at install time (offline).", target: Screen::Drivers, action: MenuAction::Open },
    MenuItem { label: "Hostname", desc: "The machine's network name.", target: Screen::Hostname, action: MenuAction::Open },
    MenuItem { label: "Username", desc: "Primary user account (gets sudo).", target: Screen::Username, action: MenuAction::Open },
    MenuItem { label: "Password", desc: "Password for the primary user.", target: Screen::Password, action: MenuAction::Open },
    MenuItem { label: "Root password", desc: "Empty locks the root account — sudo only.", target: Screen::RootPassword, action: MenuAction::Open },
    MenuItem { label: "Keyboard", desc: "Console keymap (et, us, fi, de, …) — pick from the list or type your own.", target: Screen::Keymap, action: MenuAction::Open },
    MenuItem { label: "Timezone", desc: "System timezone — pick from common zones or type one.", target: Screen::Timezone, action: MenuAction::Open },
    MenuItem { label: "Review & install", desc: "Show the final configuration before anything is written.", target: Screen::Review, action: MenuAction::Open },
    MenuItem { label: "Install now", desc: "Start installing with the current settings. The target disk is erased!", target: Screen::Review, action: MenuAction::Install },
];

/// Common keymap presets (Console keymap names, e.g. /usr/share/keymaps).
const KEYMAP_PRESETS: &[&str] = &[
    "us", "et", "fi", "de", "gb", "se", "no", "dk", "fr", "es", "it", "pl", "ru", "lv", "lt",
];

/// Common timezone presets. "custom…" opens the free-text editor.
const TIMEZONE_PRESETS: &[&str] = &[
    "UTC",
    "Europe/Tallinn",
    "Europe/Helsinki",
    "Europe/Riga",
    "Europe/Vilnius",
    "Europe/Stockholm",
    "Europe/Oslo",
    "Europe/Copenhagen",
    "Europe/Berlin",
    "Europe/London",
    "Europe/Paris",
    "Europe/Warsaw",
    "Europe/Moscow",
    "Asia/Tokyo",
    "Asia/Singapore",
    "America/New_York",
    "America/Los_Angeles",
    "Australia/Sydney",
];

/// Where keyboard input is currently routed.
enum Input {
    None,
    Text(String),
}

enum Edit {
    Keep,
    Commit,
    Cancel,
}

pub fn run(disks: Vec<Disk>) -> io::Result<Option<Config>> {
    let mut terminal = init_terminal()?;
    let result = run_loop(&mut terminal, disks);
    cleanup_terminal(&mut terminal)?;
    result
}

fn init_terminal() -> io::Result<Term> {
    terminal::enable_raw_mode()?;
    // Enter the alternate screen buffer so the installer's UI is isolated
    // from whatever was on the terminal (fastfetch logo, MOTD, prompt).
    io::stdout().execute(EnterAlternateScreen)?;
    // Some terminals seed the alt buffer with a copy of the main screen;
    // ratatui only repaints regions it writes, so clear the whole screen
    // first or the leftover login banner bleeds through the TUI.
    io::stdout().execute(crossterm::terminal::Clear(crossterm::terminal::ClearType::All))?;
    io::stdout().execute(crossterm::cursor::MoveTo(0, 0))?;
    Terminal::new(CrosstermBackend::new(io::stdout()))
}

fn cleanup_terminal(_t: &mut Term) -> io::Result<()> {
    // Leave the alternate screen and disable raw mode in the right order so
    // the terminal is restored cleanly regardless of how the installer exits.
    let _ = io::stdout().execute(LeaveAlternateScreen);
    terminal::disable_raw_mode()?;
    Ok(())
}

fn run_loop(terminal: &mut Term, disks: Vec<Disk>) -> io::Result<Option<Config>> {
    let mut cfg = Config::default();
    let mut screen = Screen::Menu;
    let mut menu_state = ListState::default();
    menu_state.select(Some(0));
    let mut disk_sel = 0usize;
    let mut picker_sel = 0usize;
    let mut driver_sel = 0usize;
    let mut input = Input::None;
    let mut progress_lines: Vec<String> = Vec::new();
    let mut frames: u64 = 0;
    tui_debug("run_loop started");

    loop {
        terminal.draw(|f| match screen {
            Screen::Done => draw_done(f, &progress_lines),
            _ => draw_menu(f, screen, &menu_state, &cfg, &disks, &input, disk_sel, picker_sel, driver_sel),
        })?;
        frames += 1;

        let polled = event::poll(std::time::Duration::from_millis(60))?;
        if !polled {
            if frames % 64 == 0 {
                tui_debug(&format!("heartbeat frame={frames} poll=false"));
            }
            continue;
        }
        tui_debug("poll=true");
        let ev = event::read()?;
        tui_debug(&format!("read event={ev:?}"));
        let Event::Key(key) = ev else { continue };
        if key.kind != KeyEventKind::Press {
            continue;
        }

        // ── Text input routing (before generic navigation) ──
        let mut consumed = false;
        if let Input::Text(buf) = &mut input {
            let edit = edit_text(buf, key);
            match edit {
                Edit::Keep => consumed = true,
                Edit::Commit | Edit::Cancel => {
                    if let Edit::Commit = edit {
                        match screen {
                            Screen::Hostname => cfg.hostname = buf.trim().to_string(),
                            Screen::Username => cfg.username = buf.trim().to_string(),
                            Screen::Password => {
                                let v = buf.trim().to_string();
                                if !v.is_empty() {
                                    cfg.password = v;
                                }
                            }
                            Screen::RootPassword => cfg.root_password = buf.trim().to_string(),
                            Screen::Keymap => {
                                let v = buf.trim().to_ascii_lowercase();
                                if !v.is_empty() {
                                    cfg.keymap = v;
                                }
                            }
                            Screen::Timezone => {
                                let v = buf.trim().to_string();
                                if !v.is_empty() {
                                    cfg.timezone = v;
                                }
                            }
                            _ => {}
                        }
                    }
                    input = Input::None;
                    screen = Screen::Menu;
                    consumed = true;
                }
            }
        }
        if consumed {
            continue;
        }

        // ── Generic navigation ──
        match screen {
            Screen::Menu => match key.code {
                KeyCode::Char('q') => return Ok(None),
                KeyCode::Esc => continue,
                KeyCode::Up | KeyCode::Char('k') => menu_prev(&mut menu_state, MENU.len()),
                KeyCode::Down | KeyCode::Char('j') => menu_next(&mut menu_state, MENU.len()),
                KeyCode::Char(c) if c.is_ascii_digit() => {
                    // Number keys jump straight to a step (archinstall-style).
                    let idx = if c == '0' { 9 } else { (c as u8 - b'1') as usize };
                    if idx < MENU.len() {
                        menu_state.select(Some(idx));
                    }
                }
                KeyCode::Enter => {
                    let item = MENU[menu_state.selected().unwrap_or(0)];
                    if item.action == MenuAction::Install {
                        if cfg.disk.is_empty() {
                            screen = Screen::Disk; // no disk chosen yet — go pick one
                        } else {
                            start_install(terminal, &mut cfg, &mut progress_lines);
                            screen = Screen::Done;
                        }
                    } else {
                        screen = item.target;
                    }
                }
                _ => {}
            },
            Screen::Disk => match key.code {
                KeyCode::Char('q') => return Ok(None),
                KeyCode::Esc | KeyCode::Char('h') | KeyCode::Left => screen = Screen::Menu,
                KeyCode::Up | KeyCode::Char('k') => {
                    disk_sel = disk_sel.saturating_sub(1);
                }
                KeyCode::Down | KeyCode::Char('j') => {
                    if disk_sel + 1 < disks.len() {
                        disk_sel += 1;
                    }
                }
                KeyCode::Enter => {
                    if let Some(d) = disks.get(disk_sel) {
                        cfg.disk = d.name.clone();
                        screen = Screen::Menu;
                    }
                }
                _ => {}
            },
            Screen::Layout => match key.code {
                KeyCode::Char('q') => return Ok(None),
                KeyCode::Esc | KeyCode::Char('h') | KeyCode::Left => screen = Screen::Menu,
                KeyCode::Up | KeyCode::Down | KeyCode::Char('j') | KeyCode::Char('k') => {
                    cfg.layout = match cfg.layout {
                        PartitionScheme::Efi => PartitionScheme::Bios,
                        PartitionScheme::Bios => PartitionScheme::Efi,
                    };
                }
                KeyCode::Char('e') => cfg.layout = PartitionScheme::Efi,
                KeyCode::Char('b') => cfg.layout = PartitionScheme::Bios,
                KeyCode::Enter => screen = Screen::Menu,
                _ => {}
            },
            Screen::Swap => match key.code {
                KeyCode::Char('q') => return Ok(None),
                KeyCode::Esc | KeyCode::Char('h') | KeyCode::Left => screen = Screen::Menu,
                KeyCode::Up | KeyCode::Down | KeyCode::Char('j') | KeyCode::Char('k')
                | KeyCode::Char('y') | KeyCode::Char('n') => cfg.swap = !cfg.swap,
                KeyCode::Enter => screen = Screen::Menu,
                _ => {}
            },
            Screen::Drivers => {
                match key.code {
                    KeyCode::Char('q') => return Ok(None),
                    KeyCode::Esc | KeyCode::Char('h') | KeyCode::Left => screen = Screen::Menu,
                    KeyCode::Up | KeyCode::Char('k') => driver_sel = driver_sel.saturating_sub(1),
                    KeyCode::Down | KeyCode::Char('j') => {
                        if driver_sel + 1 < DRIVER_OPTIONS.len() {
                            driver_sel += 1;
                        }
                    }
                    KeyCode::Char('y') | KeyCode::Char('n') | KeyCode::Enter => {
                        let name = DRIVER_OPTIONS[driver_sel];
                        let has = cfg.drivers.iter().any(|d| d == name);
                        if has {
                            cfg.drivers.retain(|d| d != name);
                        } else {
                            cfg.drivers.push(name.to_string());
                        }
                    }
                    _ => {}
                }
            }
            Screen::Hostname
            | Screen::Username
            | Screen::Password
            | Screen::RootPassword => {
                // These screens activate text input on any printable key.
                if let KeyCode::Char(c) = key.code {
                    let initial = current_value(screen, &cfg);
                    let mut buf = initial;
                    buf.push(c);
                    input = Input::Text(buf);
                }
            }
            Screen::Keymap => {
                match key.code {
                    KeyCode::Char('q') => return Ok(None),
                    KeyCode::Esc | KeyCode::Char('h') | KeyCode::Left => screen = Screen::Menu,
                    KeyCode::Up | KeyCode::Char('k') => picker_sel = picker_sel.saturating_sub(1),
                    KeyCode::Down | KeyCode::Char('j') => {
                        if picker_sel + 1 <= KEYMAP_PRESETS.len() {
                            picker_sel += 1;
                        }
                    }
                    KeyCode::Enter => {
                        if picker_sel < KEYMAP_PRESETS.len() {
                            cfg.keymap = KEYMAP_PRESETS[picker_sel].to_string();
                            screen = Screen::Menu;
                        } else {
                            // "custom…" — open the free-text editor.
                            input = Input::Text(cfg.keymap.clone());
                        }
                    }
                    KeyCode::Char(c) => {
                        // Typing anything switches to the custom editor.
                        let mut buf = cfg.keymap.clone();
                        buf.push(c);
                        input = Input::Text(buf);
                    }
                    _ => {}
                }
            }
            Screen::Timezone => {
                match key.code {
                    KeyCode::Char('q') => return Ok(None),
                    KeyCode::Esc | KeyCode::Char('h') | KeyCode::Left => screen = Screen::Menu,
                    KeyCode::Up | KeyCode::Char('k') => picker_sel = picker_sel.saturating_sub(1),
                    KeyCode::Down | KeyCode::Char('j') => {
                        if picker_sel + 1 <= TIMEZONE_PRESETS.len() {
                            picker_sel += 1;
                        }
                    }
                    KeyCode::Enter => {
                        if picker_sel < TIMEZONE_PRESETS.len() {
                            cfg.timezone = TIMEZONE_PRESETS[picker_sel].to_string();
                            screen = Screen::Menu;
                        } else {
                            input = Input::Text(cfg.timezone.clone());
                        }
                    }
                    KeyCode::Char(c) => {
                        let mut buf = cfg.timezone.clone();
                        buf.push(c);
                        input = Input::Text(buf);
                    }
                    _ => {}
                }
            }
            Screen::Review => match key.code {
                KeyCode::Char('q') => return Ok(None),
                KeyCode::Char('n') | KeyCode::Esc | KeyCode::Char('h') | KeyCode::Left => {
                    screen = Screen::Menu;
                }
                KeyCode::Enter | KeyCode::Char('y') => {
                    start_install(terminal, &mut cfg, &mut progress_lines);
                    screen = Screen::Done;
                }
                _ => {}
            },
            Screen::Done => match key.code {
                KeyCode::Enter | KeyCode::Esc | KeyCode::Char('q') => return Ok(Some(cfg)),
                _ => {}
            },
        }
    }
}

fn current_value(screen: Screen, cfg: &Config) -> String {
    match screen {
        Screen::Hostname => cfg.hostname.clone(),
        Screen::Username => cfg.username.clone(),
        Screen::Password => cfg.password.clone(),
        Screen::RootPassword => cfg.root_password.clone(),
        Screen::Keymap => cfg.keymap.clone(),
        Screen::Timezone => cfg.timezone.clone(),
        _ => String::new(),
    }
}

/// Run the install with live progress rendering: draws the progress screen
/// immediately, then re-renders after every step callback.
fn start_install(terminal: &mut Term, cfg: &mut Config, lines: &mut Vec<String>) {
    let opts = crate::install::InstallOptions {
        disk: cfg.disk.clone(),
        layout: cfg.layout,
        swap: cfg.swap,
        hostname: cfg.hostname.clone(),
        username: cfg.username.clone(),
        password: cfg.password.clone(),
        root_password: cfg.root_password.clone(),
        keymap: cfg.keymap.clone(),
        timezone: cfg.timezone.clone(),
        site_url: cfg.site_url.clone(),
        version: crate::common::distro_version(),
        drivers: cfg.drivers.clone(),
    };
    let _ = terminal.draw(|f| draw_progress(f, lines));
    let result = crate::install::run_install(&opts, |step| {
        lines.push(step.to_string());
        let _ = terminal.draw(|f| draw_progress(f, lines));
    });
    match result {
        Ok(_) => lines.push("✅ Done. Remove the install medium and reboot.".to_string()),
        Err(e) => lines.push(format!("❌ ERROR: {e}")),
    }
    cfg.installed = true;
}

fn menu_next(s: &mut ListState, len: usize) {
    if len == 0 {
        return;
    }
    let i = s.selected().map(|i| (i + 1).min(len - 1)).unwrap_or(0);
    s.select(Some(i));
}

fn menu_prev(s: &mut ListState, len: usize) {
    if len == 0 {
        return;
    }
    let i = s.selected().map(|i| i.saturating_sub(1)).unwrap_or(0);
    s.select(Some(i));
}

// ── Drawing ──────────────────────────────────────────────────────────────

fn draw_menu(
    f: &mut ratatui::Frame,
    screen: Screen,
    menu_state: &ListState,
    cfg: &Config,
    disks: &[Disk],
    input: &Input,
    disk_sel: usize,
    picker_sel: usize,
    driver_sel: usize,
) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(0), Constraint::Length(3)])
        .split(f.area());

    let version = crate::common::distro_version();
    let title = Paragraph::new(Line::from(vec![
        Span::styled(
            format!("promptLi OS {version} — Installer"),
            Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
        ),
        Span::raw("   "),
        Span::styled("offline · guided · archinstall-style", Style::default().fg(Color::Gray)),
    ]));
    f.render_widget(title, chunks[0]);

    match screen {
        Screen::Menu => draw_menu_list(f, chunks[1], menu_state, cfg),
        Screen::Disk => draw_disk_select(f, chunks[1], disks, cfg, disk_sel),
        Screen::Layout => draw_layout(f, chunks[1], cfg),
        Screen::Swap => draw_swap(f, chunks[1], cfg),
        Screen::Drivers => draw_drivers(f, chunks[1], cfg, driver_sel),
        Screen::Hostname => draw_text_prompt(f, chunks[1], "Hostname", cfg, input),
        Screen::Username => draw_text_prompt(f, chunks[1], "Username", cfg, input),
        Screen::Password => draw_text_prompt(f, chunks[1], "Password", cfg, input),
        Screen::RootPassword => {
            draw_text_prompt(f, chunks[1], "Root password (empty = root login disabled)", cfg, input)
        }
        Screen::Keymap => {
            if matches!(input, Input::Text(_)) {
                draw_text_prompt(f, chunks[1], "Console keymap (et, us, fi, …)", cfg, input)
            } else {
                draw_picker(
                    f,
                    chunks[1],
                    " Console keymap ",
                    KEYMAP_PRESETS,
                    cfg.keymap.clone(),
                    picker_sel,
                )
            }
        }
        Screen::Timezone => {
            if matches!(input, Input::Text(_)) {
                draw_text_prompt(f, chunks[1], "Timezone (e.g. Europe/Tallinn)", cfg, input)
            } else {
                draw_picker(
                    f,
                    chunks[1],
                    " System timezone ",
                    TIMEZONE_PRESETS,
                    cfg.timezone.clone(),
                    picker_sel,
                )
            }
        }
        Screen::Review => draw_review(f, chunks[1], cfg),
        _ => {}
    }

    f.render_widget(Paragraph::new(footer_hint(screen)), chunks[2]);
}

fn footer_hint(screen: Screen) -> Line<'static> {
    match screen {
        Screen::Menu => Line::from(vec![
            key("↑/↓"), Span::raw(" navigate   "), key("Enter"), Span::raw(" open   "),
            key("q"), Span::raw(" quit"),
        ]),
        Screen::Disk => Line::from(vec![
            key("↑/↓"), Span::raw(" select   "), key("Enter"), Span::raw(" choose (disk gets ERASED)   "),
            key("h"), Span::raw(" back"),
        ]),
        Screen::Layout => Line::from(vec![
            key("↑/↓"), Span::raw(" toggle   "), key("e"), Span::raw(" EFI   "),
            key("b"), Span::raw(" BIOS   "), key("Enter"), Span::raw(" confirm"),
        ]),
        Screen::Swap => Line::from(vec![
            key("y/n"), Span::raw(" toggle   "), key("Enter"), Span::raw(" confirm"),
        ]),
        Screen::Drivers => Line::from(vec![
            key("↑/↓"), Span::raw(" select   "), key("y/n"), Span::raw(" toggle   "),
            key("Enter"), Span::raw(" confirm"),
        ]),
        Screen::Hostname | Screen::Username | Screen::Password | Screen::RootPassword => {
            Line::from(vec![
                Span::raw("start typing   "),
                key("Enter"),
                Span::raw(" confirm   "),
                key("Esc"),
                Span::raw(" cancel"),
            ])
        }
        Screen::Keymap | Screen::Timezone => Line::from(vec![
            key("↑/↓"), Span::raw(" select   "), key("Enter"), Span::raw(" choose   "),
            Span::raw("type = custom   "), key("h"), Span::raw(" back"),
        ]),
        Screen::Review => Line::from(vec![
            key("Enter"), Span::raw(" install   "), key("n"), Span::raw(" back"),
        ]),
        Screen::Done => Line::from(vec![
            key("Enter"), Span::raw(" exit"),
        ]),
    }
}

fn key(s: &'static str) -> Span<'static> {
    Span::styled(s, Style::default().fg(ACCENT))
}

fn list_block(title: &'static str) -> Block<'static> {
    Block::default()
        .title(title)
        .borders(Borders::ALL)
        .border_style(Style::default().fg(ACCENT))
}

fn draw_menu_list(f: &mut ratatui::Frame, area: Rect, state: &ListState, cfg: &Config) {
    let chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(area);

    // Left: the numbered step list (archinstall-style).
    let items: Vec<ListItem> = MENU
        .iter()
        .enumerate()
        .map(|(i, m)| {
            let num = if i == MENU.len() - 1 {
                "▶".to_string()
            } else {
                format!("{:>2}", i + 1)
            };
            let style = if m.action == MenuAction::Install {
                Style::default().fg(AMBER).add_modifier(Modifier::BOLD)
            } else {
                Style::default()
            };
            ListItem::new(Line::from(vec![Span::styled(
                format!(" {num}  {}", m.label),
                style,
            )]))
        })
        .collect();
    let list = List::new(items)
        .block(list_block(" Steps (type a number to jump) "))
        .highlight_style(Style::default().bg(ACCENT).fg(Color::Black))
        .highlight_symbol("▸ ");
    let mut st = state.clone();
    f.render_stateful_widget(list, chunks[0], &mut st);

    // Right: description of the highlighted step + live config summary.
    let right = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(4), Constraint::Min(0)])
        .split(chunks[1]);
    let sel = state.selected().unwrap_or(0).min(MENU.len() - 1);
    let desc = Paragraph::new(Line::from(vec![
        Span::styled(MENU[sel].label, Style::default().fg(AMBER).add_modifier(Modifier::BOLD)),
        Span::raw(" — "),
        Span::raw(MENU[sel].desc),
    ]))
    .block(list_block(" What is this? "))
    .wrap(Wrap { trim: true });
    f.render_widget(desc, right[0]);

    let rows = summary_rows(cfg);
    let text: Vec<Line> = rows
        .iter()
        .map(|(k, v)| {
            Line::from(vec![
                Span::styled(format!("{:<14}", k), Style::default().fg(AMBER).add_modifier(Modifier::BOLD)),
                Span::raw(v.as_str()),
            ])
        })
        .collect();
    let summary = Paragraph::new(text)
        .block(list_block(" Current configuration "))
        .wrap(Wrap { trim: true });
    f.render_widget(summary, right[1]);
}

/// A scrollable preset list with a "custom…" entry at the bottom.
fn draw_picker(
    f: &mut ratatui::Frame,
    area: Rect,
    title: &'static str,
    presets: &[&str],
    current: String,
    sel: usize,
) {
    let mut items: Vec<ListItem> = presets
        .iter()
        .map(|p| {
            let mark = if *p == current.as_str() { "  ●" } else { "" };
            ListItem::new(Line::from(Span::raw(format!("  {:<22} {}", p, mark))))
        })
        .collect();
    items.push(ListItem::new(Line::from(vec![
        Span::styled("  custom…", Style::default().fg(Color::Gray)),
        Span::raw("   (type your own value)"),
    ])));
    let list = List::new(items)
        .block(list_block(title))
        .highlight_style(Style::default().bg(ACCENT).fg(Color::Black))
        .highlight_symbol("▸ ");
    let mut state = ListState::default();
    state.select(Some(sel.min(presets.len())));
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(0), Constraint::Length(1)])
        .split(area);
    f.render_stateful_widget(list, chunks[0], &mut state);
    f.render_widget(
        Paragraph::new(Span::styled(
            " type any character to enter a custom value",
            Style::default().fg(Color::Gray),
        )),
        chunks[1],
    );
}

fn draw_disk_select(f: &mut ratatui::Frame, area: Rect, disks: &[Disk], cfg: &Config, sel: usize) {
    let items: Vec<ListItem> = disks
        .iter()
        .map(|d| {
            let chosen = if d.name == cfg.disk { "  ●" } else { "" };
            let mut label = format!("  {:<10} {:>8}  {}{}", d.name, d.size_human(), d.model, chosen);
            if d.removable {
                label.push_str("  (removable)");
            }
            ListItem::new(Line::from(Span::raw(label)))
        })
        .collect();

    let warning = if disks.is_empty() {
        "No usable disks found (need ≥1 GB, non-loop)."
    } else {
        "WARNING: the chosen disk is completely erased."
    };

    let list = List::new(items)
        .block(list_block(" Select target disk "))
        .highlight_style(Style::default().bg(ACCENT).fg(Color::Black))
        .highlight_symbol("▸ ");
    let mut state = ListState::default();
    state.select(Some(sel.min(disks.len().saturating_sub(1))));

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(3), Constraint::Length(2)])
        .split(area);
    f.render_stateful_widget(list, chunks[0], &mut state);
    f.render_widget(Paragraph::new(Span::styled(warning, Style::default().fg(DANGER))), chunks[1]);
}

fn draw_layout(f: &mut ratatui::Frame, area: Rect, cfg: &Config) {
    let (efi, bios) = match cfg.layout {
        PartitionScheme::Efi => ("●", " "),
        PartitionScheme::Bios => (" ", "●"),
    };
    let text = vec![
        Line::from(format!(" {efi} UEFI  (GPT — ESP + root)")),
        Line::from(format!(" {bios} BIOS  (MBR — single root)")),
        Line::from(""),
        Line::from("UEFI is the modern default; pick BIOS only for legacy machines."),
    ];
    f.render_widget(Paragraph::new(text).block(list_block(" Partitioning scheme ")), area);
}

fn draw_swap(f: &mut ratatui::Frame, area: Rect, cfg: &Config) {
    let mark = if cfg.swap { "●" } else { "○" };
    let text = vec![
        Line::from(format!(" {mark} Create a swap partition (auto-sized)")),
        Line::from(""),
        Line::from("Swap lets the kernel page to disk when RAM runs low."),
        Line::from("Recommended for small servers."),
    ];
    f.render_widget(Paragraph::new(text).block(list_block(" Swap ")), area);
}

/// Driver groups selectable at install time (all shipped in the base image;
/// deselected groups are purged offline in the chroot).
const DRIVER_OPTIONS: &[&str] = &["wifi", "bluetooth", "audio"];

fn draw_drivers(f: &mut ratatui::Frame, area: Rect, cfg: &Config, sel: usize) {
    let mut lines: Vec<Line> = Vec::new();
    for (i, name) in DRIVER_OPTIONS.iter().enumerate() {
        let has = cfg.drivers.iter().any(|d| d == name);
        let mark = if has { "●" } else { "○" };
        let cursor = if i == sel { "▶ " } else { "  " };
        let desc = match *name {
            "wifi" => "wpa_supplicant + iw + firmware (wireless networking)",
            "bluetooth" => "bluez (Bluetooth adapters)",
            "audio" => "pipewire + wireplumber + alsa-utils (sound)",
            _ => "",
        };
        lines.push(Line::from(format!("{cursor}{mark} {name:<10} {desc}")));
    }
    lines.push(Line::from(""));
    lines.push(Line::from("y/n or Enter toggles the selected group. Deselected groups"));
    lines.push(Line::from("are removed from the installed system (fully offline)."));
    f.render_widget(Paragraph::new(lines).block(list_block(" Drivers ")), area);
}

fn draw_text_prompt(f: &mut ratatui::Frame, area: Rect, label: &str, cfg: &Config, input: &Input) {
    let (buf, editing) = match input {
        Input::Text(b) => (b.clone(), true),
        Input::None => {
            let v = match label {
                "Hostname" => cfg.hostname.clone(),
                "Username" => cfg.username.clone(),
                "Password" => cfg.password.clone(),
                "Root password (empty = root login disabled)" => cfg.root_password.clone(),
                "Console keymap (et, us, fi, …)" => cfg.keymap.clone(),
                "Timezone (e.g. Europe/Tallinn)" => cfg.timezone.clone(),
                _ => String::new(),
            };
            (v, false)
        }
    };
    let masked = matches!(screen_label_mask(label), true) && !buf.is_empty();
    let shown = if masked { "*".repeat(buf.chars().count()) } else { buf };
    let mut text = vec![
        Line::from(Span::styled(format!(" {label}"), Style::default().fg(AMBER).add_modifier(Modifier::BOLD))),
        Line::from(""),
        Line::from(Span::styled(format!("  {shown}{}", if editing { "▌" } else { "" }), Style::default().fg(Color::White))),
        Line::from(""),
        Line::from(Span::styled("  Enter to confirm, Esc to cancel", Style::default().fg(Color::Gray))),
    ];
    if masked && !editing {
        text[2] = Line::from(Span::styled("  •••••••• (set)", Style::default().fg(Color::Green)));
    }
    f.render_widget(Paragraph::new(text).block(list_block(" Settings ")), area);
}

fn screen_label_mask(label: &str) -> bool {
    label.starts_with("Password") || label.starts_with("Root password")
}

fn draw_review(f: &mut ratatui::Frame, area: Rect, cfg: &Config) {
    let rows = summary_rows(cfg);
    let mut text: Vec<Line> = rows
        .iter()
        .map(|(k, v)| {
            Line::from(vec![
                Span::styled(format!(" {:<14}", k), Style::default().fg(AMBER).add_modifier(Modifier::BOLD)),
                Span::raw(v.as_str()),
            ])
        })
        .collect();
    text.push(Line::from(""));
    text.push(Line::from(Span::styled(
        " ⚠ ALL DATA ON THE TARGET DISK WILL BE DESTROYED.",
        Style::default().fg(DANGER).add_modifier(Modifier::BOLD),
    )));
    text.push(Line::from(""));
    text.push(Line::from(" Press Enter to install, or n to go back."));
    f.render_widget(
        Paragraph::new(text).block(list_block(" Review & confirm ")).wrap(Wrap { trim: true }),
        area,
    );
}

fn draw_progress(f: &mut ratatui::Frame, lines: &[String]) {
    let text: Vec<Line> = lines.iter().map(|l| Line::from(Span::raw(l.as_str()))).collect();
    let p = Paragraph::new(text).block(list_block(" Installing … ")).wrap(Wrap { trim: true });
    f.render_widget(p, f.area());
}

fn draw_done(f: &mut ratatui::Frame, lines: &[String]) {
    let failed = lines
        .last()
        .map(|l| l.starts_with("❌"))
        .unwrap_or(false);
    let header = if failed {
        Line::from(Span::styled(
            " ❌ Installation failed.",
            Style::default().fg(DANGER).add_modifier(Modifier::BOLD),
        ))
    } else {
        Line::from(Span::styled(
            " ✅ Installation complete.",
            Style::default().fg(Color::Green).add_modifier(Modifier::BOLD),
        ))
    };
    let mut text: Vec<Line> = vec![header, Line::from("")];
    text.extend(lines.iter().map(|l| Line::from(Span::raw(l.as_str()))));
    if !failed {
        text.push(Line::from(""));
        text.push(Line::from(" Remove the install medium and reboot."));
    }
    text.push(Line::from(""));
    text.push(Line::from(" Press Enter to exit."));
    f.render_widget(Paragraph::new(text).block(list_block(" Done ")), f.area());
}

/// Handle a single key while editing text. Esc cancels (discards) the edit.
fn edit_text(buf: &mut String, key: crossterm::event::KeyEvent) -> Edit {
    match key.code {
        KeyCode::Enter => Edit::Commit,
        KeyCode::Esc => Edit::Cancel,
        KeyCode::Backspace => {
            buf.pop();
            Edit::Keep
        }
        KeyCode::Char(c) => {
            buf.push(c);
            Edit::Keep
        }
        _ => Edit::Keep,
    }
}

/// Non-interactive step printer (used by the `--disk` unattended path).
pub fn print_step(s: &str) {
    eprintln!("\x1b[1;38;2;217;72;0m  ▸ {}\x1b[0m", s);
}
