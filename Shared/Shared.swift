// Shared.swift — 세 개의 메뉴 막대 앱(AudioFix / ThemeToggle / MicRecorder)이 함께 쓰는 코드.
//
// 여기에는 앱별 로직을 두지 않는다. 프로세스 실행, 관리자 권한 실행, 알림, 메뉴 막대 아이콘,
// 로그인 항목처럼 세 앱이 똑같이 필요로 하는 것만 둔다.

import AppKit
import ServiceManagement

// MARK: - 공통 상수

enum UI {
    /// 이 맥(14" MacBook Pro)의 메뉴 막대는 노치 오른쪽 가용폭 664pt 중 약 628pt가 이미 차 있어
    /// 여유가 ~36pt뿐이다(실측). 폭이 조금이라도 늘어나면 macOS가 항목을 노치 **왼쪽**으로 밀어내는데,
    /// 그 자리는 앱 메뉴가 덮고 있어 아이콘이 영영 보이지 않는다.
    /// 그래서 폭을 고정하고, 제목 문자열은 어떤 경우에도 붙이지 않는다.
    static let itemLength: CGFloat = 24
    /// 아이콘을 담을 상자. 심볼마다 고유 비율이 달라서, 정사각형으로 강제하면 가로로 넓은 심볼
    /// (speaker.badge.exclamationmark 등)이 눌려 보인다. 비율은 유지한 채 이 상자 안에 맞춘다.
    /// 항목 폭(24pt)은 statusItem(withLength:) 이 고정하므로 이미지 크기가 폭을 흔들지는 않는다.
    ///
    /// 가로 한계를 22 로 둔 이유: `speaker.badge.exclamationmark` 는 원본이 25x17 이다.
    /// 한계가 18 이면 가로에 먼저 걸려 세로가 12pt 로 깎이고, 15pt 인 옆 아이콘들보다 눈에 띄게 작아진다.
    /// 22 면 세로를 다 쓴다(22x15). 항목이 24pt 이므로 좌우 1pt 씩은 남는다.
    static let iconSide: CGFloat = 15
    static let iconMaxWidth: CGFloat = 22

    static let symOK = "checkmark.circle.fill"
    static let symInfo = "info.circle"
    static let symErr = "exclamationmark.triangle.fill"
    static let symFallback = "questionmark.circle"

    // 시스템 설정 딥링크
    static let micSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    static let automationSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    static let loginItemsURL = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
}

/// 알림 문구에 쓸 앱 이름. 각 앱이 실행 직후 설정한다.
enum AppMeta {
    static var displayName = "MacTools"
}

// MARK: - 오류

/// 사용자에게 그대로 보여도 되는 한국어 설명을 가진 오류.
protocol KoreanError: Error, CustomStringConvertible {}

/// 사용자에게 보여줄 오류 문구.
/// `"\(error)"` 를 그대로 쓰면 NSError 가 `Error Domain=… Code=… UserInfo={…}` 로 찍혀 UI 가 깨진다.
func errText(_ e: Error) -> String {
    if let k = e as? KoreanError { return k.description }
    return (e as NSError).localizedDescription
}

// MARK: - 프로세스 실행

/// POSIX 작은따옴표 인용. 셸 계층에서 메타문자를 무력화한다.
func shq(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

struct ProcResult {
    let code: Int32
    let out: String
    let err: String

    var outTrimmed: String { out.trimmingCharacters(in: .whitespacesAndNewlines) }
    var errTrimmed: String { err.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// 백그라운드 큐에서 채우고 `DispatchGroup.wait()` 로 동기화하기 위한 상자.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// 두 파이프를 **동시에** 비운다.
/// stdout 을 EOF 까지 읽고 나서 stderr 를 읽으면, 자식이 stderr 파이프 버퍼(64KB)를 채운 채
/// 블록되어 영원히 끝나지 않는 교착이 생긴다 (자식은 write 에서, 부모는 read 에서 대기).
@discardableResult
func run(_ path: String, _ args: [String]) -> ProcResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let o = Pipe(), e = Pipe()
    p.standardOutput = o
    p.standardError = e
    // sudo -n 이 터미널을 찾아 블록되는 일이 없도록 stdin 을 /dev/null 로 고정한다.
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return ProcResult(code: -1, out: "", err: "\(error)") }

    let drain = DispatchGroup()
    let box = DataBox()
    drain.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        box.data = e.fileHandleForReading.readDataToEndOfFile()
        drain.leave()
    }
    let od = o.fileHandleForReading.readDataToEndOfFile()
    drain.wait()
    p.waitUntilExit()
    return ProcResult(code: p.terminationStatus,
                      out: String(decoding: od, as: UTF8.self),
                      err: String(decoding: box.data, as: UTF8.self))
}

