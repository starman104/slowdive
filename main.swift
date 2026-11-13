import SwiftUI
import GameController
import AppKit
import AVFoundation
import AVKit
import Foundation
import ImageIO
import Combine
import UniformTypeIdentifiers

// MARK: - Portable paths

/// Locates the "Source" folder relative to wherever the launcher is running,
/// so moving everything to external storage doesn't break paths.
let sourceRoot: URL = {
    let fm = FileManager.default

    // Walk up from the running launcher until we find Source/Switch/Games
    var dir = Bundle.main.bundleURL
    for _ in 0..<8 {
        let candidate = dir.appendingPathComponent("Source")
        if fm.fileExists(atPath: candidate.appendingPathComponent("Switch/Games").path) {
            return candidate
        }
        dir.deleteLastPathComponent()
    }

    // Fallback: main.swift is at Source/Gamecube/Gamecube-src/main.swift
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Gamecube-src
        .deletingLastPathComponent()  // Gamecube
        .deletingLastPathComponent()  // Source
}()

let switchGamesDir = sourceRoot.appendingPathComponent("Switch/Games")
let saveRoot = sourceRoot.appendingPathComponent("Switch/Save")
let configFileURL = sourceRoot.appendingPathComponent("Gamecube/launcher-config.json")

/// Relative paths are relative to Source/. Absolute and ~ paths are used as they are.
func resolvePath(_ p: String) -> String {
    if p.isEmpty { return "" }
    if p.hasPrefix("/") { return p }
    if p.hasPrefix("~") { return (p as NSString).expandingTildeInPath }
    return sourceRoot.appendingPathComponent(p).path
}

/// Files inside Source/ are stored relative (so they survive moving the drive).
func storablePath(_ url: URL) -> String {
    let root = sourceRoot.standardizedFileURL.path + "/"
    let p = url.standardizedFileURL.path
    return p.hasPrefix(root) ? String(p.dropFirst(root.count)) : p
}

// MARK: - Shell launcher helper

func runShell(_ launchPath: String, _ args: [String]) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = args
    do {
        try task.run()
    } catch {
        print("Failed to launch \(launchPath): \(error)")
    }
}

// MARK: - Portable saves
// The games save straight into Source/Switch/Save/<Game> (their "Cloud saves" folder).
// They remember that folder as an absolute path, so on a Mac where the drive is mounted
// somewhere else we make that remembered path point at the drive.

func prepareSaves() {
    let fm = FileManager.default
    try? fm.createDirectory(at: saveRoot, withIntermediateDirectories: true)

    let home = URL(fileURLWithPath: NSHomeDirectory())
    let expected = home.appendingPathComponent("Games and Emulation/Source")

    // Real folder or working link already there: nothing to do.
    if fm.fileExists(atPath: expected.path) { return }

    // Broken old link: remove it so we can replace it.
    if (try? fm.destinationOfSymbolicLink(atPath: expected.path)) != nil {
        try? fm.removeItem(at: expected)
    }

    do {
        try fm.createDirectory(at: expected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: expected, withDestinationURL: sourceRoot)
    } catch {
        print("Could not link save path: \(error)")
    }
}

// MARK: - Image cache (downsizes big images, SVG goes through NSImage)

final class ImageCache {
    static let shared = ImageCache()
    private var store: [String: NSImage] = [:]

    func image(_ path: String, maxPixel: Int = 800) -> NSImage? {
        if path.isEmpty { return nil }
        let key = "\(path)#\(maxPixel)"
        if let cached = store[key] { return cached }

        if path.lowercased().hasSuffix(".svg") {
            guard let svg = NSImage(contentsOfFile: path) else { return nil }
            store[key] = svg
            return svg
        }

        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        store[key] = img
        return img
    }
}

// MARK: - Data model (saved as JSON next to the launcher, so it travels with the drive)

extension KeyedDecodingContainer {
    /// Decode a value, or use the fallback when the key is missing (so old config files keep working).
    func value<T: Decodable>(_ key: K, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

enum TileKind: String, Codable, CaseIterable, Identifiable {
    case app, website, command
    var id: String { rawValue }
    var label: String {
        switch self {
        case .app: return "App"
        case .website: return "Website"
        case .command: return "Command"
        }
    }
    var icon: String {
        switch self {
        case .app: return "app.fill"
        case .website: return "globe"
        case .command: return "terminal.fill"
        }
    }
}

enum BorderMode: String, Codable, CaseIterable, Identifiable {
    case fixed, tile, wallpaper
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fixed: return "Fixed hue"
        case .tile: return "Tile color"
        case .wallpaper: return "Wallpaper color"
        }
    }
}

enum BubbleStyle: String, Codable, CaseIterable, Identifiable {
    case colorful, monochrome
    var id: String { rawValue }
    var label: String { self == .colorful ? "Colorful" : "Monochrome" }
}

struct TileConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "New Tile"
    var kind = TileKind.app
    var target = ""              // .app path, URL, or executable
    var arguments: [String] = [] // one argument per entry
    var imagePath = ""           // cover / tile background image (empty = colored tile)
    var accentHue = 0.58         // tile color when there is no image
    var usesSaves = false        // link the Switch save folder before launching

    init() {}

    init(title: String, kind: TileKind, target: String, arguments: [String] = [],
         imagePath: String = "", accentHue: Double = 0.58, usesSaves: Bool = false) {
        self.title = title
        self.kind = kind
        self.target = target
        self.arguments = arguments
        self.imagePath = imagePath
        self.accentHue = accentHue
        self.usesSaves = usesSaves
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        title = c.value(.title, "New Tile")
        kind = c.value(.kind, TileKind.app)
        target = c.value(.target, "")
        arguments = c.value(.arguments, [String]())
        imagePath = c.value(.imagePath, "")
        accentHue = c.value(.accentHue, 0.58)
        usesSaves = c.value(.usesSaves, false)
    }

    var accentColor: Color { Color(hue: accentHue, saturation: 0.65, brightness: 0.85) }

    static var defaults: [TileConfig] {
        [
            TileConfig(title: "The Legend of Zelda: Breath of the Wild", kind: .app,
                       target: "Switch/Games/Breath of the Wild.app",
                       imagePath: "Gamecube/Gamecube-src/botw.jpg", accentHue: 0.46, usesSaves: true),
            TileConfig(title: "PlayerUnknown's Battlegrounds", kind: .app,
                       target: "/Applications/MuMuPlayer Pro.app",
                       imagePath: "Gamecube/Gamecube-src/pubg.jpg", accentHue: 0.58),
            TileConfig(title: "Minecraft", kind: .command,
                       target: "/opt/homebrew/bin/scrcpy",
                       imagePath: "Gamecube/Gamecube-src/minecraft.png", accentHue: 0.58),
            TileConfig(title: "Mario Kart 8", kind: .app,
                       target: "/Applications/Cemu.app",
                       arguments: ["-f", "-g",
                                   "/Users/sarvesh/Games and Emulation/Cemu/gameFiles/MarioKart8/MARIO KART 8 [AMKP01]/code/Turbo.rpx"],
                       imagePath: "Gamecube/Gamecube-src/mariokart.png", accentHue: 0.58)
        ]
    }
}

struct AppSettings: Codable {
    // Appearance
    var wallpaperPath = "Gamecube/Gamecube-src/wallpaper.jpg"
    var wallpaperDim = 0.35
    var scanlinesEnabled = true
    var scanlineStrength = 1.0
    var chromaticEnabled = true
    var tintEnabled = true
    var tintStrength = 1.0
    var tintFadeSeconds = 1.0
    var borderMode = BorderMode.fixed
    var borderHue = 0.58
    var borderStrength = 1.0
    var borderRainbow = false
    var rainbowSpeed = 1.0
    var bubblesEnabled = true
    var bubbleCount = 16
    var bubbleStyle = BubbleStyle.colorful
    var bubbleHue = 0.58

    // Audio
    var musicEnabled = true
    var musicPath = "Gamecube/Gamecube-src/mainmenu.flac"
    var musicVolume = 0.55
    var tickEnabled = true                       // plays when you move between tiles
    var tickPath = "Gamecube/Gamecube-src/select.wav"
    var launchSoundEnabled = true                // plays when you start a game
    var launchSoundPath = "Gamecube/Gamecube-src/enter.wav"
    var sfxVolume = 1.0

    // General
    var launchFullscreen = true
    var quitOnLaunch = true
    var showClock = true
    var showTitleBubble = true

    init() {}

