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

/// How to run this program again. In the self-contained build the real
/// executable is started through a bundled loader, so /proc/self/exe is the
/// loader; the launcher script names itself in SHH_SELF instead.
pub fn self_path() -> Option<String> {
    match std::env::var("SHH_SELF") {
        Ok(p) if !p.is_empty() => Some(p),
        _ => std::env::current_exe().ok().map(|p| p.to_string_lossy().into_owned()),
    }
}

/// The self-contained build points GTK at its own data through environment
/// variables. Once GTK has read them, take them back out so programs this
/// one launches (a file opened in the host's image viewer) see the host's.
fn drop_bundle_env() {
    if std::env::var_os("SHH_BUNDLED").is_none() {
        return;
    }
    let _ = gio::SettingsSchemaSource::default();
    let _ = gtk::gdk_pixbuf::Pixbuf::formats();
    let _ = glib::system_data_dirs();
    std::env::remove_var("GDK_PIXBUF_MODULE_FILE");
    std::env::remove_var("GSETTINGS_SCHEMA_DIR");
    std::env::remove_var("GSK_RENDERER");
    match std::env::var("SHH_ORIG_XDG_DATA_DIRS") {
        Ok(v) if !v.is_empty() => std::env::set_var("XDG_DATA_DIRS", v),
        _ => std::env::remove_var("XDG_DATA_DIRS"),
    }
}

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

    application.connect_startup(|_| {
        // after the first frame's worth of setup, so the icon theme is loaded
        glib::idle_add_local_once(drop_bundle_env);
    });

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
