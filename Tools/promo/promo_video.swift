import AVFoundation
import Cocoa

// Avro Next promo film (1920x1080, 30 fps), timed to the narration.
//
// Every Bangla word and every suggestion list comes from the real riti engine
// through AvroEngine and CandidateState, the same path the input method uses.
// The Settings shots are the real Settings window, rendered offscreen. The
// editor window, candidate bar and notification are drawn to match the app.
//
// Inputs: Tools/promo/script.json and <media>/timing.json (from build_voice.py).
// Outputs: <media>/video.mp4 (no audio) and <media>/cues.json (key presses, for sound).
//
// Usage: promo_video <riti data dir> <script.json> <media dir> [--stills <dir>] [--only <line id>]

// MARK: - Inputs

struct ScriptLine: Decodable {
    let id: String; let scene: String; let spoken: String; let caption: String
    /// For a non-English script: the scene's English cue word -> the word spoken at that moment.
    let cues: [String: String]?
}
struct Script: Decodable { let lines: [ScriptLine] }
struct LineTime: Decodable { let id: String; let start: Double; let end: Double }
struct Timing: Decodable { let total: Double; let lines: [LineTime] }

let argv = CommandLine.arguments
guard argv.count >= 4 else { print("usage: promo_video <dataDir> <script.json> <mediaDir> [--stills dir]"); exit(2) }
let dataDir = argv[1], mediaDir = argv[3]
let stillsDir: String? = argv.firstIndex(of: "--stills").map { argv[$0 + 1] }
let script = try JSONDecoder().decode(Script.self, from: Data(contentsOf: URL(fileURLWithPath: argv[2])))
let timing = try JSONDecoder().decode(Timing.self, from: Data(contentsOf: URL(fileURLWithPath: mediaDir + "/timing.json")))
precondition(script.lines.map(\.id) == timing.lines.map(\.id), "script.json and timing.json are out of step: rerun build_voice.py")

let FPS = 30
let W: CGFloat = 1280, H: CGFloat = 720            // drawing coordinates
let OUT_W = 1920, OUT_H = 1080                      // output pixels (drawn at 1.5x)
let SCALE = CGFloat(OUT_W) / W

func frameAt(_ seconds: Double) -> Int { Int((seconds * Double(FPS)).rounded()) }
let totalFrames = frameAt(timing.total)

/// Letters and digits only (Bengali vowel signs included), so spaces and punctuation don't skew timing.
func letterCount(_ s: Substring) -> Int {
    s.unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil
        || (0x0980...0x09FF).contains($0.value) }.count
}

/// The moment a word is spoken, estimated from the share of letters before it in the line.
func wordTime(_ lineIndex: Int, _ word: String) -> Double {
    let line = script.lines[lineIndex], t = timing.lines[lineIndex]
    let target = line.cues?[word] ?? word
    // Literal code-unit search: a Bengali stem like "সিলিকন" ends inside the grapheme "নে" of
    // "সিলিকনের", which Swift's character-based String.range(of:) never matches.
    let spoken = line.spoken as NSString
    let r = spoken.range(of: target, options: [.literal, .caseInsensitive])
    guard r.location != NSNotFound else { fatalError("cue “\(target)” is not in line “\(line.id)”") }
    let before = Substring(spoken.substring(to: r.location))
    let frac = Double(letterCount(before)) / Double(max(letterCount(Substring(line.spoken)), 1))
    return t.start + frac * (t.end - t.start)
}

// MARK: - Engine (fresh user dir, like a new install)

let userDir = NSTemporaryDirectory() + "avro-promo-\(getpid())"
try? FileManager.default.createDirectory(atPath: userDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: userDir) }
guard let engine = AvroEngine(databaseDir: dataDir, userDir: userDir) else { print("engine init failed"); exit(1) }

// MARK: - Real Settings window, rendered offscreen

NSApplication.shared.setActivationPolicy(.accessory)
struct SettingsShot { let image: NSImage; let marks: [String: NSRect] }   // marks in image points (top-left origin)

