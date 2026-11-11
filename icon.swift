// 앱 아이콘 생성: swift icon.swift → AppIcon.icns
// 붉은 배경(인라인 코드 색) 위 문서 한 장, 안에 줄 번호 + 문법 색상 줄
import AppKit

func rgb(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// 위에서부터 재는 좌표 (AppKit 은 아래가 0)
func box(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x, y: CGFloat(size) - top - h, width: w, height: h) }

// 바탕: macOS 아이콘 격자(824pt 본체) + 그림자
let body = NSBezierPath(roundedRect: box(100, 100, 824, 824), xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
rgb(0xB53834).setFill(); body.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: rgb(0xD9534E), ending: rgb(0x9E2B27))!.draw(in: body, angle: -90)

// 문서: 오른쪽 위 모서리를 접은 흰 종이
let (dx, dtop, dw, dh, fold): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (262, 200, 500, 624, 110)
let d = box(dx, dtop, dw, dh)
let sheet = NSBezierPath()
sheet.move(to: NSPoint(x: d.minX, y: d.minY))
sheet.line(to: NSPoint(x: d.maxX, y: d.minY))
sheet.line(to: NSPoint(x: d.maxX, y: d.maxY - fold))
sheet.line(to: NSPoint(x: d.maxX - fold, y: d.maxY))
sheet.line(to: NSPoint(x: d.minX, y: d.maxY))
sheet.close()
NSGraphicsContext.saveGraphicsState()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25); shadow.shadowBlurRadius = 20; shadow.shadowOffset = NSSize(width: 0, height: -8)
shadow.set()
NSColor.white.setFill(); sheet.fill()
NSGraphicsContext.restoreGraphicsState()
let flap = NSBezierPath()
flap.move(to: NSPoint(x: d.maxX - fold, y: d.maxY))
flap.line(to: NSPoint(x: d.maxX - fold, y: d.maxY - fold))
flap.line(to: NSPoint(x: d.maxX, y: d.maxY - fold))
flap.close()
rgb(0xE2E2E2).setFill(); flap.fill()

// 코드 줄: 왼쪽 회색 줄 번호 + 색 막대 (색은 미리보기의 문법 색상)
let (kw, str, type, num, text, comment) = (rgb(0xB53834), rgb(0x2E7D4F), rgb(0x2A6496), rgb(0x9A5B13), rgb(0x3A3A3A), rgb(0xB0B0B0))
let lines: [(indent: CGFloat, parts: [(CGFloat, NSColor)])] = [
    (0, [(100, kw), (130, type)]),
    (44, [(80, kw), (56, text), (120, str)]),
    (44, [(110, text), (54, num)]),
    (0, []),
    (44, [(190, comment)]),
    (44, [(80, kw), (150, type)]),
    (0, [(28, text)]),
]
for (i, line) in lines.enumerated() {
    let top = 330 + CGFloat(i) * 64
    rgb(0xD0D0D0).setFill()
    NSBezierPath(roundedRect: box(306, top, 30, 26), xRadius: 8, yRadius: 8).fill()
    var x = 364 + line.indent
    for (w, color) in line.parts {
        color.setFill()
        NSBezierPath(roundedRect: box(x, top, w, 26), xRadius: 13, yRadius: 13).fill()
        x += w + 18
    }
}
NSGraphicsContext.current = nil

// iconset 크기별로 줄여 저장 → iconutil
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: size, height: size)); image.addRepresentation(rep)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.current = nil
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! out.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "AppIcon.icns 생성" : "iconutil 실패")
