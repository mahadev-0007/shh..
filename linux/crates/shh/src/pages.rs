//! The pages behind the sidebar, and the editors they open.
use crate::app::App;
use adw::prelude::*;
use gtk::{gio, glib};
use shh_core::meta::{AgentDef, IconRef, Project, ServerMeta, DEFAULT_SHELL};
use shh_core::server::{self, Server};
use shh_core::{shell, slug};
use std::rc::Rc;

pub fn build(app: &Rc<App>, id: &str) -> gtk::Widget {
    match id {
        "projects" => projects(app),
        "servers" => servers(app),
        "sessions" => {
            let active: Vec<shh_remote::ui::ActiveSession> = app
                .sessions
                .borrow()
                .iter()
                .map(|s| shh_remote::ui::ActiveSession {
                    id: s.id.clone(),
                    title: s.title(),
                    subtitle: s.spec.server.display(),
                    state: match s.state() {
                        crate::session::State::Running => "running",
                        crate::session::State::Connecting => "connecting",
                        crate::session::State::Reconnecting { .. } => "reconnecting",
                        _ => "ended",
                    }
                    .to_string(),
                    tmux_name: s.tmux_name.borrow().clone(),
                    server_slug: s.spec.server.name.clone(),
                })
                .collect();
            let (a, a2, a3) = (app.clone(), app.clone(), app.clone());
            shh_remote::ui::sessions_page_with(
                app.servers.borrow().clone(),
                Rc::new(move |server: Server, name: String| a.attach(server, name)),
                active,
                Rc::new(move |id: String| {
                    let s = a2.sessions.borrow().iter().find(|s| s.id == id).cloned();
                    if let Some(s) = s {
                        a2.focus_session(&s);
                    }
                }),
                Rc::new(move |id: String| {
                    let s = a3.sessions.borrow().iter().find(|s| s.id == id).cloned();
                    if let Some(s) = s {
                        a3.close_session(&s);
                        a3.refresh();
                    }
                }),
            )
        }
        "files" => {
            let file = app.meta();
            let shortcuts = file
                .projects
                .iter()
                .filter_map(|p| Some((p.name.clone(), app.server(&p.server)?, p.path.clone())))
                .collect();
            shh_remote::ui::files_home_with(app.servers.borrow().clone(), shortcuts)
        }
        "sharing" => shh_sharing::ui::sharing_page(),
        "settings" => settings(app),
        _ => dashboard(app),
    }
}

// MARK: - small pieces

fn row(title: &str, subtitle: &str) -> adw::ActionRow {
    adw::ActionRow::builder().title(title).subtitle(subtitle).use_markup(false).build()
}

/// Any icon the Mac app can store, or the server's coloured dot.
fn icon_widget(icon: Option<&IconRef>, hue: Option<usize>) -> gtk::Widget {
    shh_icons::widget(icon, 28, rgb_of(hue))
}

fn rgb_of(hue: Option<usize>) -> (u8, u8, u8) {
    hue.map(|h| shh_core::server::PALETTE[h % 12]).unwrap_or((140, 140, 150))
}

/// A row holding the icon chip: click to pick, or drop an image on it.
fn icon_row(
    current: Option<IconRef>,
    hue: Option<usize>,
) -> (adw::ActionRow, Rc<std::cell::RefCell<Option<IconRef>>>) {
    let chosen = Rc::new(std::cell::RefCell::new(current.clone()));
    let r = row("Icon", "Emoji, symbol, logo or your own image — or drop an image here");
    let c = chosen.clone();
    let chip = shh_icons::chip(current, rgb_of(hue), Rc::new(move |i: Option<IconRef>| {
        *c.borrow_mut() = i;
    }));
    chip.set_valign(gtk::Align::Center);
    r.add_suffix(&chip);
    (r, chosen)
}

fn icon_button(icon: &str, tip: &str) -> gtk::Button {
    let b = gtk::Button::builder()
        .icon_name(icon)
        .tooltip_text(tip)
        .valign(gtk::Align::Center)
        .build();
    b.add_css_class("flat");
    b
}

fn page_of(groups: &[&adw::PreferencesGroup]) -> gtk::Widget {
    let page = adw::PreferencesPage::new();
    for g in groups {
        page.add(*g);
    }
    page.upcast()
}

fn empty(icon: &str, title: &str, body: &str, button: Option<(&str, &str)>) -> gtk::Widget {
    let sp = adw::StatusPage::builder().icon_name(icon).title(title).description(body).build();
    if let Some((label, action)) = button {
        let b = gtk::Button::builder()
            .label(label)
            .action_name(action)
            .halign(gtk::Align::Center)
            .build();
        b.add_css_class("pill");
        b.add_css_class("suggested-action");
        sp.set_child(Some(&b));
    }
    sp.upcast()
}

fn confirm(app: &Rc<App>, heading: &str, body: &str, verb: &str, then: impl Fn() + 'static) {
    let d = adw::AlertDialog::new(Some(heading), Some(body));
    d.add_response("cancel", "Cancel");
    d.add_response("go", verb);
    d.set_response_appearance("go", adw::ResponseAppearance::Destructive);
    d.connect_response(None, move |_, r| {
        if r == "go" {
            then();
        }
    });
    d.present(Some(&app.window));
}

// MARK: - dashboard

fn tile(value: &str, label: &str) -> gtk::Widget {
    let b = gtk::Box::new(gtk::Orientation::Vertical, 2);
    b.add_css_class("card");
    b.add_css_class("tile");
    b.set_hexpand(true);
    let v = gtk::Label::new(Some(value));
    v.add_css_class("big");
    v.set_xalign(0.0);
    let l = gtk::Label::new(Some(label));
    l.add_css_class("dim-label");
    l.set_xalign(0.0);
    b.append(&v);
    b.append(&l);
    b.upcast()
}

