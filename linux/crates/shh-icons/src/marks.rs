//! Vector marks for the seeded agents, generated as SVG from the same
//! geometry the Mac app draws with, so there are no image assets to bundle.
//!
//! These are simplified, recognisable marks — not official artwork. For an
//! exact logo, add the real file through the picker's Custom tab.
use std::f64::consts::PI;
use std::fmt::Write;

pub const IDS: [&str; 10] = [
    "claude", "openai", "gemini", "command", "cursor", "terminal", "tmux", "editor", "aider",
    "opencode",
];

pub fn name(id: &str) -> &str {
    match id {
        "claude" => "Claude",
        "openai" => "OpenAI / Codex",
        "gemini" => "Gemini",
        "command" => "Command Code",
        "cursor" => "Cursor",
        "terminal" => "Terminal",
        "tmux" => "tmux",
        "editor" => "Editor",
        "aider" => "Aider",
        "opencode" => "opencode",
        other => other,
    }
}

pub fn tint(id: &str) -> &'static str {
    match id {
        "claude" => "#d97047",
        "openai" => "#0fa687",
        "gemini" => "#5287f5",
        "command" => "#c7b8f5",
        _ => "#d9d9d9",
    }
}

const S: f64 = 128.0;
const C: f64 = 64.0;
const R: f64 = 64.0;

fn p(x: f64, y: f64) -> String {
    format!("{x:.2} {y:.2}")
}

fn stroke(d: &str, width: f64, color: &str) -> String {
    format!(
        "<path d=\"{d}\" fill=\"none\" stroke=\"{color}\" stroke-width=\"{width:.2}\" \
         stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
    )
}

/// The SVG for a mark, or None for an id this build doesn't draw.
pub fn svg(id: &str) -> Option<String> {
    if !IDS.contains(&id) {
        return None;
    }
    let color = tint(id);
    let body = match id {
        "claude" => burst(R * 0.92, 11, color),
        "openai" => knot(R * 0.86, color),
        "gemini" => sparkle(R * 0.95, color),
        "command" => command(R * 0.92, color),
        "cursor" => chevron_cube(R * 0.8, color),
        "tmux" => panes(R * 0.82, color),
        "editor" => caret(R * 0.8, color),
        "aider" => hammer(R * 0.8, color),
        "opencode" => braces(R * 0.85, color),
        _ => prompt(R * 0.8, color),
    };
    // The geometry is AppKit's, y pointing up; one flip puts it the right way.
    Some(format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{S}\" height=\"{S}\" \
         viewBox=\"0 0 {S} {S}\"><g transform=\"matrix(1 0 0 -1 0 {S})\">{body}</g></svg>"
    ))
}

/// A radial burst of tapered rays, widest at the rim.
fn burst(radius: f64, rays: usize, color: &str) -> String {
    let half = (PI / rays as f64) * 0.46;
    let apex = radius * 0.06;
    let mut d = String::new();
    for i in 0..rays {
        let a = (i as f64 / rays as f64) * PI * 2.0 - PI / 2.0;
        let _ = write!(
            d,
            "M{} L{} L{} Z ",
            p(C + a.cos() * apex, C + a.sin() * apex),
            p(C + (a - half).cos() * radius, C + (a - half).sin() * radius),
            p(C + (a + half).cos() * radius, C + (a + half).sin() * radius)
        );
    }
    format!("<path d=\"{d}\" fill=\"{color}\"/>")
}

/// Three overlapping rounded lobes: a simplified interlaced knot.
fn knot(radius: f64, color: &str) -> String {
    let mut d = String::new();
    for i in 0..3 {
        let rot = i as f64 * (PI * 2.0 / 3.0);
        for step in 0..=36 {
            let t = step as f64 / 36.0;
            let a = -PI / 3.0 + t * (PI * 4.0 / 3.0) + rot;
            let rr = radius * (0.62 + 0.20 * (t * PI).cos());
            let _ = write!(
                d,
                "{}{} ",
                if step == 0 { "M" } else { "L" },
                p(C + a.cos() * rr, C + a.sin() * rr)
            );
        }
    }
    stroke(&d, radius * 0.17, color)
}

/// The four-pointed star.
fn sparkle(radius: f64, color: &str) -> String {
    let mut d = String::new();
    for i in 0..4 {
        let a = (i as f64 / 4.0) * PI * 2.0 - PI / 2.0;
        let next = a + PI / 2.0;
        let mid = a + PI / 4.0;
        let waist = p(C + mid.cos() * radius * 0.14, C + mid.sin() * radius * 0.14);
        if i == 0 {
            let _ = write!(d, "M{} ", p(C + a.cos() * radius, C + a.sin() * radius));
        }
        let _ = write!(
            d,
            "C{waist} {waist} {} ",
            p(C + next.cos() * radius, C + next.sin() * radius)
        );
    }
    d.push('Z');
    format!("<path d=\"{d}\" fill=\"{color}\"/>")
}

