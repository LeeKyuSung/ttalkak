// ThemeToggle — 메뉴 막대에서 좌클릭 한 번으로 macOS 외형(다크/라이트)을 즉시 전환한다.
//
// 아이콘 자체가 현재 상태를 보여준다: 다크 모드면 달, 라이트 모드면 해.

import AppKit

// MARK: - 외형

enum AppearanceError: KoreanError {
    case notPermitted           // -1743
    case needsConsent           // -1744
    case systemEventsMissing    // -600
    case timedOut
    case launchFailed(String)
    case other(Int32, String)

    var description: String {
        switch self {
        case .notPermitted:        return "자동화 권한이 거부되었습니다 (-1743)"
        case .needsConsent:        return "아직 승인을 기다리는 중입니다 (-1744)"
        case .systemEventsMissing: return "System Events를 찾을 수 없습니다 (-600)"
        case .timedOut:            return "시간이 초과되었습니다"
        case .launchFailed(let m): return "osascript 실행 실패: \(m)"
        case .other(let c, let m): return m.isEmpty ? "오류 (\(c))" : m
        }
    }
}

/// 백그라운드 큐에서 채우고 `DispatchGroup.wait()` 로 동기화하기 위한 상자.
private final class ErrBox: @unchecked Sendable {
    var data = Data()
}

enum Appearance {
    /// 유일하게 신뢰할 수 있는 판정.
    /// `defaults read -g AppleInterfaceStyle` 는 쓰지 않는다 —
    /// 한 번이라도 write 되면 실제 외형과 무관하게 거짓말을 한다.
    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static let script =
        "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"

    static func errorCode(_ s: String) -> Int32 {
        guard let r = s.range(of: #"\(-?\d+\)"#, options: [.regularExpression, .backwards]) else { return 0 }
        return Int32(s[r].dropFirst().dropLast()) ?? 0
    }

    /// 백그라운드 스레드에서 호출할 것 (최대 `timeout` 만큼 블록한다).
    ///
    /// 인프로세스 NSAppleScript 가 아니라 서브프로세스를 쓴다:
    /// /usr/bin/osascript 는 권한 프롬프트를 띄울 수 있는 반면,
    /// 인프로세스 경로는 권한이 없으면 -1743 으로 즉시 하드 실패한다.
    static func toggle(timeout: TimeInterval = 10) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice   // 읽지 않을 파이프를 달면 버퍼가 차서 교착된다
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw AppearanceError.launchFailed("\(error)") }

        // stderr 는 종료를 기다리는 동안 **동시에** 비운다 (파이프 버퍼 교착 방지).
        let box = ErrBox()
        let readDone = DispatchGroup()
        readDone.enter()
        DispatchQueue.global(qos: .utility).async {
            box.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            readDone.leave()
        }

        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            p.waitUntilExit()
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = readDone.wait(timeout: .now() + 2)
            throw AppearanceError.timedOut
        }
        readDone.wait()
        let msg = String(decoding: box.data, as: UTF8.self)
        guard p.terminationStatus != 0 else { return }
        switch errorCode(msg) {
        case -1743: throw AppearanceError.notPermitted
        case -1744: throw AppearanceError.needsConsent
        case -600:  throw AppearanceError.systemEventsMissing
        case let c: throw AppearanceError.other(c, msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

// MARK: - AppDelegate

final class ThemeToggleDelegate: NSObject, NSApplicationDelegate {
    private var icon: StatusIcon!
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMeta.displayName = "다크·라이트"

        icon = StatusIcon()
        icon.state = {
            let dark = Appearance.isDark
            return (dark ? "moon.fill" : "sun.max.fill",
                    dark ? "다크 모드 — 클릭하면 라이트로" : "라이트 모드 — 클릭하면 다크로")
        }
        icon.onClick = { [weak self] in self?.toggle() }
        icon.buildMenu = { [weak self] in self?.menu() ?? NSMenu() }
        icon.render()   // init 시점에는 state 가 아직 비어 있어 기본 아이콘으로 그려진다. 여기서 다시 그린다.

        // 자동 전환(예약)이나 다른 앱이 외형을 바꿔도 아이콘이 따라가도록 관찰한다.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(themeChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil)

        DispatchQueue.global(qos: .utility).async { LoginItem.refreshAsync() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func themeChanged() {
        // 알림은 임의 스레드로 올 수 있고, 외형 반영에 한 박자가 걸린다.
        DispatchQueue.main.async { [weak self] in self?.icon.render() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.icon.render() }
    }

    // MARK: 전환

    private func toggle() {
        guard !busy else { return }
        busy = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try Appearance.toggle()
                DispatchQueue.main.async {
                    self.busy = false
                    // 전환 직후에는 effectiveAppearance 가 아직 갱신되기 전일 수 있다.
                    // 알림 관찰자가 최종 상태를 그려 주므로 여기서는 한 번만 그린다.
                    self.icon.render()
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.report(error)
                }
            }
        }
    }

    /// 메인 스레드 전용.
    private func report(_ e: Error) {
        switch e {
        case AppearanceError.needsConsent:
            // 승인 대화상자가 떠 있는 상태다. 모달을 띄우면 그 위를 덮어 버린다.
            icon.flashInfo("승인 대기 — ‘허용’을 눌러주세요", seconds: 6)

        case AppearanceError.notPermitted:
            icon.flashErr("권한 거부됨")
            failAlert("자동화 권한이 필요합니다",
                      "시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 "
                      + "‘다크·라이트’ 아래의 ‘System Events’를 켜주세요.",
                      actionTitle: "설정 열기") {
                openURLString(UI.automationSettingsURL, whatFailed: "자동화 설정")
            }

        case AppearanceError.systemEventsMissing:
            icon.flashErr("실패")
            failAlert("System Events를 찾을 수 없습니다",
                      "macOS의 System Events가 응답하지 않습니다. 로그아웃 후 다시 로그인하면 대개 복구됩니다.")

        default:
            icon.flashErr("실패")
            failAlert("외형을 전환하지 못했습니다", errText(e))
        }
    }

    // MARK: 메뉴 (우클릭)

    private func menu() -> NSMenu {
        let m = NSMenu()
        addDisabledLine(m, Appearance.isDark ? "현재: 다크 모드" : "현재: 라이트 모드")
        addDisabledLine(m, "좌클릭 = 즉시 전환")
        m.addItem(.separator())
        addItem(m, "로그인 시 자동 실행", target: self, #selector(toggleLogin),
                checked: LoginItem.cachedStatus() == .enabled)
        m.addItem(.separator())
        addItem(m, "종료", target: self, #selector(quit))
        return m
    }

    @objc private func toggleLogin() { LoginItem.toggleFromMenu() }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - 진입점

@main
enum ThemeToggleMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = ThemeToggleDelegate()
        app.delegate = delegate
        _ = delegate
        app.run()
    }
}