fn dashboard(app: &Rc<App>) -> gtk::Widget {
    let file = app.meta();
    let servers = app.servers.borrow().clone();
    if servers.is_empty() {
        return empty(
            "network-server-symbolic",
            "No servers yet",
            "Add a server, then a project on it, and open it with an agent in one click.",
            Some(("Add a server", "win.new-server")),
        );
    }
    let live: Vec<_> =
        app.sessions.borrow().iter().filter(|s| s.state().is_live()).cloned().collect();

    let tiles = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    app.check_reachability();
    let reach = app.reachable.borrow().clone();
    let online = reach.values().filter(|v| **v).count();
    let label = if reach.is_empty() {
        "servers · checking…".to_string()
    } else {
        format!("servers · {online} reachable")
    };
    tiles.append(&tile(&servers.len().to_string(), &label));
    tiles.append(&tile(&file.projects.len().to_string(), "projects"));
    tiles.append(&tile(&live.len().to_string(), "running now"));
    let top = adw::PreferencesGroup::new();
    top.add(&tiles);

    let running = adw::PreferencesGroup::new();
    running.set_title("Running now");
    for s in &live {
        let r = row(&s.title(), &s.spec.server.display());
        r.add_prefix(&icon_widget(None, Some(s.spec.server.hue())));
        r.set_activatable(true);
        let (a, s) = (app.clone(), s.clone());
        r.connect_activated(move |_| a.focus_session(&s));
        running.add(&r);
    }
    running.set_visible(!live.is_empty());

    let recent = adw::PreferencesGroup::new();
    recent.set_title("Recent projects");
    let mut ps = file.projects.clone();
    ps.sort_by(|a, b| b.last_opened_at.total_cmp(&a.last_opened_at));
    for p in ps.iter().take(8) {
        recent.add(&project_row(app, p, false));
    }
    if ps.is_empty() {
        let r = row("No projects yet", "A project is a directory on a server, opened with an agent.");
        let b = gtk::Button::builder()
            .label("New project")
            .action_name("win.new-project")
            .valign(gtk::Align::Center)
            .build();
        r.add_suffix(&b);
        recent.add(&r);
    }

    let quick = adw::PreferencesGroup::new();
    quick.set_title("Quick shell");
    for s in &servers {
        let r = row(&app.server_title(s), &s.display());
        let meta = file.servers.get(&s.name);
        r.add_prefix(&icon_widget(meta.and_then(|m| m.icon.as_ref()), Some(s.hue())));
        r.set_activatable(true);
        if reach.get(&s.name) == Some(&false) {
            let l = gtk::Label::new(Some("unreachable"));
            l.add_css_class("error");
            l.add_css_class("caption");
            r.add_suffix(&l);
        }
        r.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
        let (a, s) = (app.clone(), s.clone());
        r.connect_activated(move |_| a.open_shell(s.clone()));
        quick.add(&r);
    }
    page_of(&[&top, &running, &recent, &quick])
}

// MARK: - projects

fn project_row(app: &Rc<App>, p: &Project, with_actions: bool) -> adw::ActionRow {
    let file = app.meta();
    let server = app.server(&p.server);
    let agent = file.agent(p.agent.as_deref()).map(|a| a.name.clone()).unwrap_or("Shell".into());
    let subtitle = match &server {
        Some(s) => format!("{} · {} · {}", app.server_title(s), p.path, agent),
        None => format!("server missing · {}", p.server),
    };
    let r = row(&p.name, &subtitle);
    r.add_prefix(&icon_widget(
        p.icon.as_ref().or(Some(&IconRef::emoji("📁"))),
        server.as_ref().map(|s| s.hue()),
    ));
    r.set_sensitive(server.is_some() || with_actions);
    r.set_activatable(server.is_some());
    let (a, id) = (app.clone(), p.id.clone());
    r.connect_activated(move |_| a.open_project(&id, false));
    if with_actions {
        let dup = icon_button("tab-new-symbolic", "Open another session");
        let (a, id) = (app.clone(), p.id.clone());
        dup.connect_clicked(move |_| a.open_project(&id, true));
        dup.set_sensitive(server.is_some());
        let edit = icon_button("document-edit-symbolic", "Edit");
        let (a, id) = (app.clone(), p.id.clone());
        edit.connect_clicked(move |_| edit_project(&a, Some(&id)));
        r.add_suffix(&dup);
        r.add_suffix(&edit);
    }
    r
}

fn projects(app: &Rc<App>) -> gtk::Widget {
    let file = app.meta();
    if file.projects.is_empty() {
        return empty(
            "folder-symbolic",
            "No projects yet",
            "A project is a directory on a server that opens with an agent — Claude Code, Codex, a plain shell.",
            Some(("New project", "win.new-project")),
        );
    }
    // one group per server, orphans last
    let mut groups: Vec<adw::PreferencesGroup> = Vec::new();
    let servers = app.servers.borrow().clone();
    let mut keys: Vec<String> = servers.iter().map(|s| s.name.clone()).collect();
    for p in &file.projects {
        if !keys.contains(&p.server) {
            keys.push(p.server.clone());
        }
    }
    for key in keys {
        let mut ps: Vec<&Project> = file.projects.iter().filter(|p| p.server == key).collect();
        if ps.is_empty() {
            continue;
        }
        ps.sort_by_key(|p| p.order);
        let g = adw::PreferencesGroup::new();
        match servers.iter().find(|s| s.name == key) {
            Some(s) => {
                g.set_title(&glib::markup_escape_text(&app.server_title(s)));
                g.set_description(Some(&glib::markup_escape_text(&s.display())));
            }
            None => {
                g.set_title(&glib::markup_escape_text(&key));
                g.set_description(Some("This server is no longer in servers.conf"));
            }
        }
        for p in ps {
            g.add(&project_row(app, p, true));
        }
        groups.push(g);
    }
    let refs: Vec<&adw::PreferencesGroup> = groups.iter().collect();
    page_of(&refs)
}

