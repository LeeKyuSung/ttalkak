// 왼쪽 클릭 창(docs/resourcebar.md 2절): 누른 위젯별 내용. 자리 배치는 고정(행 수가 변하지 않아 창 크기가 흔들리지 않는다).
//   CPU: 5분 그래프 + CPU 상위 8개(이름·PID·%) + 종료
//   GPU: 5분 그래프 + 렌더러·타일러 사용률 + GPU 메모리(읽히면)
//   RAM: 5분 그래프 + 앱·고정·압축·캐시·스왑·압박 + 메모리 상위 8개(footprint) + 종료
//   SSD: 사용량 한 줄 + 디스크 읽기·쓰기 상위 8개(초당 바이트) + 종료
//   네트워크: 5분 업로드·다운로드 그래프 + 현재 값
import AppKit

/// 창이 매 tick 받는 값
struct PopoverState {
    var snapshot: SystemSnapshot
    var cpu: [Double]
    var gpu: [Double]
    var ram: [Double]
    var up: [Double]
    var down: [Double]
    var swap: SwapUsage?
}

/// 위에서 아래로 배치하려고 뒤집은 바탕 뷰
private final class PopoverCanvas: NSView {
    override var isFlipped: Bool { true }
}

/// 불투명 바탕(창 배경색). 색은 그리는 순간의 외관으로 풀린다(외관을 관찰하지 않는다. 관찰하면 다시 그리기가 무한 반복된다: 커밋 10a2da8)
private final class SolidBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

// MARK: - 큰 그래프

final class HistoryGraphView: NSView {
    struct Series {
        var values: [Double]
        var color: NSColor
    }

    var series: [Series] = []
    /// nil이면 0...1(백분율). 값이 있으면 0...scaleMax(초당 바이트 등)
    var scaleMax: Double?
    var topCaption = "100%"
    let capacity: Int
    static let axisHeight: CGFloat = 14

    init(frame: NSRect, capacity: Int) {
        self.capacity = capacity
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: 0.5, y: Self.axisHeight + 0.5, width: bounds.width - 1, height: bounds.height - Self.axisHeight - 1)
        let frame = NSBezierPath(roundedRect: plot, xRadius: 4, yRadius: 4)
        NSColor.labelColor.withAlphaComponent(0.04).setFill()
        frame.fill()

        // 격자 25·50·75%
        NSColor.separatorColor.setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        for f in [0.25, 0.5, 0.75] {
            let y = (plot.minY + plot.height * f).rounded() + 0.25
            grid.move(to: NSPoint(x: plot.minX + 1, y: y))
            grid.line(to: NSPoint(x: plot.maxX - 1, y: y))
        }
        grid.stroke()

        let inner = plot.insetBy(dx: 1, dy: 1)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: plot, xRadius: 4, yRadius: 4).addClip()
        let top = max(scaleMax ?? 1, 1e-9)
        let step = inner.width / CGFloat(max(capacity - 1, 1))
        for s in series where !s.values.isEmpty {
            let vals = s.values.suffix(capacity)
            let n = vals.count
            let line = NSBezierPath()
            line.lineWidth = 1.5
            line.lineJoinStyle = .round
            let startX = n == 1 ? inner.maxX - step : inner.maxX - CGFloat(n - 1) * step
            var x = startX
            for (i, v) in vals.enumerated() {
                let r = v.isFinite ? min(max(v / top, 0), 1) : 0
                let p = NSPoint(x: n == 1 ? inner.maxX : x, y: inner.minY + 0.75 + CGFloat(r) * (inner.height - 1.5))
                if i == 0 {
                    line.move(to: NSPoint(x: startX, y: p.y))
                    if n == 1 { line.line(to: p) }
                } else {
                    line.line(to: p)
                }
                x += step
            }
            let area = line.copy() as! NSBezierPath
            area.line(to: NSPoint(x: inner.maxX, y: inner.minY))
            area.line(to: NSPoint(x: startX, y: inner.minY))
            area.close()
            s.color.withAlphaComponent(0.22).setFill()
            area.fill()
            s.color.setStroke()
            line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.separatorColor.setStroke()
        frame.lineWidth = 1
        frame.stroke()

        // 글자: 위 왼쪽 눈금, 아래 시간 축
        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        (topCaption as NSString).draw(at: NSPoint(x: plot.minX + 4, y: plot.maxY - 14), withAttributes: small)
        ("5분 전" as NSString).draw(at: NSPoint(x: plot.minX, y: 0), withAttributes: small)
        let now = "지금" as NSString
        let w = now.size(withAttributes: small).width
        now.draw(at: NSPoint(x: plot.maxX - w, y: 0), withAttributes: small)
    }
}

