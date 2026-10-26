// Model.swift — profiles, slots, actions, and the on-disk store.
import Foundation
import SwiftUI
import CoreGraphics

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case none, hotkey, text, openApp, openURL, shell
    case mute, volumeUp, volumeDown
    case pageNext, pagePrevious, pageHome
    case page                     // legacy single action with a target; kept only for old files
    var id: String { rawValue }

    /// `text` is kept only so older profile files still decode; it is no longer offered.
    static var selectableCases: [ActionKind] {
        allCases.filter { $0 != .text && $0 != .page }
    }

    /// The three page buttons are one family: they share dispatch and only differ by direction.
    var kindExplanation: String {
        switch self {
        case .mute: t("Sends the system mute key to the focused app.")
        case .volumeUp: t("Sends the system volume-up key.")
        case .volumeDown: t("Sends the system volume-down key.")
        case .pageNext: t("Moves to the next page; after the last page it wraps to the first.")
        case .pagePrevious: t("Moves to the previous page; from the first page it wraps to the last.")
        case .pageHome: t("Always jumps back to page 1, whatever page you are on.")
        default: ""
        }
    }

    /// Raw dispatch values — never translated, they drive the page change.
    var pageTarget: String? {
        switch self {
        case .pageNext: return "next"
        case .pagePrevious: return "previous"
        case .pageHome: return "home"
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .none: t("None")
        case .hotkey: t("Key combination")
        case .text: t("Type text")
        case .openApp: t("Open app")
        case .openURL: t("Open URL")
        case .shell: t("Run script")
        case .mute: t("Mute")
        case .volumeUp: t("Volume up")
        case .volumeDown: t("Volume down")
        case .pageNext: t("Next page")
        case .pagePrevious: t("Previous page")
        case .pageHome: t("First page")
        case .page: t("Change page")
        }
    }

    var symbol: String {
        switch self {
        case .none: "slash.circle"
        case .hotkey: "keyboard"
        case .text: "text.cursor"
        case .openApp: "app.badge"
        case .openURL: "link"
        case .shell: "terminal"
        case .mute: "speaker.slash"
        case .volumeUp: "speaker.wave.3"
        case .volumeDown: "speaker.wave.1"
        case .pageNext: "chevron.right.square"
        case .pagePrevious: "chevron.left.square"
        case .pageHome: "house"
        case .page: "square.grid.3x3.middle.filled"
        }
    }
}

enum Paging {
    static func label(for target: String) -> String {
        switch target {
        case "next": "Next page"
        case "previous": "Previous page"
        default: target.isEmpty ? "Next page" : "Go to page \(target)"
        }
    }
}

struct KeyAction: Codable, Equatable {
    var kind: ActionKind = .none
    var keyCode: UInt16 = 0
    var modifierFlags: UInt = 0        // NSEvent.ModifierFlags raw value
    var text: String = ""
    var target: String = ""

    var summary: String {
        switch kind {
        case .none: t("—")
case .hotkey: HotkeyFormatter.describe(keyCode: keyCode, flags: NSEvent.ModifierFlags(rawValue: modifierFlags))
        case .text: t("Type “\(text.prefix(24))”")
case .openApp: (target as NSString).lastPathComponent.isEmpty ? "—" : (target as NSString).lastPathComponent
        case .openURL: target
        case .shell: t("script")
        case .mute: t("Mute")
        case .volumeUp: t("Volume up")
        case .volumeDown: t("Volume down")
case .pageNext: t("Go to the next page")
case .pagePrevious: t("Go to the previous page")
case .pageHome: t("Go to the first page")
case .page: Paging.label(for: target)
        }
    }
}

struct Slot: Codable, Identifiable, Equatable {
    var id: Int                    // 1...18, matches the logical key number
    var label: String = ""
    var imageFile: String?         // file name inside the profile's images directory
    var action: KeyAction = KeyAction()
    var widget: WidgetConfig?      // window panes only: clock, date, cpu, page…


    var isWindow: Bool { id >= 16 }
}

