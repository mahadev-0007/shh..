Sessions now survive a dropped connection, and tell you when they want you.

- Agents run inside tmux on the server, so a dropped link no longer kills the
  work — reconnecting lands back in the same agent, mid-conversation
- Automatic reconnect with backoff, paused while the Mac is offline, and never
  for a session you exited yourself
- macOS notifications on the bell, on connection changes, and optionally when a
  long run goes quiet — only for a session you aren't already watching
- Right-click a tab to duplicate a session; a project can have several, each an
  independent agent
- Exit codes are decoded correctly for the first time; ssh's 255 was arriving as
  65280, so none of the error messages had ever matched
