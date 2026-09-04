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

---

## 12. 시스템이 이미 쓰는 글리프는 피한다

처음 고른 아이콘 셋은 스피커(`speaker.wave.2`), 해와 달(`sun.max.fill` / `moon.fill`),
마이크(`mic`)였다. 뜻은 맞는데 메뉴 막대에 올려놓으면 내 앱 아이콘이 **시스템 아이콘처럼 보인다.**

macOS가 자기 항목에 쓰고 있는 것들이라 그렇다.

| 내가 쓰려던 것 | macOS가 이미 쓰는 곳 |
| --- | --- |
| `moon.fill` | 집중 모드 |
| `mic` | "마이크 사용 중" 표시 |
| `speaker.wave.2` | 제어 센터 사운드 |
| `wifi`, `battery.*` | 말할 것도 없다 |

겹치면 두 가지를 잃는다. 눌러야 할 것을 못 찾고, 눌렀을 때 무슨 일이 생길지 짐작이 안 된다.

바꾼 셋은 이렇다. 실루엣이 서로 다르고(가로로 넓은 것 / 원 / 세로로 긴 것), 시스템 항목과도 겹치지 않는다.

| 앱 | 대기 | 동작 중 |
| --- | --- | --- |
| AudioFix | `speaker.badge.exclamationmark` (bold) | `arrow.triangle.2.circlepath` (bold) |
| ThemeToggle | `circle.lefthalf.filled` (라이트) | `circle.righthalf.filled` (다크) |
| MicRecorder | `mic.fill` | `record.circle.fill` (빨강) |

`mic.fill`은 위 표의 "피해야 할 것"에 걸리는 것처럼 보이지만 실제로는 겹치지 않는다. macOS의
"마이크 사용 중" 표시는 **녹음 중에만** 뜨고, 그때 이 아이콘은 이미 빨간 점이기 때문이다.

고를 때 확인한 것 세 가지.

**심볼이 이 배포 타깃에 있는지 확인한다.** `NSImage(systemSymbolName:)`은 없으면 `nil`을 주고
조용히 대체 아이콘으로 넘어간다. 개발 기기(macOS 26)에서는 멀쩡한데 14.0에서만 물음표가 뜨는 식이다.
`arrow.trianglehead.2.clockwise.rotate.90`이 그런 경우여서 구형인 `arrow.triangle.2.circlepath`로 바꿨다.

**정사각형으로 강제하지 않는다. 상자의 가로도 넉넉히 준다.** 심볼마다 고유 비율이 다르다.
`speaker.badge.exclamationmark`는 원본이 25×17이라 가로로 넓다. 상자를 18×15로 두면 **가로에 먼저
걸려서** 18×12가 되는데, 옆 아이콘들이 15pt인 자리에 혼자 12pt라 눈에 띄게 작아 보인다.
상자 가로를 22로 넓히면 22×15가 되어 세로를 다 쓴다. 항목 폭은 `statusItem(withLength: 24)`가
이미 고정하고 있으므로, 이미지가 커져도 항목이 밀려나지는 않는다.

```swift
let k = min(maxWidth / img.size.width, maxHeight / img.size.height)
img.size = NSSize(width: (img.size.width * k).rounded(),
                  height: (img.size.height * k).rounded())
```

**굵기(weight)를 올려도 아이콘이 커지지는 않는다.** 획만 두꺼워진다. 실제로 재 보면 효과가 작다.

| `speaker.badge.exclamationmark` | 맞춤 크기 | 칠해지는 픽셀 |
| --- | --- | --- |
| regular | 22×15 | 24.2 % |
| semibold | 22×15 | 24.8 % |
| bold | 22×15 | 26.9 % |

작아 보이는 문제는 굵기가 아니라 **상자 비율**과 **밝기**(13번)에서 온다. 굵기는 마지막에 조금
얹는 정도로만 쓴다.

---

## 13. 템플릿 이미지는 시스템 아이콘보다 흐리게 그려진다

두 가지가 걸렸다. 색이 아예 안 먹는 것, 그리고 흑백으로 두어도 시스템 아이콘보다 흐린 것.

### 색이 안 먹는다