func settingsShots() -> [String: SettingsShot] {
    // The renderer has its own bundle id (embedded Info.plist), so these writes
    // never touch the real Avro Next preferences.
    let defaultsDomain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    precondition(defaultsDomain != "org.avronext.inputmethod.AvroNext", "renderer must not use the app's defaults")
    defer { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }
    UserDefaults.standard.removePersistentDomain(forName: defaultsDomain)
    let controller = SettingsWindowController.shared
    let window = controller.window!
    window.appearance = NSAppearance(named: .aqua)
    let content = window.contentView!

    func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
    func shot() -> SettingsShot {
        content.layoutSubtreeIfNeeded()
        let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: rep)
        let img = NSImage(size: content.bounds.size)
        img.addRepresentation(rep)
        var marks: [String: NSRect] = [:]
        for v in all(content) where !v.isHiddenOrHasHiddenAncestor {
            var key: String?
            if let p = v as? NSPopUpButton { key = "popup:" + (p.titleOfSelectedItem ?? "") }
            else if let b = v as? NSButton { key = "button:" + b.title }
            else if let t = v as? NSTextField, !t.isEditable { key = "label:" + t.stringValue }
            guard let key else { continue }
            var r = v.convert(v.bounds, to: content)
            r.origin.y = content.bounds.height - r.maxY           // flip to top-left origin
            marks[key] = r
        }
        return SettingsShot(image: img, marks: marks)
    }
    var shots: [String: SettingsShot] = [:]
    let layoutPopup = all(content).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("Khipro") }!
    for (i, name) in ["phonetic", "khipro", "probhat"].enumerated() {
        layoutPopup.selectItem(at: i)
        _ = layoutPopup.target?.perform(layoutPopup.action, with: layoutPopup)
        shots[name] = shot()
    }
    layoutPopup.selectItem(at: 0)
    _ = layoutPopup.target?.perform(layoutPopup.action, with: layoutPopup)
    return shots
}
let settings = settingsShots()

// MARK: - Drawing helpers

let accent = NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1)
let green1 = NSColor(srgbRed: 0.05, green: 0.55, blue: 0.42, alpha: 1)
let green2 = NSColor(srgbRed: 0.02, green: 0.24, blue: 0.30, alpha: 1)

func bangla(_ size: CGFloat, bold: Bool = false) -> NSFont {
    NSFont(name: bold ? "KohinoorBangla-Semibold" : "KohinoorBangla-Regular", size: size)
        ?? .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
}
func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }

@discardableResult
func text(_ s: String, _ font: NSFont, _ color: NSColor, _ p: NSPoint, extra: [NSAttributedString.Key: Any] = [:]) -> CGFloat {
    var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    a.merge(extra) { $1 }
    let s = NSAttributedString(string: s, attributes: a)
    s.draw(at: p)
    return s.size().width
}
func measure(_ s: String, _ font: NSFont) -> NSSize { NSAttributedString(string: s, attributes: [.font: font]).size() }
func centered(_ s: String, _ font: NSFont, _ color: NSColor, y: CGFloat, x: CGFloat = W / 2) {
    text(s, font, color, NSPoint(x: x - measure(s, font).width / 2, y: y))
}
func rounded(_ r: NSRect, _ radius: CGFloat, _ color: NSColor) {
    color.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
}
func shadowed(_ blur: CGFloat, _ dy: CGFloat, _ alpha: CGFloat, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow(); s.shadowBlurRadius = blur; s.shadowOffset = NSSize(width: 0, height: -dy)
    s.shadowColor = NSColor(white: 0, alpha: alpha); s.set()
    body()
    NSGraphicsContext.restoreGraphicsState()
}
/// Draws `body` with an overall opacity (and an optional upward slide).
func faded(_ alpha: CGFloat, rise: CGFloat = 0, _ body: () -> Void) {
    guard alpha > 0.001, let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.saveGState(); ctx.setAlpha(min(alpha, 1)); ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.translateBy(x: 0, y: -rise * (1 - min(alpha, 1)))
    body()
    ctx.endTransparencyLayer(); ctx.restoreGState()
}
func ease(_ x: Double) -> CGFloat { let t = min(max(x, 0), 1); return CGFloat(t * t * (3 - 2 * t)) }
/// 0 → 1 over `dur` seconds starting at `t0`.
func appear(_ now: Double, _ t0: Double, _ dur: Double = 0.35) -> CGFloat { ease((now - t0) / dur) }

func background() {
    NSGradient(starting: green1, ending: green2)!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -60)
}

