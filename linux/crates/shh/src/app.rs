//! The window, the shared state, and everything that reacts to it changing.
use crate::pages;
use crate::session::{LaunchSpec, Session, State};
use adw::prelude::*;
use gtk::{gdk, gio, glib};
use shh_core::meta::{self, AppSettings, MetaFile};
use shh_core::server::{self, Server, PALETTE};
use std::cell::{Cell, RefCell};
use std::rc::Rc;

pub const NAV: [(&str, &str, &str); 7] = [
    ("dashboard", "Dashboard", "view-grid-symbolic"),
    ("projects", "Projects", "folder-symbolic"),
    ("servers", "Servers", "network-server-symbolic"),
    ("sessions", "Sessions", "utilities-terminal-symbolic"),
    ("files", "Files", "folder-remote-symbolic"),
    ("sharing", "Sharing", "emblem-shared-symbolic"),
    ("settings", "Settings", "emblem-system-symbolic"),
];

pub struct App {
    pub application: adw::Application,
    pub window: adw::ApplicationWindow,
    pub store: RefCell<meta::Store>,
    pub servers: RefCell<Vec<Server>>,
    pub sessions: RefCell<Vec<Rc<Session>>>,
    stack: gtk::Stack,
    page_bin: adw::Bin,
    tabs: adw::TabView,
    nav: gtk::ListBox,
    toasts: adw::ToastOverlay,
    current: RefCell<String>,
    reload_pending: Cell<bool>,
    _monitor: RefCell<Option<gio::FileMonitor>>,
    chrome: adw::ToolbarView,
    sidebar_btn: gtk::ToggleButton,
    /// Where pty helpers report OSC 9 / 777 notifications.
    pub notify_socket: Option<String>,
    /// slug → did a TCP connect to its ssh port succeed
    pub reachable: RefCell<std::collections::HashMap<String, bool>>,
    pub reach_checked: Cell<Option<std::time::Instant>>,
}

