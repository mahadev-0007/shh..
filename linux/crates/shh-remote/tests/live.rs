//! End-to-end checks against a real sshd. Ignored by default: they need
//! `root@127.0.0.1` with password `hunter2`, sshpass and tmux, which is what
//! the `shh-build` container provides.
//!
//!     cargo test -p shh-remote -- --ignored --test-threads=1

use base64::Engine;
use shh_core::server::Server;
use shh_remote::files::{self, RemoteFiles};
use shh_remote::{capabilities, clipboard, exec, fs, sessions};
use std::path::PathBuf;

fn server() -> Server {
    Server {
        name: "local-box".into(),
        host: "127.0.0.1".into(),
        user: "root".into(),
        port: "22".into(),
        auth: "pass".into(),
        secret: base64::engine::general_purpose::STANDARD.encode("hunter2"),
    }
}

/// A fresh directory on the "server" (the same machine), removed on drop.
struct Scratch(String);
impl Scratch {
    fn new(tag: &str) -> Scratch {
        let p = format!("/tmp/shh-live-{tag}-{}", std::process::id());
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        Scratch(p)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn sh(script: &str) -> String {
    let s = server();
    exec::ssh_script(&s, &exec::control_path(&s), true, script).expect("ssh")
}

#[test]
#[ignore]
fn files_round_trip() {
    let dir = Scratch::new("files");
    let f = RemoteFiles::new(server());

    // an awkward set of names: spaces, quotes, globs, a dotfile, a symlink
    f.make_directory(&files::join(&dir.0, "sub dir")).unwrap();
    f.make_directory(&files::join(&dir.0, "it's")).unwrap();
    std::fs::write(format!("{}/a*b.txt", dir.0), b"star").unwrap();
    std::fs::write(format!("{}/aXb.txt", dir.0), b"decoy").unwrap();
    std::fs::write(format!("{}/.hidden", dir.0), b"h").unwrap();
    std::fs::write(format!("{}/file10.txt", dir.0), b"0123456789").unwrap();
    std::fs::write(format!("{}/file2.txt", dir.0), b"x").unwrap();
    std::os::unix::fs::symlink(format!("{}/sub dir", dir.0), format!("{}/link", dir.0)).unwrap();

    let l = f.list(&dir.0).unwrap();
    assert_eq!(l.path, dir.0);
    let names: Vec<&str> = l.entries.iter().map(|e| e.name.as_str()).collect();
    for want in ["sub dir", "it's", "a*b.txt", "aXb.txt", ".hidden", "file10.txt", "file2.txt", "link"] {
        assert!(names.contains(&want), "missing {want} in {names:?}");
    }
    let get = |n: &str| l.entries.iter().find(|e| e.name == n).unwrap().clone();
    assert!(get("sub dir").is_dir && !get("sub dir").is_link);
    assert!(get("link").is_dir && get("link").is_link, "a link to a directory browses as one");
    assert!(!get("file10.txt").is_dir);
    assert_eq!(get("file10.txt").size, 10);
    assert!(get("file10.txt").modified > 1_600_000_000);
    assert!(get("file10.txt").mode.starts_with("-rw"), "mode was {:?}", get("file10.txt").mode);
    assert!(get(".hidden").is_hidden());
    // directories first, then natural order
    let pos = |n: &str| names.iter().position(|x| *x == n).unwrap();
    assert!(pos("sub dir") < pos("file2.txt"));
    assert!(pos("file2.txt") < pos("file10.txt"));

    // a trailing slash and a path that is not a directory
    assert_eq!(f.list(&format!("{}/", dir.0)).unwrap().path, dir.0);
    assert!(matches!(f.list(&format!("{}/nope", dir.0)), Err(exec::RemoteError::NotADirectory(_))));
    assert!(matches!(f.list(&format!("{}/file2.txt", dir.0)), Err(exec::RemoteError::NotADirectory(_))));

    // rename, and its refusal to clobber
    f.rename(&format!("{}/file2.txt", dir.0), &format!("{}/renamed two.txt", dir.0)).unwrap();
    assert!(std::path::Path::new(&format!("{}/renamed two.txt", dir.0)).exists());
    assert!(f.rename(&format!("{}/renamed two.txt", dir.0), &format!("{}/sub dir", dir.0)).is_err());
    assert!(std::path::Path::new(&format!("{}/renamed two.txt", dir.0)).exists());

    // upload a file and a folder with awkward names
    let local = Scratch::new("local");
    let up = PathBuf::from(format!("{}/up load's.txt", local.0));
    std::fs::write(&up, b"payload").unwrap();
    let folder = PathBuf::from(format!("{}/tree", local.0));
    std::fs::create_dir_all(folder.join("inner")).unwrap();
    std::fs::write(folder.join("inner/leaf.txt"), b"leaf").unwrap();
    f.upload(&[up.clone(), folder.clone()], &format!("{}/sub dir", dir.0)).unwrap();
    assert_eq!(std::fs::read(format!("{}/sub dir/up load's.txt", dir.0)).unwrap(), b"payload");
    assert_eq!(std::fs::read(format!("{}/sub dir/tree/inner/leaf.txt", dir.0)).unwrap(), b"leaf");

    // download: the glob character must not also fetch the decoy
    let star = PathBuf::from(format!("{}/got star.txt", local.0));
    let tree = PathBuf::from(format!("{}/got tree", local.0));
    f.download(&[
        (format!("{}/a*b.txt", dir.0), star.clone()),
        (format!("{}/sub dir/tree", dir.0), tree.clone()),
    ]).unwrap();
    assert_eq!(std::fs::read(&star).unwrap(), b"star");
    assert_eq!(std::fs::read(tree.join("inner/leaf.txt")).unwrap(), b"leaf");

    // delete, recursive, several at once
    f.delete(&[format!("{}/sub dir", dir.0), format!("{}/it's", dir.0), format!("{}/a*b.txt", dir.0)]).unwrap();
    let left: Vec<String> = f.list(&dir.0).unwrap().entries.into_iter().map(|e| e.name).collect();
    assert!(!left.contains(&"sub dir".to_string()) && !left.contains(&"it's".to_string()));
    assert!(left.contains(&"aXb.txt".to_string()), "the decoy must survive deleting a*b.txt");
    // the link's target is gone, so it is now a dangling link — still listed
    assert!(left.contains(&"link".to_string()));

    // an empty directory lists as empty, not as an error
    let empty = files::join(&dir.0, "empty");
    f.make_directory(&empty).unwrap();
    assert!(f.list(&empty).unwrap().entries.is_empty());
}

#[test]
#[ignore]
fn folder_listing() {
    let dir = Scratch::new("fs");
    std::fs::create_dir_all(format!("{}/Beta", dir.0)).unwrap();
    std::fs::create_dir_all(format!("{}/alpha one", dir.0)).unwrap();
    std::fs::write(format!("{}/file", dir.0), b"").unwrap();
    let l = fs::list(&server(), &dir.0).unwrap();
    assert_eq!(l.path, dir.0);
    assert_eq!(l.directories, vec!["alpha one", "Beta"]);

    // ~ resolves to the real home, which is what the project then stores
    let home = fs::list(&server(), "~").unwrap();
    assert_eq!(home.path, "/root");
    assert_eq!(fs::list(&server(), "").unwrap().path, "/root");
    // no subdirectories is an empty listing, not a failure
    assert!(fs::list(&server(), &format!("{}/Beta", dir.0)).unwrap().directories.is_empty());
    assert!(matches!(fs::list(&server(), "/definitely/not/here"),
                     Err(exec::RemoteError::NotADirectory(_))));
}

#[test]
#[ignore]
fn tmux_sessions() {
    let s = server();
    let name = format!("shh-live-test-1-{:04x}", std::process::id() & 0xffff);
    sh(&format!("tmux kill-session -t ={name} 2>/dev/null; tmux new-session -d -s {name} 'sleep 300'; \
                 tmux kill-session -t =not-ours 2>/dev/null; tmux new-session -d -s not-ours 'sleep 300'"));
    let list = sessions::list(&s).unwrap();
    let mine = list.iter().find(|b| b.name == name).expect("our session is listed");
    assert_eq!(mine.slug, "live-test");
    assert_eq!(mine.ordinal, 1);
    assert_eq!(mine.attached_clients, 0);
    assert!(mine.created > 1_600_000_000 && mine.last_activity >= mine.created);
    assert!(list.iter().all(|b| b.name != "not-ours"), "only shh- sessions are ours to show");

    sessions::kill(&s, &name, None).unwrap();
    assert!(sessions::list(&s).unwrap().iter().all(|b| b.name != name));
    // already gone counts as success
    sessions::kill(&s, &name, None).unwrap();
    sh("tmux kill-session -t =not-ours 2>/dev/null; true");
}

#[test]
#[ignore]
fn capability_probe() {
    let s = server();
    // the probe rides an existing master and never opens one itself
    sh("true");
    capabilities::probe(&s);
    assert_eq!(capabilities::has_tmux(&s), Some(true));
}

#[test]
#[ignore]
fn clipboard_uploads() {
    let s = server();
    sh("true"); // a session's master, which the bridge borrows
    let cp = exec::control_path(&s);

    let png = [0x89u8, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 1, 2, 3, 255, 254];
    let remote = clipboard::upload_png(&cp, &s.target(), &png).unwrap();
    assert!(remote.starts_with("/root/.cache/sshm-clip/clip-") && remote.ends_with(".png"), "{remote}");
    assert_eq!(std::fs::read(&remote).unwrap(), png, "binary bytes survive the trip");

    let local = Scratch::new("clip");
    let a = PathBuf::from(format!("{}/my notes.txt", local.0));
    std::fs::write(&a, b"notes").unwrap();
    let got = clipboard::upload_file(&cp, &s.target(), &a).unwrap();
    assert!(got.ends_with("/my notes.txt"), "{got}");
    assert_eq!(std::fs::read(&got).unwrap(), b"notes");
    assert_eq!(clipboard::typed(&[got.clone()]), format!("'{got}'"));
    let _ = std::fs::remove_file(&remote);

    // no master on that socket: a clear error, not a hang
    assert!(clipboard::upload_png("/tmp/no-such-socket.sock", &s.target(), &png).is_err());
}
