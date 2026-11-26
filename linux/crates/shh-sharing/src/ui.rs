//! Settings → Sharing, the join dialog, and the Allow/Deny prompt.
use crate::access::{self, Snapshot, Status};
use crate::invite::InviteCode;
use crate::join;
use adw::prelude::*;
use gtk::{gio, glib};
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;

fn active_window() -> Option<gtk::Window> {
    gio::Application::default()
        .and_then(|a| a.downcast::<gtk::Application>().ok())
        .and_then(|a| a.active_window())
        .or_else(|| {
            gtk::Window::list_toplevels()
                .into_iter()
                .filter_map(|w| w.downcast::<gtk::Window>().ok())
                .next()
        })
}

fn alert(parent: &impl IsA<gtk::Widget>, heading: &str, body: &str) {
    let d = adw::AlertDialog::new(Some(heading), Some(body));
    d.add_response("ok", "OK");
    d.set_default_response(Some("ok"));
    d.set_close_response("ok");
    d.present(Some(parent));
}

// ---- prompts raised by the listener thread ---------------------------------

/// Starts the main-thread pump that shows join approvals and notices. Safe to
/// call more than once.
pub(crate) fn install_pump() {
    thread_local!(static INSTALLED: Cell<bool> = const { Cell::new(false) });
    if INSTALLED.with(|i| i.replace(true)) {
        return;
    }
    glib::timeout_add_local(Duration::from_millis(300), || {
        for a in access::take_approvals() {
            present_approval(a);
        }
        for (title, body) in access::take_notices() {
            if let Some(app) = gio::Application::default() {
                let n = gio::Notification::new(&title);
                n.set_body(Some(&body));
                app.send_notification(None, &n);
            }
        }
        glib::ControlFlow::Continue
    });
}

fn present_approval(a: access::Approval) {
    let Some(win) = active_window() else {
        let _ = a.answer.send(false);
        return;
    };
    let d = adw::AlertDialog::new(Some(&a.heading), Some(&a.body));
    d.add_response("deny", "Deny");
    d.add_response("allow", "Allow");
    d.set_response_appearance("allow", adw::ResponseAppearance::Suggested);
    d.set_default_response(Some("deny"));
    d.set_close_response("deny");
    let tx = a.answer;
    d.connect_response(None, move |_, r| {
        let _ = tx.send(r == "allow");
    });
    win.present();
    d.present(Some(&win));
}

// ---- Settings → Sharing ----------------------------------------------------

fn plain_row(title: &str) -> adw::ActionRow {
    let r = adw::ActionRow::new();
    r.set_use_markup(false);
    r.set_title(title);
    r.set_subtitle_selectable(true);
    r
}

fn pill(label: &str, class: Option<&str>) -> gtk::Button {
    let b = gtk::Button::with_label(label);
    b.set_valign(gtk::Align::Center);
    if let Some(c) = class {
        b.add_css_class(c);
    }
    b
}

/// Run something that blocks off the main thread, then report any error.
fn run_blocking(page: &adw::PreferencesPage, what: &'static str,
                work: impl FnOnce() -> Result<(), String> + Send + 'static) {
    let page = page.downgrade();
    glib::spawn_future_local(async move {
        let r = gio::spawn_blocking(work).await;
        let Some(page) = page.upgrade() else { return };
        match r {
            Ok(Ok(())) => {}
            Ok(Err(msg)) => alert(&page, what, &msg),
            Err(_) => alert(&page, what, "Something went wrong."),
        }
    });
}

fn when(secs: f64) -> String {
    glib::DateTime::from_unix_local(secs as i64)
        .ok()
        .and_then(|d| d.format("%b %-e, %H:%M").ok())
        .map(|s| s.to_string())
        .unwrap_or_default()
}