// MARK: - 관리자 권한 실행

enum AdminError: KoreanError {
    case userCancelled
    case initFailed
    case failed(code: Int, message: String)

    var description: String {
        switch self {
        case .userCancelled: return "사용자가 취소했습니다"
        case .initFailed:    return "AppleScript를 생성하지 못했습니다"
        case .failed(let c, let m): return "\(m) (\(c))"
        }
    }
}

/// `do shell script … with administrator privileges` — 반드시 메인 스레드에서 호출한다.
/// (SecurityAgent UI를 띄우는 경로다.)
/// 인프로세스 NSAppleScript 를 쓰는 이유: 인증 대화상자에 "osascript" 가 아니라 앱 이름이 표시된다.
///
/// 주의: `do shell script` 는 셸의 0 이 아닌 종료 코드를 **AppleScript 오류로** 바꾼다.
/// 따라서 여기에 넘기는 스크립트는 실패해도 반드시 exit 0 으로 끝내고,
/// 결과는 stdout 토큰으로만 알려야 한다.
func admin(_ shell: String) throws -> String {
    let esc = shell
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    guard let script = NSAppleScript(source:
        "do shell script \"\(esc)\" with administrator privileges") else {
        throw AdminError.initFailed
    }
    var info: NSDictionary?
    let result = script.executeAndReturnError(&info)
    if let i = info {
        let code = (i[NSAppleScript.errorNumber] as? Int) ?? -1
        let msg = (i[NSAppleScript.errorMessage] as? String) ?? "알 수 없는 오류"
        if code == -128 { throw AdminError.userCancelled }   // 사용자 취소는 실패가 아니다
        throw AdminError.failed(code: code, message: msg)
    }
    return result.stringValue ?? ""
}

/// base64 로 감싸면 Swift / AppleScript / 셸 3중 인용 문제가 사라진다
/// (base64 출력은 [A-Za-z0-9+/=] 뿐이라 셸 메타문자가 0개).
func base64OneLiner(_ body: String) -> String {
    let b64 = Data(body.utf8).base64EncodedString()
    return "/usr/bin/printf %s '\(b64)' | /usr/bin/base64 -D | /bin/bash"
}

// MARK: - 알림

enum AlertGate {
    static var busy = false
    static var pending: [() -> Void] = []

    static func drain() {
        guard !busy, !pending.isEmpty else { return }
        pending.removeFirst()()
    }
}

