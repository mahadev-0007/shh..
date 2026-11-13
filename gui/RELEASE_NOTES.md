# shh 1.3.0

Voice mode works in remote sessions, and scrolling feels native again.

- **Voice mode over SSH.** Claude Code's voice mode on the server now hears
  this Mac's microphone, through the session's own SSH connection. Hold the
  voice key and talk, just like running Claude locally. The mic is only open
  while you're holding the key. macOS asks for microphone access the first
  time. Turn it off under Settings › Sessions › Voice input. Start Claude in a
  new session after updating: sessions already running keep their old setup.
- **Native scrolling in durable sessions.** The scroll wheel now scrolls back
  through the session's output, instead of stepping through Claude Code's
  prompt history. Hold Shift while dragging to select text the usual way.