// MARK: - servers

fn servers(app: &Rc<App>) -> gtk::Widget {
    let list = app.servers.borrow().clone();
    if list.is_empty() {
        return empty(
            "network-server-symbolic",
            "No servers yet",
            "Servers live in ~/.config/sshm/servers.conf, shared with the sshm terminal UI.",
            Some(("Add a server", "win.new-server")),
        );
    }
    let file = app.meta();
    let g = adw::PreferencesGroup::new();
    g.set_title("Servers");
    let add = gtk::Button::builder().label("Add server").action_name("win.new-server").build();
    add.add_css_class("flat");
    g.set_header_suffix(Some(&add));
    for s in &list {
        let count = file.projects.iter().filter(|p| p.server == s.name).count();
        let sub = format!(
            "{} · {} · {} project{}",
            s.display(),
            if s.auth == "key" { "key" } else { "password" },
            count,
            if count == 1 { "" } else { "s" }
        );
        let r = row(&app.server_title(s), &sub);
        let meta = file.servers.get(&s.name);
        r.add_prefix(&icon_widget(meta.and_then(|m| m.icon.as_ref()), Some(s.hue())));
        r.set_activatable(true);
        let (a, sv) = (app.clone(), s.clone());
        r.connect_activated(move |_| a.open_shell(sv.clone()));
        let shell_btn = gtk::Button::builder().label("Shell").valign(gtk::Align::Center).build();
        let (a, sv) = (app.clone(), s.clone());
        shell_btn.connect_clicked(move |_| a.open_shell(sv.clone()));
        let edit = icon_button("document-edit-symbolic", "Edit");
        let (a, slug) = (app.clone(), s.name.clone());
        edit.connect_clicked(move |_| edit_server(&a, Some(&slug)));
        r.add_suffix(&shell_btn);
        r.add_suffix(&edit);
        g.add(&r);
    }
    page_of(&[&g])
}

/// A dialog with a header carrying Cancel / Save around a preferences page.
fn form(title: &str, groups: &[&adw::PreferencesGroup]) -> (adw::Dialog, gtk::Button) {
    let page = adw::PreferencesPage::new();
    for g in groups {
        page.add(*g);
    }
    let header = adw::HeaderBar::new();
    header.set_show_start_title_buttons(false);
    header.set_show_end_title_buttons(false);
    let cancel = gtk::Button::with_label("Cancel");
    let save = gtk::Button::with_label("Save");
    save.add_css_class("suggested-action");
    header.pack_start(&cancel);
    header.pack_end(&save);
    let view = adw::ToolbarView::new();
    view.add_top_bar(&header);
    view.set_content(Some(&page));
    let dialog = adw::Dialog::builder()
        .title(title)
        .content_width(560)
        .content_height(620)
        .child(&view)
        .build();
    let d = dialog.clone();
    cancel.connect_clicked(move |_| {
        d.close();
    });
    (dialog, save)
}

