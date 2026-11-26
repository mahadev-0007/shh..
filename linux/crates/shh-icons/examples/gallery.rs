//! Visual check: every mark, some symbols, the chip, and the picker.
use adw::prelude::*;
use shh_core::meta::IconRef;
use std::rc::Rc;

fn main() {
    let app = adw::Application::builder().application_id("io.github.mahadev_0007.shh.gallery").build();
    app.connect_activate(|app| {
        let col = gtk::Box::new(gtk::Orientation::Vertical, 14);
        col.set_margin_top(16);
        col.set_margin_start(16);
        let row = |title: &str, icons: Vec<IconRef>| {
            let r = gtk::Box::new(gtk::Orientation::Horizontal, 10);
            r.append(&gtk::Label::new(Some(title)));
            for i in icons {
                r.append(&shh_icons::widget(Some(&i), 40, (251, 113, 133)));
            }
            r
        };
        col.append(&row("marks", shh_icons::marks::IDS.iter().map(|m| IconRef::mark(m)).collect()));
        col.append(&row(
            "symbols",
            ["server.rack", "terminal.fill", "folder.fill", "globe", "lock.fill", "nope"]
                .iter()
                .map(|s| IconRef { kind: "symbol".into(), value: s.to_string() })
                .collect(),
        ));
        col.append(&row("emoji", vec![IconRef::emoji("🐳"), IconRef::emoji("📁")]));
        let chip = shh_icons::chip(Some(IconRef::mark("claude")), (52, 211, 153), Rc::new(|i| println!("{i:?}")));
        chip.set_halign(gtk::Align::Start);
        col.append(&chip);
        col.append(&shh_icons::widget(None, 40, (52, 211, 153)));
        let win = adw::ApplicationWindow::builder().application(app).default_width(1100).default_height(720).content(&col).build();
        win.present();
        let tab = std::env::var("TAB").unwrap_or_default();
        let c = chip.clone();
        gtk::glib::timeout_add_local_once(std::time::Duration::from_millis(800), move || {
            let cur = match tab.as_str() {
                "" => return,
                "mark" => IconRef::mark("claude"),
                k => IconRef { kind: k.into(), value: "x".into() },
            };
            shh_icons::pick(&c, Some(cur), Rc::new(|i| println!("{i:?}")));
        });
    });
    app.run();
}