struct Page: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var slots: [Slot]

    static func empty(named name: String) -> Page {
        Page(name: name, slots: (1...18).map { Slot(id: $0) })
    }
}

struct Profile: Codable, Identifiable, Equatable {
    static let maxPages = 4

    var id = UUID()
    var name: String
    var pages: [Page]
    var activePage: Int = 0
    var window: WindowConfig?     // how the 1×3 strip is used: one wide widget or three
    var fileURLPath: String?      // where Save writes this profile (set by Save As)

    init(id: UUID = UUID(), name: String, pages: [Page], activePage: Int = 0) {
        self.id = id
        self.name = name
        self.pages = pages
        self.activePage = min(max(0, activePage), max(0, pages.count - 1))
    }

    static func newProfile(named name: String) -> Profile {
        Profile(name: name, pages: [.empty(named: "Page 1")])
    }

    // MARK: page access

    var currentPage: Page? { pages.indices.contains(activePage) ? pages[activePage] : pages.first }

    /// Slots of the page in view — every existing call site keeps working.
    var slots: [Slot] {
        get { currentPage?.slots ?? [] }
        set {
            guard pages.indices.contains(activePage) else { return }
            pages[activePage].slots = newValue
        }
    }

    func slot(_ index: Int) -> Slot? { slots.first { $0.id == index } }

    mutating func update(_ index: Int, _ body: (inout Slot) -> Void) {
        guard pages.indices.contains(activePage),
              let i = pages[activePage].slots.firstIndex(where: { $0.id == index }) else { return }
        body(&pages[activePage].slots[i])
    }

    mutating func selectPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        activePage = index
    }

    @discardableResult
    mutating func addPage() -> Bool {
        guard pages.count < Profile.maxPages else { return false }
        pages.append(.empty(named: "Page \(pages.count + 1)"))
        activePage = pages.count - 1
        return true
    }

    @discardableResult
    mutating func removePage(at index: Int) -> Bool {
        guard pages.count > 1, pages.indices.contains(index) else { return false }
        pages.remove(at: index)
        activePage = min(activePage, pages.count - 1)
        return true
    }

    // Old files stored a single `slots` array; accept both shapes.
    private enum CodingKeys: String, CodingKey { case id, name, pages, activePage, slots, window, fileURLPath }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        window = try c.decodeIfPresent(WindowConfig.self, forKey: .window)
        fileURLPath = try c.decodeIfPresent(String.self, forKey: .fileURLPath)
        name = try c.decode(String.self, forKey: .name)
        if let pages = try c.decodeIfPresent([Page].self, forKey: .pages), !pages.isEmpty {
            self.pages = pages
            activePage = try c.decodeIfPresent(Int.self, forKey: .activePage) ?? 0
        } else {
            let legacy = try c.decodeIfPresent([Slot].self, forKey: .slots) ?? []
            pages = [Page(name: "Page 1", slots: legacy.isEmpty ? (1...18).map { Slot(id: $0) } : legacy)]
            activePage = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(pages, forKey: .pages)
        try c.encode(activePage, forKey: .activePage)
        try c.encodeIfPresent(window, forKey: .window)
        try c.encodeIfPresent(fileURLPath, forKey: .fileURLPath)
    }
}

// MARK: - portable profile file

/// A profile plus its graphics in one file, for Load/Save As.
struct ProfilePackage: Codable {
    var version: Int = 1
    var profile: Profile
    var images: [String: Data]      // imageFile name → bytes (base64 in JSON)
}

// MARK: - persistence

