import AppKit

/// Markdown → 스타일 입힌 NSAttributedString. Foundation 내장 파서만 사용 (외부 의존성 없음).
/// 표·코드블록은 NSTextBlock이라 TextKit 1 텍스트 뷰에서만 그려진다.
// ponytail: 이미지는 alt 텍스트만. 필요해지면 NSTextAttachment로.
func renderMarkdown(_ source: String) -> NSAttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
    guard let md = try? AttributedString(markdown: source, options: options) else {
        return NSAttributedString(string: source)
    }

    let out = NSMutableAttributedString()
    let fm = NSFontManager.shared
    let bodyFont = NSFont.systemFont(ofSize: 14)
    var lastBlock: Int?
    var openPara: NSParagraphStyle?  // 아직 줄바꿈으로 닫지 않은 문단의 스타일
    var seenItems = Set<Int>()
    var tables: [Int: NSTextTable] = [:]
    var cells: [Int: NSTextTableBlock] = [:]
    var tableRow: (table: NSTextTable, row: Int, next: Int, columns: Int)?  // 지금 그리는 표 행과 다음 열
    var afterBlock = false  // 직전 블록이 표·코드블록·인용·수평선인지
    var quotes: [Int: NSTextBlock] = [:]
    var lastQuote: NSTextBlock?

    // 문단 끝 줄바꿈도 그 문단 스타일을 가져야 표 셀·코드블록 경계가 맞는다
    func closeParagraph() {
        if let p = openPara { out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: p])) }
        openPara = nil
    }
    func cellBlock(_ t: NSTextTable, row: Int, column: Int) -> NSTextTableBlock {
        let b = HairlineCell(table: t, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        b.setWidth(6, type: .absoluteValueType, for: .padding)
        if row == 0 { b.backgroundColor = TableColor.header }
        return b
    }
    // 파서는 빈 셀을 내보내지 않는다. 빠진 칸을 채워야 행마다 열 너비가 같아진다.
    func emptyCells(_ t: NSTextTable, row: Int, _ columns: Range<Int>) {
        for c in columns {
            closeParagraph()
            let p = NSMutableParagraphStyle()
            p.textBlocks = [cellBlock(t, row: row, column: c)]
            openPara = p
        }
    }
    // 블록 margin은 배경 안쪽까지 칠해져서, 표·코드블록 위 간격은 앞 문단의 아래 간격으로 준다.
    // 앞도 블록이면(코드블록 연속 등) 그 간격도 블록 안에 칠해지므로 빈 문단을 하나 끼운다.
    func spaceBeforeBlock() {
        guard out.length > 0 else { return }
        let r = (out.string as NSString).paragraphRange(for: NSRange(location: out.length - 1, length: 0))
        guard let last = out.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle,
              last.textBlocks.isEmpty else {
            let gap = NSMutableParagraphStyle()
            gap.minimumLineHeight = 14
            gap.maximumLineHeight = 14
            out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: gap, .font: NSFont.systemFont(ofSize: 4)]))
            return
        }
        out.enumerateAttribute(.paragraphStyle, in: r) { v, sub, _ in
            guard let p = (v as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            p.paragraphSpacing = 14
            out.addAttribute(.paragraphStyle, value: p, range: sub)
        }
    }

    for run in md.runs {
        var text = String(md[run.range].characters)
        let parts = run.presentationIntent?.components ?? []  // 안쪽 → 바깥쪽
        // 인라인 코드·코드블록 안의 <!-- --> · <br> 은 글자 그대로 둔다
        let isCode = run.inlinePresentationIntent?.contains(.code) == true
            || parts.contains { if case .codeBlock = $0.kind { return true } else { return false } }
        // HTML 주석(<!-- -->)은 그리지 않는다. 파싱에는 남겨 둬서 목록 번호를 끊는 용도는 그대로 동작한다
        if !isCode, text.contains("<!--") {
            text = text.replacingOccurrences(of: #"<!--[\s\S]*?-->\n?"#, with: "", options: .regularExpression)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        }
        let block = parts.first?.identity
        let isNewBlock = block != lastBlock

        var font = bodyFont
        var color = NSColor.textColor
        var background: NSColor?
        var inlineCode = false
        var codeBlock: NSTextBlock?
        var codeLanguage: String?
        var quote: NSTextBlock?
        var rule: NSTextBlock?
        var spacing: CGFloat = 6
        var prefix = ""
        var listIndent: CGFloat = 0  // 목록 단계별 들여쓰기 합
        var row = 0
        var cell: (id: Int, column: Int)?
        var table: (id: Int, columns: [PresentationIntent.TableColumn])?

        for (i, p) in parts.enumerated() {
            switch p.kind {
            case .header(let level):
                font = .boldSystemFont(ofSize: [28, 22, 18, 16, 14, 13][min(level, 6) - 1])
                spacing = 14
            case .codeBlock(let language):
                font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
                spacing = 0
                if text.hasSuffix("\n") { text.removeLast() }
                codeLanguage = language ?? ""
                let b = NSTextBlock()
                b.setContentWidth(100, type: .percentageValueType)
                b.backgroundColor = CodeColor.background
                b.setWidth(12, type: .absoluteValueType, for: .padding)
                codeBlock = b
            case .blockQuote:
                // 인용 하나 = 블록 하나 (여러 문단이어도 한 덩어리로): 왼쪽 막대 + 옅은 배경
                guard quote == nil else { break }
                quote = quotes[p.identity] ?? {
                    let b = NSTextBlock()
                    b.setContentWidth(100, type: .percentageValueType)
                    b.backgroundColor = QuoteColor.background
                    b.setWidth(4, type: .absoluteValueType, for: .border, edge: .minX)
                    b.setBorderColor(QuoteColor.bar, for: .minX)
                    b.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
                    b.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxX)
                    b.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minY)
                    b.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxY)
                    return b
                }()
                quotes[p.identity] = quote
            case .thematicBreak:
                text = "\u{00A0}"  // 글자 대신 줄 전체 폭 1픽셀 선 (RuleBlock)
                font = .systemFont(ofSize: 2)
                spacing = 0
                let b = RuleBlock()
                b.setContentWidth(100, type: .percentageValueType)
                b.setWidth(4, type: .absoluteValueType, for: .padding)
                rule = b
            case .orderedList, .unorderedList:
                listIndent += 14  // 단계마다 14pt (기호는 오른쪽 정렬 탭으로 본문 7pt 앞에 놓임)
            case .listItem(let ordinal):
                if isNewBlock, prefix.isEmpty, seenItems.insert(p.identity).inserted {
                    let ordered: Bool
                    if i + 1 < parts.count, case .orderedList = parts[i + 1].kind { ordered = true } else { ordered = false }
                    prefix = ordered ? "\t\(ordinal).\t" : "\t•\t"
                    // 작업 목록(GFM): "[ ] " / "[x] " 로 시작하면 체크박스. 글머리표는 • 대신, 번호는 번호 뒤 본문 앞에
                    // □(U+25A1)를 쓴다: ☐(U+2610)는 시스템 글꼴에 없어 다른 글꼴로 작게 그려져 ☑ 와 크기가 어긋난다
                    for (mark, box) in [("[ ]", "□"), ("[x]", "☑"), ("[X]", "☑")] where text == mark || text.hasPrefix(mark + " ") {
                        text.removeFirst(min(text.count, mark.count + 1))
                        if ordered { text = box + " " + text } else { prefix = "\t\(box)\t" }
                        break
                    }
                }
            case .table(let columns):
                table = (p.identity, columns)
            case .tableHeaderRow:
                row = 0
            case .tableRow(let index):
                row = index
            case .tableCell(let column):
                cell = (p.identity, column)
            default:
                break
            }
        }
        let isHeaderRow = cell != nil && row == 0

        let blockColor = color  // 목록 기호용 (인라인 코드 색을 물려받지 않게)
        if let inline = run.inlinePresentationIntent {
            if inline.contains(.code) {
                font = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                background = CodeColor.background
                color = CodeColor.inline
                inlineCode = true
            }
            if inline.contains(.stronglyEmphasized) || isHeaderRow { font = fm.convert(font, toHaveTrait: .boldFontMask) }
            if inline.contains(.emphasized) { font = fm.convert(font, toHaveTrait: .italicFontMask) }
            if inline.contains(.lineBreak) { text = "\u{2028}" }
        } else if isHeaderRow {
            font = fm.convert(font, toHaveTrait: .boldFontMask)
        }
        // 인라인 HTML 중 <br>만 줄바꿈으로 (표 셀에서 흔히 씀)
        if !isCode {
            text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\u{2028}", options: [.regularExpression, .caseInsensitive])
        }

        let t = table.map { table in
            tables[table.id] ?? {
                let t = FitTable()
                t.numberOfColumns = table.columns.count
                t.collapsesBorders = true
                t.setValue(100, type: .percentageValueType, for: .maximumWidth)  // 안전장치: 창보다 넓어지지 않게
                tables[table.id] = t
                return t
            }()
        }

        if isNewBlock {
            // 코드블록이거나 새 표의 첫 칸일 때만 블록 시작 (같은 표의 다음 행은 아님)
            let startsBlock = codeBlock != nil || rule != nil || (t != nil && tableRow?.table !== t)
                || (quote != nil && quote !== lastQuote)
            if let r = tableRow, cell == nil || r.table !== t || r.row != row {
                emptyCells(r.table, row: r.row, r.next..<r.columns)  // 이전 행의 빈 끝 칸
                tableRow = nil
            }
            // 블록 위 간격은 빈 칸을 채우기 전에: 새 표의 첫 칸이 비었으면(`| | 제목 |`) 간격 문단이 셀 사이에 끼어 표가 쪼개진다
            closeParagraph()
            if startsBlock { spaceBeforeBlock() }
            if let t, let table, let cell {
                let next = tableRow?.next ?? 0
                emptyCells(t, row: row, next..<max(next, cell.column))  // 이 칸 앞의 빈 칸
                tableRow = (t, row, cell.column + 1, table.columns.count)
            }
            closeParagraph()
            lastBlock = block
        }
        let sameQuote = quote != nil && quote === lastQuote  // 같은 인용 안의 다음 문단
        if isNewBlock { lastQuote = quote }

        if listIndent > 0 { listIndent += 16 }  // 목록 전체를 본문보다 조금 들여쓴다 (가장 바깥 한 번)
        let para = NSMutableParagraphStyle()
        para.headIndent = listIndent
        // 기호는 오른쪽 정렬 탭으로 놓으므로, 줄 시작은 "10." 같은 긴 번호가 왼쪽으로 늘어날 만큼 앞에 둔다
        para.firstLineHeadIndent = prefix.isEmpty ? listIndent : max(0, listIndent - 7 - 30)
        // 기호("\t1.\t", "\t•\t")는 본문 7pt 앞에서 끝나도록 오른쪽 정렬 탭, 그다음 본문 탭
        para.tabStops = [NSTextTab(textAlignment: .right, location: listIndent - 7),
                         NSTextTab(textAlignment: .left, location: listIndent)]
        para.paragraphSpacingBefore = isNewBlock ? spacing : 0
        para.lineSpacing = 3
        para.lineBreakStrategy = .hangulWordPriority  // 한글을 글자 중간이 아니라 띄어쓰기에서 줄바꿈
        // 한글만 있는 줄은 대체 글꼴 높이로 잡혀 영문 섞인 줄보다 기준선이 위로 뜬다. 최소 높이를 영문 글꼴 기준으로.
        // (최대 높이는 두지 않음: 고정하면 인라인 코드 배경이 줄 높이만큼 늘어남)
        para.minimumLineHeight = lineHeightReference.defaultLineHeight(for: font)

        if let codeBlock {
            para.headIndent = 0
            para.firstLineHeadIndent = 0
            para.textBlocks = [codeBlock]
            if listIndent > 0 {
                // 목록 안 코드블록: margin은 배경까지 칠해지므로, 배경 없는 바깥 블록의 padding으로 들여쓴다
                let outer = NSTextBlock()
                outer.setContentWidth(100, type: .percentageValueType)
                outer.setWidth(listIndent, type: .absoluteValueType, for: .padding, edge: .minX)
                para.textBlocks = [outer, codeBlock]
            }
        } else if let t, let table, let cell {
            // 같은 셀의 여러 run은 같은 블록을 공유해야 한 칸으로 그려진다
            let b = cells[cell.id] ?? cellBlock(t, row: row, column: cell.column)
            cells[cell.id] = b
            para.textBlocks = [b]
            para.paragraphSpacingBefore = 0
            // 목록 안 표: 셀 글자는 들여쓰지 않고 표 전체를 목록 들여쓰기만큼 옮긴다
            // (표는 배경이 없어 margin 이 칠해지는 문제가 없다)
            para.headIndent = 0
            para.firstLineHeadIndent = 0
            if listIndent > 0 { t.setWidth(listIndent, type: .absoluteValueType, for: .margin, edge: .minX) }
            switch table.columns[cell.column].alignment {
            case .center: para.alignment = .center
            case .right: para.alignment = .right
            default: para.alignment = .left
            }
        } else if let rule {
            para.textBlocks = [rule]
            para.paragraphSpacingBefore = 0
            para.minimumLineHeight = 0
        } else if isNewBlock, afterBlock, !sameQuote {
            para.paragraphSpacingBefore = 14  // 표·코드블록·인용·수평선 바로 다음 블록
        }
        if let quote {
            para.textBlocks = [quote] + para.textBlocks
            if isNewBlock, !sameQuote { para.paragraphSpacingBefore = 0 }  // 위 여백은 블록 padding으로
        }
        if isNewBlock { afterBlock = table != nil || codeBlock != nil || rule != nil || quote != nil }

        if !prefix.isEmpty {  // 목록 기호는 항목 첫 글자의 인라인 서식(코드 배경 등)을 받지 않게
            out.append(NSAttributedString(string: prefix, attributes: [.font: bodyFont, .foregroundColor: blockColor, .paragraphStyle: para]))
        }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        if let background { attrs[.backgroundColor] = background }
        if let link = run.link { attrs[.link] = link }
        if run.inlinePresentationIntent?.contains(.strikethrough) == true {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if inlineCode {
            // 배경 좌우 여백: 일반 글꼴의 줄바꿈 안 되는 공백 (고정폭 공백은 한 칸이라 너무 넓음)
            var padAttrs = attrs
            padAttrs[.font] = NSFont.systemFont(ofSize: font.pointSize)
            let pad = NSAttributedString(string: "\u{00A0}", attributes: padAttrs)
            out.append(pad)
            out.append(NSAttributedString(string: text, attributes: attrs))
            out.append(pad)
        } else if let codeLanguage {
            let code = NSMutableAttributedString(string: text, attributes: attrs)
            highlightCode(code, range: NSRange(location: 0, length: code.length), language: codeLanguage)
            if text.contains("\n") {  // 한 줄짜리(명령어 한 줄 등)는 번호 없이
                codeBlock?.setWidth(12 + numberLines(code, font: font), type: .absoluteValueType, for: .padding, edge: .minX)
            }
            // 블록 전체를 한 문단으로 (줄 단위 정규식이 먼저 돌아야 해서 칠한 뒤에 바꿈)
            code.mutableString.replaceOccurrences(of: "\n", with: "\u{2028}", range: NSRange(location: 0, length: code.length))
            out.append(code)
        } else {
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        openPara = para
    }
    if let r = tableRow { emptyCells(r.table, row: r.row, r.next..<r.columns) }
    closeParagraph()
    fitTableColumns(out)
    return out
}

