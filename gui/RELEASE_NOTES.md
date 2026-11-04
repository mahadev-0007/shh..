# shh 1.2.0

Let someone into your Mac with an invite, and move files without leaving shh.

- **Remote sessions over Tailscale.** Settings → Sharing → Allow remote
  sessions, then make an invite and send the link to one person. They click it
  (or use Servers → Join with invite, ⇧⌘J), you approve them by their Tailscale
  account, and they land in a shell on your Mac. Invites work once and expire in
  15 minutes; keys are locked to the guest's device, and Revoke ends their
  access and any open session. Needs Tailscale on both Macs and macOS Remote
  Login on the shared one
- **Files:** browse a server, and upload or download over the session's existing
  connection
- Drop or paste any file or folder into a session to upload it and type the
  remote path in; Option-drop types the local path instead
- A status card over a disconnected session, with reconnect, stop, end and close
- Drag session pills to reorder them like browser tabs
- Shift+Enter sends a newline inside tmux
- tmux is found even when it isn't on the bare PATH, and sessions run plainly
  when there is none