fn show_invite(page: &adw::PreferencesPage, code: &InviteCode) {
    let link = code.string();
    let d = adw::AlertDialog::new(
        Some("Invite ready"),
        Some("Send this link to them directly. It works once and expires in 15 minutes."),
    );
    let label = gtk::Label::new(Some(&link));
    label.set_selectable(true);
    label.set_wrap(true);
    label.set_wrap_mode(gtk::pango::WrapMode::Char);
    label.set_max_width_chars(48);
    label.add_css_class("monospace");
    d.set_extra_child(Some(&label));
    d.add_response("close", "Close");
    d.add_response("copy", "Copy link");
    d.set_response_appearance("copy", adw::ResponseAppearance::Suggested);
    d.set_default_response(Some("copy"));
    d.set_close_response("close");
    let weak = page.downgrade();
    d.connect_response(None, move |_, r| {
        if r == "copy" {
            if let Some(p) = weak.upgrade() {
                p.clipboard().set_text(&link);
            }
        }
    });
    d.present(Some(page));
}

/// Settings → Sharing: the switch, the setup steps, invites and guests.
pub fn sharing_page() -> gtk::Widget {
    let page = adw::PreferencesPage::new();
    page.set_title("Sharing");
    page.set_icon_name(Some("network-server-symbolic"));

    // -- the switch
    let main = adw::PreferencesGroup::new();
    main.set_title("Remote sessions");
    main.set_description(Some(
        "Let one specific person ssh into this computer over Tailscale, with an invite you \
         send them. Access lasts while this is on, even if shh is closed.",
    ));
    let switch = adw::SwitchRow::new();
    switch.set_title("Allow remote sessions");
    let status = plain_row("Status");
    main.add(&switch);
    main.add(&status);
    page.add(&main);

    // -- setup
    let setup = adw::PreferencesGroup::new();
    setup.set_title("Setup");
    let recheck = pill("Check again", Some("flat"));
    setup.set_header_suffix(Some(&recheck));
    let ts_row = plain_row("Tailscale");
    let ts_btn = pill("Get Tailscale", None);
    ts_row.add_suffix(&ts_btn);
    let ssh_row = plain_row("SSH server");
    let ssh_btn = pill("Turn on", Some("suggested-action"));
    ssh_row.add_suffix(&ssh_btn);
    setup.add(&ts_row);
    setup.add(&ssh_row);
    page.add(&setup);

    // -- invites
    let invites = adw::PreferencesGroup::new();
    invites.set_title("Invites");
    invites.set_description(Some("An invite works once and expires after 15 minutes."));
    let new_btn = pill("New invite", Some("suggested-action"));
    invites.set_header_suffix(Some(&new_btn));
    let label_row = adw::EntryRow::new();
    label_row.set_title("Who is it for? (optional)");
    invites.add(&label_row);
    page.add(&invites);

    // -- guests
    let guests = adw::PreferencesGroup::new();
    guests.set_title("People with access");
    page.add(&guests);

    let dynamic: Rc<RefCell<Vec<(adw::PreferencesGroup, gtk::Widget)>>> = Rc::default();
    let updating = Rc::new(Cell::new(false));
    let ssh_installed = Rc::new(Cell::new(true));

    let refresh: Rc<dyn Fn()> = {
        let (switch, status, ts_row, ts_btn, ssh_row, ssh_btn) =
            (switch.clone(), status.clone(), ts_row.clone(), ts_btn.clone(), ssh_row.clone(), ssh_btn.clone());
        let (setup, invites, guests, new_btn, label_row) =
            (setup.clone(), invites.clone(), guests.clone(), new_btn.clone(), label_row.clone());
        let (dynamic, updating, ssh_installed) = (dynamic.clone(), updating.clone(), ssh_installed.clone());
        Rc::new(move || {
            let s: Snapshot = access::snapshot();
            let on = s.file.enabled;
            updating.set(true);
            switch.set_active(on);
            updating.set(false);

            status.set_subtitle(&match &s.status {
                Status::Off => "Off".to_string(),
                Status::Starting => "Starting…".to_string(),
                Status::Listening(me) if s.is_ready() => format!(
                    "Ready. Reachable at {}",
                    if me.dns_name.is_empty() { &me.ipv4 } else { &me.dns_name }
                ),
                Status::Listening(me) => {
                    format!("Listening on {}:{}. Finish the setup below.", me.ipv4, access::port())
                }
                Status::Problem(m) => m.clone(),
            });

            ts_btn.set_visible(!s.tailscale_installed);
            ts_row.set_subtitle(&if !s.tailscale_installed {
                "Not installed. Needed on both computers.".to_string()
            } else {
                match &s.status {
                    Status::Listening(me) => format!(
                        "Connected as {} ({})",
                        if me.dns_name.is_empty() { &me.host_name } else { &me.dns_name },
                        me.ipv4
                    ),
                    Status::Problem(m) => m.clone(),
                    _ => "Installed".to_string(),
                }
            });

            ssh_installed.set(s.sshd_installed);
            let (ssh_text, ssh_action) = if !s.sshd_installed {
                (format!("Not installed. Install it here, or run:  {}", access::INSTALL_HINT), Some("Install"))
            } else {
                match s.sshd_on {
                    None => ("Checking…".to_string(), None),
                    Some(true) if s.host_key_ready => ("On".to_string(), None),
                    Some(true) => ("On, but it has no host key yet.".to_string(), None),
                    Some(false) => ("Off. People you invite sign in through it.".to_string(), Some("Turn on")),
                }
            };
            ssh_row.set_subtitle(&ssh_text);
            ssh_btn.set_visible(ssh_action.is_some());
            if let Some(a) = ssh_action {
                ssh_btn.set_label(a);
            }

            setup.set_visible(on || !s.sshd_installed || !s.tailscale_installed);
            invites.set_visible(on);
            guests.set_visible(on || !s.file.guests.is_empty());
            new_btn.set_sensitive(s.is_ready());
            label_row.set_sensitive(s.is_ready());

            for (group, row) in dynamic.borrow_mut().drain(..) {
                group.remove(&row);
            }
            let now = crate::sys::now();
            for inv in &s.file.invites {
                let row = plain_row(&inv.label);
                let mins = ((inv.expires - now) / 60.0).ceil().max(0.0) as i64;
                row.set_subtitle(&format!("Waiting to be used · expires in {mins} min"));
                let cancel = pill("Cancel", None);
                let id = inv.id.clone();
                cancel.connect_clicked(move |_| access::cancel_invite(&id));
                row.add_suffix(&cancel);
                invites.add(&row);
                dynamic.borrow_mut().push((invites.clone(), row.upcast()));
            }
            if s.file.guests.is_empty() {
                let row = plain_row("Nobody yet");
                row.set_subtitle("People appear here once you allow their invite.");
                guests.add(&row);
                dynamic.borrow_mut().push((guests.clone(), row.upcast()));
            }
            for g in &s.file.guests {
                let row = plain_row(if g.display_name.is_empty() { &g.login } else { &g.display_name });
                row.set_subtitle(&format!("{} · {} · since {}", g.login, g.node, when(g.added)));
                let revoke = pill("Revoke", Some("destructive-action"));
                let id = g.id.clone();
                revoke.connect_clicked(move |_| {
                    let id = id.clone();
                    std::thread::spawn(move || access::revoke(&id));
                });
                row.add_suffix(&revoke);
                guests.add(&row);
                dynamic.borrow_mut().push((guests.clone(), row.upcast()));
            }
        })
    };

    {
        let updating = updating.clone();
        switch.connect_active_notify(move |sw| {
            if updating.get() {
                return;
            }
            let on = sw.is_active();
            std::thread::spawn(move || access::set_enabled(on));
        });
    }
    {
        let refresh = refresh.clone();
        recheck.connect_clicked(move |_| {
            access::recheck();
            refresh();
        });
    }
    ts_btn.connect_clicked(|_| {
        let _ = gio::AppInfo::launch_default_for_uri(
            "https://tailscale.com/download/linux",
            gio::AppLaunchContext::NONE,
        );
    });
    {
        let page = page.clone();
        let ssh_installed = ssh_installed.clone();
        ssh_btn.connect_clicked(move |_| {
            if ssh_installed.get() {
                run_blocking(&page, "Couldn't turn on the ssh server", access::turn_on_sshd_blocking);
            } else {
                run_blocking(&page, "Couldn't install the ssh server", access::install_sshd_blocking);
            }
        });
    }
    {
        let page = page.clone();
        let label_row = label_row.clone();
        new_btn.connect_clicked(move |_| match access::create_invite(&label_row.text()) {
            Ok(code) => {
                label_row.set_text("");
                show_invite(&page, &code);
            }
            Err(msg) => alert(&page, "Couldn't make an invite", &msg),
        });
    }

    // Everything that changes does so on other threads; follow the generation.
    refresh();
    access::check_sshd();
    let seen = Cell::new(access::generation());
    let weak = page.downgrade();
    let ticks = Cell::new(0u32);
    glib::timeout_add_local(Duration::from_millis(400), move || {
        if weak.upgrade().is_none() {
            return glib::ControlFlow::Break;
        }
        let g = access::generation();
        ticks.set(ticks.get() + 1);
        // every half minute regardless, so "expires in" counts down
        if g != seen.get() || ticks.get() % 75 == 0 {
            seen.set(g);
            refresh();
        }
        glib::ControlFlow::Continue
    });

    page.upcast()
}

