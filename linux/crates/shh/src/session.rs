//! One ssh session in a VTE terminal: launch, password hand-off, reconnect.
use crate::app::App;
use gtk::prelude::*;
use gtk::{gdk, gio, glib, pango};
use shh_core::exit::ExitStatus;
use shh_core::meta::AgentDef;
use shh_core::server::Server;
use shh_core::{env, shell, slug, tools};
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Instant;
use vte::prelude::*;

#[derive(Clone)]
pub struct LaunchSpec {
    pub server: Server,
    pub path: Option<String>,
    pub agent: Option<AgentDef>,
    pub title: String,
    pub project_id: Option<String>,
    /// Attach to this existing tmux session instead of deriving a name.
    pub tmux_name: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum State {
    Idle,
    Connecting,
    Running,
    Reconnecting { attempt: usize, left: u32 },
    Ended(ExitStatus),
}

impl State {
    pub fn is_live(self) -> bool {
        matches!(self, State::Connecting | State::Running | State::Reconnecting { .. })
    }
    pub fn is_connected(self) -> bool {
        matches!(self, State::Connecting | State::Running)
    }
}

const BACKOFF: [u32; 8] = [1, 2, 4, 8, 15, 30, 30, 30];

pub struct Session {
    pub id: String,
    pub spec: LaunchSpec,
    pub term: vte::Terminal,
    pub root: gtk::Box,
    pub control_path: String,
    pub ordinal: usize,
    bar: gtk::Revealer,
    status: gtk::Label,
    retry_btn: gtk::Button,
    state: Cell<State>,
    attempt: Cell<usize>,
    last_launch: Cell<Instant>,
    /// Bumped whenever a pending retry must be forgotten.
    generation: Cell<u64>,
    fifo_dir: RefCell<Option<std::path::PathBuf>>,
    pub tmux_name: RefCell<Option<String>>,
    pub needs_attention: Cell<bool>,
    pid: Cell<i32>,
    // "went quiet" detection: a sustained burst of output, then silence
    last_output: Cell<Option<Instant>>,
    burst_start: Cell<Option<Instant>>,
    idle_armed: Cell<bool>,
    idle_timer: Cell<bool>,
    app: RefCell<Option<Rc<App>>>,
}

fn rgba(r: f32, g: f32, b: f32) -> gdk::RGBA {
    gdk::RGBA::new(r, g, b, 1.0)
}

impl Session {
    pub fn new(app: &Rc<App>, spec: LaunchSpec, ordinal: usize) -> Rc<Session> {
        let settings = app.settings();
        let term = vte::Terminal::new();
        term.set_hexpand(true);
        term.set_vexpand(true);
        term.set_scrollback_lines(20_000);
        term.set_mouse_autohide(true);
        term.set_audible_bell(settings.bell_sound);
        term.set_font(Some(&pango::FontDescription::from_string(&format!(
            "Monospace {}",
            settings.font_size.max(6.0)
        ))));

        // The server's colour follows you into the session: a faint wash on the
        // background and the vivid hue on the cursor, as in the TUI.
        let (r, g, b) = spec.server.rgb();
        let (r, g, b) = (r as f32 / 255.0, g as f32 / 255.0, b as f32 / 255.0);
        term.set_color_background(&rgba(0.10 + r * 0.09, 0.10 + g * 0.09, 0.12 + b * 0.09));
        term.set_color_foreground(&rgba(0.90, 0.90, 0.92));
        term.set_color_cursor(Some(&rgba(r, g, b)));

        let status = gtk::Label::new(None);
        status.set_xalign(0.0);
        status.set_hexpand(true);
        status.set_ellipsize(pango::EllipsizeMode::End);
        let retry_btn = gtk::Button::with_label("Reconnect");
        let strip = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        strip.add_css_class("toolbar");
        strip.append(&status);
        strip.append(&retry_btn);
        let bar = gtk::Revealer::new();
        bar.set_child(Some(&strip));

        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
        root.append(&term);
        root.append(&bar);

        let control_path = if settings.share_connection_per_server {
            shh_remote::exec::control_path(&spec.server)
        } else {
            format!(
                "/tmp/sshm-gui-{}-{}.sock",
                unsafe { libc::getuid() },
                &shh_core::meta::new_id()[..8]
            )
        };

        let s = Rc::new(Session {
            id: shh_core::meta::new_id(),
            spec,
            term,
            root,
            control_path,
            ordinal,
            bar,
            status,
            retry_btn,
            state: Cell::new(State::Idle),
            attempt: Cell::new(0),
            last_launch: Cell::new(Instant::now()),
            generation: Cell::new(0),
            fifo_dir: RefCell::new(None),
            tmux_name: RefCell::new(None),
            needs_attention: Cell::new(false),
            pid: Cell::new(0),
            last_output: Cell::new(None),
            burst_start: Cell::new(None),
            idle_armed: Cell::new(false),
            idle_timer: Cell::new(false),
            app: RefCell::new(Some(app.clone())),
        });

        let w = Rc::downgrade(&s);
        s.term.connect_child_exited(move |_, raw| {
            if let Some(s) = w.upgrade() {
                s.exited(raw);
            }
        });
        let w = Rc::downgrade(&s);
        s.term.connect_bell(move |_| {
            if let Some(s) = w.upgrade() {
                if s.settings().notify_on_bell {
                    s.notify("Ready for you");
                }
            }
        });
        let w = Rc::downgrade(&s);
        s.term.connect_contents_changed(move |_| {
            if let Some(s) = w.upgrade() {
                s.output_seen();
            }
        });
        let w = Rc::downgrade(&s);
        s.retry_btn.connect_clicked(move |_| {
            if let Some(s) = w.upgrade() {
                s.attempt.set(0);
                s.reconnect_now();
            }
        });

        // Dropped files are uploaded over the session's connection and their
        // remote paths typed in, like the Mac app.
        let drop = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY);
        let w = Rc::downgrade(&s);
        drop.connect_drop(move |_, value, _, _| {
            let (Some(s), Ok(list)) = (w.upgrade(), value.get::<gdk::FileList>()) else {
                return false;
            };
            for f in list.files() {
                if let Some(p) = f.path() {
                    s.upload(move |cp, target| shh_remote::clipboard::upload_file(&cp, &target, &p));
                }
            }
            true
        });
        s.term.add_controller(drop);
        s
    }