    init(from decoder: Decoder) throws {
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wallpaperPath = c.value(.wallpaperPath, d.wallpaperPath)
        wallpaperDim = c.value(.wallpaperDim, d.wallpaperDim)
        scanlinesEnabled = c.value(.scanlinesEnabled, d.scanlinesEnabled)
        scanlineStrength = c.value(.scanlineStrength, d.scanlineStrength)
        chromaticEnabled = c.value(.chromaticEnabled, d.chromaticEnabled)
        tintEnabled = c.value(.tintEnabled, d.tintEnabled)
        tintStrength = c.value(.tintStrength, d.tintStrength)
        tintFadeSeconds = c.value(.tintFadeSeconds, d.tintFadeSeconds)
        borderMode = c.value(.borderMode, d.borderMode)
        borderHue = c.value(.borderHue, d.borderHue)
        borderStrength = c.value(.borderStrength, d.borderStrength)
        borderRainbow = c.value(.borderRainbow, d.borderRainbow)
        rainbowSpeed = c.value(.rainbowSpeed, d.rainbowSpeed)
        bubblesEnabled = c.value(.bubblesEnabled, d.bubblesEnabled)
        bubbleCount = c.value(.bubbleCount, d.bubbleCount)
        bubbleStyle = c.value(.bubbleStyle, d.bubbleStyle)
        bubbleHue = c.value(.bubbleHue, d.bubbleHue)
        musicEnabled = c.value(.musicEnabled, d.musicEnabled)
        musicPath = c.value(.musicPath, d.musicPath)
        musicVolume = c.value(.musicVolume, d.musicVolume)
        tickEnabled = c.value(.tickEnabled, d.tickEnabled)
        tickPath = c.value(.tickPath, d.tickPath)
        launchSoundEnabled = c.value(.launchSoundEnabled, d.launchSoundEnabled)
        launchSoundPath = c.value(.launchSoundPath, d.launchSoundPath)
        sfxVolume = c.value(.sfxVolume, d.sfxVolume)
        launchFullscreen = c.value(.launchFullscreen, d.launchFullscreen)
        quitOnLaunch = c.value(.quitOnLaunch, d.quitOnLaunch)
        showClock = c.value(.showClock, d.showClock)
        showTitleBubble = c.value(.showTitleBubble, d.showTitleBubble)
    }
}

struct ConfigFile: Codable {
    var settings: AppSettings
    var tiles: [TileConfig]
}

final class LauncherStore: ObservableObject {
    static let shared = LauncherStore()

    @Published var settings = AppSettings()
    @Published var tiles: [TileConfig] = TileConfig.defaults

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let exists = FileManager.default.fileExists(atPath: configFileURL.path)
        if exists,
           let data = try? Data(contentsOf: configFileURL),
           let cfg = try? JSONDecoder().decode(ConfigFile.self, from: data) {
            settings = cfg.settings
            tiles = cfg.tiles
        }

        // Keep the sound engine in sync with the settings
        $settings
            .sink { SoundManager.shared.apply($0) }
            .store(in: &cancellables)

        // Save (debounced) whenever anything changes
        Publishers.CombineLatest($settings, $tiles)
            .dropFirst()
            .debounce(for: .seconds(0.4), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.save() }
            .store(in: &cancellables)

        if !exists { save() }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(ConfigFile(settings: settings, tiles: tiles)) else { return }
        try? FileManager.default.createDirectory(at: configFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: configFileURL, options: .atomic)
    }
}

// MARK: - Launching tiles

func launchTile(_ t: TileConfig) {
    if t.usesSaves { prepareSaves() }
    let args = t.arguments.filter { !$0.isEmpty }
    switch t.kind {
    case .app:
        var a = ["-n", resolvePath(t.target)]
        if !args.isEmpty { a += ["--args"] + args }
        runShell("/usr/bin/open", a)
    case .website:
        var s = t.target.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    case .command:
        runShell(resolvePath(t.target), args)
    }
}

// MARK: - Window helpers

enum LauncherWindow { static weak var window: NSWindow? }

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
    }
}

enum SettingsBridge {
    static var action: (() -> Void)?
    static var centered = false
}

/// Grabs SwiftUI's own "open Settings" action (macOS 14+), which is the reliable way to open the window.
@available(macOS 14.0, *)
struct SettingsActionCapture: View {
    @Environment(\.openSettings) private var openEnv

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { SettingsBridge.action = { openEnv() } }
    }
}

func openSettings() {
    NSApp.activate(ignoringOtherApps: true)
    if let action = SettingsBridge.action {
        action()
    } else {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

func chooseFile(types: [UTType], completion: @escaping (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if !types.isEmpty { panel.allowedContentTypes = types }
    panel.directoryURL = sourceRoot

    let handler: (NSApplication.ModalResponse) -> Void = { response in
        if response == .OK, let url = panel.url { completion(url) }
    }

    // Attach to the Settings window as a sheet so it always appears in front of it
    if let w = NSApp.keyWindow, w !== LauncherWindow.window {
        panel.beginSheetModal(for: w, completionHandler: handler)
    } else {
        panel.level = .modalPanel
        panel.begin(completionHandler: handler)
    }
}

// MARK: - Sound manager (driven by settings)

final class SoundManager {
    static let shared = SoundManager()

    private var tickPlayer: AVAudioPlayer?
    private var launchPlayer: AVAudioPlayer?
    private var musicPlayer: AVAudioPlayer?
    private var previewPlayer: AVAudioPlayer?
    private var applied: AppSettings?
    private var started = false

    private init() {}

    private func load(_ path: String) -> AVAudioPlayer? {
        let full = resolvePath(path)
        guard !full.isEmpty else { return nil }
        let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: full))
        p?.prepareToPlay()
        return p
    }

    func apply(_ s: AppSettings) {
        let old = applied
        applied = s

        if old?.tickPath != s.tickPath { tickPlayer = load(s.tickPath) }
        if old?.launchSoundPath != s.launchSoundPath { launchPlayer = load(s.launchSoundPath) }
        if old?.musicPath != s.musicPath {
            musicPlayer?.stop()
            musicPlayer = load(s.musicPath)
            musicPlayer?.numberOfLoops = -1
        }

        musicPlayer?.volume = Float(s.musicVolume)
        tickPlayer?.volume = Float(s.sfxVolume)
        launchPlayer?.volume = Float(s.sfxVolume)

        if started {
            if s.musicEnabled {
                if musicPlayer?.isPlaying == false { musicPlayer?.play() }
            } else {
                musicPlayer?.pause()
            }
        }
    }

    func playSelect() {
        guard let s = applied, s.tickEnabled else { return }
        tickPlayer?.currentTime = 0
        tickPlayer?.play()
    }

    func playEnter() {
        guard let s = applied, s.launchSoundEnabled else { return }
        launchPlayer?.currentTime = 0
        launchPlayer?.play()
    }

    var enterSoundDuration: TimeInterval {
        guard let s = applied, s.launchSoundEnabled else { return 0 }
        return launchPlayer?.duration ?? 0.3
    }

    func startMusic() {
        started = true
        guard applied?.musicEnabled == true else { return }
        if musicPlayer?.isPlaying == false { musicPlayer?.play() }
    }

    func preview(_ path: String) {
        let full = resolvePath(path)
        previewPlayer?.stop()
        previewPlayer = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: full))
        previewPlayer?.volume = Float(applied?.sfxVolume ?? 1.0)
        previewPlayer?.play()
    }
}

// MARK: - Colour sampling (tile tint, wallpaper-based border)

enum ColorSampler {
    struct HSB { var h: Double; var s: Double; var b: Double }
    private static var cache: [String: HSB] = [:]

    /// Average colour of an image, computed once and cached.
    static func average(path: String) -> HSB? {
        if path.isEmpty { return nil }
        if let c = cache[path] { return c }
        guard let img = ImageCache.shared.image(path, maxPixel: 64),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        var px = [UInt8](repeating: 0, count: 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard ok else { return nil }

        let ns = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                         blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let result = HSB(h: Double(h), s: Double(s), b: Double(b))
        cache[path] = result
        return result
    }
}

enum TileTint {
    static func hue(for tile: TileConfig) -> Double {
        if !tile.imagePath.isEmpty, let c = ColorSampler.average(path: resolvePath(tile.imagePath)) {
            return c.h
        }
        return tile.accentHue
    }

    static func color(for tile: TileConfig) -> Color {
        if !tile.imagePath.isEmpty, let c = ColorSampler.average(path: resolvePath(tile.imagePath)) {
            // Averages come out muddy, so lift saturation and keep brightness in a sane range
            return Color(hue: c.h,
                         saturation: min(1, c.s * 1.3),
                         brightness: min(0.9, max(0.55, c.b)))
        }
        return tile.accentColor
    }
}

// MARK: - Grid proportions (derived from your 1600x900 spec)

let gridColumns = 4
let gridRows = 3
let pageSize = gridColumns * gridRows

let tileAspect: CGFloat = 326.0 / 177.5
let gridGapToTileWidthRatio: CGFloat = (34.0 / 3.0) / 326.0
let gridGapToTileHeightRatio: CGFloat = (25.5 / 2.0) / 177.5
let gridOuterMarginFraction: CGFloat = ((1600.0 - 1338.0) / 2.0) / 1600.0

// MARK: - Input coordinator (keyboard + gamepad, unified focus/activate, pages)

final class InputCoordinator: ObservableObject {
    @Published var focusedIndex: Int = 0
    @Published var pressedIndex: Int? = nil

    private let store = LauncherStore.shared
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var lastDpadX: Double = 0
    private var lastDpadY: Double = 0
    private var launching = false