impl App {
    pub fn new(application: &adw::Application) -> Rc<App> {
        let store = meta::Store::load();
        let servers = server::load();
        apply_theme(&store.file.settings.theme);
        shh_remote::exec::set_share_connection(store.file.settings.share_connection_per_server);
        install_css();

        let window = adw::ApplicationWindow::builder()
            .application(application)
            .title("shh")
            .default_width(1180)
            .default_height(760)
            .build();

        // sidebar
        let nav = gtk::ListBox::new();
        nav.add_css_class("navigation-sidebar");
        nav.set_selection_mode(gtk::SelectionMode::Single);
        for (i, (_, label, icon)) in NAV.iter().enumerate() {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
            row.append(&gtk::Image::from_icon_name(icon));
            let l = gtk::Label::new(Some(label));
            l.set_xalign(0.0);
            l.set_hexpand(true);
            row.append(&l);
            let hint = gtk::Label::new(Some(&format!("Alt+{}", i + 1)));
            hint.add_css_class("dim-label");
            hint.add_css_class("caption");
            row.append(&hint);
            nav.append(&row);
        }
        let side = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .width_request(210)
            .child(&nav)
            .build();

        // content: one bin for whichever page is showing, plus the terminals
        let page_bin = adw::Bin::new();
        let tabs = adw::TabView::new();
        let stack = gtk::Stack::new();
        stack.set_hexpand(true);
        stack.add_named(&page_bin, Some("page"));
        stack.add_named(&tabs, Some("terminal"));

        let body = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        body.append(&side);
        body.append(&gtk::Separator::new(gtk::Orientation::Vertical));
        body.append(&stack);

        let toasts = adw::ToastOverlay::new();
        toasts.set_child(Some(&body));

        let header = adw::HeaderBar::new();
        let sidebar_btn = gtk::ToggleButton::builder()
            .icon_name("sidebar-show-symbolic")
            .tooltip_text("Focus mode (Ctrl+Shift+F)")
            .active(true)
            .build();
        sidebar_btn.bind_property("active", &side, "visible").sync_create().build();
        header.pack_start(&sidebar_btn);
        let new_btn = gtk::Button::builder()
            .icon_name("list-add-symbolic")
            .tooltip_text("New project (Ctrl+Shift+N)")
            .action_name("win.new-project")
            .build();
        header.pack_start(&new_btn);
        let find_btn = gtk::Button::builder()
            .icon_name("system-search-symbolic")
            .tooltip_text("Search projects, servers and commands (Ctrl+Shift+P)")
            .action_name("win.palette")
            .build();
        header.pack_end(&find_btn);
        let join_btn = gtk::Button::builder()
            .icon_name("insert-link-symbolic")
            .tooltip_text("Join with invite (Ctrl+Shift+J)")
            .action_name("win.join")
            .build();
        header.pack_end(&join_btn);

        let tab_bar = adw::TabBar::new();
        tab_bar.set_view(Some(&tabs));
        // a single session still needs its tab: that is how you get back to it
        tab_bar.set_autohide(false);
        tab_bar.set_visible(false);
        let tb = tab_bar.clone();
        tabs.connect_n_pages_notify(move |t| tb.set_visible(t.n_pages() > 0));

        let chrome = adw::ToolbarView::new();
        chrome.add_top_bar(&header);
        chrome.add_top_bar(&tab_bar);
        chrome.set_content(Some(&toasts));
        window.set_content(Some(&chrome));

        let app = Rc::new(App {
            application: application.clone(),
            window,
            store: RefCell::new(store),
            servers: RefCell::new(servers),
            sessions: RefCell::new(Vec::new()),
            stack,
            page_bin,
            tabs,
            nav,
            toasts,
            current: RefCell::new(String::new()),
            reload_pending: Cell::new(false),
            _monitor: RefCell::new(None),
            chrome,
            sidebar_btn,
            notify_socket: listen_for_notifications(),
            reachable: RefCell::new(Default::default()),
            reach_checked: Cell::new(None),
        });
        app.pump_notifications();
        app.install_tab_menu();

        let a = app.clone();
        app.nav.connect_row_activated(move |_, row| {
            let i = row.index().max(0) as usize;
            a.show_page(NAV[i.min(NAV.len() - 1)].0);
        });

        // Selecting a tab brings its terminal forward and clears its badge.
        let a = app.clone();
        app.tabs.connect_selected_page_notify(move |tabs| {
            let Some(page) = tabs.selected_page() else { return };
            a.stack.set_visible_child_name("terminal");
            a.nav.unselect_all();
            page.set_needs_attention(false);
            if let Some(s) = a.session_for(&page) {
                s.needs_attention.set(false);
                s.term.grab_focus();
            }
        });
        // Clicking the already-selected tab while a page is showing.
        let a = app.clone();
        let click = gtk::GestureClick::new();
        click.set_propagation_phase(gtk::PropagationPhase::Capture);
        click.connect_released(move |_, _, _, _| {
            if a.tabs.n_pages() > 0 {
                a.stack.set_visible_child_name("terminal");
                a.nav.unselect_all();
            }
        });
        tab_bar.add_controller(click);

        let a = app.clone();
        app.tabs.connect_close_page(move |tabs, page| {
            if let Some(s) = a.session_for(page) {
                s.terminate();
                a.sessions.borrow_mut().retain(|x| !Rc::ptr_eq(x, &s));
            }
            tabs.close_page_finish(page, true);
            if a.sessions.borrow().is_empty() {
                let cur = a.current.borrow().clone();
                a.show_page(if cur.is_empty() { "dashboard" } else { &cur });
            }
            glib::Propagation::Stop
        });

        app.install_actions();
        app.watch_config();
        shh_sharing::start();

        // warm the tmux probe so the first project open already knows
        for s in app.servers.borrow().iter().cloned() {
            std::thread::spawn(move || shh_remote::capabilities::probe(&s));
        }

        let last = app.settings().last_section;
        let start = if NAV.iter().any(|n| n.0 == last) { last } else { "dashboard".into() };
        app.show_page(&start);
        app
    }

    // MARK: state

    pub fn settings(&self) -> AppSettings {
        self.store.borrow().file.settings.clone()
    }

    pub fn meta(&self) -> MetaFile {
        self.store.borrow().file.clone()
    }

    /// Change sshm.json and write it out.
    pub fn mutate(&self, f: impl FnOnce(&mut MetaFile)) {
        let mut st = self.store.borrow_mut();
        if st.read_only {
            drop(st);
            self.toast("sshm.json was written by a newer shh — not changing it");
            return;
        }
        f(&mut st.file);
        st.save();
        shh_remote::exec::set_share_connection(st.file.settings.share_connection_per_server);
    }

    pub fn reload_servers(&self) {
        *self.servers.borrow_mut() = server::load();
    }

    pub fn server(&self, slug: &str) -> Option<Server> {
        self.servers.borrow().iter().find(|s| s.name == slug).cloned()
    }

