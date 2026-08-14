// AudioFix — 메뉴 막대에서 좌클릭 한 번으로 CoreAudio(coreaudiod)를 재시작한다.
//
// 소리가 치직거리거나 AirPods Max 같은 출력 장치가 잡히지 않을 때 쓰는 도구다.
//
// 왜 launchctl 이 아니라 killall 인가:
//   sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
// 는 SIP 가 켜진 macOS 에서 다음으로 실패한다.
//   Could not kickstart service "com.apple.audio.coreaudiod": 150:
//   Operation not permitted while System Integrity Protection is engaged (150)
// SIP 는 시스템 데몬에 대한 launchctl 조작을 막는다. 반면 root 가 SIGTERM 을 보내는 것은 허용되고,
// coreaudiod 는 launchd 가 KeepAlive 로 즉시 되살리므로 killall 이 실제로 동작하는 경로다.

import AppKit

// MARK: - CoreAudio

enum CAError: KoreanError {
    case notFound
    case notPermitted(String)
    case commandFailed(Int32, String)
    case unverified

    var description: String {
        switch self {
        case .notFound:            return "coreaudiod 프로세스를 찾을 수 없습니다"
        case .notPermitted(let m): return m.isEmpty ? "권한이 거부되었습니다" : m
        case .commandFailed(let c, let m): return m.isEmpty ? "명령이 실패했습니다 (\(c))" : m
        case .unverified:          return "재시작 여부를 확인하지 못했습니다"
        }
    }
}

enum CA {
    static let killall = "/usr/bin/killall"
    static let processName = "coreaudiod"
    static let sudoersFile = "/etc/sudoers.d/audiofix-coreaudio"

    /// 사용자가 터미널에 직접 붙여 넣을 수 있는 형태.
    static let manualCommand = "sudo killall coreaudiod"

    // MARK: PID 확인

    /// 현재 coreaudiod 의 PID. 재시작 성공 여부는 "PID 가 바뀌었는가" 로만 확실히 알 수 있다.
    static func pid() -> String? {
        let r = run("/usr/bin/pgrep", ["-x", processName])
        let v = r.outTrimmed
        return (r.code == 0 && !v.isEmpty) ? v : nil
    }