    var count: Int { store.tiles.count }
    var pageCount: Int { max(1, (count + pageSize - 1) / pageSize) }
    var currentPage: Int { focusedIndex / pageSize }

    init() {
        setupKeyboard()
        setupGamepad()

        // Keep focus valid if tiles are removed in settings
        store.$tiles
            .sink { [weak self] tiles in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let maxIndex = max(0, tiles.count - 1)
                    if self.focusedIndex > maxIndex { self.focusedIndex = maxIndex }
                }
            }
            .store(in: &cancellables)
    }

    private var launcherIsActive: Bool {
        LauncherWindow.window?.isKeyWindow == true
    }

    /// The one place focus changes. Every tile effect (frame fade, press squash) is animated from here,
    /// never with per-tile .animation modifiers: those override the page-slide animation for the selected
    /// tile and made it fly in ahead of the rest of the page.
    private func setFocused(_ new: Int) {
        guard new != focusedIndex else { return }
        let pageChanges = (new / pageSize) != (focusedIndex / pageSize)
        // Same curve as the page slide, so the focus frame and the tiles move as one
        withAnimation(pageChanges ? .easeInOut(duration: 0.34) : .easeOut(duration: 0.12)) {
            focusedIndex = new
        }
    }

    func setFocus(_ index: Int) {
        guard index != focusedIndex, index >= 0, index < count else { return }
        setFocused(index)
        SoundManager.shared.playSelect()
    }

    func move(_ delta: Int) {
        guard count > 0 else { return }
        setFocused((focusedIndex + delta + count) % count)
        SoundManager.shared.playSelect()
    }

    func moveVertical(_ rowDelta: Int) {
        guard count > 0 else { return }
        let page = focusedIndex / pageSize
        let local = focusedIndex % pageSize
        let newLocal = local + rowDelta * gridColumns
        guard newLocal >= 0 && newLocal < pageSize else { return }
        let target = page * pageSize + newLocal
        guard target < count else { return }
        setFocused(target)
        SoundManager.shared.playSelect()
    }

    func goToPage(_ page: Int) {
        guard pageCount > 1 else { return }
        let np = min(max(page, 0), pageCount - 1)
        guard np != currentPage else { return }
        let local = focusedIndex % pageSize
        setFocused(min(np * pageSize + local, count - 1))
        SoundManager.shared.playSelect()
    }

    func changePage(_ delta: Int) {
        goToPage(currentPage + delta)
    }

    func activate(_ index: Int? = nil) {
        let idx = index ?? focusedIndex
        guard idx >= 0 && idx < count, !launching else { return }
        launching = true
        let tile = store.tiles[idx]
        let quit = store.settings.quitOnLaunch

        withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { pressedIndex = idx }
        SoundManager.shared.playEnter()
        let soundDuration = SoundManager.shared.enterSoundDuration

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            launchTile(tile)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { self?.pressedIndex = nil }
        }

        let quitDelay = max(0.15, soundDuration) + 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + quitDelay) { [weak self] in
            if quit {
                NSApplication.shared.terminate(nil)
            } else {
                NSApp.hide(nil)
                self?.launching = false
            }
        }
    }

    private func setupKeyboard() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Only react when the launcher window is the one in front (not Settings)
            guard event.window === LauncherWindow.window else { return event }
            if event.modifierFlags.contains(.command) { return event }

            switch event.keyCode {
            case 123: self.move(-1); return nil
            case 124: self.move(1); return nil
            case 125: self.moveVertical(1); return nil
            case 126: self.moveVertical(-1); return nil
            case 116: self.changePage(-1); return nil   // Page Up
            case 121: self.changePage(1); return nil    // Page Down
            case 36, 49: self.activate(); return nil
            default: return event
            }
        }
    }

    private func setupGamepad() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            if let c = note.object as? GCController { self?.configure(c) }
        }
        GCController.controllers().forEach(configure)
    }

    private func configure(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }

        gamepad.dpad.valueChangedHandler = { [weak self] _, x, y in
            self?.handleAxis(x: Double(x), y: Double(y))
        }
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.handleAxis(x: Double(x), y: Double(y))
        }
        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async {
                guard let self, self.launcherIsActive else { return }
                self.activate()
            }
        }
        // Shoulder buttons flip pages
        gamepad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async {
                guard let self, self.launcherIsActive else { return }
                self.changePage(-1)
            }
        }
        gamepad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async {
                guard let self, self.launcherIsActive else { return }
                self.changePage(1)
            }
        }
        // Menu / Start opens settings
        gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async {
                guard let self, self.launcherIsActive else { return }
                openSettings()
            }
        }
    }

    private func handleAxis(x: Double, y: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.launcherIsActive else { return }
            if x > 0.5 && self.lastDpadX <= 0.5 { self.move(1) }
            else if x < -0.5 && self.lastDpadX >= -0.5 { self.move(-1) }
            self.lastDpadX = x

            if y < -0.5 && self.lastDpadY >= -0.5 { self.moveVertical(1) }
            else if y > 0.5 && self.lastDpadY <= 0.5 { self.moveVertical(-1) }
            self.lastDpadY = y
        }
    }
}

// MARK: - Wallpaper (RGB split + animated scanlines)

struct ImageBackground: View {
    private let nsImage: NSImage?
    private let dim: Double
    private let scanlines: Bool
    private let scanStrength: Double
    private let chromatic: Bool

    private let aberration: CGFloat = 2.5
    private let lineSpacing: CGFloat = 4
    private let scrollSpeed: CGFloat = 25
    private let bandSpeed: CGFloat = 140
    private let bandHeight: CGFloat = 160

    init(path: String, dim: Double, scanlines: Bool, scanStrength: Double, chromatic: Bool) {
        self.nsImage = ImageCache.shared.image(path, maxPixel: 2880)
        self.dim = dim
        self.scanlines = scanlines
        self.scanStrength = scanStrength
        self.chromatic = chromatic
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if let img = nsImage {
                    if chromatic {
                        ZStack {
                            channel(img, geo, .red).offset(x: -aberration)
                            channel(img, geo, .green)
                            channel(img, geo, .blue).offset(x: aberration)
                        }
                        .compositingGroup()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .drawingGroup()
                    } else {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    }
                }

                Color.black.opacity(dim)

                if scanlines { scanlineLayer }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }

