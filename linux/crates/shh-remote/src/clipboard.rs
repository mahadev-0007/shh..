//! Sends an image or files to the server over a live session's control socket
//! and hands back the remote path(s).
//!
//! Deliberately *not* a clipboard watcher: the upload happens only when you
//! paste or drop into a session, and the system clipboard is never written to.

use crate::exec::{self, RemoteError};
use crate::files;
use shh_core::{shell, tools};
use std::path::{Path, PathBuf};

pub const IMAGE_EXTENSIONS: [&str; 8] = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "bmp"];

/// True when a local file should travel as an image (normalised to PNG by the
/// caller) rather than as a plain file.
pub fn is_image_path(p: &Path) -> bool {
    p.extension().map(|e| IMAGE_EXTENSIONS.contains(&e.to_string_lossy().to_lowercase().as_str()))
        .unwrap_or(false)
}

/// "yyyyMMdd-HHmmss-NNNN" in local time, as the Mac app names uploads.
fn stamp() -> String {
    let mut buf = [0u8; 32];
    let n = unsafe {
        let t = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        libc::strftime(buf.as_mut_ptr() as *mut libc::c_char, buf.len(),
                       b"%Y%m%d-%H%M%S\0".as_ptr() as *const libc::c_char, &tm)
    };
    let r = 1000 + rand::random::<u32>() % 9000;
    format!("{}-{}", String::from_utf8_lossy(&buf[..n]), r)
}

fn mux(control_path: &str) -> Vec<String> {
    // ride the session's master: no handshake, and no password to supply
    vec!["-o".into(), format!("ControlPath={control_path}"), "-o".into(), "ControlMaster=no".into(),
         "-o".into(), "BatchMode=yes".into()]
}

fn last_line(e: RemoteError) -> String {
    match e {
        RemoteError::Exited(_, s) =>
            s.lines().filter(|l| !l.is_empty()).last().unwrap_or("The upload failed.").to_string(),
        other => other.to_string(),
    }
}

pub(crate) fn png_script(name: &str) -> String {
    format!("d=${{XDG_CACHE_HOME:-$HOME/.cache}}/sshm-clip; mkdir -p \"$d\" && cat > \"$d/{name}\" && printf '%s' \"$d/{name}\"")
}

/// Upload PNG bytes to `~/.cache/sshm-clip/` and return the remote path.
/// Blocking. Rides the session's existing control socket, so there is no
/// second handshake and no second password prompt.
pub fn upload_png(control_path: &str, target: &str, png: &[u8]) -> Result<String, String> {
    let name = format!("clip-{}.png", stamp());
    let args: Vec<String> = vec!["-S".into(), control_path.into(), "-o".into(), "BatchMode=yes".into(),
                                 target.into(), png_script(&name)];
    let out = exec::run(&tools::ssh(), &args, None, Some(png)).map_err(last_line)?;
    let path = out.trim();
    if path.is_empty() { Err("The upload failed.".into()) } else { Ok(path.to_string()) }
}

/// Upload local files or folders over sftp and return their remote paths, in
/// the order given. Each drop gets a directory of its own so the original
/// names survive and two drops of `notes.txt` can't overwrite each other.
pub fn upload_files(control_path: &str, target: &str, locals: &[PathBuf])
    -> Result<Vec<String>, String> {
    let script = format!("d=${{XDG_CACHE_HOME:-$HOME/.cache}}/sshm-clip/drop-{}; mkdir -p \"$d\" && printf '%s' \"$d\"",
                         stamp());
    let mut args = mux(control_path);
    args.extend([target.to_string(), script]);
    let dir = exec::run(&tools::ssh(), &args, None, None).map_err(|e| e.to_string())?;
    let dir = dir.trim();
    if dir.is_empty() {
        return Err("The upload failed.".into());
    }
    let remote: Vec<String> = locals.iter().map(|p| {
        files::join(dir, &p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default())
    }).collect();
    let batch: Vec<String> = locals.iter().zip(&remote).map(|(l, r)| {
        format!("put -r {} {}", files::sftp_quote(&l.to_string_lossy()), files::sftp_quote(r))
    }).collect();
    let mut args = mux(control_path);
    args.extend(["-b".into(), "-".into(), target.to_string()]);
    exec::run(&tools::sftp(), &args, None, Some((batch.join("\n") + "\n").as_bytes()))
        .map_err(|e| e.to_string())?;
    Ok(remote)
}

/// One file or folder; see `upload_files`.
pub fn upload_file(control_path: &str, target: &str, local: &Path) -> Result<String, String> {
    upload_files(control_path, target, &[local.to_path_buf()])?
        .into_iter().next().ok_or_else(|| "The upload failed.".to_string())
}

/// Paths as they should be typed into a shell or an agent prompt: bare when
/// that is unambiguous, single-quoted when a space or metacharacter would
/// split or expand them.
pub fn typed(paths: &[String]) -> String {
    const PLAIN: &str = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,@%:=";
    paths.iter().map(|p| {
        if p.chars().all(|c| PLAIN.contains(c)) { p.clone() } else { shell::quote(p) }
    }).collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn typing() {
        assert_eq!(typed(&["/a/b.png".into(), "/a/my file.txt".into()]), "/a/b.png '/a/my file.txt'");
    }

    #[test]
    fn stamp_shape() {
        let s = stamp();
        assert_eq!(s.len(), 20, "{s}");
        assert_eq!(&s[8..9], "-");
    }

    #[test]
    fn script_matches_the_mac_app() {
        assert_eq!(png_script("clip-x.png"),
            "d=${XDG_CACHE_HOME:-$HOME/.cache}/sshm-clip; mkdir -p \"$d\" && cat > \"$d/clip-x.png\" && printf '%s' \"$d/clip-x.png\"");
    }

    #[test]
    fn image_paths() {
        assert!(is_image_path(Path::new("/x/A.PNG")));
        assert!(!is_image_path(Path::new("/x/a.pdf")));
    }
}
