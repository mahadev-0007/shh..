//! Custom icons live as files in `~/.config/sshm/icons/`; an IconRef of kind
//! "image" stores just the filename, so the config directory stays portable.
use gtk::gdk_pixbuf::{self, Pixbuf};
use gtk::gio;
use gtk::glib;
use shh_core::meta::IconRef;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};

pub const SIDE: i32 = 256;

pub fn dir() -> PathBuf {
    shh_core::paths::config_dir().join("icons")
}

fn ensure_dir() {
    let d = dir();
    if !d.exists() {
        let _ = std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&d);
    }
}

/// `<slug of the original name>-<6 hex>.png`, the Mac app's scheme.
pub fn filename_for(stem: &str) -> String {
    format!("{}-{}.png", shh_core::slug::make(stem), &shh_core::meta::new_id()[..6])
}

/// Decode image bytes (SVG included) to fit a `side` square.
pub fn pixbuf_from_bytes(bytes: &[u8], side: i32) -> Option<Pixbuf> {
    let stream = gio::MemoryInputStream::from_bytes(&glib::Bytes::from(bytes));
    Pixbuf::from_stream_at_scale(&stream, side, side, true, gio::Cancellable::NONE).ok()
}

/// Square, aspect-fit, transparent margin — so a wide wordmark and a square
/// glyph both sit correctly in the same chip.
pub fn normalise(src: &Pixbuf) -> Option<Pixbuf> {
    let src = if src.has_alpha() { src.clone() } else { src.add_alpha(false, 0, 0, 0).ok()? };
    let out = Pixbuf::new(gdk_pixbuf::Colorspace::Rgb, true, 8, SIDE, SIDE)?;
    out.fill(0);
    let (w, h) = (src.width().min(SIDE), src.height().min(SIDE));
    src.copy_area(0, 0, w, h, &out, (SIDE - w) / 2, (SIDE - h) / 2);
    Some(out)
}

/// Copy an image in, normalised to a 256px PNG. Anything gdk-pixbuf can open
/// works: png, jpeg, gif, tiff, webp, svg.
pub fn import_image(path: &Path) -> Option<IconRef> {
    let src = Pixbuf::from_file_at_scale(path, SIDE, SIDE, true).ok()?;
    let out = normalise(&src)?;
    ensure_dir();
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("icon");
    let name = filename_for(stem);
    out.savev(dir().join(&name), "png", &[]).ok()?;
    Some(IconRef { kind: "image".into(), value: name })
}

/// Every custom icon on disk, newest first.
pub fn all() -> Vec<IconRef> {
    let Ok(rd) = std::fs::read_dir(dir()) else { return Vec::new() };
    let mut files: Vec<(std::time::SystemTime, String)> = rd
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let ext = name.rsplit('.').next().unwrap_or("").to_lowercase();
            if !["png", "jpg", "jpeg", "heic", "tiff", "gif"].contains(&ext.as_str()) {
                return None;
            }
            let t = e.metadata().and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH);
            Some((t, name))
        })
        .collect();
    files.sort_by(|a, b| b.0.cmp(&a.0));
    files.into_iter().map(|(_, n)| IconRef { kind: "image".into(), value: n }).collect()
}

pub fn delete(icon: &IconRef) {
    // a bare filename only: never follow a path out of the icons folder
    if icon.kind == "image" && !icon.value.contains('/') && !icon.value.is_empty() {
        let _ = std::fs::remove_file(dir().join(&icon.value));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filenames_follow_the_mac_scheme() {
        let n = filename_for("My Logo@2x");
        assert!(n.starts_with("my-logo-2x-"), "{n}");
        assert!(n.ends_with(".png"));
        assert_eq!(n.len(), "my-logo-2x-".len() + 6 + 4);
        assert_ne!(filename_for("a"), filename_for("a"));
    }

    #[test]
    fn a_wide_image_is_centred_on_a_transparent_square() {
        let wide = Pixbuf::new(gdk_pixbuf::Colorspace::Rgb, false, 8, 256, 64).unwrap();
        wide.fill(0xff0000ff);
        let out = normalise(&wide).unwrap();
        assert_eq!((out.width(), out.height()), (256, 256));
        let px = |x: i32, y: i32| {
            let b = out.read_pixel_bytes();
            let i = (y * out.rowstride() + x * 4) as usize;
            [b[i], b[i + 1], b[i + 2], b[i + 3]]
        };
        assert_eq!(px(128, 10)[3], 0); // margin is transparent
        assert_eq!(px(128, 128), [255, 0, 0, 255]);
    }
}
