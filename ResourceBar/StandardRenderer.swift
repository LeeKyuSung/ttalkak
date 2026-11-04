// 메뉴 막대 칸 그리기: 버튼 안 NSView 하나가 draw(_:)에서 위젯 다섯 개를 그린다(배치는 BarLayout.swift).
// 위젯마다 칸을 따로 두면 다른 화면용 복제본 스냅샷이 칸 수만큼 생겨 비싸다(docs/resourcebar.md 측정).
// BarLayout.swift와 시스템 프레임워크에만 기댄다.
//
// 안전한 최적화만 한다.
//  - 라벨 글자(CTLine)와 상자·글자 위치는 칸 높이가 바뀔 때만 다시 만든다.
//  - update()는 위젯마다 "그려질 모양"을 양자화(가장 촘촘한 화면 픽셀의 절반)해서 이전과 비교하고,
//    바뀐 위젯의 영역만 무효화한다. 그릴 때도 같은 양자화 값을 쓰므로 "값이 같으면 픽셀도 같다"가 성립한다.
//    SSD·네트워크 글자·평평한 GPU 그래프는 대개 그대로라 다시 그리지 않는다.
//  - 차트 경로와 네트워크 글자 줄은 바뀔 때만 만들고, AppKit이 다시 그리라고 할 때(외관 전환·복제본 스냅샷)는 재사용한다.
//  - 색은 draw(_:) 안에서 그 순간의 외관으로 풀어 쓴다. 외관을 KVO·알림으로 관찰하지 않는다(관찰하면 다시 그리기가 무한 반복된다: 커밋 10a2da8).
// renderCount는 draw(_:)에서 실제로 그린 위젯 수의 누계다(다른 화면 복제본 스냅샷 때 그린 것도 센다).
import AppKit
import CoreText

@objc(RBStandardRenderer)
final class StandardRenderer: NSObject, BarRenderer {
    private let barView: StandardBarView

    var renderCount: Int { barView.widgetDraws }
    /// 다른 화면 복제본은 AppKit이 뷰가 무효화될 때마다 알아서 갱신한다(이 렌더러가 제어하지 않음).
    var replicaRefreshCount: Int { -1 }

    init(statusItem: NSStatusItem) {
        let fallback = NSRect(x: 0, y: 0, width: BarLayout.totalWidth, height: NSStatusBar.system.thickness)
        barView = StandardBarView(frame: statusItem.button?.bounds ?? fallback)
        super.init()
        if let button = statusItem.button {
            barView.frame = button.bounds
            barView.autoresizingMask = [.width, .height]
            button.addSubview(barView)
        }
    }

    func update(_ frame: BarFrame) {
        barView.apply(frame)
    }

    func teardown() {
        barView.removeFromSuperview()
    }
}

private final class StandardBarView: NSView {
    /// 실제로 그린 위젯 수 누계
    private(set) var widgetDraws = 0

    // MARK: 모양 상수(pt)

    private static let boxHeight: CGFloat = 16
    private static let inset: CGFloat = 2        // 위젯 영역 안쪽 좌우 여백(위젯 사이 간격 4와 합쳐 8)
    private static let labelWidth: CGFloat = 6
    private static let labelGap: CGFloat = 2
    private static let corner: CGFloat = 2
    private static let hair: CGFloat = 1         // 테두리 1pt 고정(복제본은 다른 배율로 그려지므로 픽셀 맞춤 안 함)
    private static let arrowWidth: CGFloat = 7
    private static let fillAlpha: CGFloat = 0.35
    private static let labelFont = NSFont.systemFont(ofSize: 7, weight: .regular)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    private static let labelWords: [WidgetKind: String] = [.ssd: "SSD", .gpu: "GPU", .cpu: "CPU", .ram: "RAM"]

    private static func textAttributes(_ font: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
    }

    // MARK: 배치(높이별 캐시)