@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var selection: Profile.ID?

    /// The profile the panel is actually showing. Selecting a profile in the sidebar does not
    /// change this — only "Send to Device" (or a page key on the live profile) does.
    @Published var liveProfileID: Profile.ID? {
        didSet { UserDefaults.standard.set(liveProfileID?.uuidString, forKey: "liveProfileID") }
    }

    var isLiveSelection: Bool { liveProfileID == selection }

    private let root: URL
    private let storeURL: URL
    private var savedSnapshot = Data()
    @Published private(set) var unsavedProfileIDs: Set<UUID> = []

    /// A profile that exists only in memory: created and then never persisted.
    var hasUnsavedNewProfiles: Bool { !unsavedProfileIDs.isEmpty }

    /// True when the in-memory profiles differ from what is on disk — a freshly created profile
    /// counts, which is what triggers the save prompt on quit.
    var hasUnsavedChanges: Bool {
        if !unsavedProfileIDs.isEmpty { return true }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(profiles)) != savedSnapshot
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Deckhand", isDirectory: true)
        root = base
        storeURL = base.appendingPathComponent("profiles.json")

        // first launch as Deckhand: adopt the data written while the app was called StreamDockLite
        let legacy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StreamDockLite", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: base)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
        if let stored = UserDefaults.standard.string(forKey: "liveProfileID"),
           let id = UUID(uuidString: stored),
           profiles.contains(where: { $0.id == id }) {
            liveProfileID = id
        } else {
            liveProfileID = profiles.first?.id
        }
        selection = liveProfileID          // the editor opens on what the panel is showing
    }

    func makeLive(_ id: Profile.ID?) { liveProfileID = id }

    var selected: Binding<Profile?> {
        Binding(
            get: { [weak self] in self?.profiles.first { $0.id == self?.selection } },
            set: { _ in }
        )
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Profile].self, from: data),
              !decoded.isEmpty else {
            profiles = [Profile.newProfile(named: "Main")]
            selection = profiles.first?.id
            return
        }
        var migrated = 0
        profiles = decoded.map { profile in
            var p = profile
            for pi in p.pages.indices {
                for si in p.pages[pi].slots.indices where p.pages[pi].slots[si].action.kind == .text {
                    p.pages[pi].slots[si].action = KeyAction()   // "Type text" is retired
                    migrated += 1
                }
                for si in p.pages[pi].slots.indices where p.pages[pi].slots[si].action.kind == .page {
                    switch p.pages[pi].slots[si].action.target {
                    case "next":     p.pages[pi].slots[si].action.kind = .pageNext
                    case "previous": p.pages[pi].slots[si].action.kind = .pagePrevious
                    case "home":     p.pages[pi].slots[si].action.kind = .pageHome
                    default:         break                       // numeric "go to page N" stays legacy
                    }
                    migrated += 1
                }
            }
            return p
        }
        selection = profiles.first?.id
        if migrated > 0 { save(); Log.write("migrated \(migrated) retired text action(s) to None") }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        savedSnapshot = (try? enc.encode(decoded)) ?? Data()
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(profiles) {
            try? data.write(to: storeURL, options: .atomic)
            savedSnapshot = (try? JSONEncoder().encode(profiles)) ?? data
            unsavedProfileIDs.removeAll()
        }
    }

    func binding(for profileID: Profile.ID) -> Binding<Profile>? {
        guard let idx = profiles.firstIndex(where: { $0.id == profileID }) else { return nil }
        return Binding(
            get: { [weak self] in self?.profiles[idx] ?? Profile.newProfile(named: "Main") },
            set: { [weak self] new in
                guard let self, idx < self.profiles.count else { return }
                self.profiles[idx] = new
                self.save()
            }
        )
    }

    func addProfile(named name: String? = nil) {
        let p = Profile.newProfile(named: name ?? "Profile \(profiles.count + 1)")
        profiles.append(p)
        selection = p.id
        unsavedProfileIDs.insert(p.id)
        // deliberately not saved: it exists only in memory until you name it or quit, and the
        // quit prompt below offers to write it to disk
    }

    func setFilePath(_ path: String?, for id: Profile.ID) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].fileURLPath = path
        save()
    }

    /// Deep copy: new identity, its own image folder, same pages/actions/widgets.
    @discardableResult
    func duplicate(_ id: Profile.ID) -> Profile? {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        let original = profiles[idx]

        var copy = original
        copy.id = UUID()
        copy.fileURLPath = nil                     // a copy is not the same document on disk

        var base = "\(original.name) copy"
        var n = 2
        while profiles.contains(where: { $0.name == base }) {
            base = "\(original.name) copy \(n)"
            n += 1
        }
        copy.name = base

        // move the graphics across so the copy is self-contained
        let source = imageDirectory(for: original.id)
        let destination = imageDirectory(for: copy.id)
        for page in copy.pages {
            for slot in page.slots {
                guard let name = slot.imageFile else { continue }
                let from = source.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: from.path) else { continue }
                try? FileManager.default.copyItem(at: from,
                                                  to: destination.appendingPathComponent(name))
            }
        }

        profiles.insert(copy, at: idx + 1)
        selection = copy.id
        save()
        return copy
    }

    func rename(_ id: Profile.ID, to name: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].name = name
        save()
    }

    /// Removes a profile from the sidebar. Nothing on disk is deleted: a saved .sdprofile file and
    /// the image folder stay where they are, so the profile can be loaded again later.
    func removeFromSidebar(_ id: Profile.ID) {
        unsavedProfileIDs.remove(id)
        profiles.removeAll { $0.id == id }
        if profiles.isEmpty { profiles = [Profile.newProfile(named: "Main")] }
        selection = profiles.first?.id
        if liveProfileID == id { liveProfileID = selection }   // the panel can't keep a dead profile
        save()
    }

    // MARK: portable files

    func exportPackage(for profile: Profile) -> Data? {
        let dir = imageDirectory(for: profile.id)
        var images: [String: Data] = [:]
        for page in profile.pages {
            for slot in page.slots {
                guard let name = slot.imageFile,
                      let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { continue }
                images[name] = data
            }
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(ProfilePackage(profile: profile, images: images))
    }

    /// Load a package as a *new* profile (fresh id) and select it.
    func importPackage(_ data: Data) -> Profile? {
        guard let package = try? JSONDecoder().decode(ProfilePackage.self, from: data) else { return nil }
        var profile = package.profile
        profile.id = UUID()
        // never land two identically named rows in the sidebar
        if profiles.contains(where: { $0.name == profile.name }) {
            var n = 2
            while profiles.contains(where: { $0.name == "\(profile.name) \(n)" }) { n += 1 }
            profile.name = "\(profile.name) \(n)"
        }
        let dir = imageDirectory(for: profile.id)
        for (name, bytes) in package.images {
            try? bytes.write(to: dir.appendingPathComponent(name), options: .atomic)
        }
        // drop references whose bytes were missing from the package
        for p in profile.pages.indices {
            for s in profile.pages[p].slots.indices {
                if let name = profile.pages[p].slots[s].imageFile,
                   package.images[name] == nil {
                    profile.pages[p].slots[s].imageFile = nil
                }
            }
        }
        profiles.append(profile)
        selection = profile.id
        save()
        return profile
    }

    // images live next to the profile data, one folder per profile
    func imageDirectory(for profileID: Profile.ID) -> URL {
        let dir = root.appendingPathComponent("images/\(profileID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func imageURL(profileID: Profile.ID, slot: Slot, page: Int = 0) -> URL? {
        guard let name = slot.imageFile else { return nil }
        let url = imageDirectory(for: profileID).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Store an already-composed image (from the editor) as the slot's graphic.
    func saveImage(_ image: CGImage, for slot: Slot, profileID: Profile.ID, page: Int = 0) -> String? {
        // store upright: the device rotation is applied once when the image is sent
        guard let jpeg = ImagePrep.square(image, side: ImagePrep.size(for: slot.id)) else { return nil }
        let name = "p\(page)slot\(slot.id).jpg"
        let url = imageDirectory(for: profileID).appendingPathComponent(name)
        try? jpeg.write(to: url, options: .atomic)
        return name
    }

    /// Copy the chosen file into the profile folder, downscaled to the slot's target size.
    func importImage(from source: URL, for slot: Slot, profileID: Profile.ID, page: Int = 0) -> String? {
        guard let image = ImagePrep.load(source),
              let jpeg = ImagePrep.square(image, side: ImagePrep.size(for: slot.id)) else { return nil }
        let name = "p\(page)slot\(slot.id).jpg"
        let url = imageDirectory(for: profileID).appendingPathComponent(name)
        try? jpeg.write(to: url, options: .atomic)
        return name
    }
}