README에는 "녹음 중에는 빨간 점"이라고 써 놓고 실제로는 몇 달 동안 빨갛지 않았다. 원인은 한 줄이다.

```swift
image.isTemplate = true   // macOS 가 이 이미지를 '모양'으로만 쓴다 — 색은 전부 버려진다
```

템플릿 이미지는 알파 채널만 쓰이고 색은 macOS가 배경(다크·라이트)에 맞춰 칠한다. 그래서 평소에는
이게 맞다. 색을 쓰려면 템플릿을 꺼야 하고, 그러면 **양쪽 외형에서 다 읽히는 색**을 직접 골라야 한다.
빨강은 괜찮고, 회색 계열은 한쪽에서 사라진다.

색을 입히는 방법도 함정이 있다. `SymbolConfiguration(hierarchicalColor:)`는 계층마다 투명도를
다르게 주기 때문에, `record.circle`(링)과 `record.circle.fill`(꽉 찬 점)이 **거의 같아 보인다.**
링과 점으로 상태를 구분하려던 게 무너진다.

단색으로 확실히 칠하려면 심볼을 그린 뒤 `sourceAtop`으로 덮는다.

```swift
let out = NSImage(size: base.size)
let rect = NSRect(origin: .zero, size: base.size)
out.lockFocus()
base.draw(in: rect)
tint.set()
rect.fill(using: .sourceAtop)   // 그려진 픽셀 위에만 색을 얹는다
out.unlockFocus()
out.isTemplate = false
```

### 흑백으로 둬도 흐리다

색 문제를 고치고 나서도 "눈에 잘 안 들어온다"가 남았다. 같은 스크린샷에서 픽셀 밝기를 재 보고
원인을 알았다. 배경이 0.19인 어두운 메뉴 막대에서:

| | 획 밝기 |
| --- | --- |
| 시스템 아이콘 (Wi-Fi, 제어 센터) | 0.67 |
| 우리 템플릿 아이콘 | 0.38 |
| 색을 직접 칠한 아이콘 | 0.72 |

배경을 빼고 보면 템플릿은 시스템 아이콘의 **40% 세기**로만 그려진다. 획을 굵게 해도 이건 안 바뀐다.
세션 시작 전 원본 코드에서도 같은 값이 나왔으니 원래부터 그랬던 것이고, 메뉴 막대에 있는 다른
서드파티 앱들도 같은 대역이었다.

그래서 템플릿을 끄고 흑/백을 직접 칠한다. 문제는 **어느 쪽을 칠할지 어떻게 아느냐**다.

**`NSApp.effectiveAppearance`를 보면 틀린다.** 메뉴 막대는 라이트 모드에서도 배경화면이 어두우면
어둡게 그려진다. 이 맥이 지금 그 상태다 — 시스템은 라이트 모드인데 메뉴 막대는 어둡다.
앱 외형을 기준으로 검정을 칠하면 어두운 메뉴 막대에 검정 아이콘이 되어 **완전히 사라진다.**

```swift
// 상태 항목 버튼의 외형을 봐야 한다. 템플릿 이미지가 흑백을 정할 때 쓰는 것과 같은 값이다.
let dark = item.button?.effectiveAppearance
    .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
```

`NSColor.labelColor` 같은 동적 색을 `contentTintColor`에 넣는 것도 안 된다. 그 색은 **앱** 외형에
맞춰 풀리기 때문에 위와 똑같이 검정이 된다. 실제로 해 보니 아이콘 밝기가 0.19까지 떨어져
배경과 구분이 안 됐다.

외형은 바뀔 수 있으므로 버튼의 `effectiveAppearance`를 관찰해서 다시 그린다.

```swift
appearanceObserver = button.observe(\.effectiveAppearance) { [weak self] _, _ in
    DispatchQueue.main.async { self?.render() }
}
```

> **한계 하나.** 색을 구워 넣은 이미지는 하나뿐이라, 디스플레이 두 대의 메뉴 막대 외형이 서로 다르면
> (라이트 모드에서 한쪽 배경화면만 어두운 경우) 한쪽에만 맞는다. 템플릿은 이 경우도 알아서 처리하지만
> 대신 항상 흐리다. 둘 다 어두운 게 보통이라 밝기 쪽을 택했다.

