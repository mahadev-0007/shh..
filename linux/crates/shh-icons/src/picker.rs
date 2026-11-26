//! The icon picker: Emoji, Symbols, Logos, Custom — the Mac app's four tabs.
use crate::{catalog, marks, store, widget};
use adw::prelude::*;
use gtk::{gio, glib};
use shh_core::meta::IconRef;
use std::rc::Rc;

const CELL: i32 = 30;
const NEUTRAL: (u8, u8, u8) = (154, 153, 150);

fn flow() -> gtk::FlowBox {
    let f = gtk::FlowBox::new();
    f.set_selection_mode(gtk::SelectionMode::None);
    f.set_homogeneous(true);
    f.set_min_children_per_line(6);
    f.set_max_children_per_line(10);
    f.set_row_spacing(4);
    f.set_column_spacing(4);
    f.set_valign(gtk::Align::Start);
    f.set_margin_top(6);
    f.set_margin_bottom(12);
    f
}

fn clear(f: &gtk::FlowBox) {
    while let Some(c) = f.first_child() {
        f.remove(&c);
    }
}

fn cell(icon: &IconRef, tip: &str, choose: &Rc<dyn Fn(Option<IconRef>)>) -> gtk::Button {
    let b = gtk::Button::new();
    b.add_css_class("flat");
    b.set_child(Some(&widget(Some(icon), CELL, NEUTRAL)));
    b.set_tooltip_text(Some(tip));
    let (choose, icon) = (choose.clone(), icon.clone());
    b.connect_clicked(move |_| choose(Some(icon.clone())));
    b
}

fn scrolled(child: &impl IsA<gtk::Widget>) -> gtk::ScrolledWindow {
    gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(child)
        .build()
}

fn page(top: &[&gtk::Widget], grid: &gtk::FlowBox) -> gtk::Box {
    let b = gtk::Box::new(gtk::Orientation::Vertical, 8);
    b.set_margin_top(12);
    b.set_margin_start(14);
    b.set_margin_end(14);
    for w in top {
        b.append(*w);
    }
    b.append(&scrolled(grid));
    b
}

fn emoji_page(choose: &Rc<dyn Fn(Option<IconRef>)>) -> gtk::Box {
    let search = gtk::SearchEntry::builder().placeholder_text("Search emoji").hexpand(true).build();
    let any = gtk::Entry::builder()
        .placeholder_text("…or type any emoji")
        .width_chars(16)
        .secondary_icon_name("object-select-symbolic")
        .build();
    let top = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    top.append(&search);
    top.append(&any);

    let grid = flow();
    let fill: Rc<dyn Fn(&str)> = {
        let (grid, choose) = (grid.clone(), choose.clone());
        Rc::new(move |q: &str| {
            clear(&grid);
            for e in catalog::emoji(q) {
                grid.insert(&cell(&IconRef::emoji(e), e, &choose), -1);
            }
        })
    };
    fill("");
    let f = fill.clone();
    search.connect_search_changed(move |s| f(&s.text()));

    let use_typed: Rc<dyn Fn(&gtk::Entry)> = {
        let choose = choose.clone();
        Rc::new(move |e: &gtk::Entry| {
            let t = e.text().trim().to_string();
            if !t.is_empty() {
                choose(Some(IconRef::emoji(&t)));
            }
        })
    };
    let u = use_typed.clone();
    any.connect_activate(move |e| u(e));
    let u = use_typed.clone();
    any.connect_icon_release(move |e, _| u(e));

    page(&[top.upcast_ref()], &grid)
}

fn symbol_page(choose: &Rc<dyn Fn(Option<IconRef>)>) -> gtk::Box {
    let search = gtk::SearchEntry::builder().placeholder_text("Search symbols").build();
    let grid = flow();
    let fill: Rc<dyn Fn(&str)> = {
        let (grid, choose) = (grid.clone(), choose.clone());
        Rc::new(move |q: &str| {
            clear(&grid);
            for s in catalog::symbols(q) {
                let icon = IconRef { kind: "symbol".into(), value: s.to_string() };
                grid.insert(&cell(&icon, s, &choose), -1);
            }
        })
    };
    fill("");
    let f = fill.clone();
    search.connect_search_changed(move |s| f(&s.text()));
    page(&[search.upcast_ref()], &grid)
}

fn logo_page(choose: &Rc<dyn Fn(Option<IconRef>)>) -> gtk::Box {
    let grid = flow();
    for id in marks::IDS {
        grid.insert(&cell(&IconRef::mark(id), marks::name(id), choose), -1);
    }
    let note = gtk::Label::new(Some(
        "Simplified marks, not official artwork. For an exact logo, add the file under Custom.",
    ));
    note.add_css_class("dim-label");
    note.add_css_class("caption");
    note.set_wrap(true);
    note.set_xalign(0.0);
    page(&[note.upcast_ref()], &grid)
}