func appIcon(_ r: NSRect, onDark: Bool = true) {
    if onDark { rounded(r, r.width * 0.23, NSColor(white: 1, alpha: 0.16)) }
    else { NSGradient(starting: green1, ending: green2)!.draw(in: NSBezierPath(roundedRect: r, xRadius: r.width * 0.23, yRadius: r.width * 0.23), angle: -90) }
    let f = bangla(r.width * 0.68, bold: true), g = measure("অ", f)
    text("অ", f, .white, NSPoint(x: r.midX - g.width / 2, y: r.midY - g.height / 2))
}

func chip(_ s: String, center: NSPoint, alpha: CGFloat, filled: Bool = false) {
    let f = ui(26, .semibold), sz = measure(s, f)
    let r = NSRect(x: center.x - sz.width / 2 - 22, y: center.y - 26, width: sz.width + 44, height: 52)
    faded(alpha, rise: 18) {
        rounded(r, 26, filled ? .white : NSColor(white: 1, alpha: 0.16))
        text(s, f, filled ? green2 : .white, NSPoint(x: r.minX + 22, y: r.minY + 12))
    }
}

// MARK: - Editor and candidate bar

var editorLines: [String] = [""]
var state = CandidateState()
var keyLabel = "", keyFrame = -999
var cues: [Double] = []                       // key-press times, for the sound mix

func candidateBar(_ items: [String], _ selected: Int, at origin: NSPoint) {
    // Shows every candidate, like the app; shrinks the text when the row would run off screen.
    func widthsFor(_ size: CGFloat) -> [CGFloat] {
        items.enumerated().map { measure("\($0.offset + 1) ", ui(size * 0.65)).width + measure($0.element, bangla(size)).width + 20 * size / 26 }
    }
    let room = W - origin.x - 24
    var size: CGFloat = 26
    while size > 15 && widthsFor(size).reduce(0, +) + CGFloat(items.count) * 3 + 10 > room { size -= 1 }
    let font = bangla(size), num = ui(size * 0.65)
    let pad: CGFloat = 5, gap: CGFloat = 3, cellH: CGFloat = 46 * size / 26
    let widths = widthsFor(size)
    let bar = NSRect(x: origin.x, y: origin.y - cellH - pad * 2,
                     width: widths.reduce(0, +) + gap * CGFloat(items.count - 1) + pad * 2, height: cellH + pad * 2)
    shadowed(14, 4, 0.28) { rounded(bar, 10, NSColor(white: 0.97, alpha: 1)) }
    var x = bar.minX + pad
    for (i, s) in items.enumerated() {
        let cell = NSRect(x: x, y: bar.minY + pad, width: widths[i], height: cellH)
        let on = i == selected
        if on { rounded(cell, 7, accent) }
        let inset = 10 * size / 26
        let nw = text("\(i + 1) ", num, on ? NSColor(white: 1, alpha: 0.85) : NSColor(white: 0.45, alpha: 1),
                      NSPoint(x: cell.minX + inset, y: cell.minY + 12 * size / 26))
        text(s, font, on ? .white : .black, NSPoint(x: cell.minX + inset + nw, y: cell.minY + 6 * size / 26))
        x += widths[i] + gap
    }
}

func menuBar() {
    rounded(NSRect(x: 0, y: H - 30, width: W, height: 30), 0, NSColor(white: 1, alpha: 0.82))
    text("", ui(18), .black, NSPoint(x: 20, y: H - 27))
    text("Notes", ui(15, .semibold), .black, NSPoint(x: 52, y: H - 25))
    let ind = NSRect(x: W - 118, y: H - 25, width: 26, height: 20)
    rounded(ind, 5, .black)
    text("অ", bangla(15, bold: true), .white, NSPoint(x: ind.minX + 6, y: ind.minY - 1))
    text("Avro Next", ui(14), .black, NSPoint(x: W - 86, y: H - 24))
}