// ---- joining someone else's machine ----------------------------------------

/// Paste or accept a shh://join link: make a key, redeem the invite, trust the
/// host key and save the server (key auth). `on_joined` gets the saved server.
pub fn join_dialog(parent: &gtk::Window, url: Option<String>,
                   on_joined: Rc<dyn Fn(shh_core::server::Server)>) {
    let d = adw::AlertDialog::new(
        Some("Join with invite"),
        Some("Paste the shh:// link you were sent. Tailscale needs to be connected here too."),
    );
    let entry = gtk::Entry::new();
    entry.set_placeholder_text(Some("shh://join?…"));
    entry.set_width_chars(44);
    entry.set_activates_default(true);
    if let Some(u) = &url {
        entry.set_text(u);
    }
    d.set_extra_child(Some(&entry));
    d.add_response("cancel", "Cancel");
    d.add_response("join", "Join");
    d.set_response_appearance("join", adw::ResponseAppearance::Suggested);
    d.set_default_response(Some("join"));
    d.set_close_response("cancel");
    let win = parent.clone();
    d.connect_response(None, move |_, r| {
        if r != "join" {
            return;
        }
        match InviteCode::parse(&entry.text()) {
            Some(invite) => redeem(&win, invite, on_joined.clone()),
            None => alert(&win, "That isn't a shh invite", "The link should start with shh://join."),
        }
    });
    d.present(Some(parent));
}

