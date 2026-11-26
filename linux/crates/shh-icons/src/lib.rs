//! Icons for servers, projects and agents: an emoji, a symbol, a drawn brand
//! mark, or a picture the user supplied. The stored `IconRef` is the Mac
//! app's, so a choice made on either machine renders on both.
pub mod catalog;
pub mod marks;
mod picker;
pub mod store;

use gtk::prelude::*;
use gtk::{gdk, gdk_pixbuf, gio, glib, pango};
use shh_core::meta::IconRef;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

pub use picker::pick;
pub use store::import_image;

thread_local! {
    static TINTS: RefCell<HashSet<String>> = RefCell::new(HashSet::new());
    static MARKS: RefCell<HashMap<(String, i32), gdk::Texture>> = RefCell::new(HashMap::new());
}

/// A CSS class that sets `color` to this rgb; symbolic icons and the fallback
/// dot pick it up. Registered once per colour.
fn tint_class(rgb: (u8, u8, u8)) -> String {
    let class = format!("shh-tint-{:02x}{:02x}{:02x}", rgb.0, rgb.1, rgb.2);
    let fresh = TINTS.with(|t| t.borrow_mut().insert(class.clone()));
    if fresh {
        if let Some(display) = gdk::Display::default() {
            let p = gtk::CssProvider::new();
            p.load_from_string(&format!(".{class} {{ color: rgb({},{},{}); }}", rgb.0, rgb.1, rgb.2));
            gtk::style_context_add_provider_for_display(
                &display,
                &p,
                gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
        }
    }
    class
}

fn text(s: &str, px: f64) -> gtk::Label {
    let l = gtk::Label::new(Some(s));
    let attrs = pango::AttrList::new();
    attrs.insert(pango::AttrSize::new_size_absolute((px * pango::SCALE as f64) as i32));
    l.set_attributes(Some(&attrs));
    l
}

fn dot(size: i32, rgb: (u8, u8, u8)) -> gtk::Widget {
    let l = text("●", size as f64 * 0.6);
    l.add_css_class(&tint_class(rgb));
    l.upcast()
}

fn mark_texture(id: &str, size: i32) -> Option<gdk::Texture> {
    let key = (id.to_string(), size);
    if let Some(t) = MARKS.with(|m| m.borrow().get(&key).cloned()) {
        return Some(t);
    }
    let svg = marks::svg(id)?;
    // twice the size, so it stays crisp on a HiDPI screen
    let pb = store::pixbuf_from_bytes(svg.as_bytes(), size * 2)?;
    let t = gdk::Texture::for_pixbuf(&pb);
    MARKS.with(|m| m.borrow_mut().insert(key, t.clone()));
    Some(t)
}

fn picture(tex: &gdk::Texture, size: i32) -> gtk::Widget {
    let img = gtk::Image::from_paintable(Some(tex));
    img.set_pixel_size(size);
    img.upcast()
}

fn inner(icon: Option<&IconRef>, size: i32, rgb: (u8, u8, u8)) -> gtk::Widget {
    let Some(i) = icon else { return dot(size, rgb) };
    match i.kind.as_str() {
        "emoji" if !i.value.is_empty() => text(&i.value, size as f64 * 0.74).upcast(),
        "image" => {
            let path = store::dir().join(&i.value);
            match gdk_pixbuf::Pixbuf::from_file_at_scale(&path, size * 2, size * 2, true) {
                Ok(pb) => picture(&gdk::Texture::for_pixbuf(&pb), size),
                Err(_) => dot(size, rgb),
            }
        }
        "mark" => match mark_texture(&i.value, size) {
            Some(t) => picture(&t, size),
            None => dot(size, rgb),
        },
        "symbol" => match catalog::themed(&i.value) {
            Some(name) => {
                let img = gtk::Image::from_icon_name(&name);
                img.set_pixel_size((size as f64 * 0.72) as i32);
                img.add_css_class(&tint_class(rgb));
                img.upcast()
            }
            None => dot(size, rgb),
        },
        _ => dot(size, rgb),
    }
}

/// Render any IconRef at `size` px. `rgb` is the server's palette colour: the
/// tint for symbols and the colour of the fallback dot.
pub fn widget(icon: Option<&IconRef>, size: i32, rgb: (u8, u8, u8)) -> gtk::Widget {
    let w = inner(icon, size, rgb);
    w.set_size_request(size, size);
    w.set_halign(gtk::Align::Center);
    w.set_valign(gtk::Align::Center);
    w
}

/// A button showing the current icon. Click opens the picker; an image file
/// dropped on it is imported as a custom icon. `None` means "back to default".
pub fn chip(
    current: Option<IconRef>,
    rgb: (u8, u8, u8),
    on_change: Rc<dyn Fn(Option<IconRef>)>,
) -> gtk::Widget {
    let button = gtk::Button::new();
    button.set_tooltip_text(Some("Choose an icon — or drop an image here"));
    button.set_valign(gtk::Align::Center);
    button.set_child(Some(&widget(current.as_ref(), 32, rgb)));
    let state = Rc::new(RefCell::new(current));

    let set: Rc<dyn Fn(Option<IconRef>)> = {
        let (button, state, on_change) = (button.clone(), state.clone(), on_change.clone());
        Rc::new(move |icon: Option<IconRef>| {
            button.set_child(Some(&widget(icon.as_ref(), 32, rgb)));
            *state.borrow_mut() = icon.clone();
            on_change(icon);
        })
    };

    let (s, st) = (set.clone(), state.clone());
    button.connect_clicked(move |b| {
        let cur = st.borrow().clone();
        pick(b.upcast_ref::<gtk::Widget>(), cur, s.clone());
    });

    let drop = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY);
    let s = set.clone();
    drop.connect_drop(move |_, value, _, _| {
        let Ok(list) = value.get::<gdk::FileList>() else { return false };
        let Some(path) = list.files().into_iter().find_map(|f| f.path()) else { return false };
        let s = s.clone();
        glib::spawn_future_local(async move {
            if let Ok(Some(icon)) = gio::spawn_blocking(move || import_image(&path)).await {
                s(Some(icon));
            }
        });
        true
    });
    button.add_controller(drop);
    button.upcast()
}