// MARK: - 프로세스 한 줄

private final class ProcessRowView: NSView {
    let nameField = NSTextField(labelWithString: "")
    let pidField = NSTextField(labelWithString: "")
    let valueFields: [NSTextField]
    let killButton = NSButton(title: "종료", target: nil, action: nil)
    /// ps로 읽은 다른 계정 프로세스 줄: 종료 버튼 자리에 "(시스템)"(종료 불가)
    let systemTag = NSTextField(labelWithString: "(시스템)")
    var process: ProcStat?

    init(frame: NSRect, columns: PopoverColumns, valueCount: Int) {
        valueFields = (0..<valueCount).map { _ in NSTextField(labelWithString: "") }
        super.init(frame: frame)
        let h = frame.height
        let font = NSFont.systemFont(ofSize: 12)
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        nameField.font = font
        nameField.lineBreakMode = .byTruncatingTail
        nameField.frame = NSRect(x: columns.nameX, y: (h - 16) / 2, width: columns.nameWidth, height: 16)
        pidField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pidField.textColor = .secondaryLabelColor
        pidField.alignment = .right
        pidField.frame = NSRect(x: columns.pidX, y: (h - 15) / 2, width: columns.pidWidth, height: 15)
        for (i, f) in valueFields.enumerated() {
            f.font = mono
            f.alignment = .right
            f.frame = NSRect(x: columns.valueX[i], y: (h - 16) / 2, width: columns.valueWidth, height: 16)
        }
        killButton.bezelStyle = .push   // .rounded는 SDK에서 deprecated(대체: push)
        killButton.controlSize = .small
        killButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        killButton.frame = NSRect(x: columns.buttonX, y: (h - 20) / 2, width: columns.buttonWidth, height: 20)
        systemTag.font = NSFont.systemFont(ofSize: 10.5)
        systemTag.textColor = .secondaryLabelColor
        systemTag.alignment = .center
        systemTag.toolTip = "다른 계정(root 등)의 시스템 프로세스. ps로 읽은 값이고 종료할 수 없음"
        systemTag.frame = NSRect(x: columns.buttonX - 4, y: (h - 14) / 2, width: columns.buttonWidth + 8, height: 14)
        for v in [nameField, pidField] + valueFields + [killButton, systemTag] as [NSView] { addSubview(v) }
        clear()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func clear(message: String = "") {
        process = nil
        nameField.stringValue = message
        nameField.textColor = .secondaryLabelColor
        pidField.stringValue = ""
        for f in valueFields { f.stringValue = "" }
        killButton.isHidden = true
        systemTag.isHidden = true
    }

    func show(_ p: ProcStat, values: [String]) {
        process = p
        nameField.stringValue = p.name
        nameField.textColor = .labelColor
        nameField.toolTip = p.name
        pidField.stringValue = "\(p.pid)"
        for (i, f) in valueFields.enumerated() { f.stringValue = i < values.count ? values[i] : "" }
        if p.isSystem {
            killButton.isHidden = true
            killButton.isEnabled = false
            systemTag.isHidden = false
            return
        }
        systemTag.isHidden = true
        killButton.isHidden = false
        // 내 계정 소유가 아닌 프로세스는 종료할 수 없다. kernel_task·launchd·이 앱 자신·loginwindow도 막는다(ProcStat.canKill)
        killButton.isEnabled = p.canKill
        if p.canKill {
            killButton.toolTip = "SIGTERM으로 종료"
        } else if !p.isMine {
            killButton.toolTip = "다른 계정의 프로세스라 종료할 수 없음"
        } else if p.pid == getpid() {
            killButton.toolTip = "ResourceBar 자신은 오른쪽 클릭 메뉴의 종료로 끝냅니다"
        } else if p.endsSession {
            killButton.toolTip = "로그인 세션 자체라 종료하면 그 자리에서 로그아웃되므로 막아 둠"
        } else {
            killButton.toolTip = "시스템 프로세스라 종료할 수 없음"
        }
    }
}

/// 목록 열 위치
private struct PopoverColumns {
    var nameX: CGFloat = 0
    var nameWidth: CGFloat = 0
    var pidX: CGFloat = 0
    var pidWidth: CGFloat = 48
    var valueX: [CGFloat] = []
    var valueWidth: CGFloat = 0
    var buttonX: CGFloat = 0
    var buttonWidth: CGFloat = 46