func editor(frame f: Int) {
    menuBar()
    let win = NSRect(x: 140, y: 150, width: 1000, height: 470)
    let path = NSBezierPath(roundedRect: win, xRadius: 14, yRadius: 14)
    shadowed(30, 10, 0.35) { NSColor.white.setFill(); path.fill() }
    NSGraphicsContext.saveGraphicsState(); path.addClip()
    let bar = NSRect(x: win.minX, y: win.maxY - 46, width: win.width, height: 46)
    rounded(bar, 0, NSColor(white: 0.955, alpha: 1))
    rounded(NSRect(x: win.minX, y: bar.minY, width: win.width, height: 1), 0, NSColor(white: 0.86, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        c.setFill(); NSBezierPath(ovalIn: NSRect(x: win.minX + 20 + CGFloat(i) * 22, y: bar.midY - 7, width: 14, height: 14)).fill()
    }
    centered("আমার নোট", bangla(16, bold: true), NSColor(white: 0.25, alpha: 1), y: bar.minY + 11, x: win.midX)

    // Keep the newest lines visible.
    let visible = editorLines.suffix(5)
    let font = bangla(36)
    var y = bar.minY - 74
    for (i, line) in visible.enumerated() {
        let left = win.minX + 44
        var x = left + text(line, font, .black, NSPoint(x: left, y: y))
        if i == visible.count - 1 {
            let markX = x
            if let cur = state.current {
                x += text(cur, font, .black, NSPoint(x: x, y: y),
                          extra: [.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: accent])
            }
            if (f / 16) % 2 == 0 || state.current != nil { rounded(NSRect(x: x + 2, y: y + 6, width: 2.5, height: 42), 0, .black) }
            if state.items.count > 1 { candidateBar(state.items, state.selected, at: NSPoint(x: markX - 6, y: y - 4)) }
        }
        y -= 62
    }

    // The key being pressed.
    let age = f - keyFrame
    if age < 22 && !keyLabel.isEmpty {
        let a = age < 14 ? 1.0 : 1.0 - CGFloat(age - 14) / 8
        let kf = NSFont.monospacedSystemFont(ofSize: 24, weight: .semibold), ks = measure(keyLabel, kf)
        let pill = NSRect(x: win.maxX - ks.width - 64, y: win.minY + 22, width: ks.width + 36, height: 42)
        rounded(pill, 10, NSColor(white: 0, alpha: 0.62 * a))
        text(keyLabel, kf, NSColor(white: 1, alpha: a), NSPoint(x: pill.minX + 18, y: pill.minY + 8))
    }
}

// MARK: - Scenes (drawn per frame from the current line)

var lineIndex = 0
var frameNo = 0

func lineT(_ id: String) -> LineTime { timing.lines.first { $0.id == id }! }
func lineI(_ id: String) -> Int { timing.lines.firstIndex { $0.id == id }! }

func drawTitle(_ now: Double) {
    let a = appear(now, 0.2, 0.6)
    faded(a, rise: 30) {
        appIcon(NSRect(x: W / 2 - 75, y: 380, width: 150, height: 150))
        centered("Avro Next", ui(78, .bold), .white, y: 262)
        centered("Bangla typing for Apple Silicon Macs", ui(30, .medium), NSColor(white: 1, alpha: 0.85), y: 212)
    }
}

func drawProblem(_ now: Double) {
    let i = lineI("problem")
    // Old: iAvro, crossed out.
    let left = NSRect(x: 200, y: 260, width: 330, height: 200)
    faded(appear(now, timing.lines[i].start), rise: 20) {
        rounded(left, 22, NSColor(white: 0, alpha: 0.22))
        centered("iAvro", ui(48, .bold), NSColor(white: 1, alpha: 0.55), y: left.midY + 2, x: left.midX)
        centered("Intel only · stopped working", ui(20, .medium), NSColor(white: 1, alpha: 0.55), y: left.midY - 42, x: left.midX)
        let cross = appear(now, wordTime(i, "stopped"), 0.25)
        NSColor(srgbRed: 1, green: 0.35, blue: 0.35, alpha: cross).setStroke()
        let p = NSBezierPath(); p.lineWidth = 7; p.lineCapStyle = .round
        p.move(to: NSPoint(x: left.minX + 40, y: left.midY + 24)); p.line(to: NSPoint(x: left.minX + 40 + (left.width - 80) * cross, y: left.midY + 24))
        p.stroke()
    }
    // New: Avro Next, on "Meet".
    let meet = wordTime(i, "Meet")
    let right = NSRect(x: 750, y: 245, width: 330, height: 230)
    let arrowA = appear(now, meet - 0.3, 0.3)
    faded(arrowA) {
        NSColor(white: 1, alpha: 0.85).setStroke()
        let p = NSBezierPath(); p.lineWidth = 6; p.lineCapStyle = .round; p.lineJoinStyle = .round
        p.move(to: NSPoint(x: 572, y: 360)); p.line(to: NSPoint(x: 708, y: 360))
        p.move(to: NSPoint(x: 690, y: 378)); p.line(to: NSPoint(x: 710, y: 360)); p.line(to: NSPoint(x: 690, y: 342))
        p.stroke()
    }
    faded(appear(now, meet, 0.4), rise: 24) {
        shadowed(24, 8, 0.25) { rounded(right, 26, .white) }
        appIcon(NSRect(x: right.midX - 46, y: right.maxY - 112, width: 92, height: 92), onDark: false)
        centered("Avro Next", ui(44, .bold), green2, y: right.minY + 46, x: right.midX)
    }
}

func drawNative(_ now: Double) {
    let i = lineI("native")
    appIcon(NSRect(x: W / 2 - 55, y: 450, width: 110, height: 110))
    centered("Avro Next", ui(54, .bold), .white, y: 372)
    // An evenly spaced row of chips, each landing on its word.
    let chips: [(String, String)] = [("Free", "free"), ("Native on Apple Silicon", "Apple Silicon"), ("Ready for macOS 27", "macOS")]
    let gap: CGFloat = 26, font = ui(26, .semibold)
    let widths = chips.map { measure($0.0, font).width + 44 }
    var x = W / 2 - (widths.reduce(0, +) + gap * CGFloat(chips.count - 1)) / 2
    for (k, c) in chips.enumerated() {
        chip(c.0, center: NSPoint(x: x + widths[k] / 2, y: 280), alpha: appear(now, wordTime(i, c.1)), filled: true)
        x += widths[k] + gap
    }
    faded(appear(now, wordTime(i, "macOS") + 0.6)) {
        centered("No Rosetta needed · macOS 13 or later", ui(22, .medium), NSColor(white: 1, alpha: 0.8), y: 200)
    }
}

/// One scale for every Settings shot (fitted to the tallest), so the window
/// doesn't jump when the Probhat options appear.
let settingsScale: CGFloat = {
    let tallest = settings.values.map(\.image.size.height).max() ?? 500
    let room = (H - 30 - 16) - 140 - 34            // below the menu bar, above the caption, minus title bar
    return min(0.92, room / tallest)
}()

func settingsCard(_ shot: SettingsShot, _ now: Double, start: Double, rings: [(String, Double)]) {
    // The real window image, top-aligned under the menu bar, with a window frame around it.
    let scale = settingsScale
    let size = NSSize(width: shot.image.size.width * scale, height: shot.image.size.height * scale)
    let titleH: CGFloat = 34
    let x0 = W / 2 - size.width / 2
    let y0 = H - 30 - 16 - titleH - size.height
    let frame = NSRect(x: x0, y: y0, width: size.width, height: size.height + titleH)
    menuBar()
    faded(appear(now, start, 0.4), rise: 20) {
        shadowed(30, 10, 0.35) { rounded(frame, 12, NSColor(white: 0.985, alpha: 1)) }
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill(); NSBezierPath(ovalIn: NSRect(x: frame.minX + 14 + CGFloat(i) * 20, y: frame.maxY - 23, width: 12, height: 12)).fill()
        }
        centered("Avro Next Settings", ui(13, .semibold), NSColor(white: 0.3, alpha: 1), y: frame.maxY - 26, x: frame.midX)
        shot.image.draw(in: NSRect(x: x0, y: y0, width: size.width, height: size.height))
        // Highlight rings on the controls being named.
        for (key, t0) in rings {
            guard let m = shot.marks[key] else { continue }
            let a = appear(now, t0, 0.25)
            guard a > 0 else { continue }
            let r = NSRect(x: x0 + m.minX * scale - 4, y: y0 + size.height - m.maxY * scale - 6,
                           width: m.width * scale + 8, height: m.height * scale + 12)
            accent.withAlphaComponent(0.95 * a).setStroke()
            let p = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9); p.lineWidth = 3.5; p.stroke()
            accent.withAlphaComponent(0.10 * a).setFill(); p.fill()
        }
    }
}