    /// launchd 가 되살릴 때까지 짧게 기다린다. 백그라운드 스레드 전용.
    /// 이전 PID 를 모르면(nil) "새로 떠 있기만 하면 성공" 으로 완화해서 본다.
    static func waitForRespawn(oldPid: String?, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            guard let now = pid() else { continue }   // 아직 안 떴다
            if let old = oldPid {
                if now != old { return true }
            } else {
                return true
            }
        }
        return false
    }

    // MARK: 실행

    /// 암호 없이 시도. 결과 전체를 돌려준다 —
    /// "sudo 가 거부했다" 와 "sudo 는 통과했는데 killall 이 실패했다" 는 완전히 다른 상황이다.
    static func killNoPrompt() -> ProcResult {
        run("/usr/bin/sudo", ["-n", killall, processName])
    }

    /// sudo 자체가 거부한 것인가?
    /// sudo 의 진단은 모두 "sudo:" 로 시작한다. killall 의 오류 메시지는 그렇지 않다.
    static func sudoRefused(_ r: ProcResult) -> Bool {
        if r.code == 0 { return false }
        if r.code == -1 { return true }                       // sudo 실행 자체 실패
        for line in r.err.split(separator: "\n") where line.hasPrefix("sudo:") { return true }
        // 아무 말도 없으면 판단 근거가 없으니 인증 문제로 본다.
        return r.errTrimmed.isEmpty
    }

    /// killall 이 실행은 됐는데 실패한 경우의 원인 분류.
    static func classify(_ r: ProcResult) -> CAError {
        let m = r.errTrimmed
        let lower = m.lowercased()
        if lower.contains("no matching processes") { return .notFound }
        if lower.contains("operation not permitted") || lower.contains("not permitted") {
            return .notPermitted("SIP 또는 권한 문제로 거부되었습니다.\n\(m)")
        }
        return .commandFailed(r.code, m)
    }

    /// 관리자 인증 대화상자 1회. 메인 스레드 전용.
    static func killWithPrompt() throws {
        _ = try admin([killall, processName].map(shq).joined(separator: " "))
    }

    // MARK: 무인증 상태 확인

    static func rulePresent() -> Bool {
        FileManager.default.fileExists(atPath: sudoersFile)
    }

    /// 서명된 .app 안에서 제어 터미널 없이 도는 `sudo -n` 은 셸에서보다 느리다(약 60ms).
    /// 메뉴를 열 때마다 동기로 부르면 안 된다 — `passwordlessCached()` 를 쓸 것.
    static func passwordless() -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/true"]).code == 0
    }

    private static var probeCache: (at: Date, value: Bool)?
    private static let probeTTL: TimeInterval = 30

    static func passwordlessCached() -> Bool {
        if let c = probeCache {
            if Date().timeIntervalSince(c.at) > probeTTL { refreshProbeAsync() }
            return c.value
        }
        return refreshProbe()
    }

    @discardableResult
    static func refreshProbe() -> Bool {
        let v = passwordless()
        probeCache = (Date(), v)
        return v
    }

    static func refreshProbeAsync() {
        DispatchQueue.global(qos: .utility).async {
            let v = passwordless()
            DispatchQueue.main.async { probeCache = (Date(), v) }
        }
    }

    static func invalidateProbe() { probeCache = nil }

    // MARK: sudoers 설치 스크립트
    //
    // 설계 규칙 (하나라도 어기면 sudo 전체가 깨질 수 있다):
    //
    //  1) 종료 코드로 실패를 알리지 않는다. AppleScript 의 `do shell script` 는 0 이 아닌 종료를
    //     AppleScript 오류로 바꿔 버려서 stdout 이 Swift 쪽에 도달하지 않는다. 항상 exit 0.
    //  2) /etc 는 private/etc 심볼릭 링크다. Apple 이 출하하는 /etc/sudoers 는 includedir 를
    //     **물리 경로**(`#includedir /private/etc/sudoers.d`)로 적어 둔다. 한쪽 표기만 검사하면
    //     "includedir 없음" 으로 오판해 두 번째 줄을 덧붙이고, 같은 디렉터리를 두 번 읽게 되어
    //     `duplicate Cmnd_Alias` 로 /etc/sudoers 전체가 파싱 불능이 된다 (= sudo 사용 불가).
    //  3) 개별 조각만 `visudo -cf` 하는 것으로는 부족하다. 조각 단독으로는 통과해도 조립된
    //     전체 설정에서는 실패할 수 있다. 반드시 마지막에 `visudo -cf /etc/sudoers` 로
    //     (includedir 를 따라 들어가는) 전체 검증을 하고, 실패하면 백업으로 되돌린다.
    //
    // 주의: Swift 의 """ 리터럴도 백슬래시 이스케이프를 처리한다.
    // grep 정규식의 `\.` 는 `\\.` 로 써야 셸에 `\.` 가 도달한다.
    private static let installerTemplate = """
    set -eu
    SUDOERS_D=/etc/sudoers.d
    SUDOERS_MAIN=/etc/sudoers
    RULE="$SUDOERS_D/audiofix-coreaudio"
    # 점으로 시작하므로 @includedir 가 읽지 않는다. 해제 시 되돌릴 대상을 기록하는 표식.
    STAMP="$SUDOERS_D/.audiofix-includedir-added"
    BAK="$SUDOERS_MAIN.audiofix.bak"
    USER_NAME="__AUDIOFIX_USER__"

    MTMP=""
    TMP=""
    cleanup() {
      if [ -n "$MTMP" ]; then /bin/rm -f "$MTMP"; fi
      if [ -n "$TMP" ]; then /bin/rm -f "$TMP"; fi
    }
    trap cleanup EXIT

    ADDED_INCLUDE=0

    # 어떤 실패든 이 백업으로 되돌린다. 백업을 못 만들면 아무것도 건드리지 않는다.
    if ! /bin/cp -p "$SUDOERS_MAIN" "$BAK"; then
      /bin/echo AUDIOFIX_ERR_BACKUP
      exit 0
    fi

    # /etc 와 /private/etc 두 표기를 모두 인정한다 (위 설계 규칙 2 참고).
    if ! /usr/bin/grep -qE '^[[:space:]]*[#@]includedir[[:space:]]+/(private/)?etc/sudoers\\.d[[:space:]]*$' "$SUDOERS_MAIN"; then
      MTMP="$(/usr/bin/mktemp /tmp/.afsudoers.XXXXXX)"
      /bin/cat "$SUDOERS_MAIN" > "$MTMP"
      /bin/echo '@includedir /etc/sudoers.d' >> "$MTMP"
      if ! /usr/sbin/visudo -cf "$MTMP" >/dev/null 2>&1; then
        /bin/echo AUDIOFIX_ERR_INCLUDEDIR
        exit 0
      fi
      # mv 가 아니라 cat 리다이렉트 — /etc/sudoers 의 inode/소유자/모드를 보존한다.
      # 쓰기가 중간에 실패하면(디스크 가득 참 등) 파일이 잘린 상태로 남으므로 즉시 되돌린다.
      if ! /bin/cat "$MTMP" > "$SUDOERS_MAIN"; then
        /bin/cat "$BAK" > "$SUDOERS_MAIN" || true
        /bin/rm -f "$MTMP"
        MTMP=""
        /bin/rm -f "$BAK"
        /bin/echo AUDIOFIX_ERR_WRITE
        exit 0
      fi
      /bin/rm -f "$MTMP"
      MTMP=""
      /usr/bin/touch "$STAMP"
      /bin/chmod 0600 "$STAMP"
      ADDED_INCLUDE=1
    fi

    /bin/mkdir -p "$SUDOERS_D"

    # 임시 파일을 /etc/sudoers.d 안에, 점으로 시작하는 이름으로 만든다:
    #  - 같은 파일시스템이라 mv 가 원자적 rename() 이 되고
    #  - 점으로 시작하므로 쓰다 만 상태에서도 sudo 가 절대 읽지 않는다.
    TMP="$(/usr/bin/mktemp "$SUDOERS_D/.audiofix.XXXXXX")"
    /bin/cat > "$TMP" <<RULEEOF
    # AudioFix - restart coreaudiod without a password.
    # Managed by AudioFix. Delete this file to revoke.
    Cmnd_Alias AUDIOFIX_KILL = /usr/bin/killall coreaudiod
    Cmnd_Alias AUDIOFIX_PROBE = /usr/bin/true ""
    $USER_NAME ALL=(root) NOPASSWD: AUDIOFIX_KILL, AUDIOFIX_PROBE
    RULEEOF

    # visudo -cf 는 소유자/모드를 따지지 않으므로 chown 전에 검증한다.
    if ! /usr/sbin/visudo -cf "$TMP" >/dev/null 2>&1; then
      /bin/rm -f "$TMP"
      TMP=""
      if [ "$ADDED_INCLUDE" = "1" ]; then
        /bin/cat "$BAK" > "$SUDOERS_MAIN"
        /bin/rm -f "$STAMP"
      fi
      /bin/rm -f "$BAK"
      /bin/echo AUDIOFIX_ERR_VISUDO
      exit 0
    fi
    /usr/sbin/chown root:wheel "$TMP"
    /bin/chmod 0440 "$TMP"
    /bin/mv -f "$TMP" "$RULE"
    TMP=""

    # 조립된 전체 설정 검증. visudo 는 @includedir 를 따라 들어가므로
    # 중복 include, 이름이 겹치는 Cmnd_Alias 등 조각 단독 검사로는 못 잡는 문제를 여기서 잡는다.
    if ! /usr/sbin/visudo -cf "$SUDOERS_MAIN" >/dev/null 2>&1; then
      /bin/rm -f "$RULE"
      /bin/cat "$BAK" > "$SUDOERS_MAIN"
      if [ "$ADDED_INCLUDE" = "1" ]; then /bin/rm -f "$STAMP"; fi
      /bin/rm -f "$BAK"
      /bin/echo AUDIOFIX_ERR_ROLLBACK
      exit 0
    fi

    /bin/rm -f "$BAK"
    /bin/echo AUDIOFIX_OK
    """

    /// 해제 스크립트. 규칙 파일뿐 아니라 **설치 때 우리가 덧붙인 @includedir 줄까지** 되돌린다
    /// (표식 파일이 있을 때만. 원래 있던 줄은 절대 건드리지 않는다).
    private static let uninstallerTemplate = """
    set -eu
    SUDOERS_D=/etc/sudoers.d
    SUDOERS_MAIN=/etc/sudoers
    RULE="$SUDOERS_D/audiofix-coreaudio"
    STAMP="$SUDOERS_D/.audiofix-includedir-added"
    BAK="$SUDOERS_MAIN.audiofix-undo.bak"

    UTMP=""
    cleanup() { if [ -n "$UTMP" ]; then /bin/rm -f "$UTMP"; fi; }
    trap cleanup EXIT

    /bin/rm -f "$RULE"

    if [ -f "$STAMP" ]; then
      UTMP="$(/usr/bin/mktemp /tmp/.afsudoers.XXXXXX)"
      /bin/cp -p "$SUDOERS_MAIN" "$BAK"
      /usr/bin/grep -vE '^[[:space:]]*@includedir[[:space:]]+/etc/sudoers\\.d[[:space:]]*$' "$SUDOERS_MAIN" > "$UTMP" || true
      if [ -s "$UTMP" ]; then
        /bin/cat "$UTMP" > "$SUDOERS_MAIN"
        if /usr/sbin/visudo -cf "$SUDOERS_MAIN" >/dev/null 2>&1; then
          /bin/rm -f "$STAMP" "$BAK"
        else
          /bin/cat "$BAK" > "$SUDOERS_MAIN"
          /bin/rm -f "$BAK"
          /bin/echo AUDIOFIX_ERR_ROLLBACK
          exit 0
        fi
      else
        /bin/rm -f "$BAK"
      fi
    fi

    /bin/echo AUDIOFIX_OK
    """

    static func installerBody() -> String {
        installerTemplate.replacingOccurrences(of: "__AUDIOFIX_USER__", with: NSUserName())
    }

    static func uninstallerBody() -> String { uninstallerTemplate }

    static func installerOneLiner() -> String { base64OneLiner(installerBody()) }
    static func uninstallerOneLiner() -> String { base64OneLiner(uninstallerBody()) }

    /// 설치/해제 스크립트가 돌려준 토큰을 한국어로.
    static func tokenMessage(_ out: String) -> String? {
        if out.contains("AUDIOFIX_OK") { return nil }
        if out.contains("AUDIOFIX_ERR_BACKUP") {
            return "/etc/sudoers 백업을 만들지 못해 아무것도 변경하지 않았습니다."
        }
        if out.contains("AUDIOFIX_ERR_INCLUDEDIR") {
            return "/etc/sudoers 에 includedir 줄을 추가하면 문법 검사에 실패하여 중단했습니다."
        }
        if out.contains("AUDIOFIX_ERR_WRITE") {
            return "/etc/sudoers 에 쓰지 못해 원본으로 되돌렸습니다."
        }
        if out.contains("AUDIOFIX_ERR_VISUDO") {
            return "규칙 파일이 sudoers 문법 검사를 통과하지 못해 설치를 취소했습니다."
        }
        if out.contains("AUDIOFIX_ERR_ROLLBACK") {
            return "전체 sudoers 설정 검증에 실패하여 원래 상태로 되돌렸습니다."
        }
        return "알 수 없는 결과입니다.\n\(out)"
    }
}