    private var scanlineLayer: some View {
        let k = scanStrength
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = CGFloat(timeline.date.timeIntervalSinceReferenceDate)

            Canvas { context, size in
                let phase = (t * scrollSpeed).truncatingRemainder(dividingBy: lineSpacing)
                var dark = Path(), red = Path(), cyan = Path()
                var y = phase - lineSpacing
                while y < size.height {
                    dark.addRect(CGRect(x: 0, y: y, width: size.width, height: 2))
                    red.addRect(CGRect(x: -1, y: y - 1, width: size.width, height: 1))
                    cyan.addRect(CGRect(x: 1, y: y + 2, width: size.width, height: 1))
                    y += lineSpacing
                }
                context.fill(dark, with: .color(Color.black.opacity(min(1, 0.12 * k))))
                context.fill(red, with: .color(Color.red.opacity(min(1, 0.07 * k))))
                context.fill(cyan, with: .color(Color.cyan.opacity(min(1, 0.07 * k))))

                let travel = size.height + bandHeight
                let bandY = (t * bandSpeed).truncatingRemainder(dividingBy: travel) - bandHeight
                let band = CGRect(x: 0, y: bandY, width: size.width, height: bandHeight)
                context.fill(
                    Path(band),
                    with: .linearGradient(
                        Gradient(colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(min(1, 0.07 * k)),
                            Color.white.opacity(0)
                        ]),
                        startPoint: CGPoint(x: 0, y: band.minY),
                        endPoint: CGPoint(x: 0, y: band.maxY)
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func channel(_ img: NSImage, _ geo: GeometryProxy, _ color: Color) -> some View {
        Image(nsImage: img)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .colorMultiply(color)
            .blendMode(.plusLighter)
    }
}

// MARK: - Soft colour wash behind everything (follows the focused tile)

struct BackgroundTint: View {
    let color: Color
    let strength: Double
    let fade: Double      // seconds the tint takes to blend into the next tile's color

    var body: some View {
        let s = strength
        ZStack {
            LinearGradient(
                colors: [color.opacity(min(1, 0.10 * s)), color.opacity(min(1, 0.32 * s))],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [color.opacity(min(1, 0.22 * s)), color.opacity(0)],
                center: .bottom, startRadius: 0, endRadius: 700
            )
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: fade), value: color)
    }
}

// MARK: - Floating Aero bubbles

struct FloatingBubbles: View {
    let count: Int
    let style: BubbleStyle
    let monoHue: Double

    private struct Spec {
        let index: Int
        let xFrac: CGFloat
        let radius: CGFloat
        let speed: CGFloat
        let offset: CGFloat
        let swayAmp: CGFloat
        let swayFreq: CGFloat
        let phase: CGFloat
        let alpha: Double
        let hue: Double
        let sat: Double
    }

    // (hue, saturation): purple, teal, yellow-green, peach, mint, white, amber, sky
    private static let tints: [(Double, Double)] = [
        (0.75, 0.50), (0.47, 0.55), (0.20, 0.60), (0.07, 0.40),
        (0.40, 0.50), (0.00, 0.00), (0.14, 0.55), (0.56, 0.45)
    ]

    private static let specs: [Spec] = {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
        }
        var list: [Spec] = []
        for i in 0..<40 {
            let tint = FloatingBubbles.tints[i % FloatingBubbles.tints.count]
            list.append(Spec(
                index: i,
                xFrac: rnd(),
                radius: 22 + pow(rnd(), 1.5) * 75,
                speed: 16 + rnd() * 28,
                offset: rnd() * 2000,
                swayAmp: 8 + rnd() * 22,
                swayFreq: 0.3 + rnd() * 0.6,
                phase: rnd() * 6.28,
                alpha: 0.85 + Double(rnd()) * 0.15,
                hue: tint.0,
                sat: tint.1
            ))
        }
        return list
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = CGFloat(timeline.date.timeIntervalSinceReferenceDate)
            Canvas { ctx, size in
                for s in FloatingBubbles.specs.prefix(count) {
                    let r = s.radius
                    let travel = size.height + r * 2
                    let y = size.height + r - (s.offset + t * s.speed).truncatingRemainder(dividingBy: travel)
                    let x = s.xFrac * size.width + sin(t * s.swayFreq + s.phase) * s.swayAmp

                    let hue = style == .colorful ? s.hue : monoHue
                    let sat = style == .colorful ? s.sat : 0.45 + 0.1 * Double(s.index % 3)
                    drawBubble(&ctx, x: x, y: y, r: r, alpha: s.alpha, hue: hue, sat: sat)
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func drawBubble(_ ctx: inout GraphicsContext, x: CGFloat, y: CGFloat, r: CGFloat,
                            alpha: Double, hue: Double, sat: Double) {
        let rim = Color(hue: hue, saturation: min(1, sat * 1.3), brightness: 1.0)

        func circle(radius: CGFloat, dx: CGFloat = 0, dy: CGFloat = 0) -> Path {
            Path(ellipseIn: CGRect(x: x + dx - radius, y: y + dy - radius,
                                   width: radius * 2, height: radius * 2))
        }

        // 1. Rim glow: two faint wider strokes under the rim
        ctx.stroke(circle(radius: r - r * 0.05), with: .color(rim.opacity(0.07 * alpha)), lineWidth: r * 0.10)
        ctx.stroke(circle(radius: r - r * 0.025), with: .color(rim.opacity(0.14 * alpha)), lineWidth: r * 0.05)

        // 2. Slim single-colour rim
        ctx.stroke(circle(radius: r), with: .color(rim.opacity(0.85 * alpha)), lineWidth: max(1.0, r * 0.022))

        // 3. Crescent gloss, upper left
        var crescent = ctx
        crescent.clip(to: circle(radius: r * 0.86, dx: r * 0.09, dy: r * 0.11), options: .inverse)
        crescent.fill(circle(radius: r * 0.86), with: .linearGradient(
            Gradient(stops: [
                .init(color: Color.white.opacity(0.95 * alpha), location: 0.0),
                .init(color: Color.white.opacity(0.35 * alpha), location: 0.45),
                .init(color: Color.white.opacity(0.0), location: 0.80)
            ]),
            startPoint: CGPoint(x: x - r * 0.7, y: y - r * 0.7),
            endPoint: CGPoint(x: x + r * 0.1, y: y + r * 0.1)
        ))

        // 4. Hot spot on the crescent
        ctx.fill(
            Path(ellipseIn: CGRect(x: x - r * 0.50, y: y - r * 0.62, width: r * 0.28, height: r * 0.16)),
            with: .color(Color.white.opacity(1.0 * alpha))
        )

        // 5. Small wet glint, lower right
        ctx.fill(
            Path(ellipseIn: CGRect(x: x + r * 0.36, y: y + r * 0.42, width: r * 0.14, height: r * 0.14)),
            with: .color(Color.white.opacity(0.80 * alpha))
        )
    }
}

// MARK: - Tile frame tracking (so the selection bubble can find where to sit)

struct TileFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Tile artwork (static, rasterised once)

struct GlossShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: rect.width, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: rect.height * 0.4))
        p.addLine(to: CGPoint(x: 0, y: rect.height * 0.62))
        p.closeSubpath()
        return p
    }
}

struct TileArtwork: View {
    let imagePath: String?
    let accent: Color
    let size: CGSize

    var body: some View {
        ZStack {
            if let path = imagePath, let img = ImageCache.shared.image(path) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                LinearGradient(
                    colors: [accent.opacity(0.55), accent.opacity(0.95)],
                    startPoint: .top, endPoint: .bottom
                )
            }

            GlossShape()
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.65), Color.white.opacity(0.05)],
                    startPoint: .top, endPoint: .bottom
                ))

            Circle()
                .fill(RadialGradient(
                    colors: [Color.white.opacity(0.5), Color.white.opacity(0)],
                    center: .center, startRadius: 0, endRadius: 34
                ))
                .frame(width: size.width * 0.36, height: size.width * 0.36)
                .offset(x: size.width * 0.28, y: -size.height * 0.28)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.7), lineWidth: 1.5))
        .drawingGroup()
    }
}

// MARK: - Windows 7 Aero glass frame (hue-tinted). Flat strokes only, so it stays cheap.
// Sits 7pt outside the tile: tile corner (18) + band width (7) = 25.

struct AeroFrame: View {
    let hue: Double
    var strength: Double = 1.0     // 0.5 (pale) ... 2.5 (rich)
    var rainbow: Bool = false      // colors flow around the frame
    var speed: Double = 1.0
    private let outer: CGFloat = 25

    private func c(_ sat: Double, _ bri: Double, _ opacity: Double) -> Color {
        Color(hue: hue.truncatingRemainder(dividingBy: 1),
              saturation: min(1, sat * strength), brightness: bri)
            .opacity(min(1, opacity * strength))
    }

    private func content(angle: Double) -> some View {
        ZStack {
            // 1. Outer dark hairline
            RoundedRectangle(cornerRadius: outer)
                .strokeBorder(c(0.79, 0.38, 0.60), lineWidth: 1)

            // 2. Glass body: mostly see-through, tinted, heavier at the bottom
            RoundedRectangle(cornerRadius: outer - 1)
                .strokeBorder(glassFill(angle: angle), lineWidth: 5)
                .padding(1)

            // 3. Diagonal specular sheen
            RoundedRectangle(cornerRadius: outer - 1)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.95), location: 0.00),
                            .init(color: Color.white.opacity(0.45), location: 0.28),
                            .init(color: Color.white.opacity(0.00), location: 0.50),
                            .init(color: Color.white.opacity(0.00), location: 0.72),
                            .init(color: Color.white.opacity(0.55), location: 1.00)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 5
                )
                .padding(1)

            // 4. Bright rim on the outer edge of the glass
            RoundedRectangle(cornerRadius: outer - 1)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.95), location: 0.00),
                            .init(color: Color.white.opacity(0.15), location: 0.45),
                            .init(color: Color.white.opacity(0.35), location: 1.00)
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .padding(1)

            // 5. Inner dark hairline
            RoundedRectangle(cornerRadius: outer - 6)
                .strokeBorder(c(0.80, 0.50, 0.65), lineWidth: 1)
                .padding(6)

            // 6. Soft white inner edge glow
            RoundedRectangle(cornerRadius: outer - 7)
                .strokeBorder(Color.white.opacity(0.30), lineWidth: 1.5)
                .padding(7)
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }

    /// The glass band: a single tint, or a rainbow that rotates around the frame.
    private func glassFill(angle: Double) -> AnyShapeStyle {
        if rainbow {
            let stops = (0...12).map { i in
                Color(hue: Double(i) / 12.0, saturation: min(1, 0.55 * strength), brightness: 1.0).opacity(0.80)
            }
            return AnyShapeStyle(AngularGradient(
                gradient: Gradient(colors: stops), center: .center, angle: .degrees(angle)
            ))
        }
        return AnyShapeStyle(LinearGradient(
            colors: [c(0.25, 1.0, 0.50), c(0.60, 0.88, 0.28), c(0.74, 0.78, 0.42)],
            startPoint: .top, endPoint: .bottom
        ))
    }

    var body: some View {
        Group {
            if rainbow {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                    let a = (tl.date.timeIntervalSinceReferenceDate * 90.0 * speed).truncatingRemainder(dividingBy: 360.0)
                    content(angle: a)
                }
            } else {
                content(angle: 0)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Everything that changes how the selection border looks (compared so tiles only redraw when needed)
struct BorderStyleConfig: Equatable {
    var hue: Double
    var strength: Double
    var rainbow: Bool
    var speed: Double
}

// MARK: - Tile view

struct ChannelTileView: View, Equatable {
    let tile: TileConfig
    let index: Int
    let tileSize: CGSize
    let border: BorderStyleConfig
    let isFocused: Bool
    let isPressed: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void

    // SwiftUI skips redrawing a tile unless one of these actually changed
    static func == (l: ChannelTileView, r: ChannelTileView) -> Bool {
        l.tile == r.tile && l.index == r.index && l.isFocused == r.isFocused &&
        l.isPressed == r.isPressed && l.tileSize == r.tileSize && l.border == r.border
    }

    var body: some View {
        TileArtwork(
            imagePath: tile.imagePath.isEmpty ? nil : resolvePath(tile.imagePath),
            accent: tile.accentColor,
            size: tileSize
        )
        .overlay {
            if isFocused {
                AeroFrame(hue: border.hue, strength: border.strength, rainbow: border.rainbow, speed: border.speed)
                    .padding(-7)
                    .transition(.opacity)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.cyan, lineWidth: 5)
                .opacity(isPressed ? 1 : 0)
        )
        .overlay(
            Color.white.opacity(isPressed ? 0.3 : 0)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        )
        // Constant soft shadow for depth (never animated, so no lag)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black.opacity(0.35))
                .shadow(color: .black.opacity(0.25), radius: 5, y: 4)
        )
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .background(
            GeometryReader { g in
                Color.clear
                    .preference(key: TileFrameKey.self, value: [index: g.frame(in: .named("root"))])
            }
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture(count: 1) { onTap() }
        // No .animation modifiers here on purpose. Focus and press changes are animated by
        // InputCoordinator (withAnimation); a per-tile modifier would override the page slide.
    }
}

struct EmptySlotView: View {
    let tileSize: CGSize
    var body: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(Color.white.opacity(0.25))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
            )
            .frame(width: tileSize.width, height: tileSize.height)
    }
}