    fn app(&self) -> Option<Rc<App>> {
        self.app.borrow().clone()
    }
    fn settings(&self) -> shh_core::meta::AppSettings {
        self.app().map(|a| a.settings()).unwrap_or_default()
    }

    pub fn state(&self) -> State {
        self.state.get()
    }
    pub fn title(&self) -> String {
        if self.ordinal > 1 {
            format!("{} #{}", self.spec.title, self.ordinal)
        } else {
            self.spec.title.clone()
        }
    }

    fn set_state(self: &Rc<Self>, st: State) {
        self.state.set(st);
        let text = match st {
            State::Idle | State::Running => String::new(),
            State::Connecting => String::new(),
            State::Reconnecting { attempt, left } => {
                let online = gio::NetworkMonitor::default().is_network_available();
                if online {
                    format!("Connection lost — retry {attempt} of {} in {left}s", BACKOFF.len())
                } else {
                    "Offline — waiting for the network to come back".to_string()
                }
            }
            State::Ended(e) => match e.detail() {
                Some(d) => format!("Session ended — {d}"),
                None => "Session ended".to_string(),
            },
        };
        self.status.set_text(&text);
        self.bar.set_reveal_child(!text.is_empty());
        if let Some(app) = self.app() {
            app.session_changed(self);
        }
    }

    fn emit(&self, text: &str) {
        self.term.feed(text.as_bytes());
    }

    fn notify(self: &Rc<Self>, body: &str) {
        if let Some(app) = self.app() {
            app.notify(self, &self.title(), body);
        }
    }

