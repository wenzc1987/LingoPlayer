import AppKit

/// Keep AppKit's event loop free while the user browses files. One retained
/// panel also prevents repeated menu/keyboard actions from opening duplicates.
@MainActor final class FilePanelPresenter {
    private(set) var activePanel: NSOpenPanel?
    private var reusablePanel: NSOpenPanel?
    var isPresenting: Bool { activePanel != nil }
    func present(configure: (NSOpenPanel) -> Void, completion: @escaping ([URL]) -> Void) {
        guard activePanel == nil else { activePanel?.makeKeyAndOrderFront(nil); return }
        let panel = reusablePanel ?? NSOpenPanel()
        reusablePanel = panel
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.allowedContentTypes = []
        panel.message = ""; panel.nameFieldStringValue = ""
        configure(panel)
        activePanel = panel
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            let urls = response == .OK ? panel?.urls ?? [] : []
            self?.activePanel = nil
            if !urls.isEmpty { completion(urls) }
        }
        // Popovers may still be the key window while they are closing. Attach
        // to the stable main window (or its current sheet), never the popover.
        var owner = NSApp.mainWindow ?? NSApp.keyWindow
        while let sheet = owner?.attachedSheet { owner = sheet }
        if let owner { panel.beginSheetModal(for: owner, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
}
