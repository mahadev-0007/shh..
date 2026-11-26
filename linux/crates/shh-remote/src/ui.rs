//! GTK pages for the remote helpers: the file browser and the list of tmux
//! sessions left running on servers. Every remote call runs on a worker thread
//! (`gio::spawn_blocking`); the main loop only ever touches widgets.

use crate::exec::RemoteError;
use crate::files::{self, RemoteEntry, RemoteFiles};
use crate::sessions::{self, BackgroundSession};
use adw::prelude::*;
use gtk::{gdk, gio, glib};
use shh_core::server::Server;
use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Instant;

// MARK: - small helpers

fn human_size(n: i64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = n as f64;
    let mut u = 0;
    while v >= 1024.0 && u < UNITS.len() - 1 {
        v /= 1024.0;
        u += 1;
    }
    if u == 0 { format!("{n} B") } else { format!("{v:.1} {}", UNITS[u]) }
}

fn ago(epoch: i64) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    let d = (now - epoch).max(0);
    match d {
        0..=59 => "just now".into(),
        60..=3599 => format!("{}m ago", d / 60),
        3600..=86399 => format!("{}h ago", d / 3600),
        _ => format!("{}d ago", d / 86400),
    }
}

fn date(epoch: i64) -> String {
    glib::DateTime::from_unix_local(epoch).ok()
        .and_then(|d| d.format("%Y-%m-%d %H:%M").ok())
        .map(|s| s.to_string()).unwrap_or_default()
}

fn window_of(w: &impl IsA<gtk::Widget>) -> Option<gtk::Window> {
    w.root().and_downcast::<gtk::Window>()
}

async fn blocking<T: Send + 'static>(f: impl FnOnce() -> Result<T, RemoteError> + Send + 'static)
    -> Result<T, String> {
    match gio::spawn_blocking(f).await {
        Ok(r) => r.map_err(|e| e.to_string()),
        Err(_) => Err("The helper crashed.".into()),
    }
}

async fn ask_name(parent: &gtk::Widget, title: &str, button: &str, initial: &str) -> Option<String> {
    let dialog = adw::AlertDialog::new(Some(title), None);
    let entry = gtk::Entry::new();
    entry.set_text(initial);
    entry.set_activates_default(true);
    dialog.set_extra_child(Some(&entry));
    dialog.add_responses(&[("cancel", "Cancel"), ("ok", button)]);
    dialog.set_default_response(Some("ok"));
    dialog.set_close_response("cancel");
    dialog.set_response_appearance("ok", adw::ResponseAppearance::Suggested);
    let r = dialog.choose_future(parent).await;
    let name = entry.text().trim().to_string();
    (r == "ok" && !name.is_empty() && !name.contains('/')).then_some(name)
}

async fn confirm(parent: &gtk::Widget, title: &str, body: &str, button: &str) -> bool {
    let dialog = adw::AlertDialog::new(Some(title), Some(body));
    dialog.add_responses(&[("cancel", "Cancel"), ("ok", button)]);
    dialog.set_close_response("cancel");
    dialog.set_response_appearance("ok", adw::ResponseAppearance::Destructive);
    dialog.choose_future(parent).await == "ok"
}

fn boxed_list() -> gtk::ListBox {
    let l = gtk::ListBox::new();
    l.add_css_class("boxed-list");
    l.set_selection_mode(gtk::SelectionMode::None);
    l
}

fn clear(list: &gtk::ListBox) {
    // by row, not by first child: a list can have children that aren't rows
    while let Some(row) = list.row_at_index(0) {
        list.remove(&row);
    }
}

/// Tie a page's state to its root widget, so it lives exactly as long as the
/// widget does. The state must only hold *weak* references back to that root,
/// and signal handlers hold weak references to the state — otherwise every
/// visit to a page would leak it.
fn keep<T: 'static>(root: &impl IsA<glib::Object>, state: &Rc<T>) {
    unsafe { root.set_data("shh-state", state.clone()) }
}

fn heading(text: &str) -> gtk::Label {
    let l = gtk::Label::builder().label(text).xalign(0.0).hexpand(true).build();
    l.add_css_class("title-4");
    l
}

