Two fixes.

- Full screen no longer leaves a black gutter down the right side. A required
  max-width on the content was bounding the whole window's fitting size, so the
  split view shrank the content area rather than just the text column.
- The terminal size slider works, and now applies to sessions that are already
  open instead of only future ones. Dragging it used to write the setting, which
  rebuilt the page and destroyed the slider mid-drag.