/// 실패는 절대 조용히 넘기지 않는다. 메인 스레드 전용.
/// 이미 다른 알림이 떠 있으면 큐에 넣고 즉시 false 를 돌려준다.
@discardableResult
func failAlert(_ title: String,
               _ body: String,
               actionTitle: String? = nil,
               closeTitle: String = "닫기",
               action: (() -> Void)? = nil) -> Bool {
    if AlertGate.busy {
        AlertGate.pending.append {
            _ = failAlert(title, body, actionTitle: actionTitle, closeTitle: closeTitle, action: action)
        }
        return false
    }
    AlertGate.busy = true
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = body
    if let at = actionTitle { alert.addButton(withTitle: at) }   // 먼저 추가한 버튼이 기본(오른쪽)
    alert.addButton(withTitle: closeTitle)
    // AppKit 은 제목이 "Cancel"(현재 로케일의 그 문자열)인 버튼에만 Esc 를 자동으로 묶는다.
    // 이 앱들은 .lproj 가 없어 그 자동 매칭을 신뢰할 수 없으므로 직접 지정한다.
    // 버튼이 하나뿐일 때는 건드리지 않는다 — 그 버튼의 Return 기본 동작을 뺏게 된다.
    if actionTitle != nil { alert.buttons.last?.keyEquivalent = "\u{1b}" }
    NSApp.activate(ignoringOtherApps: true)   // 활성화는 비동기다. isActive 를 검사하지 말 것.
    let response = alert.runModal()
    AlertGate.busy = false
    DispatchQueue.main.async { AlertGate.drain() }
    if actionTitle != nil, response == .alertFirstButtonReturn {
        action?()
        return true
    }
    return false
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// `NSWorkspace.open` 은 실패해도 아무 UI 도 띄우지 않고 false 만 돌려준다. 반드시 결과를 확인한다.
@discardableResult
func openURLString(_ s: String, whatFailed: String) -> Bool {
    if let url = URL(string: s), NSWorkspace.shared.open(url) { return true }
    failAlert("\(whatFailed)을(를) 열 수 없습니다",
              "macOS가 이 위치를 열지 못했습니다.\n\n\(s)",
              actionTitle: "주소 복사") { copyToPasteboard(s) }
    return false
}

// MARK: - 메뉴 막대 아이콘

/// 좌클릭은 즉시 동작, 우클릭·컨트롤클릭은 설정 메뉴.
///
/// 핵심 제약이 둘 있다.
///  1) `statusItem.menu` 를 계속 달아 두면 **좌클릭도 메뉴를 열어 버려** 즉시 동작이 사라진다.
///     그래서 메뉴는 띄우는 순간에만 붙였다가 곧바로 뗀다.
///  2) 버튼에 제목을 붙이면 항목 폭이 늘어나고, 이 맥에서는 그 즉시 아이콘이 메뉴 막대에서
///     밀려나 사라진다. 그래서 상태·경과 시간은 전부 툴팁과 메뉴로만 전달한다.
/// 아이콘이 그릴 한 가지 모습.
///
/// `tint` 가 nil 이면 템플릿 이미지로 그린다 — macOS 가 메뉴 막대 배경(다크·라이트)에 맞춰
/// 알아서 흑백을 뒤집어 준다. 색을 지정하면 템플릿을 끄고 그 색으로 칠하므로 **양쪽 외형에서
/// 모두 읽히는 색만** 써야 한다(빨강은 괜찮다).
struct IconLook {
    let symbol: String
    let tip: String
    var tint: NSColor? = nil
    /// 심볼 획 굵기. 굵게 해도 아이콘이 **커지지는 않고** 선만 두꺼워진다(실측: regular→bold 에서
    /// 칠해지는 픽셀이 24%에서 27%로). 옆 시스템 아이콘에 묻힐 때 쓴다.
    var weight: NSFont.Weight = .regular

    init(_ symbol: String, _ tip: String, tint: NSColor? = nil, weight: NSFont.Weight = .regular) {
        self.symbol = symbol
        self.tip = tip
        self.tint = tint
        self.weight = weight
    }
}

final class StatusIcon: NSObject {
    private var item: NSStatusItem
    private let autosaveName: String

    /// 현재 상태의 모습. 상태는 앱이 소유하고, 아이콘은 그때그때 물어본다.
    var state: () -> IconLook = { IconLook(UI.symFallback, "") }
    /// 좌클릭 즉시 동작.
    var onClick: () -> Void = {}
    /// 우클릭·컨트롤클릭에서 띄울 메뉴.
    var buildMenu: () -> NSMenu = { NSMenu() }

    private var flash: (look: IconLook, until: Date)?
    private var appearanceObserver: NSKeyValueObservation?

    /// - Parameter pinDefault: "오른쪽 끝에 고정" 옵션의 **초기값**. 저장된 설정이 없을 때만 쓴다.
    ///   노치 맥에서 항목이 넘치면 macOS 는 **왼쪽부터** 자르므로, 오른쪽 끝(제어 센터 바로 왼쪽)이
    ///   유일하게 안전한 자리다. 항상 보여야 하는 앱은 켠 채로 시작한다.
    init(pinDefault: Bool = false) {
        // autosaveName 이 없으면 macOS 가 익명 항목에 "Item-N" 을 배정하는데,
        // 이 시스템에는 이미 숨김으로 저장된 "Item-0" 이 있어 그 상태를 물려받을 수 있다.
        let name = "\(Bundle.main.bundleIdentifier ?? "MacTools").status"
        autosaveName = name

        let d = UserDefaults.standard
        if d.object(forKey: Self.pinKey) == nil { d.set(pinDefault, forKey: Self.pinKey) }
        // 고정이 켜져 있으면 매 실행마다 다시 오른쪽 끝으로 보낸다. 항목을 만들기 **전에** 써야 한다.
        if d.bool(forKey: Self.pinKey) { d.set(0, forKey: Self.positionKey(name)) }

        item = Self.makeItem(name)
        super.init()
        attach()
        render()
    }

    // MARK: 오른쪽 끝 고정

    /// AppKit 이 autosaveName 항목의 위치를 저장하는 defaults 키(앱 도메인). 값은 메뉴 막대 오른쪽 끝에서의
    /// 거리(pt)로, 작을수록 오른쪽이다. 0 이면 제어 센터 바로 왼쪽까지 간다. 항목을 **만들 때만** 읽는다.
    private static func positionKey(_ name: String) -> String { "NSStatusItem Preferred Position \(name)" }

    /// 고정 옵션 on/off.
    private static let pinKey = "PinToRightEnd"
    /// 고정을 켜기 직전의 위치. 끌 때 그 자리로 되돌리려고 남긴다. 저장된 위치가 없었으면 -1.
    private static let prePinKey = "PositionBeforePin"

    /// 우클릭 메뉴의 체크 표시에 쓴다.
    var isPinnedToRight: Bool { UserDefaults.standard.bool(forKey: Self.pinKey) }

    /// 고정을 켜거나 끈다. 켜면 지금 바로 오른쪽 끝으로 옮기고, 끄면 켜기 전 자리로 되돌린다.
    func togglePinnedToRight() {
        let d = UserDefaults.standard
        let turningOn = !isPinnedToRight
        let posKey = Self.positionKey(autosaveName)

        let target: Double?
        if turningOn {
            // 되돌릴 자리를 남긴다. 저장된 위치가 아예 없었다면 -1 로 그 사실을 기록한다.
            d.set((d.object(forKey: posKey) as? Double) ?? -1, forKey: Self.prePinKey)
            target = 0
        } else if let before = d.object(forKey: Self.prePinKey) as? Double, before >= 0 {
            target = before
        } else {
            target = nil    // 켜기 전에도 정해진 자리가 없었다 → macOS 가 알아서 놓게 둔다
        }

        d.set(turningOn, forKey: Self.pinKey)
        rebuild(position: target) { [weak self] in
            self?.flashOK(turningOn ? "✓ 오른쪽 끝에 고정" : "고정 해제됨")
        }
    }

    /// 항목을 없애고 다시 만든다. AppKit 은 저장 위치를 **만들 때만** 읽기 때문이다.
    /// `position` 이 nil 이면 저장 위치를 지워 macOS 가 알아서 놓게 둔다.
    /// 우클릭 메뉴의 `performClick` 이 아직 스택에 있을 수 있어 한 턴 미룬 뒤 갈아 끼운다.
    private func rebuild(position: Double?, then completion: (() -> Void)? = nil) {
        let key = Self.positionKey(autosaveName)
        DispatchQueue.main.async { [self] in
            appearanceObserver = nil            // 옛 버튼을 보던 관찰자는 버린다
            NSStatusBar.system.removeStatusItem(item)
            if let p = position { UserDefaults.standard.set(p, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }

            item = Self.makeItem(autosaveName)  // 여기서 위치를 읽는다
            attach()
            render()
            completion?()

            // 실측(macOS 26): removeStatusItem 이 autosaveName 의 저장 키를 **한 박자 늦게** 지운다.
            // 새 항목은 이미 자리를 잡았지만 키가 사라져 다음 실행에 위치가 안 남는다. 다시 써 둔다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let p = position, UserDefaults.standard.object(forKey: key) == nil {
                    UserDefaults.standard.set(p, forKey: key)
                }
            }
        }
    }

    private static func makeItem(_ name: String) -> NSStatusItem {
        let it = NSStatusBar.system.statusItem(withLength: UI.itemLength)
        it.autosaveName = name
        it.isVisible = true
        return it
    }

    private func attach() {
        guard let b = item.button else { return }
        b.target = self
        b.action = #selector(clicked)
        // 기본값은 .leftMouseUp 뿐이다. 우클릭을 받으려면 명시해야 한다.
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // 색을 직접 칠하므로(아래 menuBarIsDark 참고) 메뉴 막대 외형이 바뀌면 다시 그려야 한다.
        appearanceObserver = b.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.render() }
        }
    }

    /// 메뉴 막대가 어두운가.
    ///
    /// 기준은 **상태 항목 버튼의** `effectiveAppearance` 다. 메뉴 막대는 라이트 모드에서도 배경화면이
    /// 어두우면 어둡게 그려지는데, 이 값이 그것까지 반영한다. `NSApp.effectiveAppearance` 를 보면
    /// 그 경우를 놓쳐서 흰 배경에 흰 아이콘을 그리게 된다.
    private func menuBarIsDark() -> Bool {
        guard let a = item.button?.effectiveAppearance else { return true }
        return a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    @objc private func clicked() {
        let ev = NSApp.currentEvent
        // 트랙패드에서는 컨트롤+클릭이 우클릭을 대신하므로 둘 다 메뉴로 보낸다.
        let wantsMenu = ev?.type == .rightMouseUp
            || (ev?.modifierFlags.contains(.control) ?? false)
        if wantsMenu { showMenu() } else { onClick() }
    }

    private func showMenu() {
        item.menu = buildMenu()
        item.button?.performClick(nil)   // 메뉴가 닫힐 때까지 반환하지 않는다
        item.menu = nil
    }

    func flashOK(_ tip: String, seconds: TimeInterval = 2) { setFlash(UI.symOK, tip, seconds) }
    func flashInfo(_ tip: String, seconds: TimeInterval = 3) { setFlash(UI.symInfo, tip, seconds) }
    func flashErr(_ tip: String, seconds: TimeInterval = 4) { setFlash(UI.symErr, tip, seconds) }

    private func setFlash(_ s: String, _ t: String, _ sec: TimeInterval) {
        // 잠깐 띄우는 피드백은 항상 템플릿이다 — 배경색을 따라가야 어느 외형에서도 읽힌다.
        flash = (IconLook(s, t), Date().addingTimeInterval(sec))
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.render() }
    }

    func render() {
        guard let b = item.button else { return }
        let look: IconLook
        if let f = flash, f.until > Date() {
            look = f.look
        } else {
            flash = nil
            look = state()
        }
        b.image = Self.image(for: look, onDark: menuBarIsDark())
        b.attributedTitle = NSAttributedString(string: "")   // 폭 고정 — 위 주석 참고
        b.toolTip = look.tip
    }

    private static func image(for look: IconLook, onDark: Bool) -> NSImage? {
        // 심볼 이름이 틀리거나 이 macOS 버전에 없어도 빈 칸이 되지 않도록 대체 아이콘을 둔다.
        guard let raw = NSImage(systemSymbolName: look.symbol, accessibilityDescription: look.tip)
                ?? NSImage(systemSymbolName: UI.symFallback, accessibilityDescription: look.tip)
        else { return nil }
        let base = raw.withSymbolConfiguration(.init(pointSize: UI.iconSide, weight: look.weight)) ?? raw

        // 비율을 지키면서 상자 안에 맞춘다.
        let s = base.size
        if s.width > 0, s.height > 0 {
            let k = min(UI.iconMaxWidth / s.width, UI.iconSide / s.height)
            base.size = NSSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
        }

        // 상태색이 없으면 메뉴 막대 배경에 맞는 흑/백으로 칠한다.
        //
        // 여기서 `isTemplate = true` 로 두면 macOS 가 알아서 흑백을 맞춰 주긴 하는데, 그리는 밝기가
        // 시스템 아이콘의 절반쯤밖에 안 된다. 같은 캡처에서 재 보면 시스템 아이콘 0.67, 템플릿 0.38이다
        // (macOS 26 실측). 옆에 나란히 두면 우리 것만 흐릿해 보여서 눈에 안 들어온다.
        // 색을 직접 칠하면 0.72 로 올라 시스템 아이콘과 같은 무게로 읽힌다.
        let tint = look.tint ?? (onDark ? NSColor.white : NSColor.black)

        // 색을 입힐 때 `SymbolConfiguration(hierarchicalColor:)` 를 쓰면 안 된다. 계층별로 투명도가
        // 달라져서 `record.circle`(링)과 `record.circle.fill`(꽉 찬 점)이 거의 같아 보인다.
        // 심볼을 그린 뒤 sourceAtop 으로 덮어 **단색**으로 만들어야 둘이 확실히 구분된다.
        let out = NSImage(size: base.size)
        let rect = NSRect(origin: .zero, size: base.size)
        out.lockFocus()
        base.draw(in: rect)
        tint.set()
        rect.fill(using: .sourceAtop)
        out.unlockFocus()
        out.isTemplate = false              // 템플릿이면 macOS 가 마스크로만 써서 색이 사라진다
        out.accessibilityDescription = look.tip
        return out
    }
}