/// 표마다 열의 최소 너비(가장 긴 단어)·최대 너비(줄바꿈 없는 내용)를 재 둔다. 실제 배분은 화면 너비를 아는
/// ZoomScrollView가 FitTable.fit으로 한다. 처음엔 최대 너비로.
private func fitTableColumns(_ s: NSAttributedString) {
    let ns = s.string as NSString
    // 줄바꿈 없이 붙어 있어야 하는 덩어리: 공백·U+2028에서 나뉘고, 하이픈·슬래시 뒤에서도 줄바꿈될 수 있음
    let words = try! NSRegularExpression(pattern: "[^\\s\u{2028}/-]+[/-]?")
    func width(_ range: NSRange) -> CGFloat {
        // 문단 스타일(표 블록)이 붙어 있으면 컨테이너 전체 폭으로 재지므로 떼고 잰다
        let text = NSMutableAttributedString(attributedString: s.attributedSubstring(from: range))
        text.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: text.length))
        // + 줄 양옆 여백(lineFragmentPadding 5pt × 2): 셀 안에서도 적용돼서 빼면 가장 넓은 내용이 줄바꿈됨
        return ceil(text.boundingRect(with: NSSize(width: 100_000, height: 100_000), options: [.usesLineFragmentOrigin]).width) + 10
    }
    var location = 0
    while location < s.length {
        let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
        location = NSMaxRange(range)
        guard let cell = (s.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
            .textBlocks.last as? NSTextTableBlock, let table = cell.table as? FitTable else { continue }
        if table.maxWidths.isEmpty {
            table.maxWidths = Array(repeating: 0, count: table.numberOfColumns)
            table.minWidths = table.maxWidths
        }
        let column = cell.startingColumn
        table.maxWidths[column] = max(table.maxWidths[column], width(range))
        words.enumerateMatches(in: s.string, range: range) { m, _, _ in
            if let m { table.minWidths[column] = max(table.minWidths[column], width(m.range)) }
        }
        table.cells.append(cell)
    }
    var seen = Set<ObjectIdentifier>()
    s.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: s.length)) { v, _, _ in
        guard let table = ((v as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock)?.table as? FitTable,
              seen.insert(ObjectIdentifier(table)).inserted else { return }
        table.apply(table.maxWidths)
    }
}

