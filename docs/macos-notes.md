# macOS 메뉴 막대 앱을 만들며 부딪힌 것들

세 앱을 만들면서 실제로 막혔던 지점과, 왜 지금 코드가 그렇게 생겼는지에 대한 기록.
전부 macOS 26.5.2 / Apple Silicon / SIP 켜짐 환경에서 직접 확인한 내용이다.

---

## 1. SIP가 켜져 있으면 `launchctl`로 시스템 데몬을 못 건드린다

CoreAudio 재시작을 처음에는 이렇게 구현했다.

```bash
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
```

깔끔해 보이지만 실행하면 이렇게 실패한다.

```text
Could not kickstart service "com.apple.audio.coreaudiod": 150:
Operation not permitted while System Integrity Protection is engaged (150)
```

SIP는 파일시스템 보호로만 알려져 있지만, **`system/` 도메인의 launchd 서비스 조작도 막는다.**
`kickstart`, `unload`, `kill` 전부 같은 150으로 막힌다. root라도 마찬가지다.

반면 root가 프로세스에 시그널을 보내는 것은 허용된다. `coreaudiod`는 launchd가 KeepAlive로
관리하므로 죽이면 즉시 되살아난다. 그래서 실제로 동작하는 경로는 결국 예전부터 쓰던 이것이다.

```bash
sudo killall coreaudiod
```

### 재시작을 "확인"하는 법

`killall`은 시그널만 보내고 끝나므로 종료 코드 0이 "재시작 성공"을 뜻하지 않는다.
확인하려면 **PID가 바뀌었는지**를 봐야 한다.

```swift
let before = pid()                  // pgrep -x coreaudiod
_ = run("/usr/bin/sudo", ["-n", "/usr/bin/killall", "coreaudiod"])
let ok = waitForRespawn(oldPid: before, timeout: 5)   // 새 PID가 뜰 때까지 폴링
```

launchd가 되살리는 데 잠깐 걸리므로 즉시 조회하면 아무것도 안 잡힌다. 짧은 간격으로 폴링해야 한다.

---

## 2. 메뉴 막대가 꽉 차면 아이콘이 "사라진다"

노치가 있는 MacBook Pro에서 상태 아이템이 조용히 안 보이는 일이 있다. 프로세스는 멀쩡히 살아 있다.

14" MacBook Pro 실측:

| 항목 | 값 |
| --- | --- |
| 화면 | 1512 × 982 pt |
| 노치 | 185 pt (663 ~ 848) |
| 노치 오른쪽 가용폭 | 664 pt |

`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`로 직접 잴 수 있다.

```swift
if let l = NSScreen.screens[0].auxiliaryTopLeftArea,
   let r = NSScreen.screens[0].auxiliaryTopRightArea {
    print("노치 폭: \(r.minX - l.maxX)")
}
```

노치 **오른쪽**에 자리가 없으면 macOS는 새 상태 아이템을 노치 **왼쪽**으로 밀어낸다.
그런데 그 자리는 앱 메뉴(파일·편집…)가 덮고 있어서 아이콘이 영영 보이지 않는다.
폭을 24 pt까지 줄인 최소 테스트 앱도 똑같이 밀려나는 것을 확인했다 — 앱이 더 작아져서 될 문제가 아니다.

### 그래서 지킨 규칙 두 가지

**폭을 고정한다.** 가변 폭이면 기본 37 pt가 되는데, 몇 pt 차이로 밀려날 수 있다.

```swift
let item = NSStatusBar.system.statusItem(withLength: 24)
```

**버튼에 제목을 절대 붙이지 않는다.** 경과 시간이나 피드백 문구를 제목으로 넣으면 그 순간 폭이 늘어나
아이콘이 밀려난다. 한 번 밀려나면 문구가 사라져도 돌아온다는 보장이 없다.

```swift
button.image = image                                   // 아이콘만
button.attributedTitle = NSAttributedString(string: "") // 항상 비움
button.toolTip = "녹음 중 03:21"                        // 정보는 여기로
```

