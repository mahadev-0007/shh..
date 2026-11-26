//! A window with one page from this crate in it, for looking at it without the
//! whole app. Needs the same `root@127.0.0.1` / `hunter2` sshd as tests/live.rs.
//!
//!     cargo run -p shh-remote --example files -- [browser|home|picker|sessions] [start path]

use adw::prelude::*;
use base64::Engine;
use shh_core::server::Server;
use shh_remote::ui::{self, ActiveSession};
use std::rc::Rc;

fn main() {
    let which = std::env::args().nth(1).unwrap_or_else(|| "browser".into());
    let start = std::env::args().nth(2);
    let app = adw::Application::builder().application_id("io.github.mahadev_0007.shh.example").build();
    app.connect_activate(move |app| {
        let start = start.clone();
        let server = Server {
            name: "local-box".into(),
            host: "127.0.0.1".into(),
            user: "root".into(),
            port: "22".into(),
            auth: "pass".into(),
            secret: base64::engine::general_purpose::STANDARD.encode("hunter2"),
        };
        let window = adw::ApplicationWindow::builder().application(app).title("shh example")
            .default_width(1100).default_height(720).build();
        let holder = adw::Bin::new();
        let view = adw::ToolbarView::new();
        view.add_top_bar(&adw::HeaderBar::new());
        view.set_content(Some(&holder));
        window.set_content(Some(&view));
        let content: gtk::Widget = match which.as_str() {
            "home" => ui::files_home_with(vec![server.clone()],
                vec![("Demo App".into(), server.clone(), "/srv/demo".into())]),
            "sessions" => ui::sessions_page_with(
                vec![server.clone()],
                Rc::new(|s, name| println!("attach {} {name}", s.name)),
                vec![ActiveSession {
                    id: "1".into(), title: "Demo App".into(),
                    subtitle: "local-box · /srv/demo".into(), state: "running".into(),
                    tmux_name: Some("shh-demo-app-1-0751".into()), server_slug: "local-box".into(),
                }, ActiveSession {
                    id: "2".into(), title: "Demo App #2".into(),
                    subtitle: "local-box · /srv/demo".into(), state: "reconnecting".into(),
                    tmux_name: None, server_slug: "local-box".into(),
                }],
                Rc::new(|id| println!("focus {id}")),
                Rc::new(|id| println!("close {id}"))),
            "picker" => gtk::Label::new(Some("folder picker")).upcast(),
            _ => ui::files_browser(server.clone(), start.as_deref().unwrap_or("/srv")),
        };
        holder.set_child(Some(&content));
        window.present();
        if which == "picker" {
            ui::folder_picker(holder.upcast_ref(), server, start.unwrap_or_else(|| "~".into()),
                              Rc::new(|p| println!("picked {p}")));
        }
    });
    app.run_with_args::<&str>(&[]);
}