    /// OSC 9 / OSC 777 from the far side, relayed by the pty helper.
    pub fn remote_notification(self: &Rc<Self>, title: &str, body: &str) {
        if !self.settings().notify_on_remote {
            return;
        }
        if let Some(app) = self.app() {
            let title = if title.is_empty() { self.title() } else { title.to_string() };
            app.notify(self, &title, body);
        }
    }

    /// Sustained output before silence counts as "a long run".
    const BURST_MIN: u64 = 3;
    /// Silence after that which counts as finished.
    const IDLE_GAP: u64 = 15;

    /// Guess that a long-running command finished when output goes quiet. An
    /// idle shell echoing a keystroke must never arm this.
    fn output_seen(self: &Rc<Self>) {
        let Some(app) = self.app() else { return };
        if !app.store.borrow().file.settings.notify_on_idle {
            return;
        }
        let now = Instant::now();
        let gap = self.last_output.get().map(|l| now.duration_since(l).as_secs());
        if gap.map(|g| g > Self::IDLE_GAP).unwrap_or(true) {
            self.burst_start.set(Some(now));
        }
        self.last_output.set(Some(now));
        if let Some(b) = self.burst_start.get() {
            if now.duration_since(b).as_secs() >= Self::BURST_MIN {
                self.idle_armed.set(true);
            }
        }
        if !self.idle_armed.get() || self.idle_timer.replace(true) {
            return;
        }
        let me = Rc::downgrade(self);
        glib::timeout_add_seconds_local(1, move || {
            let Some(s) = me.upgrade() else { return glib::ControlFlow::Break };
            let quiet = s.last_output.get().map(|l| l.elapsed().as_secs()).unwrap_or(0);
            if s.idle_armed.get() && quiet < Self::IDLE_GAP {
                return glib::ControlFlow::Continue;
            }
            s.idle_timer.set(false);
            if s.idle_armed.replace(false) {
                s.burst_start.set(None);
                if s.state() == State::Running {
                    s.notify("Finished");
                }
            }
            glib::ControlFlow::Break
        });
    }

    /// The tmux session this one lives in on the server, if any.
    fn durable_name(&self) -> Option<String> {
        if let Some(n) = &self.spec.tmux_name {
            return Some(n.clone());
        }
        let pid = self.spec.project_id.as_ref()?;
        if !self.settings().durable_sessions
            || shh_remote::capabilities::has_tmux(&self.spec.server) == Some(false)
        {
            return None;
        }
        let short: String = pid.chars().take(4).collect::<String>().to_lowercase();
        Some(format!("shh-{}-{}-{}", slug::make(&self.spec.title), self.ordinal, short))
    }

    pub fn start(self: &Rc<Self>) {
        if !self.state().is_connected() {
            self.launch();
        }
    }