잠깐 띄우는 피드백(체크 / 정보 / 경고)도 같은 규칙으로 그린다. 상태색(빨강)만 외형과 무관하게 고정이다.

---

## 14. 상태 항목을 오른쪽 끝에 고정하는 옵션 만들기

2번에서 본 대로, 항목이 넘치면 macOS는 **왼쪽부터** 지운다. 노치 맥에서 외장 모니터를 빼면
내장 화면 폭이 확 줄어드는데, 이때 살아남는 자리는 오른쪽 끝(제어 센터 옆)뿐이다.
녹음 표시처럼 "지금 켜져 있다"를 알려야 하는 항목은 거기 있어야 한다.

세 앱 모두 우클릭 메뉴에 켜고 끄는 토글로 넣었다. 켜면 매 실행마다 오른쪽 끝으로 가고,
끄면 켜기 전 자리로 돌아간다.

위치는 `autosaveName`을 기준으로 앱 도메인 defaults에 저장된다.

```
NSStatusItem Preferred Position <autosaveName>
```

값은 **메뉴 막대 오른쪽 끝에서의 거리(pt)**다. 작을수록 오른쪽이고, 0이면 갈 수 있는 가장 오른쪽이다.

```bash
defaults read kr.leekyusung.MicRecorder
# "NSStatusItem Preferred Position kr.leekyusung.MicRecorder.status" = 0;
```

여기서 걸리는 게 넷 있다.

**AppKit은 이 값을 항목을 만들 때만 읽는다.** 이미 떠 있는 항목의 defaults를 바꿔 봐야 안 움직인다.
옮기려면 항목을 없애고 다시 만들어야 한다.

**`removeStatusItem`이 저장 키를 한 박자 늦게 지운다.** 없애고 → 0을 쓰고 → 새로 만들면 새 항목은
제대로 오른쪽에 앉는데, 그 직후 옛 항목의 정리 작업이 키를 지워 버린다. 화면은 멀쩡하고 다음 실행에만
위치가 안 남는다. 잠깐 뒤에 키가 비었으면 다시 써 두는 것으로 해결했다.

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    if UserDefaults.standard.object(forKey: key) == nil {
        UserDefaults.standard.set(0, forKey: key)
    }
}
```

**끌 때 되돌릴 자리를 미리 남겨 둔다.** 켜는 순간 저장 위치를 0으로 덮어쓰기 때문에, 그전 값을
따로 적어 두지 않으면 껐을 때 갈 곳이 없다. 저장된 위치가 아예 없었던 경우도 구분해야 해서
그때는 -1로 표시하고, 끌 때 위치 키를 지워 macOS가 알아서 놓게 한다.

```swift
if turningOn {
    d.set((d.object(forKey: posKey) as? Double) ?? -1, forKey: prePinKey)
    target = 0
} else if let before = d.object(forKey: prePinKey) as? Double, before >= 0 {
    target = before
} else {
    target = nil    // 위치 키를 지운다
}
```

**옵션이 꺼져 있으면 위치에 손대지 않는다.** ⌘드래그로 옮겨 둔 자리를 앱이 실행할 때마다 되돌리면
그냥 고장 난 앱이다. 실행 시 강제 배치는 옵션이 켜져 있을 때만 한다.

```swift
if d.object(forKey: pinKey) == nil { d.set(pinDefault, forKey: pinKey) }
if d.bool(forKey: pinKey) { d.set(0, forKey: positionKey(name)) }   // 항목을 만들기 전에
```

실측으로 확인한 동작(macOS 26, 외장 모니터 연결 상태):

| 조작 | 위치 | 저장값 |
| --- | --- | --- |
| 켜기 | 321 → 1226 | `PinToRightEnd=1`, `PositionBeforePin=1158` |
| 끄기 | 1226 → 321 | `PinToRightEnd=0`, 위치 키 1158로 복원 |
| 켠 채로 재실행 | 오른쪽 끝 유지 | 그대로 |

> 검증할 때는 접근성 좌표를 쓰되 **같은 시점의 제어 센터 좌표와 비교**한다(2번의 주의 참고).
> 화면이 여러 대면 항목이 어느 디스플레이 기준으로 보고되는지가 상황에 따라 달라진다.