// MARK: - Aero page arrow button

struct AeroArrowButton: View {
    let systemName: String
    let tint: ColorSampler.HSB      // average colour of the wallpaper
    let action: () -> Void
    @State private var hovering = false

    // Keep the wallpaper's own hue and saturation; only clamp brightness so the white arrow stays readable
    private var sat: Double { min(0.95, tint.s * 1.2) }
    private var deep: Double { min(0.80, max(0.45, tint.b)) }

    private func c(_ s: Double, _ bri: Double, _ opacity: Double) -> Color {
        Color(hue: tint.h.truncatingRemainder(dividingBy: 1), saturation: s, brightness: bri).opacity(opacity)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                ZStack {
                    Circle().fill(LinearGradient(
                        colors: [c(sat * 0.55, min(1.0, deep + 0.25), 0.92),
                                 c(sat, hovering ? deep : deep * 0.85, 0.95)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    // glossy top half
                    Ellipse()
                        .fill(LinearGradient(
                            colors: [Color.white.opacity(0.85), Color.white.opacity(0.08)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .frame(width: 42, height: 24)
                        .offset(y: -13)
                }
                .clipShape(Circle())

                Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                Circle().stroke(c(sat, deep * 0.55, 0.7), lineWidth: 1)

                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            }
            .frame(width: 54, height: 54)
            .scaleEffect(hovering ? 1.08 : 1.0)
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Selection bubble (Wii U "Play With U"-style callout)

struct SpeechBubbleShape: Shape {
    var cornerRadius: CGFloat = 14
    var tailWidth: CGFloat = 22
    var tailHeight: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        let bodyRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tailHeight)
        let tailCenterX = rect.midX
        let r = min(cornerRadius, min(bodyRect.width, bodyRect.height) / 2)

        var path = Path()

        path.move(to: CGPoint(x: bodyRect.minX + r, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: bodyRect.maxX - r, y: bodyRect.minY))
        path.addArc(center: CGPoint(x: bodyRect.maxX - r, y: bodyRect.minY + r), radius: r,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - r))
        path.addArc(center: CGPoint(x: bodyRect.maxX - r, y: bodyRect.maxY - r), radius: r,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: tailCenterX + tailWidth / 2, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: tailCenterX, y: rect.maxY))
        path.addLine(to: CGPoint(x: tailCenterX - tailWidth / 2, y: bodyRect.maxY))
        path.addLine(to: CGPoint(x: bodyRect.minX + r, y: bodyRect.maxY))
        path.addArc(center: CGPoint(x: bodyRect.minX + r, y: bodyRect.maxY - r), radius: r,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + r))
        path.addArc(center: CGPoint(x: bodyRect.minX + r, y: bodyRect.minY + r), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()

        return path
    }
}

struct SelectionBubble: View {
    let text: String
    let borderColor = Color(red: 0.25, green: 0.6, blue: 0.95)
    let glossFill = LinearGradient(
        colors: [Color.white, Color(red: 0.82, green: 0.92, blue: 1.0)],
        startPoint: .top, endPoint: .bottom
    )

    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundColor(Color(red: 0.05, green: 0.2, blue: 0.5))
            .lineLimit(1)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 22)
            .background(SpeechBubbleShape().fill(glossFill))
            .overlay(SpeechBubbleShape().stroke(borderColor, lineWidth: 2))
            .fixedSize()
            .compositingGroup()
            .drawingGroup()
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }
}

// MARK: - Clock

struct LiveClock: View {
    @State private var now = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 2) {
            Text(now, format: .dateTime.hour().minute())
                .font(.system(size: 22, weight: .medium, design: .rounded))
            Text(now, format: .dateTime.weekday(.abbreviated).day().month())
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .opacity(0.85)
        }
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .onReceive(timer) { now = $0 }
    }
}

// MARK: - Floating Frutiger Aero glass capsule dock

struct DockGlassCircle: View {
    let icon: String
    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                    center: .topLeading, startRadius: 2, endRadius: 36
                )
            )
            .frame(width: 42, height: 42)
            .overlay(Circle().stroke(Color.white.opacity(0.65), lineWidth: 1))
            .overlay(Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundColor(.white))
    }
}

struct AeroDock: View {
    let showClock: Bool
    let onSettings: () -> Void
    @State private var gearHover = false