    init(width: CGFloat, margin: CGFloat, valueCount: Int, valueWidth: CGFloat) {
        let gap: CGFloat = 8
        self.valueWidth = valueWidth
        buttonX = width - margin - buttonWidth
        var x = buttonX - gap
        var xs: [CGFloat] = []
        for _ in 0..<valueCount {
            x -= valueWidth
            xs.insert(x, at: 0)
            x -= 4
        }
        valueX = xs
        pidX = x - pidWidth
        nameX = margin
        nameWidth = pidX - gap - margin
    }
}

// MARK: - 창 내용

final class DetailPopoverController: NSViewController {
    let kind: WidgetKind
    /// 종료 버튼(확인 창은 앱이 띄운다)
    var onKill: ((ProcStat) -> Void)?

    private let margin: CGFloat = 14
    private let titleField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")
    private var graph: HistoryGraphView?
    private var infoKeys: [NSTextField] = []
    private var infoValues: [NSTextField] = []
    private var rows: [ProcessRowView] = []
    private let noteField = NSTextField(wrappingLabelWithString: "")
    private var waitingShown = false

    static let graphCapacity = 300

    init(kind: WidgetKind) {
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// 프로세스 목록이 있는 창인가(목록 표본은 이런 창이 열려 있을 때만 돈다)
    var showsProcesses: Bool { [.cpu, .ram, .ssd].contains(kind) }

    private var width: CGFloat {
        switch kind {
        case .ssd: return 400
        case .cpu, .ram: return 360
        case .gpu: return 300
        case .net: return 320
        }
    }

    private var heading: String {
        switch kind {
        case .ssd: return "SSD"
        case .gpu: return "GPU"
        case .cpu: return "CPU"
        case .ram: return "메모리"
        case .net: return "네트워크"
        }
    }

    private var infoTitles: [String] {
        switch kind {
        case .ssd: return []
        case .gpu: return ["렌더러 사용률", "타일러 사용률", "GPU 메모리"]
        case .cpu: return []
        case .ram: return ["앱 메모리", "고정 메모리", "압축", "캐시된 파일", "스왑", "메모리 압박"]
        case .net: return ["업로드", "다운로드"]
        }
    }

    private var listTitle: String {
        switch kind {
        case .cpu: return "CPU를 많이 쓰는 프로세스"
        case .ram: return "메모리를 많이 쓰는 프로세스"
        case .ssd: return "디스크 읽기·쓰기를 많이 하는 프로세스"
        default: return ""
        }
    }

    private var columnTitles: [String] {
        switch kind {
        case .cpu: return ["CPU"]
        case .ram: return ["메모리"]
        case .ssd: return ["읽기", "쓰기"]
        default: return []
        }
    }

    // MARK: 배치

    override func loadView() {
        let w = width
        let canvas = PopoverCanvas(frame: NSRect(x: 0, y: 0, width: w, height: 100))
        var y: CGFloat = 12

        titleField.font = NSFont.boldSystemFont(ofSize: 13)
        titleField.stringValue = heading
        titleField.frame = NSRect(x: margin, y: y, width: w / 2 - margin, height: 18)
        valueField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        valueField.alignment = .right
        valueField.frame = NSRect(x: w / 2, y: y, width: w / 2 - margin, height: 18)
        canvas.addSubview(titleField)
        canvas.addSubview(valueField)
        y += 18 + 8

        if kind != .ssd {
            let g = HistoryGraphView(frame: NSRect(x: margin, y: y, width: w - margin * 2, height: 92),
                                     capacity: Self.graphCapacity)
            canvas.addSubview(g)
            graph = g
            y += 92 + 8
        }

        if kind == .ssd {
            // 사용량 한 줄
            let f = NSTextField(labelWithString: "")
            f.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            f.frame = NSRect(x: margin, y: y, width: w - margin * 2, height: 16)
            canvas.addSubview(f)
            infoValues.append(f)
            y += 16 + 10
        } else {
            for t in infoTitles {
                let k = NSTextField(labelWithString: t)
                k.font = NSFont.systemFont(ofSize: 12)
                k.textColor = .secondaryLabelColor
                k.frame = NSRect(x: margin, y: y, width: 120, height: 16)
                let v = NSTextField(labelWithString: "")
                v.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                v.alignment = .right
                v.lineBreakMode = .byTruncatingHead
                v.frame = NSRect(x: margin + 120, y: y, width: w - margin * 2 - 120, height: 16)
                canvas.addSubview(k)
                canvas.addSubview(v)
                infoKeys.append(k)
                infoValues.append(v)
                y += 18
            }
            if kind == .net, infoKeys.count == 2 {
                infoKeys[0].attributedStringValue = Self.arrowTitle("↑", "업로드", .systemRed)
                infoKeys[1].attributedStringValue = Self.arrowTitle("↓", "다운로드", .systemBlue)
            }
            if !infoTitles.isEmpty { y += 4 }
        }

        if showsProcesses {
            let lt = NSTextField(labelWithString: listTitle)
            lt.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            lt.frame = NSRect(x: margin, y: y, width: w - margin * 2, height: 16)
            canvas.addSubview(lt)
            y += 20

            let valueWidth: CGFloat = kind == .ssd ? 74 : 64
            let cols = PopoverColumns(width: w, margin: margin, valueCount: columnTitles.count, valueWidth: valueWidth)
            // 열 머리
            let headFont = NSFont.systemFont(ofSize: 10.5)
            func head(_ s: String, _ x: CGFloat, _ width: CGFloat, _ align: NSTextAlignment) {
                let f = NSTextField(labelWithString: s)
                f.font = headFont
                f.textColor = .tertiaryLabelColor
                f.alignment = align
                f.frame = NSRect(x: x, y: y, width: width, height: 14)
                canvas.addSubview(f)
            }
            head("프로세스", cols.nameX, cols.nameWidth, .left)
            head("PID", cols.pidX, cols.pidWidth, .right)
            for (i, t) in columnTitles.enumerated() { head(t, cols.valueX[i], cols.valueWidth, .right) }
            y += 16

            for _ in 0..<8 {
                let r = ProcessRowView(frame: NSRect(x: 0, y: y, width: w, height: 22), columns: cols,
                                       valueCount: columnTitles.count)
                r.killButton.target = self
                r.killButton.action = #selector(killPressed(_:))
                canvas.addSubview(r)
                rows.append(r)
                y += 22
            }
            rows.first?.clear(message: "측정 중…")
            waitingShown = true
            y += 4
            noteField.font = NSFont.systemFont(ofSize: 10.5)
            noteField.textColor = .secondaryLabelColor
            noteField.maximumNumberOfLines = 2
            noteField.frame = NSRect(x: margin, y: y, width: w - margin * 2, height: 28)
            canvas.addSubview(noteField)
            y += 28
        }

        y += 10
        canvas.setFrameSize(NSSize(width: w, height: y))
        // 바탕: macOS 26 창(유리)은 뒤 화면이 비친다. 뒤가 어두우면 바탕이 진한 회색이 되는데 글자 색은 섞여서(검정·연회색)
        // 거의 안 보였다. 내용을 시스템 popover 재질 안에 넣고(글자 색이 이 재질 기준으로 한 가지로 풀림),
        // 그 위에 불투명한 창 배경색을 깔아 뒤 화면과 상관없이 같은 바탕·대비가 되게 한다.
        // 앱을 활성화하지 않으므로 창은 늘 비활성 창이다 → 재질을 늘 활성 모양으로 둔다.
        let size = canvas.frame.size
        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        let solid = SolidBackgroundView(frame: backdrop.bounds)
        solid.autoresizingMask = [.width, .height]
        backdrop.addSubview(solid)
        canvas.autoresizingMask = [.width, .height]
        backdrop.addSubview(canvas)
        view = backdrop
        preferredContentSize = size
    }

    private static func arrowTitle(_ arrow: String, _ text: String, _ color: NSColor) -> NSAttributedString {
        let s = NSMutableAttributedString(string: "\(arrow) ", attributes: [
            .foregroundColor: color, .font: NSFont.boldSystemFont(ofSize: 12),
        ])
        s.append(NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12),
        ]))
        return s
    }

    // MARK: 매 tick

    func refresh(_ st: PopoverState) {
        guard isViewLoaded else { return }
        let s = st.snapshot
        switch kind {
        case .cpu:
            valueField.stringValue = ValueText.percent(s.cpu)
            setGraph([.init(values: st.cpu, color: .systemBlue)])
        case .gpu:
            valueField.stringValue = ValueText.percent(s.gpu)
            setGraph([.init(values: st.gpu, color: .systemBlue)])
            setInfo(0, ValueText.percent(s.gpuRenderer))
            setInfo(1, ValueText.percent(s.gpuTiler))
            // GPU 메모리 줄은 읽힐 때만 보인다. 창 높이는 그대로 둔다(빈 줄)
            let hasMemory = s.gpuMemoryInUse != nil
            if infoKeys.count > 2, infoValues.count > 2, infoKeys[2].isHidden == hasMemory {
                infoKeys[2].isHidden = !hasMemory
                infoValues[2].isHidden = !hasMemory
            }
            if let used = s.gpuMemoryInUse {
                var t = "\(ValueText.memory(used)) 사용"
                if let alloc = s.gpuMemoryAllocated { t += " / \(ValueText.memory(alloc)) 할당" }
                setInfo(2, t)
            }
        case .ram:
            valueField.stringValue = ValueText.percent(s.ram)
            setGraph([.init(values: st.ram, color: .systemOrange)])
            setInfo(0, ValueText.memory(s.memoryApp))
            setInfo(1, ValueText.memory(s.memoryWired))
            setInfo(2, ValueText.memory(s.memoryCompressed))
            setInfo(3, ValueText.memory(s.memoryCached))
            if let sw = st.swap {
                setInfo(4, "\(ValueText.memory(sw.used)) / \(ValueText.memory(sw.total))")
            } else {
                setInfo(4, "읽을 수 없음")
            }
            let p = MemoryPressure.label(s.pressureLevel)
            if infoValues.count > 5 {
                infoValues[5].stringValue = p
                infoValues[5].textColor = s.pressureLevel >= 4 ? .systemRed : (s.pressureLevel >= 2 ? .systemOrange : .labelColor)
            }
        case .ssd:
            valueField.stringValue = ValueText.percent(s.ssdUsed)
            let used = s.ssdTotalBytes > s.ssdFreeBytes ? s.ssdTotalBytes - s.ssdFreeBytes : 0
            setInfo(0, "사용 \(ValueText.disk(used)) / 전체 \(ValueText.disk(s.ssdTotalBytes)) · 실제 여유 \(ValueText.disk(s.ssdFreeBytes))")
        case .net:
            valueField.stringValue = ""
            let top = Self.niceScale(max(st.up.max() ?? 0, st.down.max() ?? 0))
            graph?.scaleMax = top
            graph?.topCaption = ValueText.rate(top)
            setGraph([.init(values: st.down, color: .systemBlue), .init(values: st.up, color: .systemRed)])
            setInfo(0, ValueText.rate(s.netUpBps))
            setInfo(1, ValueText.rate(s.netDownBps))
        }
    }

    private func setGraph(_ series: [HistoryGraphView.Series]) {
        guard let graph else { return }
        graph.series = series
        graph.needsDisplay = true
    }

    private func setInfo(_ i: Int, _ text: String) {
        guard i < infoValues.count, infoValues[i].stringValue != text else { return }
        infoValues[i].stringValue = text
    }

    /// 네트워크 그래프 눈금: 표시 단위(1024 기준 KB·MB·GB) 안에서 1·2·5·10·20·50·100·200·500 (최소 1 KB/s)
    private static func niceScale(_ v: Double) -> Double {
        let x = max(v.isFinite ? v : 0, 1024)
        var unit = 1024.0
        while x >= unit * 1000, unit < 1024 * 1024 * 1024 { unit *= 1024 }
        for m in [1.0, 2, 5, 10, 20, 50, 100, 200, 500] where m * unit >= x { return m * unit }
        return unit * 1024
    }

    // MARK: 2초마다(창이 열려 있을 때만)

    func showProcesses(_ lists: ProcLists) {
        guard isViewLoaded, showsProcesses else { return }
        let items: [ProcStat]
        switch kind {
        case .cpu: items = lists.cpu
        case .ram: items = lists.memory
        case .ssd: items = lists.disk
        default: items = []
        }
        let needsRates = kind != .ram
        for (i, r) in rows.enumerated() {
            if i < items.count {
                let p = items[i]
                switch kind {
                case .cpu: r.show(p, values: [ValueText.processCPU(p.cpuPct ?? 0)])
                case .ram: r.show(p, values: [ValueText.memory(p.footprint)])
                case .ssd: r.show(p, values: [ValueText.rate(p.readBps ?? 0), ValueText.rate(p.writeBps ?? 0)])
                default: break
                }
            } else if i == 0 {
                r.clear(message: needsRates && !lists.hasRates ? "측정 중…" : "해당 프로세스 없음")
            } else {
                r.clear()
            }
        }
        noteField.stringValue = Self.note(kind: kind, lists: lists)
    }

    /// 목록 아래 안내 한 줄에서 두 줄
    private static func note(kind: WidgetKind, lists: ProcLists) -> String {
        guard lists.denied > 0 else { return "" }
        if kind == .ssd {
            // SSD 창은 ps를 돌리지 않는다(ps가 디스크 읽기·쓰기를 주지 않음)
            return "시스템 계정 프로세스 \(lists.denied)개(WindowServer 등)는 디스크 사용량을 읽을 수 없어 목록에 없습니다."
        }
        if lists.systemFailed {
            return "시스템 프로세스를 읽는 ps가 응답하지 않아 이번 목록에서 \(lists.denied)개가 빠졌습니다."
        }
        guard lists.systemIncluded, lists.viaPS > 0 else {
            return "시스템 계정 프로세스 \(lists.denied)개(WindowServer 등)는 권한이 없어 읽지 못해 목록에 없습니다."
        }
        let rest = lists.unreadable > 0 ? " kernel_task 등 \(lists.unreadable)개는 읽을 수 없습니다." : ""
        if kind == .ram {
            // RSS는 대개 footprint보다 작지만(압축·그래픽 메모리 빠짐) 파일 매핑이 많으면 클 수도 있어 방향을 단정하지 않는다
            return "(시스템) 줄의 메모리는 ps의 RSS라 활성 상태 보기 값과 다릅니다(대개 더 작음).\(rest)"
        }
        return "(시스템) 줄은 ps로 읽은 다른 계정 프로세스입니다(종료 불가).\(rest)"
    }

    @objc private func killPressed(_ sender: NSButton) {
        guard let row = sender.superview as? ProcessRowView, let p = row.process, p.canKill else { return }
        onKill?(p)
    }
}