// MARK: - AppDelegate

final class AudioFixDelegate: NSObject, NSApplicationDelegate {
    private var icon: StatusIcon!
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMeta.displayName = "오디오 재시작"

        icon = StatusIcon()
        icon.state = { [weak self] in
            let busy = self?.busy ?? false
            return ("speaker.wave.2",
                    busy ? "오디오 재시작 중…" : "오디오 재시작 — 클릭하면 바로 실행")
        }
        icon.onClick = { [weak self] in self?.restart() }
        icon.buildMenu = { [weak self] in self?.menu() ?? NSMenu() }
        icon.render()   // init 시점에는 state 가 아직 비어 있어 기본 아이콘으로 그려진다. 여기서 다시 그린다.

        // 첫 클릭이 프로브 때문에 늦어지지 않도록 미리 데워 둔다.
        DispatchQueue.global(qos: .utility).async {
            CA.refreshProbeAsync()
            LoginItem.refreshAsync()
        }
    }

    // MARK: 재시작

    private func restart() {
        guard !busy else { return }
        busy = true
        icon.render()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let before = CA.pid()
            let r = CA.killNoPrompt()

            if r.code == 0 {
                self.verify(before: before)
                return
            }
            if CA.sudoRefused(r) {
                // 관리자 대화상자는 반드시 메인 스레드에서.
                DispatchQueue.main.async { self.promptAndKill(before: before) }
            } else {
                let e = CA.classify(r)
                DispatchQueue.main.async { self.fail(e) }
            }
        }
    }

    /// 메인 스레드 전용.
    private func promptAndKill(before: String?) {
        do {
            try CA.killWithPrompt()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.verify(before: before)
            }
        } catch AdminError.userCancelled {
            busy = false
            icon.flashInfo("취소됨")
            if !CA.rulePresent() {
                // 왜 암호를 물었는지, 어떻게 없앨 수 있는지 한 번 알려 준다.
                icon.flashInfo("취소됨 — 우클릭 메뉴에서 ‘비밀번호 없이 재시작 설정’을 쓸 수 있습니다", seconds: 5)
            }
        } catch {
            busy = false
            fail(error)
        }
    }

    /// 백그라운드 스레드 전용. PID 가 바뀌었는지로 실제 재시작을 확인한다.
    private func verify(before: String?) {
        let ok = CA.waitForRespawn(oldPid: before)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.busy = false
            CA.refreshProbeAsync()
            if ok {
                self.icon.flashOK("✓ 오디오 재시작됨")
            } else {
                self.icon.flashErr("확인 불가")
                failAlert("재시작 여부를 확인하지 못했습니다",
                          "명령은 오류 없이 끝났지만 coreaudiod 가 다시 뜬 것을 확인하지 못했습니다.\n"
                          + "소리가 여전히 이상하면 터미널에서 직접 실행해 보세요.\n\n\(CA.manualCommand)",
                          actionTitle: "명령 복사") { copyToPasteboard(CA.manualCommand) }
            }
        }
    }

    /// 메인 스레드 전용.
    private func fail(_ e: Error) {
        busy = false
        icon.flashErr("실패")
        failAlert("오디오 재시작 실패",
                  "\(errText(e))\n\n터미널에서 직접 실행해 보세요:\n\(CA.manualCommand)",
                  actionTitle: "명령 복사") { copyToPasteboard(CA.manualCommand) }
    }

    // MARK: 메뉴 (우클릭)

    private func menu() -> NSMenu {
        let m = NSMenu()

        addDisabledLine(m, "좌클릭 = 즉시 재시작")
        m.addItem(.separator())

        if CA.rulePresent() {
            addItem(m, "비밀번호 없이 재시작 해제…", target: self, #selector(uninstallRule))
        } else {
            addItem(m, "비밀번호 없이 재시작 설정…", target: self, #selector(installRule))
        }

        m.addItem(.separator())
        addItem(m, "로그인 시 자동 실행", target: self, #selector(toggleLogin),
                checked: LoginItem.cachedStatus() == .enabled)
        m.addItem(.separator())
        addItem(m, "종료", target: self, #selector(quit))
        return m
    }

    @objc private func installRule() {
        let ok = failAlert("비밀번호 없이 재시작을 설정할까요?",
                           "관리자 암호를 한 번 입력하면 /etc/sudoers.d/audiofix-coreaudio 파일이 만들어지고,\n"
                           + "이후에는 클릭 한 번으로 바로 재시작됩니다.\n\n"
                           + "이 규칙은 ‘killall coreaudiod’ 딱 하나만 암호 없이 허용합니다.\n"
                           + "언제든 메뉴에서 해제할 수 있습니다.",
                           actionTitle: "설정",
                           closeTitle: "취소") { [weak self] in self?.runInstaller() }
        _ = ok
    }

    private func runInstaller() {
        do {
            let out = try admin(CA.installerOneLiner())
            CA.invalidateProbe()
            CA.refreshProbe()
            if let msg = CA.tokenMessage(out) {
                failAlert("설정하지 못했습니다", msg)
            } else {
                icon.flashOK("✓ 설정됨")
            }
        } catch AdminError.userCancelled {
            icon.flashInfo("취소됨")
        } catch {
            failAlert("설정하지 못했습니다", errText(error))
        }
    }

    @objc private func uninstallRule() {
        guard CA.rulePresent() else {
            icon.flashInfo("규칙 없음")
            return
        }
        do {
            let out = try admin(CA.uninstallerOneLiner())
            CA.invalidateProbe()
            let stillPasswordless = CA.refreshProbe()
            if let msg = CA.tokenMessage(out) {
                failAlert("해제하지 못했습니다", msg)
                return
            }
            if stillPasswordless {
                // 우리 규칙은 지웠는데 여전히 통과한다면 다른 곳에 NOPASSWD 설정이 있다는 뜻이다.
                failAlert("해제했지만 여전히 암호 없이 실행됩니다",
                          "AudioFix 가 만든 규칙은 제거했습니다.\n"
                          + "다른 sudoers 설정에서 NOPASSWD 가 허용되어 있는 것으로 보입니다.")
            } else {
                icon.flashOK("✓ 해제됨")
            }
        } catch AdminError.userCancelled {
            icon.flashInfo("취소됨")
        } catch {
            failAlert("해제하지 못했습니다", errText(error))
        }
    }

    @objc private func toggleLogin() { LoginItem.toggleFromMenu() }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - 진입점

@main
enum AudioFixMain {
    static func main() {
        // 디버깅용: 앱이 실제로 만들어내는 셸 스크립트를 그대로 출력하고 끝낸다. 아무것도 실행하지 않는다.
        let args = CommandLine.arguments
        if args.contains("--print-installer") {
            print(CA.installerBody())
            return
        }
        if args.contains("--print-uninstaller") {
            print(CA.uninstallerBody())
            return
        }

        let app = NSApplication.shared
        let delegate = AudioFixDelegate()
        app.delegate = delegate
        _ = delegate       // 델리게이트는 약참조로 잡히므로 살려 둔다
        app.run()
    }
}