경과 시간은 툴팁과 우클릭 메뉴 항목 제목에 싣는다. 피드백은 아이콘을 잠깐 다른 심볼로 바꿔서 준다
(체크 / 정보 / 경고). 심볼마다 고유 폭이 다르므로 `image.size`를 강제로 통일해야 폭이 안 흔들린다.

### 디버깅할 때

아이콘이 안 보이면 접근성 좌표로 밀려났는지 확인한다. 애플 메뉴보다 x가 작으면 노치 왼쪽으로 간 것이다.

```bash
osascript -e 'tell application "System Events" to tell process "AudioFix" \
  to get {position, size} of menu bar item 1 of menu bar 1'
osascript -e 'tell application "System Events" to tell process "Finder" \
  to get position of menu bar item 1 of menu bar 1'
```

> 주의: 이 좌표의 원점은 디스플레이 배치에 따라 바뀐다. 모니터가 여러 대면 절대값을 믿지 말고
> **같은 시점에 찍은 애플 메뉴 좌표와 비교**해야 한다. 이걸 몰라서 한참 헤맸다.

---

## 3. 좌클릭 즉시 실행 + 우클릭 메뉴

`statusItem.menu`를 설정해 두면 **좌클릭도 메뉴를 연다.** 액션은 영원히 안 불린다.
즉시 실행을 원하면 메뉴를 평상시 비워 두고, 우클릭일 때만 잠깐 붙였다 떼야 한다.

```swift
button.target = self
button.action = #selector(clicked)
button.sendAction(on: [.leftMouseUp, .rightMouseUp])   // 기본값은 .leftMouseUp 뿐

@objc private func clicked() {
    let ev = NSApp.currentEvent
    // 트랙패드에서는 컨트롤+클릭이 우클릭을 대신하므로 둘 다 메뉴로 보낸다
    let wantsMenu = ev?.type == .rightMouseUp
        || (ev?.modifierFlags.contains(.control) ?? false)
    if wantsMenu { showMenu() } else { onClick() }
}

private func showMenu() {
    item.menu = buildMenu()
    item.button?.performClick(nil)   // 메뉴가 닫힐 때까지 반환하지 않는다
    item.menu = nil
}
```

부작용 하나: 이 방식이면 접근성 API의 `AXShowMenu`로는 메뉴를 열 수 없다(평상시 메뉴가 없으므로).
자동화로 테스트하려면 `CGEvent`로 진짜 우클릭을 합성해야 한다.

```swift
CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
        mouseCursorPosition: pt, mouseButton: .right)?.post(tap: .cghidEventTap)
```

---

## 4. 상태 클로저는 아이콘 생성 뒤에 연결된다

`StatusIcon`을 만들면서 생성자 안에서 첫 렌더를 했더니, 앱이 상태 클로저를 연결하기 **전**이라
기본값(물음표 아이콘)으로 그려졌다. 앱 두 개가 메뉴 막대에 물음표로 떠 있었고, 한참 뒤에야 알아챘다.

```swift
icon = StatusIcon()
icon.state = { ... }
icon.onClick = { ... }
icon.render()   // ← 이게 없으면 물음표인 채로 남는다
```

심볼 이름을 잘못 적어도 똑같이 조용히 깨진다. `NSImage(systemSymbolName:)`은 없는 이름에 `nil`을
돌려주고, 그러면 버튼이 빈 칸이 된다. 대체 아이콘을 두면 최소한 "뭔가 잘못됐다"가 보인다.

---

## 5. TCC — 코드 서명이 권한보다 먼저다

### 마이크에는 엔타이틀먼트가 필요하다

Hardened Runtime(`--options runtime`)으로 서명하면서 `com.apple.security.device.audio-input`을
빼면, TCC는 **동의 대화상자조차 띄우지 않고 즉시 거부**한다. `requestAccess`가 0초 만에
`granted = false`로 돌아오고, 상태가 `.denied`로 굳는다. 이 상태에서는 시스템 설정에서 스위치를 켜도
소용없다. 거부 사유가 사용자가 아니라 코드 서명이기 때문이다.

한 번 굳으면 이걸로 초기화해야 한다.

```bash
tccutil reset Microphone <bundle-id>
```

### ad-hoc 서명은 빌드마다 새 앱이 된다