pub fn edit_server(app: &Rc<App>, slug_in: Option<&str>) {
    let existing = slug_in.and_then(|s| app.server(s));
    let old_slug = existing.as_ref().map(|s| s.name.clone());
    let title = existing.as_ref().map(|s| app.server_title(s)).unwrap_or_default();

    let name = adw::EntryRow::builder().title("Name").text(title).build();
    let host = adw::EntryRow::builder()
        .title("Host")
        .text(existing.as_ref().map(|s| s.host.clone()).unwrap_or_default())
        .build();
    let user = adw::EntryRow::builder()
        .title("User")
        .text(existing.as_ref().map(|s| s.user.clone()).unwrap_or_else(|| "root".into()))
        .build();
    let port = adw::EntryRow::builder()
        .title("Port")
        .text(existing.as_ref().map(|s| s.port.clone()).unwrap_or_else(|| "22".into()))
        .build();
    let auth = adw::ComboRow::builder().title("Sign in with").build();
    auth.set_model(Some(&gtk::StringList::new(&["Password", "Key file"])));
    let is_key = existing.as_ref().map(|s| s.auth == "key").unwrap_or(false);
    auth.set_selected(if is_key { 1 } else { 0 });
    let pass = adw::PasswordEntryRow::builder().title("Password").build();
    let key = adw::EntryRow::builder().title("Private key path").build();
    if let Some(s) = &existing {
        if is_key {
            key.set_text(&s.secret);
        } else {
            pass.set_text(&s.password().unwrap_or_default());
        }
    } else {
        key.set_text("~/.ssh/id_ed25519");
    }
    pass.set_visible(!is_key);
    key.set_visible(is_key);
    let (p2, k2) = (pass.clone(), key.clone());
    auth.connect_selected_notify(move |c| {
        p2.set_visible(c.selected() == 0);
        k2.set_visible(c.selected() == 1);
    });

    let who = adw::PreferencesGroup::new();
    who.set_title("Server");
    who.set_description(Some(
        "The name becomes a slug in servers.conf, so `sshm <slug>` works in a terminal too.",
    ));
    for r in [&name, &host, &user, &port] {
        who.add(r);
    }
    let (icon_r, server_icon) = icon_row(
        old_slug.as_ref().and_then(|o| app.meta().servers.get(o).and_then(|m| m.icon.clone())),
        existing.as_ref().map(|s| s.hue()),
    );
    who.add(&icon_r);
    let how = adw::PreferencesGroup::new();
    how.set_title("Authentication");
    how.set_description(Some(
        "Passwords are stored base64-encoded in servers.conf (mode 0600). That is obfuscation, not encryption — prefer a key.",
    ));
    how.add(&auth);
    how.add(&pass);
    how.add(&key);

    let danger = adw::PreferencesGroup::new();
    if let Some(slug) = old_slug.clone() {
        let del = gtk::Button::with_label("Delete server");
        del.add_css_class("destructive-action");
        del.set_halign(gtk::Align::Start);
        danger.add(&del);
        let a = app.clone();
        del.connect_clicked(move |b| {
            let (a2, slug2) = (a.clone(), slug.clone());
            let dialog = b.ancestor(adw::Dialog::static_type()).and_downcast::<adw::Dialog>();
            confirm(
                &a,
                "Delete this server?",
                "Its projects are kept and shown as orphans until you remove or re-point them.",
                "Delete",
                move || {
                    server::remove(&slug2);
                    a2.mutate(|f| {
                        f.servers.remove(&slug2);
                    });
                    a2.reload_servers();
                    a2.refresh();
                    if let Some(d) = &dialog {
                        d.close();
                    }
                },
            );
        });
    }

    let (dialog, save) = form(
        if existing.is_some() { "Edit server" } else { "New server" },
        &[&who, &how, &danger],
    );
    let (a, d) = (app.clone(), dialog.clone());
    save.connect_clicked(move |_| {
        let display = name.text().trim().to_string();
        let (h, u) = (host.text().trim().to_string(), user.text().trim().to_string());
        let bad = |s: &str| s.contains('|') || s.contains('\n');
        if display.is_empty() || h.is_empty() || u.is_empty() {
            a.toast("Name, host and user are required");
            return;
        }
        let p = port.text().trim().to_string();
        let p = if p.is_empty() { "22".to_string() } else { p };
        if p.parse::<u16>().is_err() {
            a.toast("Port must be a number");
            return;
        }
        let by_key = auth.selected() == 1;
        let secret = if by_key {
            key.text().trim().to_string()
        } else {
            let pw = pass.text().to_string();
            if pw.is_empty() { String::new() } else { Server::encode_password(&pw) }
        };
        if bad(&h) || bad(&u) || bad(&secret) {
            a.toast("Fields can't contain | — it is the separator in servers.conf");
            return;
        }
        let taken = server::slugs();
        let new_slug = slug::unique(&display, &taken, old_slug.as_deref());
        let s = Server {
            name: new_slug.clone(),
            host: h,
            user: u,
            port: p,
            auth: if by_key { "key".into() } else { "pass".into() },
            secret,
        };
        server::update(s, old_slug.as_deref().unwrap_or(&new_slug));
        let old = old_slug.clone();
        a.mutate(|f| {
            // carry the icon and the projects across a rename
            let mut m: ServerMeta =
                old.as_ref().and_then(|o| f.servers.remove(o)).unwrap_or_default();
            m.display_name = Some(display.clone());
            m.icon = server_icon.borrow().clone();
            f.servers.insert(new_slug.clone(), m);
            if let Some(o) = &old {
                if *o != new_slug {
                    for p in f.projects.iter_mut().filter(|p| p.server == *o) {
                        p.server = new_slug.clone();
                    }
                }
            }
        });
        a.reload_servers();
        a.refresh();
        d.close();
    });
    dialog.present(Some(&app.window));
}