    private struct Geometry {
        let height: CGFloat
        /// 위젯 영역(무효화 단위), WidgetKind.rawValue 순
        let frames: [CGRect]
        /// 테두리 상자(네트워크는 .zero)
        let boxes: [CGRect]
        /// 위젯별 세로 라벨 글자(줄, 원점), WidgetKind.rawValue 순(네트워크는 빈 배열)
        let labels: [[(line: CTLine, origin: CGPoint)]]
        let arrowCenterX: CGFloat
        let midY: CGFloat
        let textRight: CGFloat
        let upBaseline: CGFloat
        let downBaseline: CGFloat
    }

    private var geometry: Geometry?

    /// 양자화 단위(pt): 가장 촘촘한 화면 픽셀의 절반
    private let quantum: CGFloat

    // MARK: 그릴 상태

    private var ssdLevel = -1
    /// gpu, cpu, ram 순. 그래프 점 높이(quantum 단위)
    private var chartLevels: [[Int32]] = [[], [], []]
    private var chartPaths: [(line: CGPath, fill: CGPath)?] = [nil, nil, nil]
    private var upText = ""
    private var downText = ""
    private var upLine: CTLine?
    private var downLine: CTLine?

    override init(frame: NSRect) {
        let maxScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        quantum = 1 / (max(maxScale, 1) * 2)
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }
    /// 클릭은 아래 버튼이 받는다.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static func chartIndex(_ k: WidgetKind) -> Int? {
        switch k {
        case .gpu: return 0
        case .cpu: return 1
        case .ram: return 2
        default: return nil
        }
    }

    private static func clamp01(_ v: Double) -> CGFloat {
        v.isFinite ? CGFloat(min(max(v, 0), 1)) : 0
    }

    // MARK: 배치 계산

    private func currentGeometry() -> Geometry {
        let h = bounds.height > 0 ? bounds.height : NSStatusBar.system.thickness
        if let g = geometry, g.height == h { return g }
        let g = Self.makeGeometry(height: h)
        geometry = g
        // 상자 높이는 그대로라 양자화 값은 유효하다. 위치가 바뀌므로 경로만 다시 만든다.
        chartPaths = [nil, nil, nil]
        return g
    }

    private static func makeGeometry(height h: CGFloat) -> Geometry {
        let boxY = ((h - boxHeight) / 2).rounded(.down)
        var frames: [CGRect] = []
        var boxes: [CGRect] = []
        var labels: [[(line: CTLine, origin: CGPoint)]] = []
        let labelAttrs = textAttributes(labelFont)
        let cellH = boxHeight / 3
        for k in WidgetKind.allCases {
            let f = BarLayout.frame(of: k, height: h)
            frames.append(f)
            guard let word = labelWords[k] else { boxes.append(.zero); labels.append([]); continue }
            let labelX = f.minX + inset
            let boxX = labelX + labelWidth + labelGap
            boxes.append(CGRect(x: boxX, y: boxY, width: f.maxX - inset - boxX, height: boxHeight))
            var letters: [(line: CTLine, origin: CGPoint)] = []
            for (i, ch) in word.enumerated() {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(ch), attributes: labelAttrs))
                let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let cellMid = boxY + boxHeight - cellH * (CGFloat(i) + 0.5)
                letters.append((line, CGPoint(x: labelX + (labelWidth - w) / 2, y: cellMid - labelFont.capHeight / 2)))
            }
            labels.append(letters)
        }
        let net = frames[WidgetKind.net.rawValue]
        let midY = h / 2
        return Geometry(height: h,
                        frames: frames,
                        boxes: boxes,
                        labels: labels,
                        arrowCenterX: net.minX + inset + arrowWidth / 2,
                        midY: midY,
                        textRight: net.maxX - inset,
                        upBaseline: (midY + 1.5).rounded(),
                        downBaseline: (midY - 1.5 - valueFont.capHeight).rounded())
    }

    // MARK: 값 반영 — 바뀐 위젯만 무효화

    func apply(_ f: BarFrame) {
        let g = currentGeometry()

        // SSD: 채움 높이
        let ssdInner = g.boxes[WidgetKind.ssd.rawValue].insetBy(dx: Self.hair, dy: Self.hair)
        let level = Int((Self.clamp01(f.ssdUsed) * ssdInner.height / quantum).rounded())
        if level != ssdLevel {
            ssdLevel = level
            setNeedsDisplay(g.frames[WidgetKind.ssd.rawValue])
        }

        // GPU·CPU·RAM: 점 높이 배열
        let histories = [f.gpuHistory, f.cpuHistory, f.ramHistory]
        let kinds: [WidgetKind] = [.gpu, .cpu, .ram]
        for i in 0..<3 {
            let inner = g.boxes[kinds[i].rawValue].insetBy(dx: Self.hair, dy: Self.hair)
            let range = inner.height - 1   // 선 굵기(1pt)만큼 위아래를 남긴다
            let values = histories[i].suffix(BarLayout.historyCount)
            var levels = [Int32]()
            levels.reserveCapacity(values.count)
            for v in values { levels.append(Int32((Self.clamp01(v) * range / quantum).rounded())) }
            if levels != chartLevels[i] {
                chartLevels[i] = levels
                chartPaths[i] = nil
                setNeedsDisplay(g.frames[kinds[i].rawValue])
            }
        }

        // 네트워크: 글자 두 줄
        let up = Self.formatRate(f.netUpBps)
        let down = Self.formatRate(f.netDownBps)
        if up != upText || down != downText {
            if up != upText { upText = up; upLine = nil }
            if down != downText { downText = down; downLine = nil }
            setNeedsDisplay(g.frames[WidgetKind.net.rawValue])
        }
    }

    // MARK: 그리기

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let g = currentGeometry()
        ctx.textMatrix = .identity
        for k in BarLayout.order {
            let frame = g.frames[k.rawValue]
            guard needsToDraw(frame) else { continue }
            widgetDraws += 1
            switch k {
            case .ssd:
                drawLabels(of: k, g: g, ctx: ctx)
                drawSSD(box: g.boxes[k.rawValue], ctx: ctx)
            case .gpu, .cpu, .ram:
                drawLabels(of: k, g: g, ctx: ctx)
                drawChart(Self.chartIndex(k) ?? 0, box: g.boxes[k.rawValue],
                          color: k == .ram ? .systemOrange : .systemBlue, ctx: ctx)
            case .net:
                drawNetwork(g: g, ctx: ctx)
            }
        }
    }

    private func drawLabels(of k: WidgetKind, g: Geometry, ctx: CGContext) {
        NSColor.labelColor.setFill()
        for letter in g.labels[k.rawValue] {
            ctx.textPosition = letter.origin
            CTLineDraw(letter.line, ctx)
        }
    }

    private func strokeBox(_ r: CGRect, ctx: CGContext) {
        NSColor.labelColor.setStroke()
        ctx.setLineWidth(Self.hair)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: Self.hair / 2, dy: Self.hair / 2),
                           cornerWidth: Self.corner, cornerHeight: Self.corner, transform: nil))
        ctx.strokePath()
    }

    private func clipInner(_ inner: CGRect, ctx: CGContext) {
        let r = max(Self.corner - 0.5, 0.5)
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.clip()
    }

    /// 세로 막대, 아래부터 채움
    private func drawSSD(box: CGRect, ctx: CGContext) {
        let inner = box.insetBy(dx: Self.hair, dy: Self.hair)
        let h = min(CGFloat(max(ssdLevel, 0)) * quantum, inner.height)
        if h > 0 {
            ctx.saveGState()
            clipInner(inner, ctx: ctx)
            NSColor.systemBlue.setFill()
            ctx.fill(CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: h))
            ctx.restoreGState()
        }
        strokeBox(box, ctx: ctx)
    }

    /// 최근 60개, 가장 새 값이 오른쪽 끝. 1pt 선 + 아래 반투명 채움.
    private func drawChart(_ i: Int, box: CGRect, color: NSColor, ctx: CGContext) {
        let inner = box.insetBy(dx: Self.hair, dy: Self.hair)
        if chartPaths[i] == nil { chartPaths[i] = makeChartPaths(chartLevels[i], inner: inner) }
        if let p = chartPaths[i] {
            ctx.saveGState()
            clipInner(inner, ctx: ctx)
            color.withAlphaComponent(Self.fillAlpha).setFill()
            ctx.addPath(p.fill)
            ctx.fillPath()
            color.setStroke()
            ctx.setLineWidth(1)
            ctx.setLineJoin(.round)
            ctx.addPath(p.line)
            ctx.strokePath()
            ctx.restoreGState()
        }
        strokeBox(box, ctx: ctx)
    }

    private func makeChartPaths(_ levels: [Int32], inner: CGRect) -> (line: CGPath, fill: CGPath)? {
        let n = levels.count
        guard n > 0 else { return nil }
        let step = inner.width / CGFloat(BarLayout.historyCount - 1)
        let y0 = inner.minY + 0.5
        let line = CGMutablePath()
        let startX = n == 1 ? inner.maxX - step : inner.maxX - CGFloat(n - 1) * step
        var x = startX
        for (j, l) in levels.enumerated() {
            let p = CGPoint(x: n == 1 ? inner.maxX : x, y: y0 + CGFloat(l) * quantum)
            if j == 0 {
                line.move(to: CGPoint(x: startX, y: p.y))
                if n == 1 { line.addLine(to: p) }
            } else {
                line.addLine(to: p)
            }
            x += step
        }
        let fill = line.mutableCopy() ?? CGMutablePath()
        fill.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
        fill.addLine(to: CGPoint(x: startX, y: inner.minY))
        fill.closeSubpath()
        return (line, fill)
    }

    private func drawNetwork(g: Geometry, ctx: CGContext) {
        let cx = g.arrowCenterX
        let midY = g.midY
        let headW: CGFloat = 5
        let headH: CGFloat = 3.5

        // 위 화살표(업로드, 빨강)
        NSColor.systemRed.set()
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: cx, y: midY + 1))
        ctx.addLine(to: CGPoint(x: cx, y: midY + 8 - headH + 0.5))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: cx - headW / 2, y: midY + 8 - headH))
        ctx.addLine(to: CGPoint(x: cx + headW / 2, y: midY + 8 - headH))
        ctx.addLine(to: CGPoint(x: cx, y: midY + 8))
        ctx.closePath()
        ctx.fillPath()

        // 아래 화살표(다운로드, 파랑)
        NSColor.systemBlue.set()
        ctx.move(to: CGPoint(x: cx, y: midY - 1))
        ctx.addLine(to: CGPoint(x: cx, y: midY - 8 + headH - 0.5))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: cx - headW / 2, y: midY - 8 + headH))
        ctx.addLine(to: CGPoint(x: cx + headW / 2, y: midY - 8 + headH))
        ctx.addLine(to: CGPoint(x: cx, y: midY - 8))
        ctx.closePath()
        ctx.fillPath()

        // 글자: 위 = 업로드, 아래 = 다운로드, 오른쪽 정렬
        if upLine == nil { upLine = Self.makeValueLine(upText) }
        if downLine == nil { downLine = Self.makeValueLine(downText) }
        NSColor.labelColor.setFill()
        if let l = upLine { drawRightAligned(l, right: g.textRight, baseline: g.upBaseline, ctx: ctx) }
        if let l = downLine { drawRightAligned(l, right: g.textRight, baseline: g.downBaseline, ctx: ctx) }
    }

    private static func makeValueLine(_ s: String) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: textAttributes(valueFont)))
    }

    private func drawRightAligned(_ line: CTLine, right: CGFloat, baseline: CGFloat, ctx: CGContext) {
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: (right - w).rounded(), y: baseline)
        CTLineDraw(line, ctx)
    }

    /// "28 KB/s" 형식. 1024 단위, 정수부 최대 3자리가 되게 단위를 올린다.
    private static func formatRate(_ bps: Double) -> String {
        let b = bps.isFinite ? max(bps, 0) : 0
        if b < 999.5 { return "\(Int(b.rounded())) B/s" }
        let kb = b / 1024
        if kb < 999.5 { return "\(Int(kb.rounded())) KB/s" }
        let mb = kb / 1024
        if mb < 9.95 {
            let t = Int((mb * 10).rounded())
            return "\(t / 10).\(t % 10) MB/s"
        }
        if mb < 999.5 { return "\(Int(mb.rounded())) MB/s" }
        let t = Int((mb / 1024 * 10).rounded())
        return "\(t / 10).\(t % 10) GB/s"
    }
}