/// 열 너비를 HTML 자동 표 레이아웃처럼 배분하는 표.
/// 다 들어가면 내용 너비(최대), 안 들어가면 각 열에 최소 너비(가장 긴 단어)를 보장하고
/// 남는 폭을 "줄일 여지(최대-최소)"에 비례해 나눈다 → 짧은 열은 그대로, 긴 글 열만 줄바꿈.
final class FitTable: NSTextTable {
    var minWidths: [CGFloat] = []
    var maxWidths: [CGFloat] = []
    var cells: [NSTextTableBlock] = []
    private var applied: [CGFloat] = []

    /// available: 표가 쓸 수 있는 폭. 너비가 바뀌었으면 true (레이아웃 무효화 필요)
    func fit(available: CGFloat) -> Bool {
        let indent = width(for: .margin, edge: .minX)  // 목록 안 표의 들여쓰기
        let room = max(0, available - indent - CGFloat(numberOfColumns) * 12)  // 셀 padding 6pt × 2
        let sumMax = maxWidths.reduce(0, +), sumMin = minWidths.reduce(0, +)
        let widths: [CGFloat]
        if sumMax <= room {
            widths = maxWidths
        } else if sumMin >= room {
            widths = minWidths.map { (sumMin > 0 ? $0 * room / sumMin : 0).rounded(.down) }  // 최소도 안 들어가면 비율로
        } else {
            let f = (room - sumMin) / (sumMax - sumMin)
            widths = zip(minWidths, maxWidths).map { ($0 + ($1 - $0) * f).rounded(.down) }
        }
        guard widths != applied else { return false }
        apply(widths)
        return true
    }

