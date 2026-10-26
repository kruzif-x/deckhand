// MenuBar.swift — Deckhand keeps running with no window open, so the panel keeps working.
//
// Closing the window only hides it; the process stays alive holding the HID handle, and the status
// item is how you get the window back. Quitting from that menu is a real quit (with the usual
// unsaved-profile prompt).
import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarController {
    static let shared = MenuBarController()

    private var item: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private weak var deck: DeckModel?

    func start(deck: DeckModel, store: ProfileStore) {
        self.deck = deck
        guard item == nil else { return }

        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = status.button {
            button.image = NSImage(systemSymbolName: "square.grid.3x3",
                                   accessibilityDescription: "Deckhand")
            button.image?.isTemplate = true
            button.toolTip = "Deckhand"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Open Deckhand", action: #selector(showWindow), keyEquivalent: "")

        let state = NSMenuItem(title: "Panel: disconnected", action: nil, keyEquivalent: "")
        state.isEnabled = false
        state.tag = 100
        menu.addItem(state)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Send to Device", action: #selector(sendToDevice), keyEquivalent: "r")
        menu.addItem(withTitle: "Next Page", action: #selector(nextPage), keyEquivalent: "")
        menu.addItem(withTitle: "Previous Page", action: #selector(previousPage), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Deckhand", action: #selector(quit), keyEquivalent: "q")

        for entry in menu.items where entry.action != nil {
            entry.target = self
        }
        status.menu = menu
        item = status

        // mirror the connection state in the menu and the icon
        deck.$connected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self else { return }
                menu.item(withTag: 100)?.title = connected ? "Panel: connected" : "Panel: disconnected"
                self.item?.button?.image = NSImage(
                    systemSymbolName: connected ? "square.grid.3x3.fill" : "square.grid.3x3",
                    accessibilityDescription: "Deckhand")
                self.item?.button?.image?.isTemplate = true
            }
            .store(in: &cancellables)
    }

    // MARK: menu actions

    @objc private func showWindow() {
        WindowBridge.shared.show()
    }

    @objc private func sendToDevice() {
        NotificationCenter.default.post(name: .init("deck.sendAll"), object: nil)
    }

    @objc private func nextPage() {
        NotificationCenter.default.post(name: .init("deck.pageRequest"), object: nil,
                                        userInfo: ["target": "next"])
    }

    @objc private func previousPage() {
        NotificationCenter.default.post(name: .init("deck.pageRequest"), object: nil,
                                        userInfo: ["target": "previous"])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