func drawLayouts(_ now: Double) {
    let i = lineI("layouts")
    let tK = wordTime(i, "Khipro"), tP = wordTime(i, "Probhat")
    let (name, key): (String, String) = now >= tP ? ("probhat", "popup:Probhat (Fixed)")
        : now >= tK ? ("khipro", "popup:Khipro") : ("phonetic", "popup:Avro Phonetic")
    settingsCard(settings[name]!, now, start: timing.lines[i].start, rings: [(key, timing.lines[i].start + 0.2)])
}

func drawSettingsMore(_ now: Double) {
    let i = lineI("settings")
    let shot = settings["phonetic"]!
    let style = shot.marks.keys.first { $0.hasPrefix("popup:Compact") } ?? "popup:Compact row"
    let font = shot.marks.keys.first { $0.hasPrefix("label:") && $0.hasSuffix(" pt") } ?? "label:13 pt"
    settingsCard(shot, now, start: timing.lines[lineI("layouts")].start, rings: [
        (style, wordTime(i, "suggestion bar")),
        (font, wordTime(i, "font size")),
        ("button:Use smart (curly) quotes", wordTime(i, "smart quotes")),
        ("button:Auto-Correct…", wordTime(i, "auto correct")),
    ])
}

func drawUpdates(_ now: Double) {
    let i = lineI("updates")
    menuBar()
    // The note from the typing demo, dimmed behind the notification.
    faded(0.45) { editor(frame: 0) }
    // The notification Avro Next posts (same text as UpdateManager).
    let t0 = wordTime(i, "new version")
    let a = appear(now, t0, 0.45)
    let banner = NSRect(x: W - 420 + (1 - a) * 60, y: H - 30 - 14 - 92, width: 400, height: 92)
    faded(a) {
        shadowed(22, 6, 0.30) { rounded(banner, 18, NSColor(white: 0.97, alpha: 0.98)) }
        appIcon(NSRect(x: banner.minX + 16, y: banner.midY - 22, width: 44, height: 44), onDark: false)
        text("Avro Next 0.1.7 is available", ui(16, .semibold), .black, NSPoint(x: banner.minX + 74, y: banner.maxY - 40))
        text("Click to install the update. You have 0.1.6.", ui(14), NSColor(white: 0.3, alpha: 1), NSPoint(x: banner.minX + 74, y: banner.maxY - 64))
        text("now", ui(12), NSColor(white: 0.5, alpha: 1), NSPoint(x: banner.maxX - 40, y: banner.maxY - 30))
    }
    // The input menu entry, a moment later.
    let b = appear(now, t0 + 1.3, 0.35)
    faded(b, rise: 10) {
        let menu = NSRect(x: W - 300, y: H - 30 - 14 - 92 - 24 - 96, width: 270, height: 96)
        shadowed(18, 6, 0.25) { rounded(menu, 10, NSColor(white: 0.98, alpha: 1)) }
        text("Avro Next Settings…", ui(15), .black, NSPoint(x: menu.minX + 16, y: menu.maxY - 34))
        let hl = NSRect(x: menu.minX + 6, y: menu.minY + 10, width: menu.width - 12, height: 32)
        rounded(hl, 6, accent)
        text("Install Avro Next 0.1.7…", ui(15), .white, NSPoint(x: menu.minX + 16, y: menu.minY + 16))
    }
    chip("Checks GitHub daily · verifies every download", center: NSPoint(x: W / 2 - 180, y: H - 66),   // in the gap above the editor, clear of the notification
         alpha: appear(now, t0 + 0.6), filled: true)
}