    func apply(_ widths: [CGFloat]) {
        applied = widths
        for cell in cells where cell.startingColumn < widths.count {
            cell.setContentWidth(widths[cell.startingColumn], type: .absoluteValueType)
        }
    }
}

/// 편집 중 원문은 그대로 두고 서식만 입힌다 (**굵게**는 굵게, 기호는 흐리게).
// ponytail: 매 입력마다 전체 재적용. 수 MB 문서에서 느려지면 편집된 문단만 다시 칠하기.
private let sourceRules: [(NSRegularExpression, (NSTextStorage, NSTextCheckingResult) -> Void)] = {
    let fm = NSFontManager.shared
    let dim: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.tertiaryLabelColor]
    func rule(_ pattern: String, _ apply: @escaping (NSTextStorage, NSTextCheckingResult) -> Void)
        -> (NSRegularExpression, (NSTextStorage, NSTextCheckingResult) -> Void) {
        (try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]), apply)
    }
    func trait(_ t: NSFontTraitMask) -> (NSTextStorage, NSTextCheckingResult) -> Void {
        { s, m in
            let r = m.range(at: 2)
            s.enumerateAttribute(.font, in: r) { f, sub, _ in
                if let f = f as? NSFont { s.addAttribute(.font, value: fm.convert(f, toHaveTrait: t), range: sub) }
            }
            s.addAttributes(dim, range: m.range(at: 1))
            s.addAttributes(dim, range: m.range(at: 3))
        }
    }
    return [
        rule(#"^(#{1,6} )(.*)$"#) { s, m in
            let level = m.range(at: 1).length - 1
            s.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: [22, 19, 16, 15, 14, 13][level - 1], weight: .bold), range: m.range)
            s.addAttributes(dim, range: m.range(at: 1))
        },
        rule(#"(\*\*|__)(?=\S)(.+?)(?<=\S)(\1)"#, trait(.boldFontMask)),
        rule(#"(?<![*_\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])(\1)(?![*_\w])"#, trait(.italicFontMask)),
        rule(#"(~~)(.+?)(~~)"#) { s, m in
            s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 2))
            s.addAttributes(dim, range: m.range(at: 1)); s.addAttributes(dim, range: m.range(at: 3))
        },
        rule(#"(\[)([^\]\n]+)(\]\([^)\n]*\))"#) { s, m in
            s.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range(at: 2))
            s.addAttributes(dim, range: m.range(at: 1)); s.addAttributes(dim, range: m.range(at: 3))
        },
        rule(#"^(\s*(?:[-*+]|\d+\.)) "#) { s, m in s.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: m.range(at: 1)) },
        rule(#"^\s*(?:[-*+]|\d+\.) (\[[ xX]\])(?= |$)"#) { s, m in  // 작업 목록 체크박스
            s.addAttributes([.foregroundColor: NSColor.systemOrange,
                             .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)], range: m.range(at: 1))
        },
        rule(#"^>.*$"#) { s, m in s.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range) },
        // 표: 헤더 굵게, 구분선과 | 흐리게
        rule(#"^(\|.*\|)[ \t]*\n(\|[\s:|-]+\|)[ \t]*$"#) { s, m in
            s.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold), range: m.range(at: 1))
            s.addAttributes(dim, range: m.range(at: 2))
        },
        rule(#"^[ \t]*\|.*$"#) { s, m in
            let line = s.string as NSString
            for i in m.range.location..<NSMaxRange(m.range) where line.character(at: i) == 0x7C {
                s.addAttributes(dim, range: NSRange(location: i, length: 1))
            }
        },
        rule(#"<!--[\s\S]*?-->"#) { s, m in s.addAttributes(dim, range: m.range) },  // HTML 주석
        // 코드는 마지막에: 안쪽 서식을 덮어쓴다
        rule(#"(`)([^`\n]+)(`)"#) { s, m in
            s.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: CodeColor.inline,
                             .backgroundColor: CodeColor.background], range: m.range)
            s.addAttributes(dim, range: m.range(at: 1)); s.addAttributes(dim, range: m.range(at: 3))
        },
        rule(#"^```[^\n]*\n[\s\S]*?^```[ \t]*(?:\n|$)"#) { s, m in
            s.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.textColor,
                             .backgroundColor: CodeColor.background, .strikethroughStyle: 0], range: m.range)
            // 여는 줄(```언어)과 닫는 줄은 흐리게, 그 사이 코드는 문법 색상
            let ns = s.string as NSString
            let open = ns.lineRange(for: NSRange(location: m.range.location, length: 0))
            let close = ns.lineRange(for: NSRange(location: NSMaxRange(m.range) - 1, length: 0))
            s.addAttributes(dim, range: open)
            s.addAttributes(dim, range: close)
            let language = ns.substring(with: open).trimmingCharacters(in: CharacterSet(charactersIn: "`").union(.whitespacesAndNewlines))
            if close.location > NSMaxRange(open) {
                highlightCode(s, range: NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open)), language: language)
            }
        },
    ]
}()

