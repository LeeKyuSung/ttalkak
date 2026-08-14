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
    static let iconSide: CGFloat = 15

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
final class StatusIcon: NSObject {
    private let item: NSStatusItem

    /// 현재 상태의 (심볼, 툴팁). 상태는 앱이 소유하고, 아이콘은 그때그때 물어본다.
    var state: () -> (symbol: String, tip: String) = { (UI.symFallback, "") }
    /// 좌클릭 즉시 동작.
    var onClick: () -> Void = {}
    /// 우클릭·컨트롤클릭에서 띄울 메뉴.
    var buildMenu: () -> NSMenu = { NSMenu() }

    private var flash: (symbol: String, tip: String, until: Date)?

    override init() {
        item = NSStatusBar.system.statusItem(withLength: UI.itemLength)
        super.init()
        // autosaveName 이 없으면 macOS 가 익명 항목에 "Item-N" 을 배정하는데,
        // 이 시스템에는 이미 숨김으로 저장된 "Item-0" 이 있어 그 상태를 물려받을 수 있다.
        item.autosaveName = "\(Bundle.main.bundleIdentifier ?? "MacTools").status"
        item.isVisible = true
        if let b = item.button {
            b.target = self
            b.action = #selector(clicked)
            // 기본값은 .leftMouseUp 뿐이다. 우클릭을 받으려면 명시해야 한다.
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        render()
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
        flash = (s, t, Date().addingTimeInterval(sec))
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.render() }
    }

    func render() {
        guard let b = item.button else { return }
        let symbol: String
        let tip: String
        if let f = flash, f.until > Date() {
            symbol = f.symbol
            tip = f.tip
        } else {
            flash = nil
            (symbol, tip) = state()
        }
        // 심볼 이름이 틀려도 빈 칸이 되지 않도록 대체 아이콘을 둔다.
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            ?? NSImage(systemSymbolName: UI.symFallback, accessibilityDescription: tip)
        image?.isTemplate = true            // 없으면 한쪽 외형에서 아이콘이 보이지 않는다
        image?.size = NSSize(width: UI.iconSide, height: UI.iconSide)
        b.image = image
        b.attributedTitle = NSAttributedString(string: "")   // 폭 고정 — 위 주석 참고
        b.toolTip = tip
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