ad-hoc 서명(`--sign -`)은 designated requirement가 그냥 cdhash다. 소스를 한 글자만 고쳐도
macOS가 다른 앱으로 보고 **모든 TCC 권한이 초기화된다.** 개발 중에 매번 마이크를 다시 허용하게 된다.
개발 인증서가 있으면 그걸로 서명하는 편이 훨씬 낫다.

또 하나: `swiftc`가 링크하면서 실행 파일을 `Identifier=<실행파일명>`으로 미리 ad-hoc 서명해 둔다.
그래서 번들에 다시 서명할 때 `--identifier`로 번들 ID를 명시하지 않으면 `codesign --verify`가 실패한다.

### 자동화는 엔타이틀먼트가 필요 없다 — 대신 서브프로세스로

외형 전환은 System Events에 애플이벤트를 보내야 한다. 인프로세스 `NSAppleScript`로 하면 권한이 없을 때
프롬프트 없이 `-1743`으로 하드 실패한다. 반면 `/usr/bin/osascript`는 프롬프트를 띄울 권한을 갖고 있다.
그래서 서브프로세스로 돌린다.

```swift
Process()  // /usr/bin/osascript -e 'tell application "System Events" to ...'
```

권한 사전 점검(`AEDeterminePermissionToAutomateTarget`)은 **System Events가 실행 중이 아니면 항상
`-600`**을 돌려준다. 즉 평소에는 권한 여부를 알려주지 못한다. 이 값을 사용자에게 그대로 보여주면 안 된다.

---

## 6. `defaults read -g AppleInterfaceStyle`을 믿지 마라

다크 모드 판정에 흔히 쓰이지만 신뢰할 수 없다. 값이 없으면 라이트라는 뜻인데, 자동 전환을 쓰거나
누군가 한 번 `defaults write`를 했으면 실제 외형과 어긋난다. 실제로 이 값은 "Light"인데 시스템은
다크인 상태를 만났다.

앱 안에서는 이것만 믿으면 된다.

```swift
NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
```

외부에서 바뀌는 것(자동 전환·다른 앱)까지 따라가려면 알림을 관찰한다.

```swift
DistributedNotificationCenter.default().addObserver(
    self, selector: #selector(themeChanged),
    name: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
```

---

## 7. `do shell script`는 0이 아닌 종료 코드를 삼킨다

AppleScript의 `do shell script`는 셸이 0이 아닌 코드로 끝나면 **그걸 AppleScript 오류로 바꿔 버린다.**
그러면 stdout이 Swift 쪽에 도달하지 않는다. 스크립트 안에서 실패 원인을 구분해 봐야 소용이 없다.

그래서 관리자 권한으로 돌리는 스크립트는 **무조건 `exit 0`**으로 끝내고, 결과는 stdout 토큰으로만 알린다.

```bash
if ! do_something; then
  /bin/echo AUDIOFIX_ERR_WRITE
  exit 0            # exit 1 이면 이 echo 가 Swift 에 안 온다
fi
```

사용자 취소는 오류 번호 `-128`로 온다. 실패가 아니라 정상 흐름이므로 따로 처리한다.

인용 지옥도 피해야 한다. Swift 문자열 → AppleScript 문자열 → 셸, 3중으로 이스케이프가 겹친다.
스크립트 본문을 base64로 감싸면 메타문자가 아예 사라진다.

```swift
let b64 = Data(body.utf8).base64EncodedString()
return "/usr/bin/printf %s '\(b64)' | /usr/bin/base64 -D | /bin/bash"
```

---

## 8. 파이프 두 개를 순서대로 읽으면 교착한다

`Process`로 stdout을 EOF까지 다 읽고 나서 stderr를 읽으면, 출력이 많을 때 멈춘다.
자식이 stderr 파이프 버퍼(64KB)를 채운 채 write에서 블록되고, 부모는 stdout read에서 기다린다.

**두 파이프를 동시에 비워야 한다.**

```swift
let drain = DispatchGroup()
drain.enter()
DispatchQueue.global().async {
    box.data = e.fileHandleForReading.readDataToEndOfFile()
    drain.leave()
}
let od = o.fileHandleForReading.readDataToEndOfFile()
drain.wait()
p.waitUntilExit()
```