func styleMarkdownSource(_ storage: NSTextStorage, plain: [NSAttributedString.Key: Any]) {
    let full = NSRange(location: 0, length: storage.length)
    storage.beginEditing()
    storage.setAttributes(plain, range: full)
    for (regex, apply) in sourceRules {
        regex.enumerateMatches(in: storage.string, range: full) { m, _, _ in if let m { apply(storage, m) } }
    }
    storage.endEditing()
}

/// TextKit 1로 전환(TextKit 2는 NSTextTable·NSTextBlock을 못 그림)하고 배경을 글자 폭에 맞추는 레이아웃 매니저를 단다.
func useTextKit1(_ tv: NSTextView) {
    _ = tv.layoutManager
    tv.textContainer?.replaceLayoutManager(TightBackgroundLayoutManager())
}

/// 줄바꿈된 인라인 코드 배경을 줄마다 실제 글자 영역에만 칠한다.
/// (기본 동작은 줄 끝·줄 맨 앞까지 칠하고, 여러 줄일 때 넘어오는 사각형도 한 줄씩 밀려 있음)
/// 줄바꿈 문자를 포함한 배경(편집기의 ``` 코드블록)은 블록이므로 그대로 줄 끝까지 칠한다.
final class TightBackgroundLayoutManager: NSLayoutManager {
    /// 코드 줄 번호: .lineNumber 가 달린 글자의 줄 왼쪽 여백(번호 칸)에 오른쪽 맞춤으로 그린다
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.lineNumber, in: chars) { value, range, _ in
            guard let n = value as? Int, let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
            let g = glyphIndexForCharacter(at: range.location)
            let line = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let x0 = location(forGlyphAt: g).x  // 줄 조각 기준
            // 줄 높이 규칙(최소 높이)을 본문과 같게 줘서 줄 조각 위에서부터 그리면 기준선이 맞는다
            // (빈 줄은 줄바꿈 글자라 글리프 y 로 기준선을 알 수 없음)
            let para = NSMutableParagraphStyle()
            para.minimumLineHeight = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight ?? 0
            let label = "\(n)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: para]
            let width = label.size(withAttributes: attrs).width
            label.draw(with: NSRect(x: origin.x + line.minX + x0 - lineNumberGap - width, y: origin.y + line.minY, width: width + 1, height: line.height),
                       options: .usesLineFragmentOrigin, attributes: attrs)
        }
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        // 선택 영역 하이라이트·블록 배경은 그대로 두고, 배경 속성이 있는 한 문단 안의 텍스트만 다룬다
        guard charRange.length > 0, let storage = textStorage, NSMaxRange(charRange) <= storage.length,
              storage.attribute(.backgroundColor, at: charRange.location, effectiveRange: nil) as? NSColor == color,
              (storage.string as NSString).rangeOfCharacter(from: .newlines, range: charRange).location == NSNotFound else {
            return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
        // 줄마다 이 범위 글자의 영역. 컨테이너 좌표라 텍스트 뷰 좌표(컨테이너 원점만큼 이동)로 옮겨 그린다.
        let origin = firstTextView?.textContainerOrigin ?? .zero
        let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var rects: [NSRect] = []
        enumerateLineFragments(forGlyphRange: glyphs) { _, _, container, lineGlyphs, _ in
            rects.append(self.boundingRect(forGlyphRange: NSIntersectionRange(lineGlyphs, glyphs), in: container)
                .offsetBy(dx: origin.x, dy: origin.y))
        }
        rects.withUnsafeBufferPointer {
            super.fillBackgroundRectArray($0.baseAddress!, count: rects.count, forCharacterRange: charRange, color: color)
        }
    }
}

/// 마우스가 있는 모니터 (새 창·Quick Look이 뜰 화면)
func currentScreen() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
}

func screenKey(_ screen: NSScreen) -> String {
    "\(screen.localizedName) \(Int(screen.frame.width))x\(Int(screen.frame.height))"
}

