//! Interactive terminal UI (ratatui + crossterm) for the installer.

use crate::common::Disk;
use crate::disk::PartitionScheme;
use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use crossterm::terminal::{self, EnterAlternateScreen, LeaveAlternateScreen};
use crossterm::ExecutableCommand;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, List, ListItem, Paragraph};
use ratatui::Terminal;
use std::io;

const ACCENT: Color = Color::Rgb(0xd9, 0x48, 0x00);

pub struct UiConfig {
    pub disk: String,
    pub layout: PartitionScheme,
    pub hostname: String,
    pub username: String,
    pub password: String,
    pub site_url: String,
    pub confirmed: bool,
}

impl Default for UiConfig {
    fn default() -> Self {
        UiConfig {
            disk: String::new(),
            layout: PartitionScheme::Efi,
            hostname: "promptli".to_string(),
            username: "promptli".to_string(),
            password: "promptli".to_string(),
            site_url: crate::common::DEFAULT_SITE_URL.to_string(),
            confirmed: false,
        }
    }
}

enum Screen {
    DiskSelect,
    Confirm,
}

/// Run the interactive TUI and return the chosen config (or None if cancelled).
pub fn run(disks: Vec<Disk>) -> io::Result<Option<UiConfig>> {
    let mut terminal = init_terminal()?;
    let result = run_loop(&mut terminal, disks);
    cleanup_terminal(&mut terminal)?;
    result
}

fn init_terminal() -> io::Result<Terminal<CrosstermBackend<std::io::Stdout>>> {
    terminal::enable_raw_mode()?;
    std::io::stdout().execute(EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(std::io::stdout());
    Terminal::new(backend)
}

fn cleanup_terminal(_terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>) -> io::Result<()> {
    terminal::disable_raw_mode()?;
    std::io::stdout().execute(LeaveAlternateScreen)?;
    Ok(())
}

fn run_loop(
    terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
    disks: Vec<Disk>,
) -> io::Result<Option<UiConfig>> {
    let mut cfg = UiConfig::default();
    let mut selected = 0usize;
    let mut screen = Screen::DiskSelect;

    loop {
        terminal.draw(|f| match screen {
            Screen::DiskSelect => draw_disk_select(f, &disks, selected, &cfg),
            Screen::Confirm => draw_confirm(f, &cfg),
        })?;

        if event::poll(std::time::Duration::from_millis(100))? {
            if let Event::Key(key) = event::read()? {
                if key.kind != KeyEventKind::Press {
                    continue;
                }
                match screen {
                    Screen::DiskSelect => match key.code {
                        KeyCode::Up | KeyCode::Char('k') => {
                            if selected > 0 {
                                selected -= 1;
                            }
                        }
                        KeyCode::Down | KeyCode::Char('j') => {
                            if selected + 1 < disks.len() {
                                selected += 1;
                            }
                        }
                        KeyCode::Enter => {
                            if let Some(d) = disks.get(selected) {
                                cfg.disk = d.name.clone();
                                screen = Screen::Confirm;
                            }
                        }
                        KeyCode::Char('q') | KeyCode::Esc => return Ok(None),
                        _ => {}
                    },
                    Screen::Confirm => match key.code {
                        KeyCode::Char('y') | KeyCode::Enter => {
                            cfg.confirmed = true;
                            return Ok(Some(cfg));
                        }
                        KeyCode::Char('n') | KeyCode::Esc => screen = Screen::DiskSelect,
                        KeyCode::Char('q') => return Ok(None),
                        _ => {}
                    },
                }
            }
        }
    }
}

fn draw_disk_select(f: &mut ratatui::Frame, disks: &[Disk], selected: usize, cfg: &UiConfig) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(0), Constraint::Length(3)])
        .split(f.area());

    let title = Paragraph::new(Line::from(Span::styled(
        "⚡ promptLi OS — Installer",
        Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
    )))
    .block(Block::default().borders(Borders::NONE));
    f.render_widget(title, chunks[0]);

    let items: Vec<ListItem> = disks
        .iter()
        .map(|d| {
            let mut label = format!("  {:<10} {:>8}  {}", d.name, d.size_human(), d.model);
            if d.removable {
                label.push_str("  (removable)");
            }
            ListItem::new(Line::from(Span::raw(label)))
        })
        .collect();

    let list = List::new(items)
        .block(
            Block::default()
                .title(" Select target disk ")
                .borders(Borders::ALL)
                .border_style(Style::default().fg(ACCENT)),
        )
        .highlight_style(Style::default().bg(ACCENT).fg(Color::Black))
        .highlight_symbol("▸ ");
    f.render_stateful_widget(list, chunks[1], &mut ratatui::widgets::ListState::default().with_selected(Some(selected)));

    let hint = Paragraph::new(Line::from(vec![
        Span::styled("↑/↓", Style::default().fg(ACCENT)),
        Span::raw(" navigate   "),
        Span::styled("Enter", Style::default().fg(ACCENT)),
        Span::raw(" select   "),
        Span::styled("q", Style::default().fg(ACCENT)),
        Span::raw(" quit"),
    ]));
    f.render_widget(hint, chunks[2]);
    let _ = cfg;
}

fn draw_confirm(f: &mut ratatui::Frame, cfg: &UiConfig) {
    let layout_name = match cfg.layout {
        PartitionScheme::Efi => "UEFI (GPT, ESP + root)",
        PartitionScheme::Bios => "BIOS (MBR, single root)",
    };

    let text = format!(
        "Target disk:   /dev/{}\n\
         Partitioning:  {}\n\
         Hostname:      {}\n\
         User:          {}\n\
         Update server: {}\n\n\
         ALL DATA ON /dev/{} WILL BE DESTROYED.\n\
         Are you sure? [y/n]",
        cfg.disk, layout_name, cfg.hostname, cfg.username, cfg.site_url, cfg.disk
    );

    let warning = Span::styled(
        "⚠ This will permanently erase the selected disk.",
        Style::default().fg(Color::Rgb(0xf7, 0x76, 0x8e)).add_modifier(Modifier::BOLD),
    );

    let paragraph = Paragraph::new(vec![
        Line::from(warning),
        Line::from(""),
        Line::from(text),
    ])
    .block(Block::default().title(" Confirm installation ").borders(Borders::ALL))
    .style(Style::default().fg(Color::White));

    f.render_widget(paragraph, f.area());
}

/// Non-interactive fallback used when the installer is run with `--disk`.
pub fn print_step(s: &str) {
    eprintln!("\x1b[1;38;2;217;72;0m  ▸ {}\x1b[0m", s);
}
