// 앱 본체: 1초 tick(값 읽기 → 이력 → 렌더러 → 열린 창 → 기록 판정 → 측정), 클릭 분배, 창, 메뉴, 측정 모드.
import AppKit

final class AppController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let options: AppOptions
    private let sampler = SystemSampler()          // 만들 때 CPU·네트워크 기준값을 잡는다
    private let samplerCreatedAt = ProcessInfo.processInfo.systemUptime
    private let processSampler = ProcessSampler()
    private let spikeLogger: SpikeLogger
    private var slot: StatusSlot?
    private var renderer: BarRenderer?
    private let rendererName = "standard"
    private var timer: Timer?
    private var started = false

    // 이력: 메뉴바 60점(시작할 때 첫 값으로 채움), 창 300점(5분)
    private var barCPU = RollingSeries(capacity: BarLayout.historyCount)
    private var barGPU = RollingSeries(capacity: BarLayout.historyCount)
    private var barRAM = RollingSeries(capacity: BarLayout.historyCount)
    private var longCPU = RollingSeries(capacity: DetailPopoverController.graphCapacity)
    private var longGPU = RollingSeries(capacity: DetailPopoverController.graphCapacity)
    private var longRAM = RollingSeries(capacity: DetailPopoverController.graphCapacity)
    private var longUp = RollingSeries(capacity: DetailPopoverController.graphCapacity)
    private var longDown = RollingSeries(capacity: DetailPopoverController.graphCapacity)
    private var last = SystemSnapshot()
    private var lastSwap: SwapUsage?

    // 창
    private var popover: NSPopover?
    private var popoverController: DetailPopoverController?
    private var popoverKind: WidgetKind?
    private var outsideClickMonitor: Any?
    private var lastClose: (kind: WidgetKind, at: Double)?
    private var processBaseline: ProcSample?
    private var processGeneration = 0

    // 측정(--duration)
    private var measuring = false
    private var m0 = (t: 0.0, user: 0.0, sys: 0.0, renders: 0, replicas: 0, spikes: 0)
    /// 측정 시작 때 끝난 자식 프로세스(ps)의 CPU 누계
    private var m0Children = 0.0
    private var mTicks = 0
    private var mMainVisible = 0
    private var mReplicaKnown = 0
    private var mReplicaVisible = 0

    init(options: AppOptions) {
        self.options = options
        spikeLogger = SpikeLogger(directory: options.logDir ?? SpikeLogger.defaultDirectory,
                                  rules: options.spikeTest ? SpikeLogger.testRules : SpikeLogger.normalRules,
                                  sampler: processSampler)
        super.init()
    }

    // MARK: 시작

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMeta.displayName = "리소스 모니터"
        LoginItem.refreshAsync()
        spikeLogger.start()

        let slot = StatusSlot(noPin: options.noPin)
        slot.willRebuild = { [weak self] in self?.detachFromItem() }
        slot.didRebuild = { [weak self] item in self?.attach(to: item) }
        self.slot = slot
        attach(to: slot.item)

        // 첫 값: 기준값을 잡은 지 0.3초 이상 지나서 읽어야 CPU·네트워크 비율이 의미 있다
        let wait = max(0, 0.3 - (ProcessInfo.processInfo.systemUptime - samplerCreatedAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.firstFrame() }

        if let d = options.duration {
            // 측정 구간 경계는 오차 없는 타이머로(긴 asyncAfter는 GCD 여유 때문에 수백 ms 늦을 수 있다)
            let w = options.warmup
            schedulePrecise(after: w, #selector(beginMeasure))
            schedulePrecise(after: w + d, #selector(finishMeasure))
            DispatchQueue.main.asyncAfter(deadline: .now() + w + d + 30) { exit(2) }   // 안전장치
        }
    }

    private func firstFrame() {
        guard !started else { return }
        started = true
        let s = sampler.read()
        last = s
        barCPU.fill(s.cpu)
        barGPU.fill(s.gpu)
        barRAM.fill(s.ram)
        pushLong(s)
        renderer?.update(barFrame())
        spikeLogger.evaluate(s, now: ProcessInfo.processInfo.systemUptime)

        let t = Timer(timeInterval: 1.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)   // 메뉴·확인 창이 떠 있는 동안에도 돈다
        timer = t

        if let k = options.openKind {
            // 칸 창이 자리를 잡은 뒤에 연다. 앱을 활성화하지 않는다(다른 앱의 키보드 포커스를 뺏지 않음).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openWhenPlaced(k, waited: 0.3)
            }
        }
    }

    /// --open: 본 칸 창이 "보임"이 될 때까지 0.1초 간격으로 기다렸다가(최대 1.5초) 연다. 막 만든 창은 가림 상태가
    /// 아직 정해지지 않아 "가려짐"으로 보이고, 그러면 창이 다른 화면 복제 칸에 붙는 일이 있었다(시험에서 25번 중 2번).
    /// 1.5초가 지나도 가려져 있으면(노치 화면에서 밀려남 등) 지금처럼 보이는 복제 칸에 붙인다.
    private func openWhenPlaced(_ k: WidgetKind, waited: Double) {
        let visible = slot?.item.button?.window?.occlusionState.contains(.visible) == true
        if visible || waited >= 1.5 {
            showPopover(k, keepOpen: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.openWhenPlaced(k, waited: waited + 0.1)
        }
    }

    private func pushLong(_ s: SystemSnapshot) {
        longCPU.push(s.cpu)
        longGPU.push(s.gpu)
        longRAM.push(s.ram)
        longUp.push(s.netUpBps)
        longDown.push(s.netDownBps)
    }

    private func barFrame() -> BarFrame {
        BarFrame(ssdUsed: last.ssdUsed, gpuHistory: barGPU.values, cpuHistory: barCPU.values,
                 ramHistory: barRAM.values, netUpBps: last.netUpBps, netDownBps: last.netDownBps)
    }

    // MARK: 칸·렌더러

    private func attach(to item: NSStatusItem) {
        if let b = item.button {
            b.target = self
            b.action = #selector(statusItemClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])   // 기본값은 왼쪽 버튼뿐
        }
        renderer = makeBarRenderer(for: item)
        if started { renderer?.update(barFrame()) }
    }

    private func detachFromItem() {
        closePopover()
        renderer?.teardown()
        renderer = nil
    }

    /// 그리기는 StandardRenderer 하나다. Core Animation 레이어로 그리는 방식도 시험했는데 코어 하나의 0.1%p만
    /// 아끼면서 다른 화면 복제 칸 갱신을 문서에 없는 AppKit 동작에 기대야 해서 넣지 않았다(docs/resourcebar.md).
    private func makeBarRenderer(for item: NSStatusItem) -> BarRenderer {
        StandardRenderer(statusItem: item)
    }

    // MARK: tick(1초)

    @objc private func tick() {
        let s = sampler.read()
        last = s
        barCPU.push(s.cpu)
        barGPU.push(s.gpu)
        barRAM.push(s.ram)
        pushLong(s)
        renderer?.update(barFrame())
        if let vc = popoverController, popover?.isShown == true {
            if popoverKind == .ram { lastSwap = sampler.readSwap() }
            vc.refresh(popoverState())
        }
        spikeLogger.evaluate(s, now: ProcessInfo.processInfo.systemUptime)
        if measuring { sampleVisibility() }
    }

    private func popoverState() -> PopoverState {
        PopoverState(snapshot: last, cpu: longCPU.values, gpu: longGPU.values, ram: longRAM.values,
                     up: longUp.values, down: longDown.values, swap: lastSwap)
    }

    // MARK: 클릭

    @objc private func statusItemClicked(_ sender: Any?) {
        let ev = NSApp.currentEvent
        // 트랙패드에서는 control-클릭이 오른쪽 클릭을 대신하므로 둘 다 메뉴로
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true {
            showMenu(clickedWindow: ev?.window)
            return
        }
        let k = widgetForClick(ev)
        if let p = popover, p.isShown {
            let same = popoverKind == k
            closePopover()
            if same { return }   // 같은 위젯을 다시 누르면 닫기만
        } else if let lc = lastClose, lc.kind == k, ProcessInfo.processInfo.systemUptime - lc.at < 0.4 {
            // 창 밖 클릭으로 막 닫힌 직후의 같은 위젯 클릭(누를 때 닫히고 뗄 때 이 동작이 온다) → 다시 열지 않는다
            return
        }
        showPopover(k, keepOpen: false, clickedWindow: ev?.window)
    }

    /// 창을 붙일 곳: 보통은 버튼. 클릭이 다른 화면의 복제 칸에서 왔거나, 본 칸 창이 가려져 있고(노치 화면 메뉴 막대가
    /// 꽉 차서 밀려남) 복제 칸이 보이면 그 복제 창에 붙인다. 복제 창 안 배치는 본 창과 같다(버튼이 같은 x에 있다).
    private func popoverAnchor(for k: WidgetKind, clickedWindow: NSWindow?) -> (view: NSView, rect: NSRect)? {
        guard let button = slot?.item.button else { return nil }
        let inButton = BarLayout.frame(of: k, height: button.bounds.height)
        guard let main = button.window else { return (button, inButton) }
        var target: NSWindow?
        if let w = clickedWindow, Self.isReplicaWindow(w, main: main) {
            target = w
        } else if !main.occlusionState.contains(.visible) {
            target = NSApp.windows.first { Self.isReplicaWindow($0, main: main) && $0.occlusionState.contains(.visible) }
        }
        guard let w = target, let content = w.contentView else { return (button, inButton) }
        let inWindow = button.convert(inButton, to: nil)
        let rect = NSRect(x: inWindow.minX, y: 0, width: inWindow.width, height: w.frame.height)
        return (content, content.convert(rect, from: nil))
    }

    /// 다른 화면 복제 칸 창인가: 이 앱의 상태 막대 창 중 본 칸 창이 아닌 것(칸은 하나뿐이다).
    /// 클래스 이름(NSStatusBarWindow, 비공개)이 바뀌어도 놓치지 않게 공개 값으로도 본다: 상태 막대 이상 층,
    /// 본 칸 창과 같은 폭, 메뉴 막대 높이(macOS 26.6 실측: 본 칸·복제 모두 층 25, 폭 244, 높이 30·33).
    /// 창(NSPopover)은 폭이 300 이상, 메뉴는 메뉴 막대보다 높아서 걸리지 않는다.
    static func isReplicaWindow(_ w: NSWindow, main: NSWindow) -> Bool {
        guard w !== main else { return false }
        if w.className.contains("NSStatusBarWindow") { return true }
        return w.level.rawValue >= NSWindow.Level.statusBar.rawValue
            && abs(w.frame.width - main.frame.width) < 1 && w.frame.height < 60
    }

    private func widgetForClick(_ ev: NSEvent?) -> WidgetKind {
        guard let button = slot?.item.button else { return .cpu }
        if let ev, [.leftMouseUp, .leftMouseDown, .rightMouseUp, .rightMouseDown].contains(ev.type) {
            // 다른 화면의 복제 칸에서 온 클릭도 창 안 배치가 같으므로 같은 변환을 쓴다
            return BarLayout.widget(atX: button.convert(ev.locationInWindow, from: nil).x)
        }
        // 접근성 누르기 등 마우스 사건이 아닐 때: 지금 마우스 위치가 칸 위면 그 위젯, 아니면 CPU
        if let w = button.window, w.frame.contains(NSEvent.mouseLocation) {
            let p = button.convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            return BarLayout.widget(atX: p.x)
        }
        return .cpu
    }

    // MARK: 창

    private func showPopover(_ k: WidgetKind, keepOpen: Bool, clickedWindow: NSWindow? = nil) {
        guard let anchor = popoverAnchor(for: k, clickedWindow: clickedWindow) else { return }
        closePopover()
        let vc = DetailPopoverController(kind: k)
        vc.onKill = { [weak self] p in self?.confirmKill(p) }
        _ = vc.view
        let p = NSPopover()
        p.contentViewController = vc
        p.contentSize = vc.preferredContentSize
        // --open: 창 밖 클릭으로 닫히지 않게. 평소: 창 밖을 누르면 닫힘
        p.behavior = keepOpen ? .applicationDefined : .transient
        p.delegate = self
        popover = p
        popoverController = vc
        popoverKind = k
        if k == .ram { lastSwap = sampler.readSwap() }
        vc.refresh(popoverState())
        // 앱을 활성화하지 않는다. 대신 다른 앱을 누르면 닫히도록 전역 클릭 감시를 단다.
        p.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .minY)
        if !keepOpen { installOutsideClickMonitor() }
        if vc.showsProcesses { startProcessSampling() }
    }

    private func closePopover() {
        guard let p = popover else { return }
        forgetPopover(p)
        p.close()
    }

    /// 창 상태 정리(여러 번 불려도 된다)
    private func forgetPopover(_ p: NSPopover) {
        guard p === popover else { return }
        if let k = popoverKind { lastClose = (k, ProcessInfo.processInfo.systemUptime) }
        stopProcessSampling()
        removeOutsideClickMonitor()
        popover = nil
        popoverController = nil
        popoverKind = nil
        lastSwap = nil
    }

    func popoverWillClose(_ notification: Notification) {
        if let p = notification.object as? NSPopover { forgetPopover(p) }
    }

    func popoverDidClose(_ notification: Notification) {
        if let p = notification.object as? NSPopover { forgetPopover(p) }
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in
            self?.closePopover()
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
    }

    // MARK: 프로세스 목록(창이 열려 있을 때만: 기준 표본 → 1초 뒤 첫 목록 → 이후 2초마다)

    private func startProcessSampling(firstDelay: Double = 1.0) {
        processGeneration += 1
        processBaseline = nil
        let gen = processGeneration
        sampleProcesses(gen: gen, nextDelay: firstDelay)
    }

    private func stopProcessSampling() {
        processGeneration += 1
        processBaseline = nil
    }

    private func sampleProcesses(gen: Int, nextDelay: Double) {
        guard gen == processGeneration, let k = popoverKind else { return }
        let prev = processBaseline
        let ps = processSampler
        // CPU·메모리 창은 직접 못 읽는 다른 계정 프로세스를 ps로 함께 받는다. SSD 창은 ps가 디스크 값을 주지 않아 안 돌린다
        let includeSystem = k == .cpu || k == .ram
        ps.queue.async {
            let cur = ps.sample(includeSystem: includeSystem)
            let lists = ps.lists(from: prev, to: cur,
                                 cpuTop: k == .cpu ? 8 : 0, memoryTop: k == .ram ? 8 : 0,
                                 diskTop: k == .ssd ? 8 : 0, writeTop: 0)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.processGeneration else { return }
                self.processBaseline = cur
                self.popoverController?.showProcesses(lists)
                DispatchQueue.main.asyncAfter(deadline: .now() + nextDelay) { [weak self] in
                    self?.sampleProcesses(gen: gen, nextDelay: 2.0)
                }
            }
        }
    }

    // MARK: 종료 버튼

    private func confirmKill(_ p: ProcStat) {
        guard p.canKill else { return }
        let subject = "\(p.name)(PID \(p.pid))"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(subject)\(ValueText.objectParticle(after: subject)) 종료할까요?"
        alert.informativeText = "SIGTERM을 보냅니다. 저장하지 않은 내용은 사라질 수 있습니다."
        alert.addButton(withTitle: "종료")
        alert.addButton(withTitle: "취소")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        // 확인 창(뒤따르는 알림 창 포함)을 누르는 동안 창이 닫히지 않게 잠시 고정
        let pop = popover
        let behavior = pop?.behavior
        pop?.behavior = .applicationDefined
        removeOutsideClickMonitor()
        // 비활성 앱의 runModal 창은 키 창이 되지 못해 Return·Esc가 앞에 있던 앱으로 가고 다른 창 뒤에 깔릴 수 있다.
        // 사용자가 종료 버튼을 누른 이때만 앱을 활성화한다. --open(시험·측정)에서는 활성화하지 않는다.
        if options.openKind == nil && !NSApp.isActive { NSApp.activate() }
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed {
            // 목록은 최대 2초 전 표본이고 확인 창은 누를 때까지 열려 있었다. 그 사이 끝났거나 PID가 다른 프로세스에
            // 재사용됐을 수 있으므로 보내기 직전에 시작 시각·소유자가 그대로인지 다시 본다.
            if !ProcessSampler.isStillSame(p) {
                let gone = NSAlert()
                gone.messageText = "이미 끝난 프로세스입니다"
                gone.informativeText = "\(subject)에 종료 신호를 보내지 않았습니다. 목록을 새로 고칩니다."
                gone.runModal()
            } else if kill(p.pid, SIGTERM) != 0 {
                let err = String(cString: strerror(errno))
                let fail = NSAlert()
                fail.messageText = "\(subject)\(ValueText.objectParticle(after: subject)) 종료하지 못했습니다"
                fail.informativeText = err
                fail.runModal()
            }
        }
        if let pop, let behavior, pop === popover {
            pop.behavior = behavior
            if behavior == .transient { installOutsideClickMonitor() }
        }
        // 목록을 곧바로 새로 고친다
        if confirmed, popover != nil, popoverController?.showsProcesses == true { startProcessSampling(firstDelay: 0.5) }
    }

    // MARK: 오른쪽 클릭 메뉴

    private func showMenu(clickedWindow: NSWindow?) {
        guard let slot else { return }
        closePopover()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let pin = NSMenuItem(title: "메뉴 막대 오른쪽 끝에 고정", action: #selector(togglePin), keyEquivalent: "")
        pin.target = self
        pin.state = slot.pinnedThisRun ? .on : .off
        menu.addItem(pin)
        let logs = NSMenuItem(title: "기록 폴더 열기", action: #selector(openLogFolder), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)
        let login = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.cachedStatus() == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "종료", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        // 다른 화면의 복제 칸에서 눌렀으면 그 칸 바로 아래에 띄운다. 본 칸 버튼의 performClick은 메뉴를 본 칸 자리에
        // 띄우는데, 그 자리는 다른 화면이거나(고정을 끄면) 노치 뒤로 밀려 가려진 곳일 수 있다. 고정을 다시 켜는
        // 메뉴가 바로 그때 필요하다. 왼쪽 클릭 창과 같은 판별(복제 창 안 배치는 본 칸 창과 같다).
        if let w = clickedWindow, let button = slot.item.button, let main = button.window,
           Self.isReplicaWindow(w, main: main), let content = w.contentView {
            let left = button.convert(NSPoint.zero, to: nil).x   // 칸 왼쪽 끝(창 좌표, 아래가 0)
            menu.popUp(positioning: nil, at: content.convert(NSPoint(x: left, y: 0), from: nil), in: content)
            return
        }
        // statusItem.menu를 계속 달아 두면 왼쪽 클릭도 메뉴가 되므로 띄우는 순간에만 붙였다 뗀다
        slot.item.menu = menu
        slot.item.button?.performClick(nil)   // 메뉴가 닫힐 때까지 돌아오지 않는다
        slot.item.menu = nil
    }

    @objc private func toggleLogin() {
        LoginItem.toggleFromMenu()
    }

    @objc private func togglePin() {
        slot?.togglePin()
    }

    @objc private func openLogFolder() {
        let dir = spikeLogger.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !NSWorkspace.shared.open(dir) {
            let a = NSAlert()
            a.messageText = "기록 폴더를 열지 못했습니다"
            a.informativeText = dir.path
            a.runModal()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: 측정(--duration N --warmup W)

    private func schedulePrecise(after seconds: Double, _ selector: Selector) {
        let t = Timer(timeInterval: seconds, target: self, selector: selector, userInfo: nil, repeats: false)
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
    }

    @objc private func beginMeasure() {
        let c = Self.processCPUSeconds()
        m0Children = Self.childrenCPUSeconds()
        m0 = (ProcessInfo.processInfo.systemUptime, c.user, c.sys, renderer?.renderCount ?? 0,
              renderer?.replicaRefreshCount ?? -1, spikeLogger.linesWritten)
        mTicks = 0
        mMainVisible = 0
        mReplicaKnown = 0
        mReplicaVisible = 0
        measuring = true
    }

    private func sampleVisibility() {
        mTicks += 1
        let main = slot?.item.button?.window
        if main?.occlusionState.contains(.visible) == true { mMainVisible += 1 }
        // 복제 창: 이 앱의 상태 막대 창 중 본 칸 창이 아닌 것(칸은 하나뿐이다)
        var known = false
        var visible = false
        for w in NSApp.windows where main.map({ Self.isReplicaWindow(w, main: $0) }) ?? false {
            known = true
            if w.occlusionState.contains(.visible) { visible = true }
        }
        if known { mReplicaKnown += 1 }
        if visible { mReplicaVisible += 1 }
    }

    @objc private func finishMeasure() {
        guard measuring else { return }
        measuring = false
        let wall = ProcessInfo.processInfo.systemUptime - m0.t
        let c = Self.processCPUSeconds()
        let user = c.user - m0.user
        let sys = c.sys - m0.sys
        // 앱이 띄운 ps(끝나고 거둔 자식)의 CPU. cpu_pct(앱 자신)에는 들지 않으므로 따로 적고 합계도 적는다
        let children = max(0, Self.childrenCPUSeconds() - m0Children)
        let replicaNow = renderer?.replicaRefreshCount ?? -1
        let screen = slot?.item.button?.window?.screen
        func r(_ v: Double, _ digits: Double) -> Double { (v * digits).rounded() / digits }
        let fields: [(String, OrderedJSON)] = [
            ("renderer", .string(rendererName)),
            ("cpu_pct", .double(r((user + sys) / max(wall, 0.001) * 100, 1000))),
            ("cpu_children_pct", .double(r(children / max(wall, 0.001) * 100, 1000))),
            ("cpu_total_pct", .double(r((user + sys + children) / max(wall, 0.001) * 100, 1000))),
            ("cpu_user_s", .double(r(user, 10000))),
            ("cpu_sys_s", .double(r(sys, 10000))),
            ("wall_s", .double(r(wall, 1000))),
            ("ticks", .int(mTicks)),
            ("renders", .int((renderer?.renderCount ?? 0) - m0.renders)),
            ("replica_refreshes", .int((replicaNow < 0 || m0.replicas < 0) ? -1 : replicaNow - m0.replicas)),
            ("phys_footprint_mb", .double(r(Self.physFootprintMB(), 10))),
            ("main_screen", screen.map { .string($0.localizedName) } ?? .null),
            ("main_screen_scale", screen.map { .double(Double($0.backingScaleFactor)) } ?? .null),
            ("main_window_visible_ratio", .double(mTicks > 0 ? r(Double(mMainVisible) / Double(mTicks), 1000) : 0)),
            // 복제 창을 한 번도 못 봤으면(화면 하나 등) 모름 = -1
            ("replica_visible_ratio", .double(mReplicaKnown > 0 ? r(Double(mReplicaVisible) / Double(mReplicaKnown), 1000) : -1)),
            ("popup", popoverKind.map { .string($0.optionName) } ?? .null),
            ("spike_events", .int(spikeLogger.linesWritten - m0.spikes)),
        ]
        // 키 이름순(여러 번 잰 결과를 줄끼리 비교하기 쉽게)
        let line = OrderedJSON.object(fields.sorted { $0.0 < $1.0 }).text
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
        renderer?.teardown()
        exit(0)
    }

    private static func processCPUSeconds() -> (user: Double, sys: Double) {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return (Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6,
                Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6)
    }

    /// 끝나고 거둔 자식 프로세스(ps)의 사용자 + 시스템 CPU 누계(초)
    private static func childrenCPUSeconds() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_CHILDREN, &ru)
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
            + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    }

    private static func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