/// 모니터별 확대 배율. 앱이 저장하고, Quick Look 확장은 shared-preference 예외 권한으로 같은 값을 읽는다.
func savedZoom(for screen: NSScreen?) -> CGFloat {
    let defaults = Bundle.main.bundleIdentifier == "kr.hwangti.quicklooklite.preview" ? UserDefaults(suiteName: "kr.hwangti.quicklooklite") : .standard
    guard let screen else { return 1.25 }
    if let zoom = defaults?.dictionary(forKey: "zoomByScreen")?[screenKey(screen)] as? Double, zoom > 0 { return zoom }
    // 배율 없이 쓰는 4K(1x, 3000pt 이상)는 글자가 아주 작게 보여서 기본을 크게
    return screen.backingScaleFactor < 2 && screen.frame.width >= 3000 ? 1.75 : 1.25
}

func saveZoom(_ zoom: CGFloat, for screen: NSScreen) {
    var all = UserDefaults.standard.dictionary(forKey: "zoomByScreen") ?? [:]
    all[screenKey(screen)] = Double(zoom)
    UserDefaults.standard.set(all, forKey: "zoomByScreen")
}

/// 확대해도 가로 스크롤이 안 생기는 텍스트 스크롤 뷰 (TextKit 1).
func makeZoomableTextView() -> NSScrollView {
    let scroll = ZoomScrollView()
    let tv = NSTextView()
    useTextKit1(tv)
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    tv.textContainer?.widthTracksTextView = true
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.horizontalScrollElasticity = .none
    scroll.allowsMagnification = true  // 트랙패드 핀치 확대도 됨
    scroll.documentView = tv
    return scroll
}

/// 배율이 걸린 상태에서 크기가 바뀌면 자동 리사이즈가 배율을 무시해 문서가 보이는 폭보다 넓어진다.
/// 크기·배율이 바뀔 때마다 문서 폭을 보이는 폭(clip view bounds)에 맞춘다.
final class ZoomScrollView: NSScrollView {
    override var magnification: CGFloat { didSet { fitDocumentWidth() } }
    override func tile() { super.tile(); fitDocumentWidth() }
    override func reflectScrolledClipView(_ clip: NSClipView) { super.reflectScrolledClipView(clip); fitDocumentWidth() }

    private var fittedWidth: CGFloat = -1

    private func fitDocumentWidth() {
        guard let doc = documentView else { return }
        let width = contentView.bounds.width
        if abs(doc.frame.width - width) > 0.5 { doc.setFrameSize(NSSize(width: width, height: doc.frame.height)) }
        // 문서 뷰는 자동 리사이즈로 먼저 맞춰지기도 하므로, 마지막으로 표를 맞춘 너비와 비교한다
        if abs(doc.frame.width - fittedWidth) > 0.5 { refitTables() }
    }

    /// 보이는 폭에 맞춰 표 열 너비를 다시 배분. 크기·배율이 바뀔 때와 내용을 새로 넣었을 때 부른다.
    func refitTables() {
        guard let tv = documentView as? NSTextView, let storage = tv.textStorage, let lm = tv.layoutManager,
              let container = tv.textContainer else { return }
        fittedWidth = tv.frame.width
        let available = tv.frame.width - tv.textContainerInset.width * 2 - container.lineFragmentPadding * 2
        var seen = Set<ObjectIdentifier>(), changed = false
        let all = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.paragraphStyle, in: all) { v, _, _ in
            guard let table = ((v as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock)?.table as? FitTable,
                  seen.insert(ObjectIdentifier(table)).inserted else { return }
            changed = table.fit(available: available) || changed
        }
        if changed {
            lm.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
            tv.needsDisplay = true
        }
    }
}

/// 지금 쓰는 모니터(마우스가 있는 화면) 가운데에 놓을 창 위치·크기.
/// preferred(사용자가 맞춘 크기)가 없으면 화면에 비례해서, 4K처럼 넓은 화면에서는 창도 커진다.
func screenFittedFrame(minimum: NSSize, preferred: NSSize? = nil) -> NSRect {
    guard let area = currentScreen()?.visibleFrame else {
        return NSRect(origin: .zero, size: preferred ?? minimum)
    }
    let wanted = preferred ?? NSSize(width: max(minimum.width, area.width * 0.5), height: max(minimum.height, area.height * 0.8))
    let size = NSSize(width: min(area.width, wanted.width), height: min(area.height, wanted.height))
    return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
}

// MARK: - 코드 색상 (Claude 입력창 인라인 코드 색 #B53834 / #EFEFEF 기준)

private func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
    func rgb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light) }
}

private let lineHeightReference = NSLayoutManager()

/// 수평선(---): 줄 전체 폭에 2pt 선. 표 테두리(1픽셀, 연한 색)와 헷갈리지 않게 더 굵고 진하게.
final class RuleBlock: NSTextBlock {
    override func drawBackground(withFrame frame: NSRect, in view: NSView?, characterRange: NSRange, layoutManager: NSLayoutManager) {
        guard let view else { return }
        TableColor.rule.setFill()
        view.backingAlignedRect(NSRect(x: frame.minX, y: frame.midY - 1, width: frame.width, height: 2),
                                options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest]).fill()
    }
}

