Fixes silent loss of your projects.

Swift's synthesized Codable initialiser ignores property defaults, so every time
the app gained a new setting, configs written by an older version failed to
decode. The old error handling then reset to defaults and saved over the file,
taking your projects with it.

Config now decodes leniently — a missing key falls back to its default — and a
file that cannot be parsed is never overwritten. Every historical config format
is verified to load.
