# shh 1.3.1

Sharing this Mac over Tailscale now works, and setting it up takes a couple
of clicks.

- **Sharing no longer fails with "Unexpected output from tailscale status".**
  shh could not read Tailscale's status when Tailscale was installed as the
  Mac app, so remote sessions never became ready. It does now.
- **Guided setup.** Settings › Sharing shows what is still missing, one step
  at a time, each with a button that fixes it. When everything is in place it
  collapses to a single "Ready" line.
- **Turn on Remote Login from shh.** One button and your Mac password, instead
  of a trip through System Settings. If that doesn't take, System Settings
  opens as before.
- **Simpler invites.** "Invite someone" copies the link for you, ready to
  paste into a message. The button only appears once setup is complete, so the
  "no ssh host key" error is gone.