512KB를 stderr로 뿜는 프로그램으로 재현해서 확인했다. 순서대로 읽으면 영원히 안 끝난다.

읽지 않을 파이프를 달아 두는 것도 같은 이유로 위험하다. 안 쓸 거면 `FileHandle.nullDevice`를 준다.

---

## 9. 녹음 파일은 종료될 때 마무리해 줘야 한다

`AVCaptureAudioFileOutput`은 `stopRecording()` 뒤에 **비동기로** moov atom을 쓴다.
이걸 기다리지 않고 프로세스가 죽으면 파일은 헤더 없는 mdat 덩어리가 되어 사실상 복구가 불가능하다.

앱 종료와 로그아웃 두 경로를 모두 막아야 한다.

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard recorder.isRecording else { return .terminateNow }
    recorder.stop()
    return .terminateLater      // delegate 콜백에서 reply(toApplicationShouldTerminate:)
}
```

`.terminateLater`를 쓰면 마무리가 끝나지 않을 때 앱이 영영 안 닫히므로 감시 타이머가 필요하다.
로그아웃은 종료 애플이벤트보다 `NSWorkspace.willPowerOffNotification`이 먼저 올 수 있어 거기서도 멈춘다.
이 경로에서는 모달을 띄우면 안 된다 — 로그아웃이 막힌다.

### 중단돼도 파일은 살아 있을 수 있다

블루투스 이어폰 연결이 끊기는 것 같은 상황에서, AVFoundation은 오류를 주면서도 파일은 재생 가능한
상태로 남길 때가 있다. 이 키로 구분한다.

```swift
let playable = (error as NSError?)?
    .userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
```

`true`면 "중단됐지만 저장됐으니 지우지 마세요"라고 알려 줘야 한다. 그냥 실패로 처리하면
사용자가 멀쩡한 녹음을 지운다. 자주 보게 되는 코드는 -11808(장치 연결 끊김), -11807(디스크 가득),
-11811(파일 크기 한도), -11819(미디어 서비스 재설정).

---

## 10. 클릭 두 번을 막는 플래그가 필요하다

블루투스 마이크는 세션 시작에 수백 ms에서 수 초가 걸린다. 그 사이 `isRecording`은 아직 `false`라
사용자가 "안 눌렸나?" 하고 한 번 더 누르면 녹음이 두 개 시작되어 서로를 죽인다.

클릭 시점에 **메인 스레드에서 동기적으로** 세우는 플래그가 있어야 한다.

```swift
guard !isBusy else { return }
starting = true          // isRecording 은 한참 뒤에나 true 가 된다
sessionQueue.async { ... }
```

파일명도 초 단위로만 만들면 같은 초에 두 번 시작할 때 충돌한다
(`AVCaptureFileOutput`은 이미 존재하는 URL로의 시작을 실패시킨다). 접미사로 유일성을 보장한다.

---

## 11. `swiftc` 하나로 .app 번들 만들기

Xcode 프로젝트도 SwiftPM도 없이 만들 수 있다. `-framework` 플래그는 필요 없다 — `import`만으로
autolink된다.

```bash
swiftc -parse-as-library -O -whole-module-optimization \
  -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -module-name AudioFix \
  -o AudioFix.app/Contents/MacOS/AudioFix \
  Shared/Shared.swift AudioFix/AudioFix.swift
```

- `-parse-as-library`를 주면 `main.swift`라는 이름의 파일에서도 `@main`을 쓸 수 있다
  (최상위 코드가 없을 때만).
- 배포 타깃은 14.0 이상이어야 한다. `AVCaptureDevice.DeviceType.microphone`이 macOS 14부터다.
- `LSUIElement`를 `true`로 두면 `setActivationPolicy(.accessory)`를 호출할 필요가 없다.
- `NSMicrophoneUsageDescription`이 빠지면 TCC가 프로세스를 SIGABRT로 죽인다. 크래시로 나타나므로
  `plutil -lint`로 빌드 때 잡는 편이 낫다.