func drawInstall(_ now: Double) {
    let i = lineI("install")
    centered("Get it in 3 steps", ui(46, .bold), .white, y: 540)
    let steps: [(String, String, String, String)] = [
        ("1", "Download", "github.com/bmshamsul/avro-next", "Download"),
        ("2", "Install", "Open “Install Avro Next.pkg”", "install,"),
        ("3", "Add", "Keyboard › Input Sources › Bengali", "add"),
    ]
    for (k, s) in steps.enumerated() {
        let r = NSRect(x: 110 + CGFloat(k) * 360, y: 250, width: 340, height: 230)
        faded(appear(now, wordTime(i, s.3), 0.35), rise: 24) {
            shadowed(20, 6, 0.22) { rounded(r, 22, .white) }
            let c = NSRect(x: r.midX - 30, y: r.maxY - 80, width: 60, height: 60)
            green1.setFill(); NSBezierPath(ovalIn: c).fill()
            centered(s.0, ui(32, .bold), .white, y: c.minY + 10, x: c.midX)
            centered(s.1, ui(34, .bold), green2, y: r.minY + 76, x: r.midX)
            centered(s.2, ui(17, .medium), NSColor(white: 0.35, alpha: 1), y: r.minY + 40, x: r.midX)
        }
    }
    faded(appear(now, wordTime(i, "Input Sources") + 0.4)) {
        centered("Early release: if macOS asks, click Open Anyway in Privacy & Security.",
                 ui(19, .medium), NSColor(white: 1, alpha: 0.8), y: 200)
    }
}