// MARK: - 메뉴 조립 도우미

@discardableResult
func addItem(_ menu: NSMenu,
             _ title: String,
             target: AnyObject?,
             _ selector: Selector?,
             enabled: Bool = true,
             checked: Bool = false) -> NSMenuItem {
    let mi = NSMenuItem(title: title, action: selector, keyEquivalent: "")
    mi.target = target
    mi.isEnabled = enabled && selector != nil
    mi.state = checked ? .on : .off
    menu.addItem(mi)
    return mi
}

/// 세 앱이 똑같이 다는 "오른쪽 끝에 고정" 토글. 문구가 갈리지 않도록 여기에 둔다.
@discardableResult
func addPinRightItem(_ menu: NSMenu, _ icon: StatusIcon, target: AnyObject, _ selector: Selector) -> NSMenuItem {
    addItem(menu, "메뉴 막대 오른쪽 끝에 고정", target: target, selector, checked: icon.isPinnedToRight)
}

func addDisabledLine(_ menu: NSMenu, _ title: String) {
    let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    mi.isEnabled = false
    menu.addItem(mi)
}

// MARK: - 로그인 항목

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    // SMAppService.status 는 XPC 왕복이라 5~14ms 든다. 메뉴 구성 경로에서는 캐시를 쓴다.
    private static var cache: (at: Date, value: SMAppService.Status)?
    private static let ttl: TimeInterval = 30

    static func cachedStatus() -> SMAppService.Status {
        if let c = cache {
            if Date().timeIntervalSince(c.at) > ttl { refreshAsync() }
            return c.value
        }
        return refresh()
    }

    @discardableResult
    static func refresh() -> SMAppService.Status {
        let s = status
        cache = (Date(), s)
        return s
    }

    static func refreshAsync() {
        DispatchQueue.global(qos: .utility).async {
            let s = status
            DispatchQueue.main.async { cache = (Date(), s) }
        }
    }

    static func invalidate() { cache = nil }

    /// 성공하면 새 상태를 돌려준다. 실패는 던진다.
    @discardableResult
    static func toggle() throws -> Bool {
        if isEnabled {
            try SMAppService.mainApp.unregister()
            invalidate()
            return false
        }
        try SMAppService.mainApp.register()
        invalidate()
        return true
    }

    /// 메뉴에서 쓰는 공통 처리. 실패하면 설정 화면으로 보낸다.
    static func toggleFromMenu() {
        do {
            let on = try toggle()
            refresh()
            _ = on
        } catch {
            failAlert("로그인 항목을 변경하지 못했습니다",
                      "\(errText(error))\n\n시스템 설정 > 일반 > 로그인 항목에서 \(AppMeta.displayName)를 허용해 주세요.",
                      actionTitle: "설정 열기") {
                openURLString(UI.loginItemsURL, whatFailed: "로그인 항목 설정")
            }
        }
    }
}