    var body: some View {
        HStack(spacing: 18) {
            DockGlassCircle(icon: "applelogo")

            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.22))
                .frame(width: 26, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.5), lineWidth: 1))
                .overlay(Image(systemName: "sdcard.fill").font(.system(size: 13)).foregroundColor(.white.opacity(0.85)))

            if showClock {
                Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 28)

                LiveClock()
                    .padding(.horizontal, 6)
            }

            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 28)

            Button(action: onSettings) {
                DockGlassCircle(icon: "gearshape.fill")
                    .scaleEffect(gearHover ? 1.1 : 1.0)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { gearHover = $0 }
            .animation(.easeOut(duration: 0.12), value: gearHover)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.30, blue: 0.45).opacity(0.80),
                            Color(red: 0.03, green: 0.14, blue: 0.28).opacity(0.88)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        )
        .overlay(
            Canvas { context, size in
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Color.black.opacity(0.18)))
                    y += 4
                }
            }
            .clipShape(Capsule())
            .allowsHitTesting(false)
        )
        .overlay(Capsule().stroke(Color.white.opacity(0.55), lineWidth: 1.5))
        .overlay(
            Capsule()
                .trim(from: 0.52, to: 0.98)
                .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .blur(radius: 0.6)
        )
        .shadow(color: Color(red: 0.2, green: 0.7, blue: 0.85).opacity(0.5), radius: 20, y: 10)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var input = InputCoordinator()
    @ObservedObject private var store = LauncherStore.shared
    @State private var tileFrames: [Int: CGRect] = [:]
    // The page whose slide has finished. The name bubble stays hidden until it matches the current page.
    @State private var settledPage = 0

    private func borderHue(for tile: TileConfig) -> Double {
        let s = store.settings
        switch s.borderMode {
        case .fixed:
            return s.borderHue
        case .tile:
            return TileTint.hue(for: tile)
        case .wallpaper:
            return ColorSampler.average(path: resolvePath(s.wallpaperPath))?.h ?? s.borderHue
        }
    }

    private func borderConfig(for tile: TileConfig) -> BorderStyleConfig {
        let s = store.settings
        return BorderStyleConfig(hue: borderHue(for: tile), strength: s.borderStrength,
                                 rainbow: s.borderRainbow, speed: s.rainbowSpeed)
    }

    /// One slot of the 4x3 grid: a real tile if there is one, otherwise a transparent placeholder.
    @ViewBuilder
    private func slot(index i: Int, tiles: [TileConfig], size: CGSize) -> some View {
        if i < tiles.count {
            let tile = tiles[i]
            ChannelTileView(
                tile: tile, index: i, tileSize: size,
                border: i == input.focusedIndex
                    ? borderConfig(for: tile)
                    : BorderStyleConfig(hue: 0, strength: 1, rainbow: false, speed: 1),
                isFocused: input.focusedIndex == i,
                isPressed: input.pressedIndex == i,
                onTap: { input.setFocus(i) },
                onDoubleTap: { input.activate(i) }
            )
            .equatable()
        } else {
            EmptySlotView(tileSize: size)
        }
    }

    /// A full page: always 3 rows x 4 columns = 12 slots, empty ones shown as transparent tiles.
    private func pageGrid(page p: Int, tiles: [TileConfig], size: CGSize,
                          hSpacing: CGFloat, vSpacing: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: vSpacing) {
            ForEach(0..<gridRows, id: \.self) { row in
                HStack(spacing: hSpacing) {
                    ForEach(0..<gridColumns, id: \.self) { col in
                        slot(index: p * pageSize + row * gridColumns + col, tiles: tiles, size: size)
                    }
                }
            }
        }
        .frame(width: width, height: height)
    }

    var body: some View {
        let s = store.settings
        let tiles = store.tiles
        let pageCount = max(1, (tiles.count + pageSize - 1) / pageSize)
        let page = min(input.currentPage, pageCount - 1)
        let focused: TileConfig? = tiles.indices.contains(input.focusedIndex) ? tiles[input.focusedIndex] : nil
        // Page arrows take the wallpaper's average colour
        let arrowTint = ColorSampler.average(path: resolvePath(s.wallpaperPath))
            ?? ColorSampler.HSB(h: s.borderHue, s: 0.7, b: 0.7)
        let bubbleVisible = (settledPage == page)

        GeometryReader { _ in
            ZStack {
                ImageBackground(
                    path: resolvePath(s.wallpaperPath),
                    dim: s.wallpaperDim,
                    scanlines: s.scanlinesEnabled,
                    scanStrength: s.scanlineStrength,
                    chromatic: s.chromaticEnabled
                )
                .ignoresSafeArea()

                if s.tintEnabled, let f = focused {
                    BackgroundTint(color: TileTint.color(for: f), strength: s.tintStrength, fade: s.tintFadeSeconds)
                }

                if s.bubblesEnabled {
                    FloatingBubbles(count: s.bubbleCount, style: s.bubbleStyle, monoHue: s.bubbleHue)
                }

                GeometryReader { geo in
                    let horizontalPadding = geo.size.width * gridOuterMarginFraction
                    let availableWidth = geo.size.width - horizontalPadding * 2
                    let tileW = max(100, availableWidth / (CGFloat(gridColumns) + CGFloat(gridColumns - 1) * gridGapToTileWidthRatio))
                    let tileH = tileW / tileAspect
                    let hSpacing = tileW * gridGapToTileWidthRatio
                    let vSpacing = tileH * gridGapToTileHeightRatio
                    let size = CGSize(width: tileW, height: tileH)

                    // All pages sit side by side; sliding the row changes page
                    HStack(spacing: 0) {
                        ForEach(0..<pageCount, id: \.self) { p in
                            Group {
                                if abs(p - page) <= 1 {
                                    pageGrid(page: p, tiles: tiles, size: size,
                                             hSpacing: hSpacing, vSpacing: vSpacing,
                                             width: geo.size.width, height: geo.size.height)
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                    .offset(x: -CGFloat(page) * geo.size.width)
                    .animation(.easeInOut(duration: 0.34), value: page)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                    .clipped()
                }

                if tiles.isEmpty {
                    Text("No games yet. Press ⌘, to add some.")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(Color.black.opacity(0.4)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.6), lineWidth: 1))
                }

                if s.showTitleBubble, let frame = tileFrames[input.focusedIndex], let f = focused {
                    SelectionBubble(text: f.title)
                        .position(x: frame.midX, y: max(30, frame.minY - 40))
                        .allowsHitTesting(false)
                        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: input.focusedIndex)
                        // Hidden while pages slide (it used to jump to the new tile's final spot early)
                        .opacity(bubbleVisible ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: bubbleVisible)
                }
            }
            .coordinateSpace(name: "root")
            .onPreferenceChange(TileFrameKey.self) { tileFrames = $0 }
            // Page arrows (only when there is more than one page)
            .overlay {
                if pageCount > 1 {
                    HStack {
                        if page > 0 {
                            AeroArrowButton(systemName: "chevron.left", tint: arrowTint) { input.changePage(-1) }
                        }
                        Spacer()
                        if page < pageCount - 1 {
                            AeroArrowButton(systemName: "chevron.right", tint: arrowTint) { input.changePage(1) }
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
            // Page dots
            .overlay(alignment: .bottom) {
                if pageCount > 1 {
                    HStack(spacing: 10) {
                        ForEach(0..<pageCount, id: \.self) { p in
                            Circle()
                                .fill(Color.white.opacity(p == page ? 0.95 : 0.40))
                                .frame(width: p == page ? 11 : 8, height: p == page ? 11 : 8)
                                .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.8))
                                .onTapGesture { input.goToPage(p) }
                        }
                    }
                    .padding(.bottom, 120)
                    .animation(.easeOut(duration: 0.15), value: page)
                }
            }
            .overlay(alignment: .bottom) {
                AeroDock(showClock: s.showClock, onSettings: { openSettings() })
                    .padding(.bottom, 26)
            }
        }
        .frame(minWidth: 780, minHeight: 580)
        .background(WindowAccessor { LauncherWindow.window = $0 })
        .background {
            if #available(macOS 14.0, *) {
                SettingsActionCapture()
            }
        }
        // When the page changes, bring the name bubble back once the slide (0.34 s) has finished
        .onChange(of: page) { newPage in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settledPage = newPage }
        }
        .onAppear {
            SoundManager.shared.startMusic()
            if store.settings.launchFullscreen {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    (LauncherWindow.window ?? NSApp.windows.first)?.toggleFullScreen(nil)
                }
            }
        }
    }
}

// =====================================================================
// MARK: - Settings window (⌘,) — Windows 7 Aero style
// =====================================================================

enum Aero {
    static let ink = Color(red: 0.07, green: 0.20, blue: 0.38)
    static let inkSoft = Color(red: 0.22, green: 0.36, blue: 0.54)
    static let accent = Color(red: 0.15, green: 0.52, blue: 0.92)
}

struct AeroSettingsBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.72, green: 0.90, blue: 1.00),
                    Color(red: 0.42, green: 0.72, blue: 0.96),
                    Color(red: 0.64, green: 0.88, blue: 0.99)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.white.opacity(0.60), Color.white.opacity(0)],
                center: .topLeading, startRadius: 0, endRadius: 460
            )
            RadialGradient(
                colors: [Color.cyan.opacity(0.28), Color.cyan.opacity(0)],
                center: .bottomTrailing, startRadius: 0, endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

struct AeroCard<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = title {
                Text(t)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(Aero.ink)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.80), Color.white.opacity(0.52)],
                    startPoint: .top, endPoint: .bottom
                ))
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.2, green: 0.4, blue: 0.6).opacity(0.40), lineWidth: 0.75))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.9), lineWidth: 1).padding(1))
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let subtitle: String?
    let control: Control

    init(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Aero.ink)
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundColor(Aero.inkSoft)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            control
        }
    }
}

struct AeroButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        let top = prominent ? Color(red: 0.45, green: 0.78, blue: 1.0) : Color.white
        let bottom = prominent ? Color(red: 0.12, green: 0.48, blue: 0.88) : Color(red: 0.80, green: 0.89, blue: 0.97)
        return configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundColor(prominent ? .white : Aero.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: 7)
                        .fill(LinearGradient(
                            colors: [Color.white.opacity(0.5), Color.white.opacity(0)],
                            startPoint: .top, endPoint: .center
                        ))
                }
            )
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(red: 0.25, green: 0.42, blue: 0.62).opacity(0.85), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.7), lineWidth: 1).padding(1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Rainbow hue slider with a glossy knob
struct HueSlider: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(
                        colors: (0...12).map { Color(hue: Double($0) / 12.0, saturation: 0.65, brightness: 1.0) },
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(height: 10)
                    .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1))
                    .overlay(Capsule().stroke(Color.black.opacity(0.2), lineWidth: 0.5))

                Circle()
                    .fill(Color(hue: value, saturation: 0.7, brightness: 1.0))
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: CGFloat(value) * (w - 20))
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    let v = (g.location.x - 10) / max(1, w - 20)
                    value = Double(min(max(v, 0), 1))
                }
            )
        }
        .frame(width: 240, height: 24)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case tiles, appearance, audio, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tiles: return "Games"
        case .appearance: return "Appearance"
        case .audio: return "Audio"
        case .general: return "General"
        }
    }
    var icon: String {
        switch self {
        case .tiles: return "square.grid.3x3.fill"
        case .appearance: return "paintpalette.fill"
        case .audio: return "speaker.wave.2.fill"
        case .general: return "gearshape.fill"
        }
    }
}

struct AeroTabBar: View {
    @Binding var tab: SettingsTab