func drawEnd(_ now: Double) {
    let i = lineI("cta")
    let a = appear(now, timing.lines[i].start, 0.5)
    faded(a, rise: 30) {
        appIcon(NSRect(x: W / 2 - 62, y: 448, width: 124, height: 124))
        centered("Free and open source", ui(60, .bold), .white, y: 352)
    }
    let b = appear(now, wordTime(i, "Download"), 0.4)
    faded(b, rise: 16) {
        let url = "github.com/bmshamsul/avro-next", f = ui(32, .semibold), sz = measure(url, f)
        let r = NSRect(x: W / 2 - sz.width / 2 - 30, y: 262, width: sz.width + 60, height: 64)
        rounded(r, 32, .white)
        text(url, f, green2, NSPoint(x: r.minX + 30, y: r.minY + 14))
    }
    faded(appear(now, wordTime(i, "help"), 0.4)) {
        centered("Contributions welcome · by Shamsul Haq Bhuyan", ui(22, .medium), NSColor(white: 1, alpha: 0.85), y: 205)
    }
}

func caption(_ now: Double) {
    guard let i = timing.lines.firstIndex(where: { now >= $0.start - 0.05 && now <= $0.end + 0.35 }) else { return }
    let s = script.lines[i].caption
    let f = ui(30, .semibold), sz = measure(s, f)
    let a = min(appear(now, timing.lines[i].start - 0.05, 0.15), 1 - appear(now, timing.lines[i].end + 0.2, 0.15))
    faded(a) {
        let r = NSRect(x: W / 2 - sz.width / 2 - 22, y: 70, width: sz.width + 44, height: sz.height + 18)
        rounded(r, 14, NSColor(white: 0, alpha: 0.55))
        text(s, f, .white, NSPoint(x: r.minX + 22, y: r.minY + 9))
    }
}

let editorScenes: Set<String> = ["type_phonetic", "type_suggest", "type_choose", "type_learn", "type_shift", "type_numbers", "type_emoji"]

func drawFrame(_ f: Int) {
    let now = Double(f) / Double(FPS)
    background()
    let scene = script.lines[lineIndex].scene
    // Fade in when the picture changes kind (cards → editor → settings → cards).
    let groupStart: Double = {
        var j = lineIndex
        func group(_ s: String) -> String { editorScenes.contains(s) ? "editor" : s.hasPrefix("settings") ? "settings" : s }
        while j > 0 && group(script.lines[j - 1].scene) == group(scene) { j -= 1 }
        return j == 0 ? 0 : timing.lines[j].start - 0.2
    }()
    faded(appear(now, groupStart, 0.35)) {
        switch scene {
        case "title": drawTitle(now)
        case "problem": drawProblem(now)
        case "native": drawNative(now)
        case "settings_layouts": drawLayouts(now)
        case "settings_more": drawSettingsMore(now)
        case "updates": drawUpdates(now)
        case "install": drawInstall(now)
        case "end": drawEnd(now)
        default: editor(frame: f)
        }
    }
    caption(now)
}

// MARK: - Video writer

let videoURL = URL(fileURLWithPath: mediaDir + "/video.mp4")
try? FileManager.default.removeItem(at: videoURL)
let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: OUT_W, AVVideoHeightKey: OUT_H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000,
                                      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: OUT_W, kCVPixelBufferHeightKey as String: OUT_H,
])
writer.add(input)
guard writer.startWriting() else { print("writer failed"); exit(1) }
writer.startSession(atSourceTime: .zero)

func render(into ctx: CGContext) {
    ctx.scaleBy(x: SCALE, y: SCALE)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    drawFrame(frameNo)
    NSGraphicsContext.restoreGraphicsState()
}

/// Writes frames until `target` (a frame number), keeping the current line up to date.
func emitUntil(_ target: Int) {
    while frameNo < min(target, totalFrames) {
        lineIndex = timing.lines.lastIndex { frameAt($0.start) <= frameNo } ?? 0
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let pb = buffer else { print("no pixel buffer"); exit(1) }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: OUT_W, height: OUT_H, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        render(into: ctx)
        CVPixelBufferUnlockBaseAddress(pb, [])
        adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frameNo), timescale: CMTimeScale(FPS)))
        frameNo += 1
    }
}
func emit(_ n: Int) { emitUntil(frameNo + n) }
func waitUntil(_ seconds: Double) { emitUntil(frameAt(seconds)) }