/// 확대 배율과 상관없이 테두리를 항상 화면 1픽셀로, 픽셀 격자에 맞춰 그리는 표 셀.
/// (테두리를 pt로 주면 확대한 만큼 굵어지고 픽셀 사이에 걸려 2~3픽셀로 번짐)
/// 맞닿은 두 셀이 경계선을 같은 픽셀에 각자 그린다: 화면 일부만 다시 그려져도(스크롤 등) 선이 지워지지 않고,
/// 옆 셀의 헤더 배경이 선을 덮어도 그 셀이 다시 그린다.
final class HairlineCell: NSTextTableBlock {
    override func drawBackground(withFrame frame: NSRect, in view: NSView?, characterRange: NSRange, layoutManager: NSLayoutManager) {
        super.drawBackground(withFrame: frame, in: view, characterRange: characterRange, layoutManager: layoutManager)
        guard let view else { return }
        let px = view.convertFromBacking(NSSize(width: 1, height: 1))
        // 경계선 가운데에 1픽셀: 두 셀이 같은 좌표로 계산하므로 같은 픽셀에 겹쳐 그려진다
        func horizontal(_ y: CGFloat) -> NSRect {
            NSRect(x: frame.minX - px.width / 2, y: y - px.height / 2, width: frame.width + px.width, height: px.height)
        }
        func vertical(_ x: CGFloat) -> NSRect {
            NSRect(x: x - px.width / 2, y: frame.minY - px.height / 2, width: px.width, height: frame.height + px.height)
        }
        TableColor.border.setFill()
        for edge in [horizontal(frame.minY), horizontal(frame.maxY), vertical(frame.minX), vertical(frame.maxX)] {
            view.backingAlignedRect(edge, options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest]).fill()
        }
    }
}

enum QuoteColor {
    static let bar = CodeColor.inline  // 하이라이팅 색(Claude 붉은색)과 통일
    static let background = color(0xFAFAFA, 0x1F1F1F)
}

enum TableColor {
    static let border = color(0xD9D9D9, 0x444444)
    static let header = color(0xF2F2F2, 0x2A2A2A)
    static let rule = color(0xB5B5B5, 0x666666)  // 수평선
}

enum CodeColor {
    static let background = color(0xEFEFEF, 0x2C2C2C)
    static let inline = color(0xB53834, 0xF0807A)
    static let keyword = color(0xB53834, 0xF0807A)
    static let string = color(0x2E7D4F, 0x8FCB9B)
    static let comment = color(0x8A8A8A, 0x8C8C8C)
    static let number = color(0x9A5B13, 0xE0A96D)
    static let type = color(0x2A6496, 0x7FB5E6)
}