fn downloads_folder() -> PathBuf {
    let dir = glib::user_special_dir(glib::UserDirectory::Downloads)
        .unwrap_or_else(|| shh_core::paths::home().join("Downloads"));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// A page inside the main window. The window already has its own title bar,
/// so this one carries a title and a back button and nothing else — no second
/// set of minimise / maximise / close.
fn page(child: &impl IsA<gtk::Widget>, title: &str, subtitle: &str) -> adw::NavigationPage {
    let bar = adw::HeaderBar::new();
    bar.set_show_start_title_buttons(false);
    bar.set_show_end_title_buttons(false);
    bar.set_title_widget(Some(&adw::WindowTitle::new(title, subtitle)));
    let tv = adw::ToolbarView::new();
    tv.add_top_bar(&bar);
    tv.set_content(Some(child));
    adw::NavigationPage::new(&tv, title)
}

// MARK: - files

/// Pick a server, then browse it.
pub fn files_home(servers: Vec<Server>) -> gtk::Widget {
    files_home_with(servers, Vec::new())
}

/// The Files section's front door: pick a server, or jump straight into a
/// project's folder. `shortcuts` are (title, server, remote path).
pub fn files_home_with(servers: Vec<Server>, shortcuts: Vec<(String, Server, String)>) -> gtk::Widget {
    if servers.is_empty() {
        return adw::StatusPage::builder()
            .icon_name("folder-remote-symbolic")
            .title("No servers yet")
            .description("Add a machine first, then browse its files here.")
            .build().upcast();
    }
    let nav = adw::NavigationView::new();
    let open = {
        let nav = nav.downgrade();
        move |server: &Server, path: &str, title: &str| {
            let Some(nav) = nav.upgrade() else { return };
            nav.push(&page(&files_browser(server.clone(), path), title, &server.display()));
        }
    };

    let body = gtk::Box::new(gtk::Orientation::Vertical, 12);
    body.append(&heading("Servers"));
    let list = boxed_list();
    for s in &servers {
        let row = adw::ActionRow::builder().title(&s.name).subtitle(s.display())
            .use_markup(false).activatable(true).tooltip_text("Browse files").build();
        row.add_prefix(&gtk::Image::from_icon_name("network-server-symbolic"));
        row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
        let (open, s) = (open.clone(), s.clone());
        row.connect_activated(move |_| open(&s, "~", &s.name));
        list.append(&row);
    }
    body.append(&list);

    if !shortcuts.is_empty() {
        let h = heading("Project folders");
        h.set_margin_top(12);
        body.append(&h);
        let list = boxed_list();
        for (title, server, path) in &shortcuts {
            let row = adw::ActionRow::builder().title(title)
                .subtitle(format!("{} · {}", server.name, path))
                .use_markup(false).activatable(true).tooltip_text("Browse files").build();
            row.add_prefix(&gtk::Image::from_icon_name("folder-symbolic"));
            row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
            let (open, server, path, title) = (open.clone(), server.clone(), path.clone(), title.clone());
            row.connect_activated(move |_| open(&server, &path, &title));
            list.append(&row);
        }
        body.append(&list);
    }

    let clamp = adw::Clamp::builder().child(&body).maximum_size(820).margin_top(24)
        .margin_bottom(24).margin_start(12).margin_end(12).build();
    let scroll = gtk::ScrolledWindow::builder().child(&clamp).vexpand(true).build();
    nav.add(&page(&scroll, "Files", "Browse, upload and download over SFTP."));
    nav.upcast()
}

struct Browser {
    files: Arc<RemoteFiles>,
    path: RefCell<String>,
    entries: RefCell<Vec<RemoteEntry>>,
    visible: RefCell<Vec<RemoteEntry>>,
    /// The row a context menu was opened on.
    clicked: RefCell<Option<RemoteEntry>>,
    show_hidden: Cell<bool>,
    root: glib::WeakRef<gtk::Box>,
    stack: gtk::Stack,
    list: gtk::ListBox,
    error_page: adw::StatusPage,
    menu: gtk::PopoverMenu,
    path_entry: gtk::Entry,
    up: gtk::Button,
    status: gtk::Label,
    spinner: gtk::Spinner,
}

impl Browser {
    fn widget(&self) -> Option<gtk::Widget> {
        self.root.upgrade().map(|r| r.upcast())
    }

    fn set_status(&self, text: &str, error: bool) {
        self.status.set_text(text);
        if error { self.status.add_css_class("error") } else { self.status.remove_css_class("error") }
    }

    fn load(self: &Rc<Self>) {
        let this = self.clone();
        let path = self.path.borrow().clone();
        let files = self.files.clone();
        self.spinner.start();
        glib::spawn_future_local(async move {
            let result = blocking(move || files.list(&path)).await;
            this.spinner.stop();
            match result {
                Ok(listing) => {
                    *this.path.borrow_mut() = listing.path.clone();
                    this.path_entry.set_text(&listing.path);
                    this.up.set_sensitive(listing.path != "/");
                    *this.entries.borrow_mut() = listing.entries;
                    this.render();
                }
                Err(e) => {
                    // nothing to show for this path: say why, and offer a way back
                    this.entries.borrow_mut().clear();
                    this.visible.borrow_mut().clear();
                    clear(&this.list);
                    this.error_page.set_description(Some(&e));
                    this.stack.set_visible_child_name("error");
                    this.set_status("", false);
                }
            }
        });
    }

    fn render(&self) {
        clear(&self.list);
        let hidden = self.show_hidden.get();
        let visible: Vec<RemoteEntry> = self.entries.borrow().iter()
            .filter(|e| hidden || !e.is_hidden()).cloned().collect();
        for e in &visible {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
            row.set_margin_top(6);
            row.set_margin_bottom(6);
            row.set_margin_start(10);
            row.set_margin_end(10);
            let icon = if e.is_dir { "folder-symbolic" }
                       else if e.is_link { "emblem-symbolic-link" }
                       else { "text-x-generic-symbolic" };
            row.append(&gtk::Image::from_icon_name(icon));
            let name = gtk::Label::builder().label(&e.name).xalign(0.0).hexpand(true)
                .ellipsize(gtk::pango::EllipsizeMode::Middle).build();
            row.append(&name);
            for (text, width) in [(if e.is_dir { String::new() } else { human_size(e.size) }, 9),
                                  (date(e.modified), 16), (e.mode.clone(), 10)] {
                let l = gtk::Label::builder().label(&text).xalign(1.0).width_chars(width).build();
                l.add_css_class("dim-label");
                l.add_css_class("numeric");
                row.append(&l);
            }
            self.list.append(&row);
        }
        let n = visible.len();
        let skipped = self.entries.borrow().len() - n;
        let mut text = format!("{n} item{}", if n == 1 { "" } else { "s" });
        if skipped > 0 {
            text.push_str(&format!(" · {skipped} hidden"));
        }
        self.set_status(&text, false);
        self.stack.set_visible_child_name(if n == 0 { "empty" } else { "list" });
        *self.visible.borrow_mut() = visible;
    }

    fn go(self: &Rc<Self>, path: &str) {
        *self.path.borrow_mut() = path.to_string();
        self.load();
    }

    fn selected(&self) -> Vec<RemoteEntry> {
        let visible = self.visible.borrow();
        self.list.selected_rows().iter()
            .filter_map(|r| visible.get(r.index() as usize).cloned()).collect()
    }

    fn remote_path(&self, e: &RemoteEntry) -> String {
        files::join(&self.path.borrow(), &e.name)
    }

    /// Run one remote operation, show progress, then refresh the listing.
    fn run(self: &Rc<Self>, title: &str,
           op: impl FnOnce(&RemoteFiles) -> Result<(), RemoteError> + Send + 'static) {
        let this = self.clone();
        let files = self.files.clone();
        let title = title.to_string();
        self.set_status(&format!("{title}…"), false);
        self.spinner.start();
        glib::spawn_future_local(async move {
            let result = blocking(move || op(&files)).await;
            this.spinner.stop();
            match result {
                Ok(()) => this.load(),
                Err(e) => this.set_status(&format!("✗ {title}: {e}"), true),
            }
        });
    }

    fn upload(self: &Rc<Self>, locals: Vec<PathBuf>) {
        if locals.is_empty() { return; }
        let dir = self.path.borrow().clone();
        let n = locals.len();
        self.run(&format!("Uploading {n} item{}", if n == 1 { "" } else { "s" }),
                 move |f| f.upload(&locals, &dir));
    }

    fn choose_upload(self: &Rc<Self>) {
        let b = self.clone();
        glib::spawn_future_local(async move {
            let Some(root) = b.widget() else { return };
            let title = format!("Upload to {} on {}", b.path.borrow(), b.files.server.name);
            let dialog = gtk::FileDialog::builder().title(title).accept_label("Upload").build();
            let Ok(model) = dialog.open_multiple_future(window_of(&root).as_ref()).await else { return };
            let locals: Vec<PathBuf> = (0..model.n_items())
                .filter_map(|i| model.item(i).and_downcast::<gio::File>()?.path()).collect();
            b.upload(locals);
        });
    }

    /// Copy `items` into a local folder, then show them in the file manager.
    fn download(self: &Rc<Self>, items: Vec<RemoteEntry>, dir: PathBuf) {
        if items.is_empty() { return; }
        // two selected items can't share a name, but the folder may already
        // hold one: never overwrite, number instead
        let pairs: Vec<(String, PathBuf)> = items.iter()
            .map(|e| (self.remote_path(e), files::unique_local(&dir.join(&e.name)))).collect();
        let n = pairs.len();
        let this = self.clone();
        let files = self.files.clone();
        self.set_status(&format!("Downloading {n} item{}…", if n == 1 { "" } else { "s" }), false);
        self.spinner.start();
        glib::spawn_future_local(async move {
            let first = pairs[0].1.clone();
            let result = blocking(move || files.download(&pairs)).await;
            this.spinner.stop();
            match result {
                Ok(()) => {
                    this.set_status(&format!("✓ Downloaded to {}", dir.display()), false);
                    let window = this.widget().and_then(|w| window_of(&w));
                    gtk::FileLauncher::new(Some(&gio::File::for_path(first)))
                        .open_containing_folder(window.as_ref(), gio::Cancellable::NONE, |_| {});
                }
                Err(e) => this.set_status(&format!("✗ Download: {e}"), true),
            }
        });
    }

    fn choose_download(self: &Rc<Self>) {
        let b = self.clone();
        glib::spawn_future_local(async move {
            let sel = b.selected();
            if sel.is_empty() {
                b.set_status("Select something to download.", true);
                return;
            }
            let Some(root) = b.widget() else { return };
            let dialog = gtk::FileDialog::builder().title("Download to").accept_label("Download").build();
            let Ok(folder) = dialog.select_folder_future(window_of(&root).as_ref()).await else { return };
            if let Some(dir) = folder.path() {
                b.download(sel, dir);
            }
        });
    }

    fn new_folder(self: &Rc<Self>) {
        let b = self.clone();
        glib::spawn_future_local(async move {
            let Some(parent) = b.widget() else { return };
            if let Some(name) = ask_name(&parent, "New folder", "Create", "untitled folder").await {
                let path = files::join(&b.path.borrow(), &name);
                b.run("Creating folder", move |f| f.make_directory(&path));
            }
        });
    }

    fn rename_selected(self: &Rc<Self>) {
        let b = self.clone();
        glib::spawn_future_local(async move {
            let sel = b.selected();
            let [e] = sel.as_slice() else {
                b.set_status("Select one item to rename.", true);
                return;
            };
            let Some(parent) = b.widget() else { return };
            if let Some(name) = ask_name(&parent, &format!("Rename “{}”", e.name), "Rename", &e.name).await {
                if name == e.name { return; }
                let from = b.remote_path(e);
                let to = files::join(&b.path.borrow(), &name);
                b.run("Renaming", move |f| f.rename(&from, &to));
            }
        });
    }

    fn delete_selected(self: &Rc<Self>) {
        let b = self.clone();
        glib::spawn_future_local(async move {
            let sel = b.selected();
            if sel.is_empty() {
                b.set_status("Select something to delete.", true);
                return;
            }
            let Some(parent) = b.widget() else { return };
            let server = &b.files.server.name;
            let title = if sel.len() == 1 { format!("Delete “{}” from {server}?", sel[0].name) }
                        else { format!("Delete {} items from {server}?", sel.len()) };
            let body = "This removes it from the server for good, including everything inside \
                        any folders. There is no trash on the server.";
            if confirm(&parent, &title, body, "Delete").await {
                let paths: Vec<String> = sel.iter().map(|e| b.remote_path(e)).collect();
                b.run("Deleting", move |f| f.delete(&paths));
            }
        });
    }

    fn copy_paths(&self) {
        let text = self.selected().iter().map(|e| self.remote_path(e)).collect::<Vec<_>>().join("\n");
        if text.is_empty() { return; }
        if let Some(w) = self.widget() {
            w.clipboard().set_text(&text);
            self.set_status("Path copied", false);
        }
    }

    /// Double-click or Enter: step into a folder, fetch a file to Downloads.
    fn open_entry(self: &Rc<Self>, e: &RemoteEntry) {
        if e.is_dir {
            let p = self.remote_path(e);
            self.go(&p);
        } else {
            self.download(vec![e.clone()], downloads_folder());
        }
    }

    /// Right-click. Outside the selection it acts on the clicked row alone;
    /// on empty space it offers only the folder-wide actions.
    fn show_menu(&self, x: f64, y: f64) {
        let row = self.list.row_at_y(y as i32);
        if let Some(r) = &row {
            if !r.is_selected() {
                self.list.unselect_all();
                self.list.select_row(Some(r));
            }
        }
        let clicked = row.as_ref().and_then(|r| self.visible.borrow().get(r.index() as usize).cloned());
        let menu = gio::Menu::new();
        if let Some(e) = &clicked {
            let top = gio::Menu::new();
            if e.is_dir {
                top.append(Some("Open"), Some("files.open"));
            }
            top.append(Some("Download to Downloads"), Some("files.download-default"));
            top.append(Some("Download…"), Some("files.download"));
            top.append(Some("Copy Path"), Some("files.copy-path"));
            menu.append_section(None, &top);
            let edit = gio::Menu::new();
            if self.list.selected_rows().len() == 1 {
                edit.append(Some("Rename…"), Some("files.rename"));
            }
            edit.append(Some("Delete…"), Some("files.delete"));
            menu.append_section(None, &edit);
        }
        *self.clicked.borrow_mut() = clicked;
        let rest = gio::Menu::new();
        rest.append(Some("Upload…"), Some("files.upload"));
        rest.append(Some("New Folder…"), Some("files.new-folder"));
        rest.append(Some("Refresh"), Some("files.refresh"));
        menu.append_section(None, &rest);
        self.menu.set_menu_model(Some(&menu));
        // the click is in the list's coordinates, the popover in the page's
        let at = self.root.upgrade()
            .and_then(|root| self.list.compute_point(&root, &gtk::graphene::Point::new(x as f32, y as f32)))
            .map(|p| (p.x() as i32, p.y() as i32))
            .unwrap_or((x as i32, y as i32));
        self.menu.set_pointing_to(Some(&gdk::Rectangle::new(at.0, at.1, 1, 1)));
        self.menu.popup();
    }
}

// Dragging rows out of the window. GTK has no file promises, but a content
// provider is asked for its data only when something actually accepts the
// drop — so the download happens then, off the main thread, into a temporary
// folder, and the file manager is handed the resulting file:// URIs to copy.
mod promise {
    use super::*;
    use gtk::subclass::prelude::*;
    use std::future::Future;
    use std::pin::Pin;

    #[derive(Clone)]
    pub struct Job {
        pub files: Arc<RemoteFiles>,
        /// (remote path, file name)
        pub items: Vec<(String, String)>,
        pub done: Rc<RefCell<Option<Result<String, String>>>>,
        pub status: Rc<dyn Fn(&str, bool)>,
    }

    impl Job {
        async fn uri_list(&self) -> Result<String, String> {
            if let Some(r) = self.done.borrow().clone() {
                return r;
            }
            let dir = std::env::temp_dir().join(format!("shh-drag-{:08x}", rand::random::<u32>()));
            std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
            let pairs: Vec<(String, PathBuf)> =
                self.items.iter().map(|(r, n)| (r.clone(), dir.join(n))).collect();
            let n = pairs.len();
            (self.status)(&format!("Downloading {n} item{}…", if n == 1 { "" } else { "s" }), false);
            let (files, work) = (self.files.clone(), pairs.clone());
            let result = blocking(move || files.download(&work)).await.map(|_| {
                pairs.iter().map(|(_, l)| format!("{}\r\n", gio::File::for_path(l).uri())).collect::<String>()
            });
            match &result {
                Ok(_) => (self.status)("✓ Downloaded", false),
                Err(e) => (self.status)(&format!("✗ Download: {e}"), true),
            }
            *self.done.borrow_mut() = Some(result.clone());
            result
        }
    }

    #[derive(Default)]
    pub struct Imp {
        pub job: RefCell<Option<Job>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for Imp {
        const NAME: &'static str = "ShhRemoteFilePromise";
        type Type = super::FilePromise;
        type ParentType = gdk::ContentProvider;
    }

    impl ObjectImpl for Imp {}

    impl ContentProviderImpl for Imp {
        fn formats(&self) -> gdk::ContentFormats {
            gdk::ContentFormatsBuilder::new().add_mime_type("text/uri-list").build()
        }

        fn write_mime_type_future(&self, _mime_type: &str, stream: &gio::OutputStream,
                                  io_priority: glib::Priority)
            -> Pin<Box<dyn Future<Output = Result<(), glib::Error>> + 'static>> {
            let job = self.job.borrow().clone();
            let stream = stream.clone();
            Box::pin(async move {
                let fail = |m: &str| glib::Error::new(gio::IOErrorEnum::Failed, m);
                let job = job.ok_or_else(|| fail("nothing to drag"))?;
                let uris = job.uri_list().await.map_err(|e| fail(&e))?;
                stream.write_all_future(uris.into_bytes(), io_priority).await.map_err(|(_, e)| e)?;
                Ok(())
            })
        }
    }
}

glib::wrapper! {
    pub struct FilePromise(ObjectSubclass<promise::Imp>) @extends gdk::ContentProvider;
}

impl FilePromise {
    fn new(job: promise::Job) -> Self {
        use gtk::subclass::prelude::ObjectSubclassIsExt;
        let obj: Self = glib::Object::new();
        *obj.imp().job.borrow_mut() = Some(job);
        obj
    }
}

/// The browser for one server, starting at `start`.
pub fn files_browser(server: Server, start: &str) -> gtk::Widget {
    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let bar = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    bar.set_margin_top(8);
    bar.set_margin_bottom(8);
    bar.set_margin_start(10);
    bar.set_margin_end(10);

    let btn = |icon: &str, tip: &str| {
        let b = gtk::Button::from_icon_name(icon);
        b.set_tooltip_text(Some(tip));
        b
    };
    let up = btn("go-up-symbolic", "Enclosing folder");
    let refresh = btn("view-refresh-symbolic", "Refresh");
    let path_entry = gtk::Entry::builder().hexpand(true).placeholder_text("Path").build();
    let hidden = gtk::ToggleButton::builder().icon_name("view-reveal-symbolic")
        .tooltip_text("Show hidden files").build();
    let new_folder = btn("folder-new-symbolic", "New folder");
    let upload = btn("document-send-symbolic", "Upload…");
    let download = btn("folder-download-symbolic", "Download…");
    let rename = btn("document-edit-symbolic", "Rename");
    let delete = btn("user-trash-symbolic", "Delete");
    for w in [up.upcast_ref::<gtk::Widget>(), path_entry.upcast_ref(), refresh.upcast_ref(),
              hidden.upcast_ref(), new_folder.upcast_ref(), upload.upcast_ref(),
              download.upcast_ref(), rename.upcast_ref(), delete.upcast_ref()] {
        bar.append(w);
    }

    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::Multiple);
    list.set_activate_on_single_click(false);
    let scroll = gtk::ScrolledWindow::builder().child(&list).vexpand(true).build();

    let empty = adw::StatusPage::builder().icon_name("folder-symbolic").title("Empty folder")
        .description("Drop files here to upload them.").vexpand(true).build();
    let retry = gtk::Button::builder().label("Try again").halign(gtk::Align::Center).build();
    retry.add_css_class("pill");
    let error_page = adw::StatusPage::builder().icon_name("dialog-warning-symbolic")
        .title("Couldn't open this folder").child(&retry).vexpand(true).build();
    let stack = gtk::Stack::new();
    stack.add_named(&scroll, Some("list"));
    stack.add_named(&empty, Some("empty"));
    stack.add_named(&error_page, Some("error"));

    let menu = gtk::PopoverMenu::from_model(None::<&gio::Menu>);
    // parented to the page, not the list: the list's children are its rows
    menu.set_parent(&root);
    menu.set_has_arrow(false);
    menu.set_halign(gtk::Align::Start);
    root.connect_destroy(glib::clone!(#[weak] menu, move |_| menu.unparent()));

    let foot = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    foot.set_margin_top(6);
    foot.set_margin_bottom(6);
    foot.set_margin_start(10);
    foot.set_margin_end(10);
    let spinner = gtk::Spinner::new();
    let status = gtk::Label::builder().xalign(0.0).hexpand(true)
        .ellipsize(gtk::pango::EllipsizeMode::End).build();
    status.add_css_class("dim-label");
    let hint = gtk::Label::new(Some("Drop files to upload · drag rows out to download · double-click a file to fetch it"));
    hint.add_css_class("dim-label");
    hint.add_css_class("caption");
    hint.set_ellipsize(gtk::pango::EllipsizeMode::End);
    foot.append(&spinner);
    foot.append(&status);
    foot.append(&hint);

    root.append(&bar);
    root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    root.append(&stack);
    root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    root.append(&foot);

    let b = Rc::new(Browser {
        files: Arc::new(RemoteFiles::new(server)),
        path: RefCell::new(if start.is_empty() { "~".to_string() } else { start.to_string() }),
        entries: RefCell::new(Vec::new()),
        visible: RefCell::new(Vec::new()),
        clicked: RefCell::new(None),
        show_hidden: Cell::new(false),
        root: root.downgrade(),
        stack: stack.clone(),
        list: list.clone(),
        error_page,
        menu,
        path_entry: path_entry.clone(),
        up: up.clone(),
        status,
        spinner,
    });
    keep(&root, &b);

    up.connect_clicked(glib::clone!(#[weak] b, move |_| {
        let parent = files::parent(&b.path.borrow());
        b.go(&parent);
    }));
    refresh.connect_clicked(glib::clone!(#[weak] b, move |_| b.load()));
    retry.connect_clicked(glib::clone!(#[weak] b, move |_| b.load()));
    path_entry.connect_activate(glib::clone!(#[weak] b, move |e| b.go(e.text().trim())));
    hidden.connect_toggled(glib::clone!(#[weak] b, move |t| {
        b.show_hidden.set(t.is_active());
        b.render();
    }));
    list.connect_row_activated(glib::clone!(#[weak] b, move |_, row| {
        let entry = b.visible.borrow().get(row.index() as usize).cloned();
        if let Some(e) = entry {
            b.open_entry(&e);
        }
    }));
    new_folder.connect_clicked(glib::clone!(#[weak] b, move |_| b.new_folder()));
    rename.connect_clicked(glib::clone!(#[weak] b, move |_| b.rename_selected()));
    delete.connect_clicked(glib::clone!(#[weak] b, move |_| b.delete_selected()));
    upload.connect_clicked(glib::clone!(#[weak] b, move |_| b.choose_upload()));
    download.connect_clicked(glib::clone!(#[weak] b, move |_| b.choose_download()));

    // the context menu's actions
    let actions = gio::SimpleActionGroup::new();
    let add = |name: &str, f: fn(&Rc<Browser>)| {
        let a = gio::SimpleAction::new(name, None);
        a.connect_activate(glib::clone!(#[weak] b, move |_, _| f(&b)));
        actions.add_action(&a);
    };
    add("open", |b| {
        let e = b.clicked.borrow().clone();
        if let Some(e) = e {
            b.open_entry(&e);
        }
    });
    add("download-default", |b| b.download(b.selected(), downloads_folder()));
    add("download", |b| b.choose_download());
    add("copy-path", |b| b.copy_paths());
    add("rename", |b| b.rename_selected());
    add("delete", |b| b.delete_selected());
    add("upload", |b| b.choose_upload());
    add("new-folder", |b| b.new_folder());
    add("refresh", |b| b.load());
    root.insert_action_group("files", Some(&actions));

    let right = gtk::GestureClick::builder().button(gdk::BUTTON_SECONDARY).build();
    right.connect_pressed(glib::clone!(#[weak] b, move |g, _, x, y| {
        g.set_state(gtk::EventSequenceState::Claimed);
        b.show_menu(x, y);
    }));
    list.add_controller(right);

    // Delete, F2 and F5 where a file manager has them
    let keys = gtk::EventControllerKey::new();
    keys.connect_key_pressed(glib::clone!(#[weak] b, #[upgrade_or] glib::Propagation::Proceed,
        move |_, key, _, _| {
            match key {
                gdk::Key::Delete | gdk::Key::KP_Delete => b.delete_selected(),
                gdk::Key::F2 => b.rename_selected(),
                gdk::Key::F5 => b.load(),
                _ => return glib::Propagation::Proceed,
            }
            glib::Propagation::Stop
        }));
    list.add_controller(keys);

    // drag rows out to download them
    let drag = gtk::DragSource::builder().actions(gdk::DragAction::COPY).build();
    drag.connect_prepare(glib::clone!(#[weak] b, #[upgrade_or] None, move |_, _, y| {
        let row = b.list.row_at_y(y as i32)?;
        let items: Vec<RemoteEntry> = if row.is_selected() {
            b.selected()
        } else {
            b.visible.borrow().get(row.index() as usize).cloned().into_iter().collect()
        };
        if items.is_empty() {
            return None;
        }
        let weak = Rc::downgrade(&b);
        let job = promise::Job {
            files: b.files.clone(),
            items: items.iter().map(|e| (b.remote_path(e), e.name.clone())).collect(),
            done: Rc::new(RefCell::new(None)),
            status: Rc::new(move |text, error| {
                if let Some(b) = weak.upgrade() {
                    b.set_status(text, error);
                }
            }),
        };
        Some(FilePromise::new(job).upcast())
    }));
    list.add_controller(drag);

    // drop local files anywhere on the listing to upload them here
    let drop = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY);
    // our own rows dragged back in are downloads in waiting, not uploads
    drop.connect_accept(|_, d| d.drag().is_none());
    drop.connect_drop(glib::clone!(#[weak] b, #[upgrade_or] false, move |_, value, _, _| {
        let Ok(list) = value.get::<gdk::FileList>() else { return false };
        b.upload(list.files().iter().filter_map(|f| f.path()).collect());
        true
    }));
    stack.add_controller(drop);

    b.load();
    root.upcast()
}

// MARK: - folder picker

struct Picker {
    server: Server,
    path: RefCell<String>,
    dirs: RefCell<Vec<String>>,
    list: gtk::ListBox,
    entry: gtk::Entry,
    status: gtk::Label,
    spinner: gtk::Spinner,
    empty: gtk::Label,
}

impl Picker {
    fn load(self: &Rc<Self>) {
        let this = self.clone();
        let (server, path) = (self.server.clone(), self.path.borrow().clone());
        self.entry.set_text(&path);
        self.status.set_visible(false);
        self.spinner.start();
        glib::spawn_future_local(async move {
            let result = blocking(move || crate::fs::list(&server, &path)).await;
            this.spinner.stop();
            clear(&this.list);
            match result {
                Ok(listing) => {
                    // the server's own idea of the path: `~` becomes /home/you
                    *this.path.borrow_mut() = listing.path.clone();
                    this.entry.set_text(&listing.path);
                    for d in &listing.directories {
                        let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
                        row.set_margin_top(6);
                        row.set_margin_bottom(6);
                        row.set_margin_start(10);
                        row.set_margin_end(10);
                        row.append(&gtk::Image::from_icon_name("folder-symbolic"));
                        let l = gtk::Label::builder().label(d).xalign(0.0).hexpand(true)
                            .ellipsize(gtk::pango::EllipsizeMode::Middle).build();
                        l.add_css_class("monospace");
                        row.append(&l);
                        row.append(&gtk::Image::from_icon_name("go-next-symbolic"));
                        this.list.append(&row);
                    }
                    this.empty.set_visible(listing.directories.is_empty());
                    *this.dirs.borrow_mut() = listing.directories;
                }
                Err(e) => {
                    this.dirs.borrow_mut().clear();
                    this.empty.set_visible(false);
                    this.status.set_text(&e);
                    this.status.set_visible(true);
                }
            }
        });
    }

    fn go(self: &Rc<Self>, path: String) {
        *self.path.borrow_mut() = if path.is_empty() { "~".into() } else { path };
        self.load();
    }
}

/// A minimal remote directory picker for the project form: the current path,
/// its subdirectories, up, and choose. One `ls` per step over the server's
/// control socket. `on_pick` receives the resolved absolute path.
pub fn folder_picker(parent: &gtk::Widget, server: Server, start: String, on_pick: Rc<dyn Fn(String)>) {
    let cancel = gtk::Button::with_label("Cancel");
    let choose = gtk::Button::with_label("Choose this folder");
    choose.add_css_class("suggested-action");
    let bar = adw::HeaderBar::new();
    bar.set_show_start_title_buttons(false);
    bar.set_show_end_title_buttons(false);
    bar.set_title_widget(Some(&adw::WindowTitle::new(&server.name, &server.display())));
    bar.pack_start(&cancel);
    bar.pack_end(&choose);

    let up = gtk::Button::from_icon_name("go-up-symbolic");
    up.set_tooltip_text(Some("Enclosing folder"));
    let home = gtk::Button::from_icon_name("go-home-symbolic");
    home.set_tooltip_text(Some("Home folder"));
    let entry = gtk::Entry::builder().hexpand(true).placeholder_text("Path").build();
    entry.add_css_class("monospace");
    let spinner = gtk::Spinner::new();
    let nav = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    nav.append(&up);
    nav.append(&home);
    nav.append(&entry);
    nav.append(&spinner);

    let status = gtk::Label::builder().xalign(0.0).wrap(true).visible(false).build();
    status.add_css_class("error");
    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::None);
    list.set_activate_on_single_click(true);
    let empty = gtk::Label::builder().label("No folders in here").visible(false)
        .margin_top(24).margin_bottom(24).build();
    empty.add_css_class("dim-label");
    let inner = gtk::Box::new(gtk::Orientation::Vertical, 0);
    inner.append(&list);
    inner.append(&empty);
    let scroll = gtk::ScrolledWindow::builder().child(&inner).vexpand(true).build();
    let frame = gtk::Frame::new(None);
    frame.set_child(Some(&scroll));

    let body = gtk::Box::new(gtk::Orientation::Vertical, 8);
    body.set_margin_top(12);
    body.set_margin_bottom(12);
    body.set_margin_start(12);
    body.set_margin_end(12);
    body.append(&nav);
    body.append(&status);
    body.append(&frame);

    let view = adw::ToolbarView::new();
    view.add_top_bar(&bar);
    view.set_content(Some(&body));
    let dialog = adw::Dialog::builder().title("Choose a folder").content_width(480)
        .content_height(460).child(&view).build();

    let p = Rc::new(Picker {
        server,
        path: RefCell::new(if start.trim().is_empty() { "~".to_string() } else { start.trim().to_string() }),
        dirs: RefCell::new(Vec::new()),
        list: list.clone(),
        entry: entry.clone(),
        status,
        spinner,
        empty,
    });
    keep(&dialog, &p);

    up.connect_clicked(glib::clone!(#[weak] p, move |_| {
        let parent = files::parent(&p.path.borrow());
        p.go(parent);
    }));
    home.connect_clicked(glib::clone!(#[weak] p, move |_| p.go("~".into())));
    entry.connect_activate(glib::clone!(#[weak] p, move |e| p.go(e.text().trim().to_string())));
    list.connect_row_activated(glib::clone!(#[weak] p, move |_, row| {
        let name = p.dirs.borrow().get(row.index() as usize).cloned();
        if let Some(name) = name {
            let next = files::join(&p.path.borrow(), &name);
            p.go(next);
        }
    }));
    cancel.connect_clicked(glib::clone!(#[weak] dialog, move |_| {
        dialog.close();
    }));
    choose.connect_clicked(glib::clone!(#[weak] dialog, #[weak] p, move |_| {
        // whatever is in the box wins, so a folder that doesn't exist yet can
        // still be typed and chosen
        let typed = p.entry.text().trim().to_string();
        let path = if typed.is_empty() { p.path.borrow().clone() } else { typed };
        on_pick(path);
        dialog.close();
    }));

    dialog.present(Some(parent));
    p.load();
}

// MARK: - sessions

/// A session the app has open in a tab right now.
#[derive(Debug, Clone, PartialEq)]
pub struct ActiveSession {
    pub id: String,
    pub title: String,
    pub subtitle: String,
    /// "running", "connecting", "reconnecting", "ended", …
    pub state: String,
    /// The tmux session this tab is attached to, if any.
    pub tmux_name: Option<String>,
    pub server_slug: String,
}

/// What the last check found, so flipping between pages doesn't cost a round
/// trip to every server each time. (when, servers asked, found, unreachable)
type Checked = (Instant, Vec<String>, Vec<BackgroundSession>, Vec<String>);
thread_local! {
    static LAST_CHECK: RefCell<Option<Checked>> = const { RefCell::new(None) };
}
const CHECK_EVERY_SECS: u64 = 20;

struct SessionsPage {
    servers: Vec<Server>,
    on_attach: Rc<dyn Fn(Server, String)>,
    on_focus: Rc<dyn Fn(String)>,
    on_close: Rc<dyn Fn(String)>,
    active: RefCell<Vec<ActiveSession>>,
    found: RefCell<Vec<BackgroundSession>>,
    failed: RefCell<Vec<String>>,
    root: glib::WeakRef<gtk::Box>,
    active_box: gtk::Box,
    active_note: gtk::Label,
    active_list: gtk::ListBox,
    bg_box: gtk::Box,
    bg_note: gtk::Label,
    bg_list: gtk::ListBox,
    empty: adw::StatusPage,
    note: gtk::Label,
    refresh: gtk::Button,
    fetching: Cell<bool>,
}

impl SessionsPage {
    fn server_names(&self) -> Vec<String> {
        self.servers.iter().map(|s| format!("{}|{}", s.name, s.display())).collect()
    }

    fn fetch(self: &Rc<Self>, force: bool) {
        if self.fetching.get() || self.servers.is_empty() { return; }
        if !force {
            let names = self.server_names();
            let cached = LAST_CHECK.with(|c| c.borrow().as_ref()
                .filter(|(at, asked, _, _)| at.elapsed().as_secs() < CHECK_EVERY_SECS && *asked == names)
                .map(|(_, _, found, failed)| (found.clone(), failed.clone())));
            if let Some((found, failed)) = cached {
                *self.found.borrow_mut() = found;
                *self.failed.borrow_mut() = failed;
                self.render();
                return;
            }
        }
        self.fetching.set(true);
        self.refresh.set_sensitive(false);
        self.render();
        let this = self.clone();
        let servers = self.servers.clone();
        glib::spawn_future_local(async move {
            // one thread per server, so a single unreachable box costs its own
            // timeout and no one else's
            let results = gio::spawn_blocking(move || {
                let handles: Vec<_> = servers.into_iter().map(|s| {
                    std::thread::spawn(move || { let r = sessions::list(&s); (s, r) })
                }).collect();
                handles.into_iter().filter_map(|h| h.join().ok()).collect::<Vec<_>>()
            }).await.unwrap_or_default();

            let mut found: Vec<BackgroundSession> = Vec::new();
            let mut failed: Vec<String> = Vec::new();
            for (s, r) in results {
                match r {
                    Ok(list) => found.extend(list),
                    Err(_) => failed.push(s.name),
                }
            }
            found.sort_by(|a, b| b.last_activity.cmp(&a.last_activity));
            failed.sort();
            LAST_CHECK.with(|c| *c.borrow_mut() =
                Some((Instant::now(), this.server_names(), found.clone(), failed.clone())));
            *this.found.borrow_mut() = found;
            *this.failed.borrow_mut() = failed;
            this.fetching.set(false);
            this.refresh.set_sensitive(true);
            this.render();
        });
    }

    /// Background sessions no tab here is already attached to.
    fn detached(&self) -> Vec<BackgroundSession> {
        let active = self.active.borrow();
        self.found.borrow().iter().filter(|b| {
            !active.iter().any(|a| a.tmux_name.as_deref() == Some(b.name.as_str())
                                   && a.server_slug == b.server.name)
        }).cloned().collect()
    }

    fn render(self: &Rc<Self>) {
        let active = self.active.borrow().clone();
        let detached = self.detached();
        let fetching = self.fetching.get();
        let failed = self.failed.borrow().clone();

        let nothing = active.is_empty() && detached.is_empty();
        self.empty.set_visible(nothing);
        self.empty.set_title(if fetching { "Checking your servers…" } else { "Nothing running" });
        self.refresh.set_visible(!self.servers.is_empty());

        // active
        clear(&self.active_list);
        self.active_box.set_visible(!active.is_empty());
        let running = active.iter().filter(|a| a.state == "running").count();
        self.active_note.set_text(&format!("{running} running"));
        for a in &active {
            let row = adw::ActionRow::builder().title(&a.title).subtitle(&a.subtitle)
                .use_markup(false).activatable(true).tooltip_text("Show this session").build();
            row.add_prefix(&gtk::Image::from_icon_name("utilities-terminal-symbolic"));
            let state = gtk::Label::new(Some(&capitalise(&a.state)));
            state.add_css_class("caption");
            state.add_css_class(match a.state.as_str() {
                "running" => "success",
                "ended" | "idle" => "dim-label",
                _ => "warning",
            });
            row.add_suffix(&state);
            let close = gtk::Button::builder().icon_name("window-close-symbolic")
                .tooltip_text("Close this tab").valign(gtk::Align::Center).build();
            close.add_css_class("flat");
            let id = a.id.clone();
            close.connect_clicked(glib::clone!(#[weak(rename_to = this)] self, move |_| {
                (this.on_close)(id.clone());
                this.active.borrow_mut().retain(|x| x.id != id);
                this.render();
                // its tmux session may now be running on its own
                glib::timeout_add_seconds_local_once(1, glib::clone!(#[weak] this, move || this.fetch(true)));
            }));
            row.add_suffix(&close);
            let (cb, id) = (self.on_focus.clone(), a.id.clone());
            row.connect_activated(move |_| cb(id.clone()));
            self.active_list.append(&row);
        }

        // background
        clear(&self.bg_list);
        self.bg_box.set_visible(!detached.is_empty() || (fetching && !nothing));
        self.bg_list.set_visible(!detached.is_empty());
        self.bg_note.set_text(&if fetching && detached.is_empty() { "checking…".to_string() }
                               else { format!("{} detached", detached.len()) });
        for s in detached {
            let attached = match s.attached_clients {
                0 => "detached".to_string(),
                1 => "1 client attached elsewhere".to_string(),
                n => format!("{n} clients attached elsewhere"),
            };
            let row = adw::ActionRow::builder().title(&s.name)
                .subtitle(format!("{} · {} · active {} · started {}",
                                  s.server.name, attached, ago(s.last_activity), ago(s.created)))
                .use_markup(false).build();
            row.add_prefix(&gtk::Image::from_icon_name("utilities-terminal-symbolic"));

            let attach = gtk::Button::builder().label("Attach").valign(gtk::Align::Center).build();
            attach.add_css_class("suggested-action");
            let (cb, srv, name) = (self.on_attach.clone(), s.server.clone(), s.name.clone());
            attach.connect_clicked(move |_| cb(srv.clone(), name.clone()));

            let end = gtk::Button::builder().label("End").valign(gtk::Align::Center).build();
            end.add_css_class("destructive-action");
            end.connect_clicked(glib::clone!(#[weak(rename_to = this)] self, move |_| this.end(s.clone())));
            row.add_suffix(&attach);
            row.add_suffix(&end);
            self.bg_list.append(&row);
        }

        self.note.set_visible(!failed.is_empty());
        self.note.set_text(&format!("Couldn't check {} for background sessions.", failed.join(", ")));
    }

    fn end(self: &Rc<Self>, s: BackgroundSession) {
        let this = self.clone();
        glib::spawn_future_local(async move {
            let Some(parent) = this.root.upgrade().map(|r| r.upcast::<gtk::Widget>()) else { return };
            let body = format!("This stops whatever is running in it on {} and closes \
                                its tmux session.", s.server.display());
            if !confirm(&parent, &format!("End “{}”?", s.name), &body, "End Session").await {
                return;
            }
            // gone from the list straight away; the server catches up
            this.found.borrow_mut().retain(|b| !(b.name == s.name && b.server == s.server));
            LAST_CHECK.with(|c| *c.borrow_mut() = None);
            this.render();
            let (srv, name) = (s.server.clone(), s.name.clone());
            if let Err(e) = blocking(move || sessions::kill(&srv, &name, None)).await {
                let alert = adw::AlertDialog::new(Some(&format!("Couldn't end “{}”", s.name)), Some(&e));
                alert.add_response("ok", "OK");
                alert.present(Some(&parent));
                this.fetch(true);
            }
        });
    }
}

fn capitalise(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

/// shh's tmux sessions still running on `servers`, with attach and end.
/// `on_attach` receives the server and the exact tmux session name.
pub fn sessions_page(servers: Vec<Server>, on_attach: Rc<dyn Fn(Server, String)>) -> gtk::Widget {
    sessions_page_with(servers, on_attach, Vec::new(), Rc::new(|_| {}), Rc::new(|_| {}))
}

/// The whole Sessions page: the tabs open right now (`active`), then the tmux
/// sessions still running on `servers` that no tab is attached to.
/// `on_focus` and `on_close` receive an `ActiveSession::id`.
pub fn sessions_page_with(servers: Vec<Server>, on_attach: Rc<dyn Fn(Server, String)>,
                          active: Vec<ActiveSession>, on_focus: Rc<dyn Fn(String)>,
                          on_close: Rc<dyn Fn(String)>) -> gtk::Widget {
    let root = gtk::Box::new(gtk::Orientation::Vertical, 12);
    root.set_margin_top(24);
    root.set_margin_bottom(24);
    root.set_margin_start(12);
    root.set_margin_end(12);

    let note_label = || {
        let l = gtk::Label::new(None);
        l.add_css_class("dim-label");
        l
    };

    let active_box = gtk::Box::new(gtk::Orientation::Vertical, 8);
    let active_head = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let active_note = note_label();
    active_head.append(&heading("Active"));
    active_head.append(&active_note);
    let active_list = boxed_list();
    active_box.append(&active_head);
    active_box.append(&active_list);

    let bg_box = gtk::Box::new(gtk::Orientation::Vertical, 8);
    bg_box.set_margin_top(12);
    let bg_head = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let bg_note = note_label();
    let refresh = gtk::Button::builder().label("Refresh").build();
    bg_head.append(&heading("Running in background"));
    bg_head.append(&bg_note);
    bg_head.append(&refresh);
    let bg_list = boxed_list();
    bg_box.append(&bg_head);
    bg_box.append(&bg_list);

    let empty = adw::StatusPage::builder()
        .icon_name("utilities-terminal-symbolic")
        .title("Nothing running")
        .description(if servers.is_empty() { "Add a server, then open a project on it." }
                     else { "Open a project from the dashboard and its session shows up here." })
        .vexpand(true)
        .build();
    let note = gtk::Label::builder().xalign(0.0).wrap(true).visible(false).build();
    note.add_css_class("dim-label");
    note.add_css_class("caption");

    root.append(&active_box);
    root.append(&bg_box);
    root.append(&empty);
    root.append(&note);

    let page = Rc::new(SessionsPage {
        servers, on_attach, on_focus, on_close,
        active: RefCell::new(active),
        found: RefCell::new(Vec::new()),
        failed: RefCell::new(Vec::new()),
        root: root.downgrade(),
        active_box, active_note, active_list, bg_box, bg_note, bg_list,
        empty, note, refresh: refresh.clone(), fetching: Cell::new(false),
    });
    keep(&root, &page);
    refresh.connect_clicked(glib::clone!(#[weak] page, move |_| page.fetch(true)));
    page.render();
    page.fetch(false);

    let clamp = adw::Clamp::builder().child(&root).maximum_size(820).build();
    gtk::ScrolledWindow::builder().child(&clamp).vexpand(true).build().upcast()
}