    @ViewBuilder
    private func tabBackground(selected: Bool) -> some View {
        ZStack {
            Capsule().fill(LinearGradient(
                colors: selected
                    ? [Color(red: 0.40, green: 0.75, blue: 1.0), Color(red: 0.10, green: 0.45, blue: 0.85)]
                    : [Color.white.opacity(0.65), Color.white.opacity(0.30)],
                startPoint: .top, endPoint: .bottom
            ))
            Capsule().fill(LinearGradient(
                colors: [Color.white.opacity(selected ? 0.55 : 0.40), Color.white.opacity(0)],
                startPoint: .top, endPoint: .center
            ))
            .padding(2)
            Capsule().strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
            Capsule().stroke(Color(red: 0.15, green: 0.35, blue: 0.6).opacity(0.5), lineWidth: 0.75)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SettingsTab.allCases) { t in
                Button { tab = t } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.icon)
                        Text(t.title)
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(tab == t ? .white : Aero.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(tabBackground(selected: tab == t))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SettingsRoot: View {
    @State private var tab: SettingsTab = .tiles

    var body: some View {
        ZStack {
            AeroSettingsBackground()

            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    Text("Launcher Settings")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundColor(Aero.ink)
                        .shadow(color: .white.opacity(0.8), radius: 0, y: 1)
                    AeroTabBar(tab: $tab)
                }
                .padding(.top, 34)
                .padding(.bottom, 12)

                Group {
                    switch tab {
                    case .tiles: TilesTab()
                    case .appearance: AppearanceTab()
                    case .audio: AudioTab()
                    case .general: GeneralTab()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 860, height: 640)
        .preferredColorScheme(.light)
        .background(WindowAccessor { w in
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = false   // true made sliders drag the whole window
            w.collectionBehavior.insert(.fullScreenAuxiliary)
            w.level = .floating
            w.backgroundColor = NSColor(red: 0.55, green: 0.80, blue: 0.97, alpha: 1)
            if !SettingsBridge.centered {
                SettingsBridge.centered = true
                w.center()
            }
        })
    }
}

// MARK: Games tab

struct TileRow: View {
    let tile: TileConfig

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundColor(Aero.inkSoft)

            if !tile.imagePath.isEmpty, let img = ImageCache.shared.image(resolvePath(tile.imagePath), maxPixel: 120) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(tile.accentColor)
                    .frame(width: 40, height: 22)
            }

            Text(tile.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Aero.ink)
                .lineLimit(1)
            Spacer()
            Image(systemName: tile.kind.icon)
                .font(.system(size: 11))
                .foregroundColor(Aero.inkSoft)
        }
        .padding(.vertical, 2)
    }
}

struct TilesTab: View {
    @ObservedObject var store = LauncherStore.shared
    @State private var selected: UUID?

    private func tileBinding(_ id: UUID) -> Binding<TileConfig> {
        Binding(
            get: { store.tiles.first(where: { $0.id == id }) ?? TileConfig() },
            set: { new in
                if let i = store.tiles.firstIndex(where: { $0.id == id }) { store.tiles[i] = new }
            }
        )
    }

    private func move(_ delta: Int) {
        guard let id = selected, let i = store.tiles.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard j >= 0 && j < store.tiles.count else { return }
        store.tiles.swapAt(i, j)
    }

    private func add(_ kind: TileKind) {
        var t = TileConfig()
        t.kind = kind
        t.title = kind == .website ? "New Website" : "New App"
        if kind == .website { t.target = "https://" }
        store.tiles.append(t)
        selected = t.id
    }

    private func removeSelected() {
        guard let id = selected, let i = store.tiles.firstIndex(where: { $0.id == id }) else { return }
        store.tiles.remove(at: i)
        if store.tiles.isEmpty {
            selected = nil
        } else {
            selected = store.tiles[min(i, store.tiles.count - 1)].id
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Left: reorderable list
            VStack(spacing: 8) {
                List(selection: $selected) {
                    ForEach(store.tiles) { tile in
                        TileRow(tile: tile).tag(tile.id)
                    }
                    .onMove { store.tiles.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.55))
                )
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.2, green: 0.4, blue: 0.6).opacity(0.4), lineWidth: 0.75))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Text("Drag rows to reorder, or use the arrows.")
                    .font(.system(size: 11))
                    .foregroundColor(Aero.inkSoft)

                HStack(spacing: 6) {
                    Button { add(.app) } label: { Label("App", systemImage: "plus") }
                    Button { add(.website) } label: { Label("Web", systemImage: "plus") }
                    Spacer()
                    Button { move(-1) } label: { Image(systemName: "arrow.up") }
                    Button { move(1) } label: { Image(systemName: "arrow.down") }
                    Button { removeSelected() } label: { Image(systemName: "trash") }
                }
                .buttonStyle(AeroButtonStyle())
            }
            .frame(width: 290)

            // Right: editor
            ScrollView {
                if let id = selected, store.tiles.contains(where: { $0.id == id }) {
                    TileEditor(tile: tileBinding(id))
                } else {
                    AeroCard {
                        Text("Select a game on the left, or add a new one.")
                            .font(.system(size: 13))
                            .foregroundColor(Aero.inkSoft)
                    }
                }
            }
        }
        .onAppear { if selected == nil { selected = store.tiles.first?.id } }
    }
}

struct TileEditor: View {
    @Binding var tile: TileConfig

    private var argsText: Binding<String> {
        Binding(
            get: { tile.arguments.joined(separator: "\n") },
            set: { tile.arguments = $0.components(separatedBy: "\n") }
        )
    }

    private var targetTitle: String {
        switch tile.kind {
        case .app: return "Application"
        case .website: return "Web address"
        case .command: return "Executable"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            AeroCard("Tile") {
                SettingRow("Name") {
                    TextField("Name", text: $tile.title)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                SettingRow("Type") {
                    Picker("", selection: $tile.kind) {
                        ForEach(TileKind.allCases) { k in Text(k.label).tag(k) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
                SettingRow(targetTitle, subtitle: tile.kind == .website ? "Opens in your default browser" : nil) {
                    HStack(spacing: 6) {
                        TextField(tile.kind == .website ? "https://…" : "Path", text: $tile.target)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: tile.kind == .website ? 260 : 190)
                        if tile.kind != .website {
                            Button("Choose…") {
                                chooseFile(types: tile.kind == .app ? [.application] : []) { url in
                                    tile.target = storablePath(url)
                                    if tile.title.hasPrefix("New ") {
                                        tile.title = url.deletingPathExtension().lastPathComponent
                                    }
                                }
                            }
                            .buttonStyle(AeroButtonStyle())
                        }
                    }
                }
                if tile.kind != .website {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Arguments (one per line, optional)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Aero.ink)
                        TextEditor(text: argsText)
                            .font(.system(size: 11, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.75)))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(red: 0.2, green: 0.4, blue: 0.6).opacity(0.35), lineWidth: 0.75))
                            .frame(height: 70)
                    }
                    SettingRow("Link save folder before launch",
                               subtitle: "For the Switch games saving to Source/Switch/Save") {
                        Toggle("", isOn: $tile.usesSaves).labelsHidden().toggleStyle(.switch)
                    }
                }
                HStack {
                    Spacer()
                    Button("Test launch") { launchTile(tile) }
                        .buttonStyle(AeroButtonStyle(prominent: true))
                }
            }

            AeroCard("Tile background") {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        if !tile.imagePath.isEmpty, let img = ImageCache.shared.image(resolvePath(tile.imagePath), maxPixel: 400) {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            LinearGradient(
                                colors: [tile.accentColor.opacity(0.55), tile.accentColor.opacity(0.95)],
                                startPoint: .top, endPoint: .bottom
                            )
                        }
                    }
                    .frame(width: 160, height: 87)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.8), lineWidth: 1.5))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(tile.imagePath.isEmpty ? "No image: using a colored tile" : URL(fileURLWithPath: tile.imagePath).lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundColor(Aero.inkSoft)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Button("Choose image…") {
                                chooseFile(types: [.image]) { url in tile.imagePath = storablePath(url) }
                            }
                            Button("Clear") { tile.imagePath = "" }
                        }
                        .buttonStyle(AeroButtonStyle())
                        Text("Tile color (when there is no image)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Aero.ink)
                        HueSlider(value: $tile.accentHue)
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }
}

// MARK: Appearance tab

struct BorderPreview: View {
    let hue: Double
    var strength: Double = 1.0
    var rainbow: Bool = false
    var speed: Double = 1.0

    var body: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(LinearGradient(
                colors: [Color(red: 0.45, green: 0.70, blue: 0.9), Color(red: 0.2, green: 0.4, blue: 0.7)],
                startPoint: .top, endPoint: .bottom
            ))
            .frame(width: 120, height: 66)
            .overlay(AeroFrame(hue: hue, strength: strength, rainbow: rainbow, speed: speed).padding(-7))
            .padding(10)
    }
}

struct FileRow: View {
    let title: String
    @Binding var path: String
    let defaultPath: String
    let types: [UTType]

    var body: some View {
        SettingRow(title, subtitle: path.isEmpty ? "None" : URL(fileURLWithPath: path).lastPathComponent) {
            HStack(spacing: 6) {
                Button("Choose…") { chooseFile(types: types) { path = storablePath($0) } }
                Button("Default") { path = defaultPath }
            }
            .buttonStyle(AeroButtonStyle())
        }
    }
}

struct AppearanceTab: View {
    @ObservedObject var store = LauncherStore.shared

    private var previewHue: Double {
        let s = store.settings
        switch s.borderMode {
        case .fixed: return s.borderHue
        case .tile: return store.tiles.first.map { TileTint.hue(for: $0) } ?? s.borderHue
        case .wallpaper: return ColorSampler.average(path: resolvePath(s.wallpaperPath))?.h ?? s.borderHue
        }
    }

