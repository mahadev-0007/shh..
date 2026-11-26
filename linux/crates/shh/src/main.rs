//! shh for Ubuntu: GTK4 + libadwaita + VTE. The Mac app's twin — same config
//! files, same remote commands, native widgets.
mod app;
mod pages;
mod proxy;
mod session;

use adw::prelude::*;
use gtk::{gio, glib};

pub const APP_ID: &str = "io.github.mahadev_0007.shh";
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
pub const REPO: &str = "mahadev-0007/shh..";

fn main() -> glib::ExitCode {
    // helper mode: no GTK, just the pty relay (see proxy.rs)
    let args: Vec<String> = std::env::args().collect();
    if args.len() > 5 && args[1] == "--pty-proxy" && args[4] == "--" {
        std::process::exit(proxy::run(&args[2], &args[3], &args[5..]));
    }
    let application = adw::Application::builder()
        .application_id(APP_ID)
        .flags(gio::ApplicationFlags::HANDLES_OPEN)
        .build();

    // One window per process; a second launch (or a clicked shh:// link) lands
    // in the running instance through GApplication.
    let holder: std::rc::Rc<std::cell::RefCell<Option<std::rc::Rc<app::App>>>> = Default::default();

    let h = holder.clone();
    application.connect_activate(move |a| {
        let existing = h.borrow().clone();
        match existing {
            Some(app) => app.window.present(),
            None => {
                let app = app::App::new(a);
                app.window.present();
                *h.borrow_mut() = Some(app);
            }
        }
    });

    let h = holder.clone();
    application.connect_open(move |a, files, _| {
        a.activate();
        let app = h.borrow().clone();
        if let Some(app) = app {
            for f in files {
                let uri = f.uri().to_string();
                if uri.starts_with("shh:") {
                    app.join(Some(uri));
                }
            }
        }
    });

    application.run()
}