    fn launch(self: &Rc<Self>) {
        self.set_state(State::Connecting);
        self.last_launch.set(Instant::now());
        let was_retrying = self.attempt.get() > 0;
        let settings = self.settings();
        let server = &self.spec.server;

        let mut args: Vec<String> = vec![
            "-p".into(), server.port.clone(),
            "-o".into(), format!("ServerAliveInterval={}", env::string("SSHM_ALIVE_INTERVAL", "10")),
            "-o".into(), format!("ServerAliveCountMax={}", env::string("SSHM_ALIVE_COUNT", "3")),
            "-o".into(), format!("ConnectTimeout={}", env::string("SSHM_CONNECT_TIMEOUT", "10")),
            "-o".into(), "TCPKeepAlive=yes".into(),
            "-o".into(), "LogLevel=ERROR".into(),
            "-o".into(), "ControlMaster=auto".into(),
            "-o".into(), format!("ControlPath={}", self.control_path),
            "-o".into(),
            format!("ControlPersist={}", if settings.share_connection_per_server { "60" } else { "no" }),
        ];
        if server.auth == "key" {
            args.extend(["-i".into(), server.secret.clone(), "-o".into(), "IdentitiesOnly=yes".into()]);
        } else {
            // don't let ssh burn its auth attempts on agent keys first
            args.extend([
                "-o".into(), "PubkeyAuthentication=no".into(),
                "-o".into(), "PreferredAuthentications=password,keyboard-interactive".into(),
            ]);
        }

        let durable = self.durable_name();
        *self.tmux_name.borrow_mut() = durable.clone();
        let voice = settings.voice_input.then_some(shh_sharing::voice::REMOTE_BIN);
        let has_work = self.spec.path.is_some()
            || self.spec.agent.as_ref().map(|a| !a.command.is_empty()).unwrap_or(false);
        let script = if self.spec.tmux_name.is_some() && !has_work {
            // attaching to a session someone left running
            durable.as_deref().filter(|n| shell::is_safe(n)).map(|n| {
                shell::tmux_wrap(&format!("{} -l", "${SHELL:-/bin/sh}"), n, None)
            })
        } else {
            shell::remote_script(
                self.spec.path.as_deref(),
                self.spec.agent.as_ref(),
                durable.as_deref(),
                voice,
            )
        };
        match script {
            // A remote command needs an explicit pty: without -t, full-screen
            // agents either refuse to start or render garbage.
            Some(script) => args.extend(["-t".into(), server.target(), script]),
            None => {
                args.push(server.target());
                if has_work {
                    self.emit(
                        "\x1b[33mThat path or command can't be sent safely \
                         (newlines aren't allowed) — opening a plain shell.\x1b[0m\r\n\r\n",
                    );
                }
            }
        }

        let ssh = tools::ssh();
        let mut argv: Vec<String> = Vec::new();
        let mut password: Option<(String, std::path::PathBuf)> = None;
        match (server.password(), tools::sshpass()) {
            (Some(pass), Some(sshpass)) => match make_fifo() {
                Some((dir, fifo)) => {
                    // The password goes to sshpass on fd 3 through a fifo in a
                    // 0700 directory: never in argv, never on disk.
                    let script = format!(
                        "exec {} -d 3 {} \"$@\" 3< {}",
                        shell::quote(&sshpass),
                        shell::quote(&ssh),
                        shell::quote(&fifo.to_string_lossy())
                    );
                    argv.extend(["/bin/bash".into(), "-c".into(), script, "sshm".into()]);
                    *self.fifo_dir.borrow_mut() = Some(dir);
                    password = Some((pass, fifo));
                }
                None => argv.push(ssh.clone()),
            },
            (Some(_), None) => {
                self.emit(
                    "sshpass is not installed, so ssh will prompt for the password.\r\n\
                     install it with:  sudo apt install sshpass\r\n\r\n",
                );
                argv.push(ssh.clone());
            }
            _ => argv.push(ssh.clone()),
        }
        argv.extend(args);

        // Remote notifications need to see the byte stream before VTE eats it.
        if settings.notify_on_remote {
            let sock = self.app().and_then(|a| a.notify_socket.clone());
            if let (Some(sock), Ok(exe)) = (sock, std::env::current_exe()) {
                let mut wrapped = vec![
                    exe.to_string_lossy().into_owned(),
                    "--pty-proxy".into(),
                    sock,
                    self.id.clone(),
                    "--".into(),
                ];
                wrapped.append(&mut argv);
                argv = wrapped;
            }
        }

        let argv_ref: Vec<&str> = argv.iter().map(String::as_str).collect();
        let term_env = format!("TERM={}", env::remote_term());
        let me = Rc::downgrade(self);
        self.term.spawn_async(
            vte::PtyFlags::DEFAULT,
            None,
            &argv_ref,
            &[term_env.as_str()],
            glib::SpawnFlags::DEFAULT,
            || {},
            -1,
            gio::Cancellable::NONE,
            move |res| {
                let Some(s) = me.upgrade() else { return };
                match res {
                    Ok(pid) => {
                        s.pid.set(pid.0);
                        s.set_state(State::Running);
                        if s.settings().voice_input {
                            shh_sharing::voice::attach(
                                s.control_path.clone(),
                                s.spec.server.target(),
                                s.spec.server.port.clone(),
                            );
                        }
                    }
                    Err(e) => {
                        s.emit(&format!("could not start ssh: {e}\r\n"));
                        s.cleanup_fifo();
                        s.set_state(State::Ended(ExitStatus::Code(127)));
                    }
                }
            },
        );

        if let Some((pass, fifo)) = password {
            std::thread::spawn(move || write_password(&fifo, &pass));
        }

        // Only call it a recovery once the new connection has actually held.
        if was_retrying {
            let me = Rc::downgrade(self);
            glib::timeout_add_seconds_local_once(5, move || {
                if let Some(s) = me.upgrade() {
                    if s.state() == State::Running && s.settings().notify_on_disconnect {
                        s.notify("Reconnected");
                    }
                }
            });
        }
    }