pub fn edit_project(app: &Rc<App>, id: Option<&str>) {
    let file = app.meta();
    let servers = app.servers.borrow().clone();
    if servers.is_empty() {
        app.toast("Add a server first");
        edit_server(app, None);
        return;
    }
    let existing = id.and_then(|i| file.projects.iter().find(|p| p.id == i).cloned());

    let name = adw::EntryRow::builder()
        .title("Name")
        .text(existing.as_ref().map(|p| p.name.clone()).unwrap_or_default())
        .build();
    let (icon, project_icon) = icon_row(
        existing.as_ref().and_then(|p| p.icon.clone()).or(Some(IconRef::emoji("📁"))),
        existing.as_ref().and_then(|p| app.server(&p.server)).map(|s| s.hue()),
    );
    let server_row = adw::ComboRow::builder().title("Server").build();
    let titles: Vec<String> = servers.iter().map(|s| app.server_title(s)).collect();
    let title_refs: Vec<&str> = titles.iter().map(String::as_str).collect();
    server_row.set_model(Some(&gtk::StringList::new(&title_refs)));
    let sel = existing
        .as_ref()
        .and_then(|p| servers.iter().position(|s| s.name == p.server))
        .unwrap_or(0);
    server_row.set_selected(sel as u32);
    let path = adw::EntryRow::builder()
        .title("Directory on the server")
        .text(existing.as_ref().map(|p| p.path.clone()).unwrap_or_else(|| "~".into()))
        .build();

    let agent_row = adw::ComboRow::builder().title("Opens with").build();
    let default_name = file.agent(None).map(|a| a.name.clone()).unwrap_or("Shell".into());
    let mut names = vec![format!("Default ({default_name})")];
    names.extend(file.agents.iter().map(|a| a.name.clone()));
    let name_refs: Vec<&str> = names.iter().map(String::as_str).collect();
    agent_row.set_model(Some(&gtk::StringList::new(&name_refs)));
    let asel = existing
        .as_ref()
        .and_then(|p| p.agent.as_ref())
        .and_then(|id| file.agents.iter().position(|a| &a.id == id))
        .map(|i| i + 1)
        .unwrap_or(0);
    agent_row.set_selected(asel as u32);

    let what = adw::PreferencesGroup::new();
    what.set_title("Project");
    what.add(&name);
    what.add(&icon);
    what.add(&server_row);
    // browse the server for the directory instead of typing it
    let browse = gtk::Button::builder().label("Browse…").valign(gtk::Align::Center).build();
    browse.add_css_class("flat");
    path.add_suffix(&browse);
    {
        let (servers, server_row, path) = (servers.clone(), server_row.clone(), path.clone());
        browse.connect_clicked(move |b| {
            let s = servers[(server_row.selected() as usize).min(servers.len() - 1)].clone();
            let p2 = path.clone();
            shh_remote::ui::folder_picker(
                b.upcast_ref::<gtk::Widget>(),
                s,
                path.text().to_string(),
                Rc::new(move |picked: String| p2.set_text(&picked)),
            );
        });
    }
    what.add(&path);
    what.add(&agent_row);

    // the exact shape of what will run
    let preview = gtk::Label::new(None);
    preview.add_css_class("monospace");
    preview.add_css_class("dim-label");
    preview.set_xalign(0.0);
    preview.set_wrap(true);
    preview.set_selectable(true);
    let runs = adw::PreferencesGroup::new();
    runs.set_title("What runs");
    runs.add(&preview);

    let update: Rc<dyn Fn()> = {
        let (file, servers, app) = (file.clone(), servers.clone(), app.clone());
        let (preview, server_row, path, agent_row) =
            (preview.clone(), server_row.clone(), path.clone(), agent_row.clone());
        Rc::new(move || {
            let s = &servers[(server_row.selected() as usize).min(servers.len() - 1)];
            let agent = match agent_row.selected() as usize {
                0 => file.agent(None),
                i => file.agents.get(i - 1),
            };
            let durable = app.settings().durable_sessions;
            let p = path.text().to_string();
            preview.set_text(&shell::preview(&s.target(), Some(p.as_str()), agent, durable));
        })
    };
    update();
    let u = update.clone();
    path.connect_changed(move |_| u());
    let u = update.clone();
    server_row.connect_selected_notify(move |_| u());
    let u = update.clone();
    agent_row.connect_selected_notify(move |_| u());

    let danger = adw::PreferencesGroup::new();
    if let Some(p) = existing.clone() {
        let del = gtk::Button::with_label("Delete project");
        del.add_css_class("destructive-action");
        del.set_halign(gtk::Align::Start);
        danger.add(&del);
        let a = app.clone();
        del.connect_clicked(move |b| {
            let (a2, pid) = (a.clone(), p.id.clone());
            let dialog = b.ancestor(adw::Dialog::static_type()).and_downcast::<adw::Dialog>();
            confirm(
                &a,
                "Delete this project?",
                "Only the shortcut is removed. Nothing on the server is touched.",
                "Delete",
                move || {
                    a2.mutate(|f| f.projects.retain(|x| x.id != pid));
                    a2.refresh();
                    if let Some(d) = &dialog {
                        d.close();
                    }
                },
            );
        });
    }

    let (dialog, save) = form(
        if existing.is_some() { "Edit project" } else { "New project" },
        &[&what, &runs, &danger],
    );
    let (a, d) = (app.clone(), dialog.clone());
    save.connect_clicked(move |_| {
        let n = name.text().trim().to_string();
        let p = path.text().trim().to_string();
        if n.is_empty() {
            a.toast("Give the project a name");
            return;
        }
        if !shell::is_safe(&p) {
            a.toast("The directory can't contain a newline");
            return;
        }
        let s = &servers[(server_row.selected() as usize).min(servers.len() - 1)];
        let agent_id = match agent_row.selected() as usize {
            0 => None,
            i => file.agents.get(i - 1).map(|x| x.id.clone()),
        };
        let icon_ref = project_icon.borrow().clone();
        let existing = existing.clone();
        let server_slug = s.name.clone();
        let is_new = existing.is_none();
        a.mutate(|f| match &existing {
            Some(old) => {
                if let Some(x) = f.projects.iter_mut().find(|x| x.id == old.id) {
                    x.name = n;
                    x.path = if p.is_empty() { "~".into() } else { p };
                    x.server = server_slug;
                    x.agent = agent_id;
                    x.icon = icon_ref;
                }
            }
            None => {
                let mut np = Project::new(&n, &server_slug, if p.is_empty() { "~" } else { &p });
                np.agent = agent_id;
                np.icon = icon_ref;
                np.order = f.projects.iter().map(|x| x.order).max().unwrap_or(-1) + 1;
                f.projects.push(np);
            }
        });
        if is_new {
            a.show_page("projects");
        } else {
            a.refresh();
        }
        d.close();
    });
    dialog.present(Some(&app.window));
}

// MARK: - settings

fn switch(
    app: &Rc<App>,
    title: &str,
    subtitle: &str,
    get: fn(&shh_core::meta::AppSettings) -> bool,
    set: fn(&mut shh_core::meta::AppSettings, bool),
) -> adw::SwitchRow {
    let r = adw::SwitchRow::builder().title(title).subtitle(subtitle).build();
    r.set_active(get(&app.settings()));
    let a = app.clone();
    r.connect_active_notify(move |r| {
        let v = r.is_active();
        a.mutate(|f| set(&mut f.settings, v));
    });
    r
}