    pub fn server_title(&self, s: &Server) -> String {
        self.store
            .borrow()
            .file
            .servers
            .get(&s.name)
            .and_then(|m| m.display_name.clone())
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| s.name.clone())
    }

    /// Both config files are watched: an edit from the bash TUI (or the Mac
    /// app over a synced folder) shows up here within a second.
    fn watch_config(self: &Rc<Self>) {
        let dir = gio::File::for_path(shh_core::paths::config_dir());
        let Ok(mon) = dir.monitor_directory(gio::FileMonitorFlags::NONE, gio::Cancellable::NONE)
        else {
            return;
        };
        let a = self.clone();
        mon.connect_changed(move |_, file, _, _| {
            let name = file.basename().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
            if name != "servers.conf" && name != "sshm.json" {
                return;
            }
            if a.reload_pending.replace(true) {
                return;
            }
            let a = a.clone();
            glib::timeout_add_local_once(std::time::Duration::from_millis(300), move || {
                a.reload_pending.set(false);
                let servers = server::load();
                let fresh = meta::Store::load();
                let changed =
                    *a.servers.borrow() != servers || a.store.borrow().file != fresh.file;
                if changed {
                    *a.servers.borrow_mut() = servers;
                    *a.store.borrow_mut() = fresh;
                    a.refresh();
                }
            });
        });
        *self._monitor.borrow_mut() = Some(mon);
    }

    // MARK: navigation

    pub fn show_page(self: &Rc<Self>, id: &str) {
        *self.current.borrow_mut() = id.to_string();
        let widget = pages::build(self, id);
        self.page_bin.set_child(Some(&widget));
        self.stack.set_visible_child_name("page");
        if let Some(i) = NAV.iter().position(|n| n.0 == id) {
            if let Some(row) = self.nav.row_at_index(i as i32) {
                self.nav.select_row(Some(&row));
            }
        }
        if self.settings().last_section != id && !self.store.borrow().read_only {
            let id = id.to_string();
            self.mutate(|f| f.settings.last_section = id);
        }
    }

    /// Rebuild the page that is showing, after the model changed.
    pub fn refresh(self: &Rc<Self>) {
        let id = self.current.borrow().clone();
        if id.is_empty() {
            return;
        }
        let widget = pages::build(self, &id);
        self.page_bin.set_child(Some(&widget));
    }

    pub fn toast(&self, text: &str) {
        self.toasts.add_toast(adw::Toast::new(text));
    }

    // MARK: sessions

    fn session_for(&self, page: &adw::TabPage) -> Option<Rc<Session>> {
        let child = page.child();
        self.sessions.borrow().iter().find(|s| s.root.upcast_ref::<gtk::Widget>() == &child).cloned()
    }

    pub fn current_session(&self) -> Option<Rc<Session>> {
        if self.stack.visible_child_name().as_deref() != Some("terminal") {
            return None;
        }
        self.tabs.selected_page().and_then(|p| self.session_for(&p))
    }

    /// Open a project. An existing live session is brought forward instead of
    /// starting a second one, unless `force` (Duplicate Session).
    pub fn open_project(self: &Rc<Self>, project_id: &str, force: bool) {
        let file = self.meta();
        let Some(p) = file.projects.iter().find(|p| p.id == project_id).cloned() else { return };
        let Some(server) = self.server(&p.server) else {
            self.toast(&format!("Server “{}” is missing from servers.conf", p.server));
            return;
        };
        if !force {
            let existing = self
                .sessions
                .borrow()
                .iter()
                .find(|s| s.spec.project_id.as_deref() == Some(project_id) && s.state().is_live())
                .cloned();
            if let Some(s) = existing {
                self.focus_session(&s);
                return;
            }
        }
        let agent = file.agent(p.agent.as_deref()).cloned();
        let id = p.id.clone();
        self.mutate(|f| {
            if let Some(x) = f.projects.iter_mut().find(|x| x.id == id) {
                x.touch();
            }
        });
        self.open(LaunchSpec {
            server,
            path: Some(p.path.clone()),
            agent,
            title: p.name.clone(),
            project_id: Some(p.id.clone()),
            tmux_name: None,
        });
    }

    pub fn open_shell(self: &Rc<Self>, server: Server) {
        let title = self.server_title(&server);
        self.open(LaunchSpec { server, path: None, agent: None, title, project_id: None, tmux_name: None });
    }

    pub fn attach(self: &Rc<Self>, server: Server, tmux: String) {
        self.open(LaunchSpec {
            server,
            path: None,
            agent: None,
            title: tmux.clone(),
            project_id: None,
            tmux_name: Some(tmux),
        });
    }

    pub fn open(self: &Rc<Self>, spec: LaunchSpec) {
        // tabs after the first for the same project are #2, #3, …
        let ordinal = match &spec.project_id {
            Some(pid) => {
                let used: Vec<usize> = self
                    .sessions
                    .borrow()
                    .iter()
                    .filter(|s| s.spec.project_id.as_ref() == Some(pid))
                    .map(|s| s.ordinal)
                    .collect();
                (1..).find(|n| !used.contains(n)).unwrap_or(1)
            }
            None => 1,
        };
        let s = Session::new(self, spec, ordinal);
        self.sessions.borrow_mut().push(s.clone());
        let page = self.tabs.append(&s.root);
        page.set_title(&s.title());
        page.set_tooltip(&s.spec.server.display());
        self.tabs.set_selected_page(&page);
        self.stack.set_visible_child_name("terminal");
        self.nav.unselect_all();
        s.start();
        s.term.grab_focus();
    }

    pub fn close_session(&self, s: &Rc<Session>) {
        if self.sessions.borrow().iter().any(|x| Rc::ptr_eq(x, s)) {
            self.tabs.close_page(&self.tabs.page(&s.root));
        }
    }

    pub fn focus_session(&self, s: &Rc<Session>) {
        let page = self.tabs.page(&s.root);
        self.tabs.set_selected_page(&page);
        self.stack.set_visible_child_name("terminal");
        self.nav.unselect_all();
        s.term.grab_focus();
    }

    /// A session's state moved: reflect it on its tab.
    pub fn session_changed(&self, s: &Rc<Session>) {
        if !self.sessions.borrow().iter().any(|x| Rc::ptr_eq(x, s)) {
            return;
        }
        let page = self.tabs.page(&s.root);
        page.set_loading(matches!(s.state(), State::Connecting | State::Reconnecting { .. }));
        let icon = match s.state() {
            State::Ended(e) if !e.is_clean() => Some("dialog-warning-symbolic"),
            State::Ended(_) => Some("media-playback-stop-symbolic"),
            _ => None,
        };
        page.set_indicator_icon(icon.map(gio::ThemedIcon::new).as_ref());
    }

    /// Something in a session wants the user — but only say so for a session
    /// they are not already looking at.
    pub fn notify(&self, s: &Rc<Session>, title: &str, body: &str) {
        let watching = self.window.is_active()
            && self.current_session().map(|c| Rc::ptr_eq(&c, s)).unwrap_or(false);
        if watching {
            return;
        }
        s.needs_attention.set(true);
        if self.sessions.borrow().iter().any(|x| Rc::ptr_eq(x, s)) {
            self.tabs.page(&s.root).set_needs_attention(true);
        }
        let n = gio::Notification::new(title);
        n.set_body(Some(body));
        n.set_default_action("app.activate");
        self.application.send_notification(Some(&format!("session-{}", s.id)), &n);
    }

    pub fn join(self: &Rc<Self>, url: Option<String>) {
        let a = self.clone();
        shh_sharing::ui::join_dialog(
            self.window.upcast_ref::<gtk::Window>(),
            url,
            Rc::new(move |server: Server| {
                a.reload_servers();
                *a.store.borrow_mut() = meta::Store::load();
                a.refresh();
                a.open_shell(server);
            }),
        );
    }

    // MARK: actions and keys

    fn install_actions(self: &Rc<Self>) {
        let add = |name: &str, accels: &[&str], f: Box<dyn Fn(&Rc<App>)>| {
            let action = gio::SimpleAction::new(name, None);
            let a = self.clone();
            action.connect_activate(move |_, _| f(&a));
            self.window.add_action(&action);
            self.application.set_accels_for_action(&format!("win.{name}"), accels);
        };
        // Ctrl+Shift, not Ctrl: plain Ctrl+W/N/R/C belong to the shell.
        add("new-project", &["<Ctrl><Shift>n"], Box::new(|a| pages::edit_project(a, None)));
        add("new-server", &["<Ctrl><Shift>s"], Box::new(|a| pages::edit_server(a, None)));
        add("join", &["<Ctrl><Shift>j"], Box::new(|a| a.join(None)));
        add("copy", &["<Ctrl><Shift>c"], Box::new(|a| {
            if let Some(s) = a.current_session() {
                s.copy();
            }
        }));
        add("paste", &["<Ctrl><Shift>v"], Box::new(|a| {
            if let Some(s) = a.current_session() {
                s.paste();
            }
        }));
        add("close-tab", &["<Ctrl><Shift>w"], Box::new(|a| {
            if a.current_session().is_some() {
                if let Some(p) = a.tabs.selected_page() {
                    a.tabs.close_page(&p);
                }
            }
        }));
        add("duplicate", &["<Ctrl><Shift>d"], Box::new(|a| {
            if let Some(s) = a.current_session() {
                match &s.spec.project_id {
                    Some(pid) => a.open_project(pid, true),
                    None => a.open(s.spec.clone()),
                }
            }
        }));
        add("reconnect", &["<Ctrl><Shift>r"], Box::new(|a| {
            if let Some(s) = a.current_session() {
                s.reconnect_now();
            }
        }));
        add("reload", &["F5"], Box::new(|a| {
            a.reload_servers();
            *a.store.borrow_mut() = meta::Store::load();
            a.refresh();
        }));
        add("prev-tab", &["<Ctrl><Shift>bracketleft", "<Ctrl>Page_Up"], Box::new(|a| {
            a.tabs.select_previous_page();
        }));
        add("next-tab", &["<Ctrl><Shift>bracketright", "<Ctrl>Page_Down"], Box::new(|a| {
            a.tabs.select_next_page();
        }));
        add("palette", &["<Ctrl><Shift>p", "<Ctrl>k"], Box::new(|a| pages::palette(a)));
        add("focus-mode", &["<Ctrl><Shift>f"], Box::new(|a| {
            // the terminal owns the window: no sidebar, no header, no tabs
            let on = a.chrome.reveals_top_bars();
            a.chrome.set_reveal_top_bars(!on);
            a.sidebar_btn.set_active(!on);
        }));
        add("fullscreen", &["F11"], Box::new(|a| {
            a.window.set_fullscreened(!a.window.is_fullscreen());
        }));
        add("end-remote", &[], Box::new(|a| {
            let Some(s) = a.current_session() else { return };
            let Some(name) = s.tmux_name.borrow().clone() else {
                a.toast("This session isn't running in tmux on the server");
                return;
            };
            let (server, cp, a2, s2) = (s.spec.server.clone(), s.control_path.clone(), a.clone(), s.clone());
            glib::spawn_future_local(async move {
                let r = gio::spawn_blocking(move || {
                    shh_remote::sessions::kill(&server, &name, Some(cp.as_str())).map_err(|e| e.to_string())
                })
                .await;
                match r {
                    Ok(Ok(_)) => {
                        if a2.sessions.borrow().iter().any(|x| Rc::ptr_eq(x, &s2)) {
                            a2.tabs.close_page(&a2.tabs.page(&s2.root));
                        }
                    }
                    Ok(Err(e)) => a2.toast(&format!("Couldn't end it: {e}")),
                    Err(_) => {}
                }
            });
        }));
        for (i, (id, _, _)) in NAV.iter().enumerate() {
            let key = format!("<Alt>{}", i + 1);
            add(&format!("go-{id}"), &[key.as_str()], Box::new(move |a| a.show_page(id)));
        }
    }
}