/// 정규식 문법 하이라이터. 왼쪽부터 주석·문자열·숫자·키워드·타입 중 먼저 걸리는 것으로 칠해서
/// 문자열 안의 // 나 주석 안의 키워드는 칠하지 않는다.
// ponytail: 키워드 목록 기반이라 "대부분 맞는" 수준. 여러 줄 문자열(""" 등)은 미지원.
private let highlighters: [String: NSRegularExpression] = {
    let cLike = "abstract assert async await boolean break byte case catch char class const continue def default defer delete do double else enum export extends extension external false final finally float fn for fun func function get go guard if impl implements import in init instanceof int interface internal is let long match mod module mut namespace new nil null object open operator override package private protected protocol pub public readonly record return sealed self set short static struct super switch synchronized this throw throws trait true try type typealias typeof undefined union unsafe use val var void volatile when where while with yield"
    let python = "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return self True try while with yield"
    let shell = "case do done elif else esac exit export fi for function if in local return then until while echo cd source set unset"
    let sql = "add all alter and as asc between by case create delete desc distinct drop else end exists from group having in index insert inner into is join key left like limit not null offset on or order outer primary references right select set table then union unique update values view when where"
    let json = "true false null"
    let config = "true false null yes no on off"

    let cComment = #"//[^\n]*|/\*[\s\S]*?\*/"#, hashComment = #"#[^\n]*"#, sqlComment = #"--[^\n]*|/\*[\s\S]*?\*/"#
    let strings = #""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`"#
    /// key: 타입 색으로 칠할 언어별 패턴(JSON 키, 셸 변수, 설정 키). 문자열보다 먼저 둬야 `"키":` 가 키로 잡힌다
    /// extra: 이름 붙은 그룹을 직접 쓴 추가 패턴 (g = 키워드 색, a = 타입 색). JSX 태그·속성용
    func make(_ comment: String?, _ keywords: String, types: Bool, caseInsensitive: Bool = false,
              key: String? = nil, extra: String? = nil) -> NSRegularExpression {
        let kw = keywords.split(separator: " ").joined(separator: "|")
        var parts = [comment.map { "(?<c>\($0))" }, extra, key.map { "(?<t>\($0))" }, "(?<s>\(strings))",
                     #"(?<n>\b\d[\d_]*(?:\.\d+)?[a-zA-Z]*\b)"#,
                     "(?<k>\\b\(caseInsensitive ? "(?i:" : "(?:")\(kw))\\b)"].compactMap { $0 }
        if types, key == nil { parts.append(#"(?<t>\b[A-Z][A-Za-z0-9_]*[a-z][A-Za-z0-9_]*\b)"#) }  // PascalCase (상수 ALL_CAPS 제외)
        return try! NSRegularExpression(pattern: parts.joined(separator: "|"))
    }
    let c = make(cComment, cLike, types: true)
    var map: [String: NSRegularExpression] = ["": c]
    // JSX/TSX: 태그 이름(<button>, </h1>)은 키워드 색, 속성 이름(onClick=)은 타입 색, TS 기본 타입은 키워드
    let jsx = make(cComment, cLike + " string number boolean any unknown never bigint symbol object", types: true,
                   extra: #"(?<g>(?<=<|</)[A-Za-z][\w.:-]*)|(?<a>[A-Za-z_][\w-]*(?==[{"']))"#)
    for lang in ["jsx", "tsx", "ts", "typescript"] { map[lang] = jsx }
    for lang in ["java", "kotlin", "kt", "kts", "js", "mjs", "cjs", "javascript", "swift",
                 "go", "rust", "rs", "c", "cc", "cpp", "c++", "h", "hpp", "cs", "csharp", "dart", "php", "scala", "groovy",
                 "gradle"] { map[lang] = c }
    let py = make(hashComment, python, types: true)
    for lang in ["python", "py", "rb", "ruby"] { map[lang] = py }
    let sh = make(hashComment, shell, types: false, key: #"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$[0-9@#?*!$-]"#)  // $변수
    for lang in ["sh", "bash", "zsh", "shell", "console", "dockerfile"] { map[lang] = sh }
    // 설정 파일: 줄 맨 앞의 키(`key:` / `key =`)
    let cfg = make(#"[#;!][^\n]*"#, config, types: false, key: #"(?m:^)[ \t]*(?:- )?[A-Za-z_][\w.-]*(?=[ \t]*[:=])"#)
    for lang in ["yaml", "yml", "toml", "properties", "ini", "conf", "env"] { map[lang] = cfg }
    map["sql"] = make(sqlComment, sql, types: false, caseInsensitive: true)
    map["json"] = make(nil, json, types: false, key: #""(?:\\.|[^"\\\n])*"(?=\s*:)"#)  // "키":
    // XML/HTML: 주석 · 속성 값 · 태그 이름(키워드 색) · 속성 이름(타입 색) · 엔티티(숫자 색)
    let xml = try! NSRegularExpression(pattern: [
        #"(?<c><!--[\s\S]*?-->)"#, #"(?<s>"[^"\n]*"|'[^'\n]*')"#, #"(?<k>(?<=<|</|<\?)[\w:.-]+)"#,
        #"(?<t>[\w:.-]+(?=\s*=))"#, #"(?<n>&#?\w+;)"#].joined(separator: "|"))
    for lang in ["xml", "html", "htm", "svg", "xhtml", "plist"] { map[lang] = xml }
    // CSS/SCSS: 주석(/* */, scss 의 // — url(http://) 안은 제외) · 문자열 · @규칙·!important(키워드 색)
    //           · 속성 이름·$변수·--변수(타입 색) · 색상값·숫자+단위(숫자 색)
    let css = try! NSRegularExpression(pattern: [
        #"(?<c>/\*[\s\S]*?\*/|(?<![:/])//[^\n]*)"#, #"(?<s>"[^"\n]*"|'[^'\n]*')"#, #"(?<k>@[\w-]+|!important)"#,
        #"(?<t>(?m:^)[ \t]*-?[\w-]+(?=\s*:[^;{}\n]*;)|\$[\w-]+|--[\w-]+)"#,
        #"(?<n>#[0-9a-fA-F]{3,8}\b|\b\d+(?:\.\d+)?(?:px|em|rem|vh|vw|vmin|vmax|ms|s|deg|fr|%)?)"#].joined(separator: "|"))
    for lang in ["css", "scss", "sass", "less"] { map[lang] = css }
    return map
}()

/// 파일 내용 읽기: UTF-8 이 아니면 CP949(EUC-KR 로 저장된 옛 한글 파일)로, 그것도 아니면 깨진 글자만 바꿔서
func decodeText(_ data: Data) -> String {
    let text = String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosKorean.rawValue))))
        ?? String(decoding: data, as: UTF8.self)
    return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text  // BOM
}

/// 코드 파일 미리보기: 고정폭 + 문법 색상. language 는 확장자(java, sh, json …)
// ponytail: 1MB 넘는 파일은 색칠을 건너뛴다 — 정규식이 느려져 미리보기가 늦게 뜬다
func renderCode(_ source: String, language: String) -> NSAttributedString {
    let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    let para = NSMutableParagraphStyle()
    para.lineSpacing = 3
    para.tabStops = []
    para.defaultTabInterval = 4 * (" " as NSString).size(withAttributes: [.font: font]).width
    let code = NSMutableAttributedString(string: source, attributes: [.font: font, .foregroundColor: NSColor.textColor,
                                                                       .paragraphStyle: para])
    if code.length < 1_000_000 { highlightCode(code, range: NSRange(location: 0, length: code.length), language: language) }
    para.headIndent = numberLines(code, font: font)
    para.firstLineHeadIndent = para.headIndent
    code.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: code.length))
    return code
}

extension NSAttributedString.Key {
    /// 줄 첫 글자에 다는 줄 번호. 글자로 넣지 않으므로 드래그 복사에 딸려 오지 않는다 (그리는 건 레이아웃 매니저)
    static let lineNumber = NSAttributedString.Key("QuickLookLite.lineNumber")
}

/// 줄마다 첫 글자에 번호를 달고, 번호 칸 너비(가장 긴 번호 + 간격)를 돌려준다.
func numberLines(_ s: NSMutableAttributedString, font: NSFont) -> CGFloat {
    let text = s.string as NSString
    var n = 0, i = 0
    while i < text.length {
        n += 1
        s.addAttribute(.lineNumber, value: n, range: NSRange(location: i, length: 1))
        i = NSMaxRange(text.lineRange(for: NSRange(location: i, length: 0)))
    }
    return ("\(n)" as NSString).size(withAttributes: [.font: font]).width + lineNumberGap
}

private let lineNumberGap: CGFloat = 14

func highlightCode(_ s: NSMutableAttributedString, range: NSRange, language: String?) {
    let lang = (language ?? "").lowercased().trimmingCharacters(in: .whitespaces)
    guard let regex = highlighters[lang] ?? highlighters[""] else { return }
    let colors: [(String, NSColor)] = [("c", CodeColor.comment), ("s", CodeColor.string), ("n", CodeColor.number),
                                       ("k", CodeColor.keyword), ("t", CodeColor.type),
                                       ("g", CodeColor.keyword), ("a", CodeColor.type)]
    regex.enumerateMatches(in: s.string, range: range) { m, _, _ in
        guard let m else { return }
        for (name, color) in colors where m.range(withName: name).location != NSNotFound {
            s.addAttribute(.foregroundColor, value: color, range: m.range(withName: name))
        }
    }
}