var stillCount = 0
func still(_ name: String) {
    guard let dir = stillsDir else { return }
    let ctx = CGContext(data: nil, width: OUT_W, height: OUT_H, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    render(into: ctx)
    stillCount += 1
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try? rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(dir)/\(String(format: "%02d", stillCount))-\(name).png"))
}

// MARK: - Typing actions (real engine)

func press(_ label: String) { keyLabel = label; keyFrame = frameNo; cues.append(Double(frameNo) / Double(FPS)) }

func type(_ word: String, perKey: Int = 5) {
    for ch in word {
        press(ch.isUppercase ? "⇧ \(ch)" : (ch == " " ? "Space" : String(ch)))
        let s = engine.press(KeyMap.code(for: ch)!, shift: ch.isUppercase, selection: state.selected)
        if let s { state.load(s.items, preferred: s.previouslySelectedIndex) }
        emit(perKey)
    }
}
func down(_ n: Int = 1, every: Int = 9) { for _ in 0..<n { press("↓"); state.move(by: 1); emit(every) } }
func commit(_ label: String = "Space", suffix: String = " ", hold: Int = 6) {
    press(label)
    if let s = state.current { engine.commit(index: state.selected); editorLines[editorLines.count - 1] += s + suffix }
    state.clear()
    emit(hold)
}
func newLine() { editorLines.append("") }
func words(_ list: [String], perKey: Int = 5, pause: Int = 6) {
    for w in list { type(w, perKey: perKey); emit(pause); commit() }
}

// MARK: - Film

func at(_ id: String, _ offset: Double = 0) { waitUntil(lineT(id).start + offset) }

at("hook", 0.4); still("title")
at("problem"); waitUntil(wordTime(lineI("problem"), "Meet") + 1.0); still("problem")
at("native"); waitUntil(lineT("native").end); still("native")

at("phonetic", 0.6)
words(["ami", "banglay", "gan", "gai"])
still("phonetic")

at("suggest", 0.2); newLine()
type("kemon", perKey: 6); emit(10); commit()
type("acho?", perKey: 6); emit(14); still("suggest"); emit(10); commit()

at("choose", 0.2); newLine()
type("ami"); emit(6); commit()
type("bhalo", perKey: 6); emit(14)
waitUntil(wordTime(lineI("choose"), "arrow"))
down(4, every: 8); emit(12); still("choose")
waitUntil(wordTime(lineI("choose"), "space")); commit()

at("learn", 0.1); newLine()
type("amio"); emit(4); commit()
type("bhalo", perKey: 6); emit(36); still("learn"); commit()

at("shift", 0.4); newLine()
type("amar"); emit(4); commit()
type("baRi", perKey: 7); emit(10); still("shift"); commit()
type("Dhaka", perKey: 7); emit(12); commit()

at("numbers", 0.3); newLine()
type("2026", perKey: 5); emit(4); commit()
type("sal,"); emit(4); commit()
type("dam"); emit(4); commit()
type("$500.", perKey: 6); emit(10); still("numbers"); commit()

at("emoji", 0.1); newLine()
type("Thik", perKey: 6); emit(10); down(2, every: 9); emit(10); still("emoji"); commit()

at("layouts", 0.3); waitUntil(wordTime(lineI("layouts"), "Probhat") + 0.4); still("layouts")
at("settings"); waitUntil(lineT("settings").end); still("settings")
at("updates"); waitUntil(lineT("updates").end + 0.8); still("updates")
at("install"); waitUntil(lineT("install").end + 0.5); still("install")
at("cta"); waitUntil(lineT("cta").end); still("end")
emitUntil(totalFrames)

input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { print("writer error: \(String(describing: writer.error))"); exit(1) }
try JSONSerialization.data(withJSONObject: ["keys": cues]).write(to: URL(fileURLWithPath: mediaDir + "/cues.json"))
print(String(format: "wrote %@: %d frames (%.1f s), %d key cues", videoURL.path, frameNo, Double(frameNo) / Double(FPS), cues.count))