impl App {
    /// Right-click a tab.
    fn install_tab_menu(self: &Rc<Self>) {
        let menu = gio::Menu::new();
        menu.append(Some("Duplicate Session"), Some("win.duplicate"));
        menu.append(Some("Reconnect"), Some("win.reconnect"));
        let danger = gio::Menu::new();
        danger.append(Some("End Session on Server"), Some("win.end-remote"));
        danger.append(Some("Close Tab"), Some("win.close-tab"));
        menu.append_section(None, &danger);
        self.tabs.set_menu_model(Some(&menu));
        let a = self.clone();
        self.tabs.connect_setup_menu(move |tabs, page| {
            if let Some(p) = page {
                tabs.set_selected_page(p);
                a.stack.set_visible_child_name("terminal");
            }
        });
    }

    /// Drain what the pty helpers reported; runs on the main loop.
    fn pump_notifications(self: &Rc<Self>) {
        let Some(path) = self.notify_socket.clone() else { return };
        let (tx, rx) = std::sync::mpsc::channel::<String>();
        std::thread::spawn(move || {
            let Ok(sock) = std::os::unix::net::UnixDatagram::bind(&path) else { return };
            let mut buf = [0u8; 8192];
            while let Ok(n) = sock.recv(&mut buf) {
                if tx.send(String::from_utf8_lossy(&buf[..n]).into_owned()).is_err() {
                    break;
                }
            }
        });
        let a = Rc::downgrade(self);
        glib::timeout_add_local(std::time::Duration::from_millis(300), move || {
            let Some(a) = a.upgrade() else { return glib::ControlFlow::Break };
            while let Ok(msg) = rx.try_recv() {
                let mut parts = msg.splitn(3, '\x1f');
                let (Some(id), Some(title), Some(body)) = (parts.next(), parts.next(), parts.next())
                else {
                    continue;
                };
                let s = a.sessions.borrow().iter().find(|s| s.id == id).cloned();
                if let Some(s) = s {
                    s.remote_notification(title, body);
                }
            }
            glib::ControlFlow::Continue
        });
        let path = self.notify_socket.clone();
        self.application.connect_shutdown(move |_| {
            if let Some(p) = &path {
                let _ = std::fs::remove_file(p);
            }
        });

        // a quiet check on launch; the .deb itself is replaced by apt
        if self.settings().automatic_updates {
            let a = Rc::downgrade(self);
            glib::timeout_add_seconds_local_once(8, move || {
                glib::spawn_future_local(async move {
                    let latest = gio::spawn_blocking(pages::latest_release).await.ok().flatten();
                    if let (Some(a), Some(tag)) = (a.upgrade(), latest) {
                        if pages::newer(&tag, crate::VERSION) {
                            a.toast(&format!("shh {tag} is available — see Settings → Updates"));
                        }
                    }
                });
            });
        }
    }

