import AppKit
import QuickLookUI

/// Finder에서 스페이스 누르면 뜨는 Quick Look 미리보기. 마크다운은 렌더링, 코드 파일은 문법 색상.
/// (csv 는 시스템 Office.qlgenerator 가 우선이라 여기로 오지 않는다 — macOS 기본도 표로 보여 준다)
final class PreviewViewController: NSViewController, QLPreviewingController {
    private static let markdown: Set<String> = ["md", "markdown", "mdown", "mkd"]

    private let scroll = makeZoomableTextView()
    private var textView: NSTextView { scroll.documentView as! NSTextView }

    override func loadView() {
        textView.isEditable = false
        textView.textContainerInset = NSSize(width: 24, height: 20)
        scroll.magnification = savedZoom(for: currentScreen())  // 편집기에서 이 모니터에 맞춘 배율
        view = scroll
        preferredContentSize = screenFittedFrame(minimum: NSSize(width: 820, height: 640)).size
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let source = decodeText(try Data(contentsOf: url))
        let ext = url.pathExtension.lowercased()
        let rendered = Self.markdown.contains(ext) ? renderMarkdown(source) : renderCode(source, language: ext)
        textView.textStorage?.setAttributedString(rendered)
        (scroll as? ZoomScrollView)?.refitTables()
    }
}