/// The ⌘ glyph: a square whose four corners curl into 3/4 loops.
fn command(radius: f64, color: &str) -> String {
    let r = radius * 0.23;
    let a = radius * 0.46;
    let corners = [(C + a, C + a), (C + a, C - a), (C - a, C - a), (C - a, C + a)];
    let spans = [(180.0, 270.0), (90.0, 180.0), (0.0, 90.0), (270.0, 0.0)];
    let mut d = String::new();
    let mut first = true;
    for ((cx, cy), (start, end)) in corners.iter().zip(spans.iter()) {
        // clockwise in a y-up space means the angle decreases
        let (start, mut end): (f64, f64) = (*start, *end);
        while end >= start {
            end -= 360.0;
        }
        let steps = 40;
        for s in 0..=steps {
            let deg = start + (end - start) * (s as f64 / steps as f64);
            let rad = deg.to_radians();
            let _ = write!(
                d,
                "{}{} ",
                if first { "M" } else { "L" },
                p(cx + rad.cos() * r, cy + rad.sin() * r)
            );
            first = false;
        }
    }
    d.push('Z');
    stroke(&d, radius * 0.155, color)
}

fn chevron_cube(radius: f64, color: &str) -> String {
    let outer = format!(
        "M{} L{} L{} L{} Z",
        p(C, C + radius),
        p(C - radius * 0.86, C - radius * 0.5),
        p(C, C - radius),
        p(C + radius * 0.86, C - radius * 0.5)
    );
    let inner = format!("M{} L{}", p(C, C + radius), p(C, C - radius));
    format!(
        "{}<path d=\"{inner}\" fill=\"none\" stroke=\"{color}\" stroke-width=\"{:.2}\"/>",
        stroke(&outer, radius * 0.18, color),
        radius * 0.16
    )
}

fn panes(radius: f64, color: &str) -> String {
    let (x, y, w, h) = (C - radius, C - radius * 0.78, radius * 2.0, radius * 1.56);
    let lw = radius * 0.15;
    format!(
        "<rect x=\"{x:.2}\" y=\"{y:.2}\" width=\"{w:.2}\" height=\"{h:.2}\" rx=\"{:.2}\" \
         fill=\"none\" stroke=\"{color}\" stroke-width=\"{lw:.2}\"/>\
         <path d=\"M{} L{}\" fill=\"none\" stroke=\"{color}\" stroke-width=\"{lw:.2}\"/>",
        radius * 0.18,
        p(C, y),
        p(C, y + h)
    )
}

fn caret(radius: f64, color: &str) -> String {
    let left = C - radius * 0.75;
    let d = format!(
        "M{} L{} M{} L{} M{} L{}",
        p(left, C + radius * 0.6),
        p(C + radius * 0.2, C + radius * 0.6),
        p(left, C),
        p(C + radius * 0.55, C),
        p(left, C - radius * 0.6),
        p(C, C - radius * 0.6)
    );
    stroke(&d, radius * 0.2, color)
}

/// A hammer: a diagonal handle with a slab head, which stays readable small.
fn hammer(radius: f64, color: &str) -> String {
    let handle = format!(
        "M{} L{}",
        p(C - radius * 0.62, C - radius * 0.72),
        p(C + radius * 0.24, C + radius * 0.16)
    );
    format!(
        "{}<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"{:.2}\" \
         fill=\"{color}\" transform=\"rotate(45 {:.2} {:.2})\"/>",
        stroke(&handle, radius * 0.24, color),
        C - radius * 0.02,
        C + radius * 0.16,
        radius * 0.92,
        radius * 0.46,
        radius * 0.12,
        C + radius * 0.44,
        C + radius * 0.39
    )
}

fn braces(radius: f64, color: &str) -> String {
    let mut d = String::new();
    for sign in [-1.0, 1.0] {
        let x = C + sign * radius * 0.52;
        let _ = write!(
            d,
            "M{} L{} L{} L{} L{} ",
            p(x - sign * radius * 0.28, C + radius * 0.82),
            p(x, C + radius * 0.42),
            p(x + sign * radius * 0.26, C),
            p(x, C - radius * 0.42),
            p(x - sign * radius * 0.28, C - radius * 0.82)
        );
    }
    stroke(&d, radius * 0.17, color)
}

fn prompt(radius: f64, color: &str) -> String {
    let d = format!(
        "M{} L{} L{} M{} L{}",
        p(C - radius * 0.7, C + radius * 0.45),
        p(C - radius * 0.1, C - radius * 0.05),
        p(C - radius * 0.7, C - radius * 0.55),
        p(C + radius * 0.1, C - radius * 0.55),
        p(C + radius * 0.72, C - radius * 0.55)
    );
    stroke(&d, radius * 0.2, color)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_mark_renders_to_pixels() {
        for id in IDS {
            let svg = svg(id).unwrap();
            let pb = crate::store::pixbuf_from_bytes(svg.as_bytes(), 64)
                .unwrap_or_else(|| panic!("{id} did not parse as SVG"));
            assert_eq!((pb.width(), pb.height()), (64, 64), "{id}");
            // something was actually drawn
            let bytes = pb.read_pixel_bytes();
            let n = pb.n_channels() as usize;
            let inked = bytes.chunks(n).filter(|px| px[n - 1] > 0).count();
            assert!(inked > 100, "{id} is blank ({inked} px)");
        }
    }

    #[test]
    fn unknown_ids_are_refused() {
        assert!(svg("nope").is_none());
        assert_eq!(name("claude"), "Claude");
        assert_eq!(name("nope"), "nope");
    }

    #[test]
    fn seeded_agents_all_have_a_mark() {
        for a in shh_core::meta::seed_agents() {
            let icon = a.icon.unwrap();
            assert!(svg(&icon.value).is_some(), "{} has no mark", icon.value);
        }
    }
}