fn settings(app: &Rc<App>) -> gtk::Widget {
    let file = app.meta();

    // Agents
    let agents = adw::PreferencesGroup::new();
    agents.set_title("Agents");
    agents.set_description(Some(
        "What a project opens with. If a tool is set up in ~/.bashrc or ~/.zshrc rather than a profile file, keep -i in its shell.",
    ));
    let add = gtk::Button::with_label("Add agent");
    add.add_css_class("flat");
    agents.set_header_suffix(Some(&add));
    let a = app.clone();
    add.connect_clicked(move |_| {
        let id = format!("custom-{}", &shh_core::meta::new_id()[..8].to_lowercase());
        a.mutate(|f| {
            f.agents.push(AgentDef {
                id,
                name: "New agent".into(),
                icon: None,
                command: String::new(),
                shell: DEFAULT_SHELL.into(),
                keep_shell: true,
                builtin: false,
            })
        });
        a.refresh();
    });
    let default_row = adw::ComboRow::builder().title("Default agent").build();
    let names: Vec<&str> = file.agents.iter().map(|a| a.name.as_str()).collect();
    default_row.set_model(Some(&gtk::StringList::new(&names)));
    if let Some(i) = file.agents.iter().position(|a| a.id == file.settings.default_agent) {
        default_row.set_selected(i as u32);
    }
    let (a, ids) = (app.clone(), file.agents.iter().map(|a| a.id.clone()).collect::<Vec<_>>());
    default_row.connect_selected_notify(move |c| {
        if let Some(id) = ids.get(c.selected() as usize).cloned() {
            a.mutate(|f| f.settings.default_agent = id);
        }
    });
    agents.add(&default_row);
    for ag in &file.agents {
        let ex = adw::ExpanderRow::builder()
            .title(glib::markup_escape_text(&ag.name))
            .subtitle(glib::markup_escape_text(if ag.command.is_empty() {
                "just cd there"
            } else {
                &ag.command
            }))
            .build();
        let field = |title: &str, value: &str, set: fn(&mut AgentDef, String)| {
            let e = adw::EntryRow::builder().title(title).text(value).show_apply_button(true).build();
            let (a, id) = (app.clone(), ag.id.clone());
            e.connect_apply(move |e| {
                let v = e.text().to_string();
                if !shell::is_safe(&v) {
                    a.toast("That can't contain a newline");
                    return;
                }
                a.mutate(|f| {
                    if let Some(x) = f.agents.iter_mut().find(|x| x.id == id) {
                        set(x, v);
                    }
                });
            });
            e
        };
        ex.add_prefix(&icon_widget(ag.icon.as_ref(), None));
        {
            let r = row("Icon", "");
            let (a, id) = (app.clone(), ag.id.clone());
            let chip = shh_icons::chip(ag.icon.clone(), rgb_of(None), Rc::new(move |i: Option<IconRef>| {
                a.mutate(|f| {
                    if let Some(x) = f.agents.iter_mut().find(|x| x.id == id) {
                        x.icon = i.clone();
                    }
                });
            }));
            chip.set_valign(gtk::Align::Center);
            r.add_suffix(&chip);
            ex.add_row(&r);
        }
        ex.add_row(&field("Name", &ag.name, |a, v| a.name = v));
        ex.add_row(&field("Command", &ag.command, |a, v| a.command = v));
        ex.add_row(&field("Shell wrapper", &ag.shell, |a, v| a.shell = v));
        let keep = adw::SwitchRow::builder()
            .title("Keep shell")
            .subtitle("Drop to a prompt in the project directory when the agent exits")
            .active(ag.keep_shell)
            .build();
        let (a, id) = (app.clone(), ag.id.clone());
        keep.connect_active_notify(move |r| {
            let v = r.is_active();
            a.mutate(|f| {
                if let Some(x) = f.agents.iter_mut().find(|x| x.id == id) {
                    x.keep_shell = v;
                }
            });
        });
        ex.add_row(&keep);
        let del = gtk::Button::with_label("Remove agent");
        del.add_css_class("flat");
        del.add_css_class("error");
        del.set_halign(gtk::Align::Start);
        del.set_margin_start(8);
        del.set_margin_top(6);
        del.set_margin_bottom(6);
        let (a, id) = (app.clone(), ag.id.clone());
        del.connect_clicked(move |_| {
            a.mutate(|f| f.agents.retain(|x| x.id != id));
            a.refresh();
        });
        ex.add_row(&del);
        agents.add(&ex);
    }

    // Sessions
    let sessions = adw::PreferencesGroup::new();
    sessions.set_title("Sessions");
    sessions.add(&switch(
        app,
        "Keep sessions alive",
        "Run each project's agent inside tmux on the server, so it survives a dropped connection",
        |s| s.durable_sessions,
        |s, v| s.durable_sessions = v,
    ));
    sessions.add(&switch(
        app,
        "Reconnect automatically",
        "Retry with backoff when the link drops; pauses while offline",
        |s| s.auto_reconnect,
        |s, v| s.auto_reconnect = v,
    ));
    sessions.add(&switch(
        app,
        "One connection per server",
        "Projects on the same server share an authenticated connection, so you sign in once",
        |s| s.share_connection_per_server,
        |s, v| s.share_connection_per_server = v,
    ));
    sessions.add(&switch(
        app,
        "Paste images",
        "Ctrl+Shift+V with an image on the clipboard uploads it and types its remote path",
        |s| s.paste_images_to_server,
        |s, v| s.paste_images_to_server = v,
    ));
    sessions.add(&switch(
        app,
        "Voice input",
        "Lend this computer's microphone to Claude Code's voice mode on the server",
        |s| s.voice_input,
        |s, v| s.voice_input = v,
    ));

    // Notifications
    let notes = adw::PreferencesGroup::new();
    notes.set_title("Notifications");
    notes.set_description(Some("Only for a session you are not currently looking at."));
    notes.add(&switch(app, "Terminal bell", "What most agents ring when they finish or need input",
        |s| s.notify_on_bell, |s, v| s.notify_on_bell = v));
    notes.add(&switch(app, "From the server",
        "Notifications a tool sends itself (OSC 9 / OSC 777). tmux filters most of these",
        |s| s.notify_on_remote, |s, v| s.notify_on_remote = v));
    notes.add(&switch(app, "Went quiet",
        "Guess a long run finished when output stops for 15 seconds. It misfires",
        |s| s.notify_on_idle, |s, v| s.notify_on_idle = v));
    notes.add(&switch(app, "Connection", "Dropped, reconnected, or exited with an error",
        |s| s.notify_on_disconnect, |s, v| s.notify_on_disconnect = v));
    notes.add(&switch(app, "Bell sound", "Play the system bell as well",
        |s| s.bell_sound, |s, v| s.bell_sound = v));

    // Appearance
    let look = adw::PreferencesGroup::new();
    look.set_title("Appearance");
    let theme = adw::ComboRow::builder().title("Theme").build();
    theme.set_model(Some(&gtk::StringList::new(&["Dark", "Light", "Follow system"])));
    theme.set_selected(match file.settings.theme.as_str() {
        "dark" => 0,
        "light" => 1,
        _ => 2,
    });
    let a = app.clone();
    theme.connect_selected_notify(move |c| {
        let v = ["dark", "light", "system"][(c.selected() as usize).min(2)];
        crate::app::apply_theme(v);
        a.mutate(|f| f.settings.theme = v.to_string());
    });
    look.add(&theme);
    let font = adw::SpinRow::with_range(8.0, 28.0, 1.0);
    font.set_title("Terminal font size");
    font.set_subtitle("Applies to sessions opened from now on");
    font.set_value(file.settings.font_size);
    let a = app.clone();
    font.connect_value_notify(move |r| {
        let v = r.value();
        a.mutate(|f| f.settings.font_size = v);
    });
    look.add(&font);

    // Config
    let config = adw::PreferencesGroup::new();
    config.set_title("Config");
    let dir = shh_core::paths::config_dir();
    let files = row("Config folder", &dir.to_string_lossy());
    let open = gtk::Button::builder().label("Open").valign(gtk::Align::Center).build();
    let a = app.clone();
    open.connect_clicked(move |_| {
        let uri = gio::File::for_path(shh_core::paths::config_dir()).uri();
        gtk::UriLauncher::new(&uri).launch(Some(&a.window), gio::Cancellable::NONE, |_| {});
    });
    files.add_suffix(&open);
    config.add(&files);
    let known: std::collections::HashSet<String> =
        app.servers.borrow().iter().map(|s| s.name.clone()).collect();
    let orphans = file.projects.iter().filter(|p| !known.contains(&p.server)).count();
    if orphans > 0 {
        let r = row(
            &format!("{orphans} orphaned project{}", if orphans == 1 { "" } else { "s" }),
            "They point at servers that are no longer in servers.conf",
        );
        let b = gtk::Button::builder().label("Remove").valign(gtk::Align::Center).build();
        b.add_css_class("destructive-action");
        let a = app.clone();
        b.connect_clicked(move |_| {
            let (a2, known) = (a.clone(), known.clone());
            confirm(&a, "Remove orphaned projects?", "This can't be undone.", "Remove", move || {
                a2.mutate(|f| f.projects.retain(|p| known.contains(&p.server)));
                a2.refresh();
            });
        });
        r.add_suffix(&b);
        config.add(&r);
    }
    if let Some(err) = &app.store.borrow().load_error {
        config.add(&row("sshm.json could not be read — it will not be overwritten", err));
    }

    // Updates: no Sparkle here; the .deb is replaced by apt, we only say when.
    let updates = adw::PreferencesGroup::new();
    updates.set_title("Updates");
    let ver = row("shh", &format!("Version {}", crate::VERSION));
    let check = gtk::Button::builder().label("Check now").valign(gtk::Align::Center).build();
    let a = app.clone();
    check.connect_clicked(move |b| {
        b.set_sensitive(false);
        let (a, b) = (a.clone(), b.clone());
        glib::spawn_future_local(async move {
            let latest = gio::spawn_blocking(latest_release).await.ok().flatten();
            b.set_sensitive(true);
            match latest {
                Some(tag) if newer(&tag, crate::VERSION) => a.toast(&format!(
                    "{tag} is available — install it with the install script or the .deb on GitHub"
                )),
                Some(_) => a.toast("You're up to date"),
                None => a.toast("Couldn't reach GitHub"),
            }
        });
    });
    ver.add_suffix(&check);
    updates.add(&ver);
    updates.add(&switch(app, "Check automatically", "Look for a new release when shh starts",
        |s| s.automatic_updates, |s, v| s.automatic_updates = v));

    page_of(&[&agents, &sessions, &notes, &look, &config, &updates])
}