fn redeem(parent: &gtk::Window, invite: InviteCode, on_joined: Rc<dyn Fn(shh_core::server::Server)>) {
    let waiting = adw::AlertDialog::new(
        Some(&format!("Waiting for {}", invite.host_label)),
        Some("They're being asked to allow you, by your Tailscale account and device. \
              This finishes on its own once they answer."),
    );
    let spinner = gtk::Spinner::new();
    spinner.set_spinning(true);
    waiting.set_extra_child(Some(&spinner));
    waiting.add_response("hide", "Hide");
    waiting.set_close_response("hide");
    waiting.present(Some(parent));

    let win = parent.clone();
    glib::spawn_future_local(async move {
        let r = gio::spawn_blocking(move || join::redeem(&invite)).await;
        waiting.force_close();
        match r {
            Ok(Ok(joined)) => {
                let label = joined.label.clone();
                // the server's `name` is only a slug; keep the name they go by
                let mut st = shh_core::meta::Store::load();
                st.file.servers.entry(joined.server.name.clone()).or_default().display_name =
                    Some(label.clone());
                st.save();
                on_joined(joined.server);
                alert(&win, "You're in", &format!("{label} was added to your servers."));
            }
            Ok(Err(e)) => alert(&win, "Couldn't join", &e.to_string()),
            Err(_) => alert(&win, "Couldn't join", "Something went wrong."),
        }
    });
}
