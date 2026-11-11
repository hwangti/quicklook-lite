import AppKit

/// .md 더블클릭 시 열리는 편집기. 원문 편집(+서식 표시 옵션), ⌘S 저장(자동저장 포함), ⌘E·툴바로 미리보기 전환, ⌘+/⌘- 확대.
final class Document: NSDocument, NSTextViewDelegate, NSToolbarDelegate {
    static let plain: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.textColor]
    static var styledEditing: Bool {
        get { UserDefaults.standard.bool(forKey: "styledEditing") }
        set { UserDefaults.standard.set(newValue, forKey: "styledEditing") }
    }

    private var text = ""
    private var textView: NSTextView?
    private var scrollView: NSScrollView?
    private var modeControl: NSSegmentedControl?
    private var previewing = false

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let scroll = makeZoomableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.textContainerInset = NSSize(width: 16, height: 14)
        tv.delegate = self
        textView = tv
        scrollView = scroll
        showSource()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = scroll
        let toolbar = NSToolbar(identifier: "editor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [.mode]
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // 이 모니터에서 마지막으로 맞춘 크기로 열고, 크기를 바꾸면 기억
        let saved = currentScreen().flatMap { Self.savedWindowSizes[screenKey($0)] }
        window.setFrame(screenFittedFrame(minimum: window.frame.size, preferred: saved), display: false)
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window,
                                               queue: .main) { [weak window] _ in
            guard let window, let screen = window.screen else { return }
            Self.savedWindowSizes[screenKey(screen)] = window.frame.size
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window,
                                               queue: .main) { [weak self] _ in self?.applyZoom() }
        addWindowController(NSWindowController(window: window))
        applyZoom()  // 창이 놓인 모니터의 배율 (창 컨트롤러가 붙은 뒤라야 screen을 앎)
    }

    /// 모니터별 편집기 창 크기
    static var savedWindowSizes: [String: NSSize] {
        get {
            (UserDefaults.standard.dictionary(forKey: "windowSizeByScreen") as? [String: String] ?? [:])
                .mapValues { NSSizeFromString($0) }
        }
        set { UserDefaults.standard.set(newValue.mapValues { NSStringFromSize($0) }, forKey: "windowSizeByScreen") }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.mode] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.mode] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let mode = NSSegmentedControl(labels: ["원본", "미리보기"], trackingMode: .selectOne,
                                      target: self, action: #selector(modeChanged(_:)))
        mode.selectedSegment = previewing ? 1 : 0
        modeControl = mode
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "보기"
        item.view = mode
        return item
    }

    private func showSource() {
        guard let tv = textView else { return }
        tv.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.plain))
        tv.typingAttributes = Self.plain
        restyle()
    }

    func restyle() {
        guard let tv = textView, let storage = tv.textStorage, !previewing, !tv.hasMarkedText() else { return }
        if Self.styledEditing {
            styleMarkdownSource(storage, plain: Self.plain)
        } else {
            storage.setAttributes(Self.plain, range: NSRange(location: 0, length: storage.length))
        }
    }

    func textDidChange(_ notification: Notification) { restyle() }

    @objc func toggleStyledEditing(_ sender: Any?) {
        Self.styledEditing.toggle()
        NSDocumentController.shared.documents.forEach { ($0 as? Document)?.restyle() }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleStyledEditing(_:)) {
            (item as? NSMenuItem)?.state = Self.styledEditing ? .on : .off
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    @objc func modeChanged(_ sender: NSSegmentedControl) {
        if (sender.selectedSegment == 1) != previewing { togglePreview(sender) }
    }

    @objc func zoomIn(_ sender: Any?) { changeZoom { $0 + 0.25 } }
    @objc func zoomOut(_ sender: Any?) { changeZoom { $0 - 0.25 } }
    @objc func zoomReset(_ sender: Any?) { changeZoom { _ in 1 } }

    private var screen: NSScreen? { windowControllers.first?.window?.screen }

    func applyZoom() { scrollView?.magnification = savedZoom(for: screen) }

    /// 이 창이 있는 모니터의 배율을 바꿔 저장하고, 같은 모니터의 창에 모두 적용 (Quick Look도 이 값을 씀)
    private func changeZoom(_ change: (CGFloat) -> CGFloat) {
        guard let screen else { return }
        saveZoom(min(max(change(savedZoom(for: screen)), 0.5), 3), for: screen)
        NSDocumentController.shared.documents.forEach { ($0 as? Document)?.applyZoom() }
    }

    @objc func togglePreview(_ sender: Any?) {
        guard let tv = textView else { return }
        if previewing {
            previewing = false
            tv.isRichText = false
            tv.isEditable = true
            showSource()
        } else {
            text = tv.string
            tv.undoManager?.removeAllActions()  // 미리보기로 바뀐 텍스트에 옛 undo가 적용되지 않게
            tv.isEditable = false
            tv.isRichText = true
            tv.textStorage?.setAttributedString(renderMarkdown(text))
            (scrollView as? ZoomScrollView)?.refitTables()
            previewing = true
        }
        modeControl?.selectedSegment = previewing ? 1 : 0
    }

    override func data(ofType typeName: String) throws -> Data {
        Data((previewing ? text : textView?.string ?? text).utf8)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        text = String(decoding: data, as: UTF8.self)
        if !previewing { showSource() }
    }
}

extension NSToolbarItem.Identifier {
    static let mode = NSToolbarItem.Identifier("mode")
}

func menu(_ title: String, _ items: [(String, Selector, String)]) -> NSMenuItem {
    let m = NSMenu(title: title)
    for (t, action, key) in items { m.addItem(withTitle: t, action: action, keyEquivalent: key) }
    let item = NSMenuItem()
    item.submenu = m
    return item
}

let app = NSApplication.shared
UserDefaults.standard.register(defaults: ["styledEditing": true])
_ = NSDocumentController.shared  // 파일 열기 이벤트를 받으려면 실행 전에 만들어 둬야 함

let find = NSMenuItem(title: "찾기…", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")
find.tag = NSTextFinder.Action.showFindInterface.rawValue

let mainMenu = NSMenu()
mainMenu.addItem(menu("QuickLookLite", [("QuickLookLite 종료", #selector(NSApplication.terminate(_:)), "q")]))
mainMenu.addItem(menu("파일", [
    ("새로 만들기", #selector(NSDocumentController.newDocument(_:)), "n"),
    ("열기…", #selector(NSDocumentController.openDocument(_:)), "o"),
    ("저장", #selector(NSDocument.save(_:)), "s"),
    ("닫기", #selector(NSWindow.performClose(_:)), "w"),
]))
let edit = menu("편집", [
    ("실행 취소", Selector(("undo:")), "z"),
    ("실행 복귀", Selector(("redo:")), "Z"),
    ("오려두기", #selector(NSText.cut(_:)), "x"),
    ("복사", #selector(NSText.copy(_:)), "c"),
    ("붙여넣기", #selector(NSText.paste(_:)), "v"),
    ("모두 선택", #selector(NSText.selectAll(_:)), "a"),
])
edit.submenu?.addItem(find)
mainMenu.addItem(edit)
mainMenu.addItem(menu("보기", [
    ("미리보기 전환", #selector(Document.togglePreview(_:)), "e"),
    ("편집 중 서식 표시", #selector(Document.toggleStyledEditing(_:)), "E"),
    ("확대", #selector(Document.zoomIn(_:)), "="),
    ("축소", #selector(Document.zoomOut(_:)), "-"),
    ("실제 크기", #selector(Document.zoomReset(_:)), "0"),
]))
app.mainMenu = mainMenu

app.setActivationPolicy(.regular)
app.run()