    fn cleanup_fifo(&self) {
        if let Some(d) = self.fifo_dir.borrow_mut().take() {
            let _ = std::fs::remove_dir_all(d);
        }
    }

    fn exited(self: &Rc<Self>, raw: i32) {
        self.pid.set(0);
        self.cleanup_fifo();
        // The remote app may have died mid-escape; put the terminal back.
        self.emit(
            "\x1b>\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l\x1b[?1015l\
             \x1b[?1004l\x1b[?2004l\x1b[?1l\x1b[?25h\x1b[0m",
        );
        if self.app.borrow().is_none() {
            return; // closed by the user
        }
        let status = ExitStatus::from_raw(raw);
        // A session that held for a while and then dropped is a fresh failure.
        if self.last_launch.get().elapsed().as_secs() > 30 {
            self.attempt.set(0);
        }
        let settings = self.settings();
        let durable = self.spec.project_id.is_some() || self.spec.tmux_name.is_some();
        if status.should_reconnect() && settings.auto_reconnect && durable {
            if settings.notify_on_disconnect {
                self.notify("Connection lost — reconnecting");
            }
            self.schedule_reconnect();
            return;
        }
        if !status.is_clean() && settings.notify_on_disconnect {
            self.notify(&status.detail().unwrap_or_else(|| status.label()));
        }
        self.attempt.set(0);
        self.set_state(State::Ended(status));
    }

    fn schedule_reconnect(self: &Rc<Self>) {
        let attempt = self.attempt.get();
        if attempt >= BACKOFF.len() {
            self.set_state(State::Ended(ExitStatus::Code(255)));
            return;
        }
        let mut left = BACKOFF[attempt];
        self.attempt.set(attempt + 1);
        self.set_state(State::Reconnecting { attempt: attempt + 1, left });

        let gen = self.generation.get() + 1;
        self.generation.set(gen);
        let me = Rc::downgrade(self);
        glib::timeout_add_seconds_local(1, move || {
            let Some(s) = me.upgrade() else { return glib::ControlFlow::Break };
            if s.generation.get() != gen || !matches!(s.state(), State::Reconnecting { .. }) {
                return glib::ControlFlow::Break;
            }
            // Don't burn attempts against a dead interface.
            if gio::NetworkMonitor::default().is_network_available() {
                left = left.saturating_sub(1);
            }
            if left == 0 {
                s.reconnect_now();
                return glib::ControlFlow::Break;
            }
            s.set_state(State::Reconnecting { attempt: s.attempt.get(), left });
            glib::ControlFlow::Continue
        });
    }

    pub fn reconnect_now(self: &Rc<Self>) {
        self.generation.set(self.generation.get() + 1);
        if self.state().is_connected() {
            return;
        }
        self.emit("\r\n");
        self.clear_stale_control_socket();
        self.launch();
    }