pub fn latest_release() -> Option<String> {
    let url = format!("https://api.github.com/repos/{}/releases/latest", crate::REPO);
    let out = std::process::Command::new("curl")
        .args(["-fsSL", "--max-time", "10", "-H", "Accept: application/vnd.github+json", &url])
        .output()
        .ok()?;
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).ok()?;
    Some(v.get("tag_name")?.as_str()?.to_string())
}

pub fn newer(tag: &str, current: &str) -> bool {
    let parse = |s: &str| -> Vec<u64> {
        s.trim_start_matches('v').split('.').map(|p| p.parse().unwrap_or(0)).collect()
    };
    parse(tag) > parse(current)
}

// MARK: - command palette

/// Ctrl+Shift+P. Projects, servers, live sessions and actions in one list,
/// filtered as you type; Enter runs the first match.
pub fn palette(app: &Rc<App>) {
    type Run = Rc<dyn Fn(&Rc<App>)>;
    let mut items: Vec<(String, String, Run)> = Vec::new();
    let file = app.meta();

    for s in app.sessions.borrow().iter().filter(|s| s.state().is_live()) {
        let s2 = s.clone();
        items.push((
            format!("Switch to {}", s.title()),
            format!("running · {}", s.spec.server.display()),
            Rc::new(move |a| a.focus_session(&s2)),
        ));
    }
    let mut ps = file.projects.clone();
    ps.sort_by(|a, b| b.last_opened_at.total_cmp(&a.last_opened_at));
    for p in ps {
        let Some(server) = app.server(&p.server) else { continue };
        let id = p.id.clone();
        items.push((
            p.name.clone(),
            format!("project · {} · {}", app.server_title(&server), p.path),
            Rc::new(move |a| a.open_project(&id, false)),
        ));
    }
    for s in app.servers.borrow().iter() {
        let s2 = s.clone();
        items.push((
            format!("Shell on {}", app.server_title(s)),
            format!("server · {}", s.display()),
            Rc::new(move |a| a.open_shell(s2.clone())),
        ));
    }
    for (id, label, _) in crate::app::NAV {
        items.push((format!("Go to {label}"), "page".into(), Rc::new(move |a| a.show_page(id))));
    }
    let actions: [(&str, &str); 6] = [
        ("New project", "win.new-project"),
        ("New server", "win.new-server"),
        ("Join with invite", "win.join"),
        ("Reload config files", "win.reload"),
        ("Toggle focus mode", "win.focus-mode"),
        ("Toggle full screen", "win.fullscreen"),
    ];
    for (label, action) in actions {
        items.push((
            label.to_string(),
            "command".into(),
            Rc::new(move |a| {
                let _ = gtk::prelude::WidgetExt::activate_action(&a.window, action, None);
            }),
        ));
    }

    let entry = gtk::SearchEntry::new();
    entry.set_placeholder_text(Some("Search projects, servers or run a command…"));
    entry.set_margin_top(12);
    entry.set_margin_start(12);
    entry.set_margin_end(12);
    let list = gtk::ListBox::new();
    list.add_css_class("navigation-sidebar");
    list.set_selection_mode(gtk::SelectionMode::Browse);
    let mut haystack: Vec<String> = Vec::new();
    for (title, sub, _) in &items {
        let r = row(title, sub);
        r.set_activatable(true);
        list.append(&r);
        haystack.push(format!("{title} {sub}").to_lowercase());
    }
    let haystack = Rc::new(haystack);
    let query = Rc::new(std::cell::RefCell::new(String::new()));
    {
        let (h, q) = (haystack.clone(), query.clone());
        list.set_filter_func(move |r| {
            let q = q.borrow();
            let text = h.get(r.index().max(0) as usize).map(String::as_str).unwrap_or("");
            q.split_whitespace().all(|w| text.contains(w))
        });
    }
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(&list)
        .build();
    let body = gtk::Box::new(gtk::Orientation::Vertical, 8);
    body.append(&entry);
    body.append(&scroll);
    let dialog = adw::Dialog::builder()
        .content_width(560)
        .content_height(460)
        .child(&body)
        .build();

    let first_visible = {
        let (list, h, q) = (list.clone(), haystack.clone(), query.clone());
        move || -> Option<gtk::ListBoxRow> {
            let q = q.borrow();
            (0..h.len())
                .find(|i| q.split_whitespace().all(|w| h[*i].contains(w)))
                .and_then(|i| list.row_at_index(i as i32))
        }
    };
    {
        let (list, q, fv) = (list.clone(), query.clone(), first_visible.clone());
        entry.connect_search_changed(move |e| {
            *q.borrow_mut() = e.text().to_lowercase();
            list.invalidate_filter();
            list.select_row(fv().as_ref());
        });
    }
    let items = Rc::new(items);
    let run = {
        let (app, items, dialog) = (app.clone(), items.clone(), dialog.clone());
        Rc::new(move |index: i32| {
            if let Some((_, _, f)) = items.get(index.max(0) as usize) {
                dialog.close();
                f(&app);
            }
        })
    };
    {
        let run = run.clone();
        list.connect_row_activated(move |_, r| run(r.index()));
    }
    {
        let (list, run, fv) = (list.clone(), run.clone(), first_visible.clone());
        entry.connect_activate(move |_| {
            if let Some(r) = list.selected_row().or_else(|| fv()) {
                run(r.index());
            }
        });
    }
    // arrow keys move the selection while the cursor stays in the search box
    let keys = gtk::EventControllerKey::new();
    {
        let (list, h, q) = (list.clone(), haystack.clone(), query.clone());
        keys.connect_key_pressed(move |_, key, _, _| {
            let dir: i32 = match key {
                gtk::gdk::Key::Down => 1,
                gtk::gdk::Key::Up => -1,
                _ => return glib::Propagation::Proceed,
            };
            let q = q.borrow();
            let shown: Vec<i32> = (0..h.len())
                .filter(|i| q.split_whitespace().all(|w| h[*i].contains(w)))
                .map(|i| i as i32)
                .collect();
            if shown.is_empty() {
                return glib::Propagation::Stop;
            }
            let cur = list.selected_row().map(|r| r.index()).unwrap_or(-1);
            let pos = shown.iter().position(|i| *i == cur).map(|p| p as i32).unwrap_or(-1);
            let next = (pos + dir).clamp(0, shown.len() as i32 - 1);
            if let Some(r) = list.row_at_index(shown[next as usize]) {
                list.select_row(Some(&r));
                r.grab_focus();
            }
            glib::Propagation::Stop
        });
    }
    entry.add_controller(keys);
    // the search entry swallows Escape for itself; hand it to the dialog
    let d = dialog.clone();
    entry.connect_stop_search(move |_| {
        d.close();
    });
    list.select_row(list.row_at_index(0).as_ref());
    dialog.present(Some(&app.window));
    entry.grab_focus();
}