fn custom_page(choose: &Rc<dyn Fn(Option<IconRef>)>) -> gtk::Box {
    let add = gtk::Button::with_label("Add image…");
    let hint = gtk::Label::new(Some("Or drop an image straight onto any icon."));
    hint.add_css_class("dim-label");
    hint.add_css_class("caption");
    let top = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    top.append(&add);
    top.append(&hint);

    let grid = flow();
    // Rc<dyn Fn()> that refers to itself, for "delete, then redraw"
    let fill: Rc<std::cell::RefCell<Option<Rc<dyn Fn()>>>> = Default::default();
    let f: Rc<dyn Fn()> = {
        let (grid, choose, again) = (grid.clone(), choose.clone(), Rc::downgrade(&fill));
        Rc::new(move || {
            clear(&grid);
            for icon in store::all() {
                let b = cell(&icon, &icon.value, &choose);
                let menu = gtk::Popover::new();
                let del = gtk::Button::with_label("Delete this icon");
                del.add_css_class("flat");
                menu.set_child(Some(&del));
                menu.set_parent(&b);
                let (m, icon2, again2) = (menu.clone(), icon.clone(), again.clone());
                del.connect_clicked(move |_| {
                    m.popdown();
                    store::delete(&icon2);
                    if let Some(f) = again2.upgrade().and_then(|c| c.borrow().clone()) {
                        f();
                    }
                });
                let m = menu.clone();
                b.connect_destroy(move |_| m.unparent());
                let click = gtk::GestureClick::builder().button(3).build();
                let m = menu.clone();
                click.connect_pressed(move |_, _, _, _| m.popup());
                b.add_controller(click);
                grid.insert(&b, -1);
            }
        })
    };
    *fill.borrow_mut() = Some(f.clone());
    f();
    // keep the self-reference alive as long as the grid is
    let keep = fill.clone();
    grid.connect_destroy(move |_| {
        keep.borrow_mut().take();
    });

    let choose = choose.clone();
    add.connect_clicked(move |b| {
        let filter = gtk::FileFilter::new();
        filter.set_name(Some("Images"));
        filter.add_pixbuf_formats();
        let dialog = gtk::FileDialog::builder()
            .title("Pick a logo or photo — it's copied into ~/.config/sshm/icons/")
            .modal(true)
            .default_filter(&filter)
            .build();
        let window = b.root().and_downcast::<gtk::Window>();
        let choose = choose.clone();
        dialog.open(window.as_ref(), gio::Cancellable::NONE, move |res| {
            let Some(path) = res.ok().and_then(|f| f.path()) else { return };
            glib::spawn_future_local(async move {
                if let Ok(Some(icon)) = gio::spawn_blocking(move || store::import_image(&path)).await {
                    choose(Some(icon));
                }
            });
        });
    });

    page(&[top.upcast_ref()], &grid)
}

/// Open the picker. `on_pick(None)` means the user asked for the default back.
pub fn pick(parent: &gtk::Widget, current: Option<IconRef>, on_pick: Rc<dyn Fn(Option<IconRef>)>) {
    let dialog = adw::Dialog::builder().title("Icon").content_width(500).content_height(520).build();

    let choose: Rc<dyn Fn(Option<IconRef>)> = {
        let d = dialog.clone();
        Rc::new(move |icon| {
            on_pick(icon);
            d.close();
        })
    };

    let stack = adw::ViewStack::new();
    stack.add_titled_with_icon(&emoji_page(&choose), Some("emoji"), "Emoji", "face-smile-symbolic");
    stack.add_titled_with_icon(&symbol_page(&choose), Some("symbol"), "Symbols", "starred-symbolic");
    stack.add_titled_with_icon(&logo_page(&choose), Some("mark"), "Logos", "applications-engineering-symbolic");
    stack.add_titled_with_icon(&custom_page(&choose), Some("image"), "Custom", "image-x-generic-symbolic");
    if let Some(c) = &current {
        if ["emoji", "symbol", "mark", "image"].contains(&c.kind.as_str()) {
            stack.set_visible_child_name(&c.kind);
        }
    }

    let switcher = adw::ViewSwitcher::builder().stack(&stack).policy(adw::ViewSwitcherPolicy::Wide).build();
    switcher.set_margin_top(4);
    switcher.set_margin_start(10);
    switcher.set_margin_end(10);
    let header = adw::HeaderBar::new();
    let reset = gtk::Button::with_label("Default");
    reset.set_tooltip_text(Some("Go back to the default icon"));
    let c = choose.clone();
    reset.connect_clicked(move |_| c(None));
    header.pack_start(&reset);

    let view = adw::ToolbarView::new();
    view.add_top_bar(&header);
    view.add_top_bar(&switcher);
    view.set_content(Some(&stack));
    dialog.set_child(Some(&view));
    dialog.present(Some(parent));
}