    /// Can each server's ssh port be reached? Checked off the main thread, at
    /// most every 30 seconds, and only redraws when an answer changes.
    pub fn check_reachability(self: &Rc<Self>) {
        if self.reach_checked.get().map(|t| t.elapsed().as_secs() < 30).unwrap_or(false) {
            return;
        }
        self.reach_checked.set(Some(std::time::Instant::now()));
        let servers = self.servers.borrow().clone();
        let a = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let res = gio::spawn_blocking(move || {
                let handles: Vec<_> = servers
                    .into_iter()
                    .map(|s| std::thread::spawn(move || (s.name.clone(), can_connect(&s.host, &s.port))))
                    .collect();
                handles.into_iter().filter_map(|h| h.join().ok()).collect::<std::collections::HashMap<_, _>>()
            })
            .await;
            let (Some(a), Ok(map)) = (a.upgrade(), res) else { return };
            if *a.reachable.borrow() != map {
                *a.reachable.borrow_mut() = map;
                if *a.current.borrow() == "dashboard" || *a.current.borrow() == "servers" {
                    a.refresh();
                }
            }
        });
    }
}

fn can_connect(host: &str, port: &str) -> bool {
    use std::net::ToSocketAddrs;
    let Ok(addrs) = format!("{host}:{port}").to_socket_addrs() else { return false };
    addrs
        .into_iter()
        .any(|a| std::net::TcpStream::connect_timeout(&a, std::time::Duration::from_secs(3)).is_ok())
}

/// A datagram socket in the runtime dir; the reader thread binds it.
fn listen_for_notifications() -> Option<String> {
    let dir = glib::user_runtime_dir();
    let path = dir.join(format!("shh-notify-{}.sock", std::process::id()));
    let _ = std::fs::remove_file(&path);
    Some(path.to_string_lossy().into_owned())
}

pub fn apply_theme(theme: &str) {
    adw::StyleManager::default().set_color_scheme(match theme {
        "light" => adw::ColorScheme::ForceLight,
        "dark" => adw::ColorScheme::ForceDark,
        _ => adw::ColorScheme::Default,
    });
}

/// One class per palette hue, so a server keeps its colour everywhere.
fn install_css() {
    let mut css = String::from(
        ".tile { padding: 18px; border-radius: 14px; }\n\
         .tile .big { font-size: 28px; font-weight: 800; }\n\
         .dot { font-size: 16px; }\n",
    );
    for (i, (r, g, b)) in PALETTE.iter().enumerate() {
        css.push_str(&format!(".hue-{i} {{ color: rgb({r},{g},{b}); }}\n"));
    }
    let provider = gtk::CssProvider::new();
    provider.load_from_string(&css);
    if let Some(display) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
}