    private var bubbleCountBinding: Binding<Double> {
        Binding(
            get: { Double(store.settings.bubbleCount) },
            set: { store.settings.bubbleCount = Int($0.rounded()) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                AeroCard("Wallpaper") {
                    FileRow(title: "Wallpaper image", path: $store.settings.wallpaperPath,
                            defaultPath: "Gamecube/Gamecube-src/wallpaper.jpg", types: [.image])
                    SettingRow("Darken wallpaper", subtitle: "Keeps white text readable") {
                        Slider(value: $store.settings.wallpaperDim, in: 0...0.7)
                            .tint(Aero.accent).frame(width: 200)
                    }
                    SettingRow("CRT scanlines") {
                        Toggle("", isOn: $store.settings.scanlinesEnabled).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Scanline strength") {
                        Slider(value: $store.settings.scanlineStrength, in: 0.2...2.0)
                            .tint(Aero.accent).frame(width: 200)
                    }
                    .disabled(!store.settings.scanlinesEnabled)
                    .opacity(store.settings.scanlinesEnabled ? 1 : 0.45)
                    SettingRow("Chromatic aberration", subtitle: "RGB split on the wallpaper") {
                        Toggle("", isOn: $store.settings.chromaticEnabled).labelsHidden().toggleStyle(.switch)
                    }
                }

                AeroCard("Wallpaper tint") {
                    SettingRow("Tint wallpaper with the selected tile's color") {
                        Toggle("", isOn: $store.settings.tintEnabled).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Tint strength") {
                        Slider(value: $store.settings.tintStrength, in: 0.2...2.0)
                            .tint(Aero.accent).frame(width: 200)
                    }
                    .disabled(!store.settings.tintEnabled)
                    .opacity(store.settings.tintEnabled ? 1 : 0.45)
                    SettingRow("Tint fade time", subtitle: "\(Int(store.settings.tintFadeSeconds)) seconds to blend into the next tile's color") {
                        Slider(value: $store.settings.tintFadeSeconds, in: 1...8, step: 1)
                            .tint(Aero.accent).frame(width: 200)
                    }
                    .disabled(!store.settings.tintEnabled)
                    .opacity(store.settings.tintEnabled ? 1 : 0.45)
                }

                AeroCard("Selection border") {
                    HStack(alignment: .center, spacing: 16) {
                        BorderPreview(hue: previewHue,
                                      strength: store.settings.borderStrength,
                                      rainbow: store.settings.borderRainbow,
                                      speed: store.settings.rainbowSpeed)
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("", selection: $store.settings.borderMode) {
                                ForEach(BorderMode.allCases) { m in Text(m.label).tag(m) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Text("Border hue")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Aero.ink)
                            HueSlider(value: $store.settings.borderHue)
                                .disabled(store.settings.borderMode != .fixed)
                                .opacity(store.settings.borderMode == .fixed ? 1 : 0.4)
                        }
                    }
                    SettingRow("Border color strength", subtitle: "Higher = richer, more saturated glass") {
                        Slider(value: $store.settings.borderStrength, in: 0.5...2.5)
                            .tint(Aero.accent).frame(width: 200)
                    }
                    SettingRow("Rainbow border", subtitle: "Colors flow around the glass frame (overrides the hue)") {
                        Toggle("", isOn: $store.settings.borderRainbow).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Rainbow speed") {
                        Slider(value: $store.settings.rainbowSpeed, in: 0.2...3.0)
                            .tint(Aero.accent).frame(width: 200)
                    }
                    .disabled(!store.settings.borderRainbow)
                    .opacity(store.settings.borderRainbow ? 1 : 0.45)
                }

                AeroCard("Bubbles") {
                    SettingRow("Floating bubbles") {
                        Toggle("", isOn: $store.settings.bubblesEnabled).labelsHidden().toggleStyle(.switch)
                    }
                    Group {
                        SettingRow("Amount") {
                            Slider(value: bubbleCountBinding, in: 4...40)
                                .tint(Aero.accent).frame(width: 200)
                        }
                        SettingRow("Color") {
                            Picker("", selection: $store.settings.bubbleStyle) {
                                ForEach(BubbleStyle.allCases) { b in Text(b.label).tag(b) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 220)
                        }
                        SettingRow("Monochrome hue") {
                            HueSlider(value: $store.settings.bubbleHue)
                        }
                        .disabled(store.settings.bubbleStyle != .monochrome)
                        .opacity(store.settings.bubbleStyle == .monochrome ? 1 : 0.4)
                    }
                    .disabled(!store.settings.bubblesEnabled)
                    .opacity(store.settings.bubblesEnabled ? 1 : 0.45)
                }
            }
            .padding(.bottom, 4)
        }
    }
}

// MARK: Audio tab

struct SoundRow: View {
    let title: String
    let subtitle: String
    @Binding var enabled: Bool
    @Binding var path: String
    let defaultPath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(title, subtitle: subtitle) {
                Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch)
            }
            HStack(spacing: 8) {
                Image(systemName: "music.note")
                    .foregroundColor(Aero.inkSoft)
                Text(path.isEmpty ? "None" : URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundColor(Aero.inkSoft)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 6) {
                    Button { SoundManager.shared.preview(path) } label: { Image(systemName: "play.fill") }
                    Button("Choose…") { chooseFile(types: [.audio]) { path = storablePath($0) } }
                    Button("Default") { path = defaultPath }
                }
                .buttonStyle(AeroButtonStyle())
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
        }
    }
}

struct AudioTab: View {
    @ObservedObject var store = LauncherStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                AeroCard("Main menu theme") {
                    SoundRow(title: "Menu music", subtitle: "Loops while the launcher is open",
                             enabled: $store.settings.musicEnabled, path: $store.settings.musicPath,
                             defaultPath: "Gamecube/Gamecube-src/mainmenu.flac")
                    SettingRow("Music volume") {
                        Slider(value: $store.settings.musicVolume, in: 0...1)
                            .tint(Aero.accent).frame(width: 200)
                    }
                }

                AeroCard("Sound effects") {
                    SoundRow(title: "Change tile tick", subtitle: "Plays when you move between tiles",
                             enabled: $store.settings.tickEnabled, path: $store.settings.tickPath,
                             defaultPath: "Gamecube/Gamecube-src/select.wav")
                    Divider()
                    SoundRow(title: "Select sound", subtitle: "Plays when you start a game",
                             enabled: $store.settings.launchSoundEnabled, path: $store.settings.launchSoundPath,
                             defaultPath: "Gamecube/Gamecube-src/enter.wav")
                    Divider()
                    SettingRow("Effects volume") {
                        Slider(value: $store.settings.sfxVolume, in: 0...1)
                            .tint(Aero.accent).frame(width: 200)
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }
}

// MARK: General tab

struct GeneralTab: View {
    @ObservedObject var store = LauncherStore.shared
    @State private var confirmSettingsReset = false
    @State private var confirmTilesReset = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                AeroCard("Launcher") {
                    SettingRow("Open fullscreen") {
                        Toggle("", isOn: $store.settings.launchFullscreen).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Quit launcher when a game starts",
                               subtitle: "Off = the launcher hides and stays in the background") {
                        Toggle("", isOn: $store.settings.quitOnLaunch).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Show clock in the dock") {
                        Toggle("", isOn: $store.settings.showClock).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Show game title above the selected tile") {
                        Toggle("", isOn: $store.settings.showTitleBubble).labelsHidden().toggleStyle(.switch)
                    }
                }

                AeroCard("Controls") {
                    Text("Arrow keys / D-pad: move  ·  Return / Space / A: start  ·  Page Up / Page Down / L1 / R1: change page  ·  ⌘, / Menu button: settings")
                        .font(.system(size: 12))
                        .foregroundColor(Aero.inkSoft)
                }

                AeroCard("Data") {
                    SettingRow("Config file", subtitle: storablePath(configFileURL)) {
                        Button("Show in Finder") {
                            store.save()
                            NSWorkspace.shared.activateFileViewerSelecting([configFileURL])
                        }
                        .buttonStyle(AeroButtonStyle())
                    }
                    Text("Settings and your game list are saved inside the Source folder, so they move with the drive.")
                        .font(.system(size: 11))
                        .foregroundColor(Aero.inkSoft)
                    HStack(spacing: 8) {
                        Button("Reset settings…") { confirmSettingsReset = true }
                        Button("Reset game list…") { confirmTilesReset = true }
                    }
                    .buttonStyle(AeroButtonStyle())
                }
            }
            .padding(.bottom, 4)
        }
        .confirmationDialog("Reset all settings to defaults?", isPresented: $confirmSettingsReset, titleVisibility: .visible) {
            Button("Reset settings", role: .destructive) { store.settings = AppSettings() }
        }
        .confirmationDialog("Replace your game list with the default one?", isPresented: $confirmTilesReset, titleVisibility: .visible) {
            Button("Reset game list", role: .destructive) { store.tiles = TileConfig.defaults }
        }
    }
}

// MARK: - App entry point

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct GamecubeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 640)

        // ⌘, opens this automatically
        Settings {
            SettingsRoot()
        }
    }
}