    fn clear_stale_control_socket(&self) {
        if !std::path::Path::new(&self.control_path).exists() {
            return;
        }
        let ok = std::process::Command::new(tools::ssh())
            .args(["-S", &self.control_path, "-O", "check", &self.spec.server.target()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !ok {
            let _ = std::fs::remove_file(&self.control_path);
        }
    }

    /// Stop for good: the tab is closing.
    pub fn terminate(&self) {
        self.generation.set(self.generation.get() + 1);
        *self.app.borrow_mut() = None;
        self.cleanup_fifo();
        // SIGHUP is what closing a terminal window sends.
        let pid = self.pid.replace(0);
        if pid > 0 && self.state.get().is_connected() {
            unsafe { libc::kill(pid, libc::SIGHUP) };
        }
    }

    pub fn copy(&self) {
        self.term.copy_clipboard_format(vte::Format::Text);
    }

    /// Ctrl+Shift+V: an image on the clipboard is uploaded and its remote path
    /// typed in; anything else pastes as text. The clipboard is never written.
    pub fn paste(self: &Rc<Self>) {
        let clip = self.term.clipboard();
        let has_image = clip.formats().contain_mime_type("image/png");
        if !(has_image && self.settings().paste_images_to_server && self.state() == State::Running) {
            self.term.paste_clipboard();
            return;
        }
        let me = Rc::downgrade(self);
        clip.read_texture_async(gio::Cancellable::NONE, move |res| {
            let Some(s) = me.upgrade() else { return };
            match res {
                Ok(Some(tex)) => {
                    let png = tex.save_to_png_bytes().to_vec();
                    s.upload(move |cp, target| shh_remote::clipboard::upload_png(&cp, &target, &png));
                }
                _ => s.term.paste_clipboard(),
            }
        });
    }

    fn upload(
        self: &Rc<Self>,
        work: impl FnOnce(String, String) -> Result<String, String> + Send + 'static,
    ) {
        if self.state() != State::Running {
            return;
        }
        let (cp, target) = (self.control_path.clone(), self.spec.server.target());
        let me = Rc::downgrade(self);
        if let Some(app) = self.app() {
            app.toast("Uploading…");
        }
        glib::spawn_future_local(async move {
            let res = gio::spawn_blocking(move || work(cp, target)).await;
            let Some(s) = me.upgrade() else { return };
            match res {
                Ok(Ok(path)) => s.term.feed_child(format!("{path} ").as_bytes()),
                Ok(Err(e)) => {
                    if let Some(app) = s.app() {
                        app.toast(&format!("Upload failed: {e}"));
                    }
                }
                Err(_) => {}
            }
        });
    }
}

fn make_fifo() -> Option<(std::path::PathBuf, std::path::PathBuf)> {
    use std::os::unix::fs::DirBuilderExt;
    let dir = std::env::temp_dir().join(format!("sshm-{}", shh_core::meta::new_id()));
    std::fs::DirBuilder::new().mode(0o700).create(&dir).ok()?;
    let path = dir.join("pw");
    let c = std::ffi::CString::new(path.to_string_lossy().as_bytes()).ok()?;
    if unsafe { libc::mkfifo(c.as_ptr(), 0o600) } != 0 {
        let _ = std::fs::remove_dir_all(&dir);
        return None;
    }
    Some((dir, path))
}

/// O_WRONLY on a fifo blocks until a reader arrives; poll instead so a child
/// that dies before opening it cannot wedge this thread forever.
fn write_password(fifo: &std::path::Path, pass: &str) {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    for _ in 0..100 {
        match std::fs::OpenOptions::new().write(true).custom_flags(libc::O_NONBLOCK).open(fifo) {
            Ok(mut f) => {
                let _ = f.write_all(format!("{pass}\n").as_bytes());
                break;
            }
            Err(_) => std::thread::sleep(std::time::Duration::from_millis(50)),
        }
    }
    if let Some(dir) = fifo.parent() {
        let _ = std::fs::remove_dir_all(dir);
    }
}
