# 딸깍 (ttalkak)

[English](README.md) · 한국어

한 가지 일만 하는 macOS 메뉴 막대 앱 세 개. **좌클릭하면 바로 실행된다.** 메뉴가 안 뜬다.

![메뉴 막대 아이콘](screenshots/menubar-icons.png)

| 앱 | 좌클릭하면 | 필요한 권한 |
| --- | --- | --- |
| 🔊 **AudioFix** (오디오 재시작) | `coreaudiod` 재시작 — 소리가 치직거리거나 출력 장치가 안 잡힐 때 | 관리자 암호 (1회 설정으로 생략 가능) |
| ◐ **ThemeToggle** (다크·라이트) | 시스템 외형 즉시 전환 | 자동화 (System Events) |
| 🎤 **MicRecorder** (녹음) | 녹음 시작 / 중지 | 마이크, 다운로드 폴더 |

**우클릭**(또는 컨트롤+클릭)하면 설정 메뉴가 열린다.

![우클릭 메뉴](screenshots/audiofix-menu.png)

아이콘이 곧 상태다. ThemeToggle은 현재 모드에 따라 해와 달이 바뀌고, MicRecorder는 대기 중이면 마이크,
녹음 중이면 빨간 점이다. 경과 시간과 안내 문구는 **툴팁과 우클릭 메뉴**에만 싣는다 — 메뉴 막대에 글자를
붙이면 아이콘이 밀려나 사라지기 때문이다. ([왜 그런지](docs/macos-notes.md#2-메뉴-막대가-꽉-차면-아이콘이-사라진다))

---

## 요구 사항

- macOS 14.0 이상 (Apple Silicon)
- Xcode 명령줄 도구 (`xcode-select --install`)

## 빌드와 설치

```bash
git clone https://github.com/LeeKyuSung/ttalkak.git
cd ttalkak
bash build.sh                    # 셋 다
bash build.sh MicRecorder        # 하나만

for a in AudioFix ThemeToggle MicRecorder; do
  ditto "build/$a.app" "/Applications/$a.app" && open "/Applications/$a.app"
done
```

`/Applications` 밑에 두는 게 중요하다. `/private/tmp` 같은 데서 실행하면 macOS가 권한을 기억하지 못한다.

각 앱의 우클릭 메뉴에서 **로그인 시 자동 실행**을 켜면 부팅 후 자동으로 뜬다.

### 서명

`Apple Development` 인증서가 있으면 자동으로 찾아 쓴다. 없으면 ad-hoc 서명으로 넘어가는데, 이 경우
**소스를 고칠 때마다 권한(마이크·자동화)이 초기화된다.** ad-hoc 서명은 코드 해시가 곧 앱의 신원이라
한 글자만 바꿔도 macOS가 다른 앱으로 보기 때문이다.

번들 ID를 바꾸려면:

```bash
BUNDLE_PREFIX=com.example bash build.sh
```

### 제거

앱을 종료하고 `/Applications`에서 지우면 된다. AudioFix의 sudoers 설정을 했다면
[docs/sudoers.md](docs/sudoers.md#손으로-되돌리기)를 보고 함께 되돌린다.

---

## 권한

앱이 셋으로 나뉘어 있어 권한도 앱별로 따로 허용해야 한다.

| 앱 | 권한 | 위치 | 언제 물어보나 |
| --- | --- | --- | --- |
| ThemeToggle | 자동화 → System Events | 설정 › 개인정보 보호 및 보안 › 자동화 | 첫 전환 클릭 |
| MicRecorder | 마이크 | 설정 › 개인정보 보호 및 보안 › 마이크 | 첫 녹음 클릭 |
| MicRecorder | 다운로드 폴더 | 설정 › 개인정보 보호 및 보안 › 파일 및 폴더 | 첫 저장 |
| AudioFix | 없음 (관리자 암호만) | — | — |

거부해도 조용히 실패하지 않는다. 해당 설정 화면으로 바로 가는 버튼이 붙은 안내가 뜬다.

마이크가 거부 상태로 굳어 설정에서 켜도 안 되면 한 번만:

```bash
tccutil reset Microphone kr.leekyusung.MicRecorder
```

---

## 녹음 파일

- 저장 위치: **`~/Downloads`**
- 파일명: `녹음_2026-08-14_101530.m4a` (같은 초에 겹치면 `-1`, `-2` … 접미사)
- 형식: AAC 모노 64 kbps `.m4a` — Whisper 계열에 그대로 넣을 수 있다

입력 장치는 우클릭 메뉴 › **입력 장치**에서 고르고 기억된다. 첫 실행 기본값은 **내장 마이크**다.
AirPods 같은 블루투스 기기를 입력으로 잡으면 HFP로 내려가 녹음 내내 출력 음질이 통화 수준으로 떨어진다.

안전장치:

- 녹음 중 앱을 종료하거나 로그아웃해도 파일을 정상 마무리한다 (안 하면 재생 불가 파일이 된다)
- 이어폰 연결이 끊겨도 그때까지 녹음된 부분은 재생 가능한 상태로 저장하고 원인을 알려준다
- 빠르게 두 번 눌러도 녹음이 두 개 생기지 않는다

---

## 비밀번호 없이 오디오 재시작 (선택)

기본값은 클릭할 때마다 관리자 암호를 묻는다. AudioFix 우클릭 메뉴의 **"비밀번호 없이 재시작 설정…"**
을 직접 누르면 규칙 파일 하나가 생기고, 이후로는 클릭 한 번으로 끝난다. **자동으로 설치되지 않는다.**

허용되는 것은 `killall coreaudiod` 딱 하나다. 인자까지 정확히 일치해야 하므로 다른 프로세스를 죽이는 데
쓸 수 없다. 설치 전에 실제 스크립트를 확인할 수 있다.

```bash
/Applications/AudioFix.app/Contents/MacOS/AudioFix --print-installer
```

sudoers를 잘못 만지면 sudo를 못 쓰게 되므로 백업·검증·롤백을 겹겹이 뒀다.
자세한 설계와 되돌리는 법은 [docs/sudoers.md](docs/sudoers.md)에 있다.

---

## 왜 `launchctl`이 아니라 `killall`인가

SIP가 켜져 있으면(기본값) 시스템 데몬에 대한 `launchctl` 조작이 통째로 막힌다.

```text
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
→ Could not kickstart service: 150: Operation not permitted while
  System Integrity Protection is engaged (150)
```

반면 root가 시그널을 보내는 것은 허용되고, `coreaudiod`는 launchd가 곧바로 되살린다.
AudioFix는 재시작 성공 여부를 **PID가 바뀌었는지**로 확인한다. 명령이 오류 없이 끝났어도 PID가 그대로면
"확인 불가"라고 알린다.

---

## 구조

```text
ttalkak/
├── Shared/Shared.swift          공통 — 프로세스 실행, 관리자 권한, 알림, 메뉴 막대 아이콘, 로그인 항목
├── AudioFix/AudioFix.swift
├── ThemeToggle/ThemeToggle.swift
├── MicRecorder/MicRecorder.swift
├── build.sh
└── docs/
    ├── macos-notes.md           만들면서 부딪힌 macOS 제약들
    └── sudoers.md               권한 설계와 되돌리는 법
```

의존성 없음. 각 앱은 `Shared.swift` + 자기 파일을 `swiftc` 한 번으로 컴파일한다.
Xcode 프로젝트도 SwiftPM도 쓰지 않는다.

`Shared.swift`의 `StatusIcon`이 클릭 구분을 담당한다. 핵심은 `statusItem.menu`를 **평상시 비워 두는**
것이다 — 메뉴를 계속 달아 두면 좌클릭도 메뉴를 열어버려 "즉시 실행"이 사라진다.

---

## 문서

- **[docs/macos-notes.md](docs/macos-notes.md)** — SIP, 노치 뒤로 사라지는 아이콘, TCC와 코드 서명,
  파이프 교착, 녹음 파일 마무리 등 만들면서 부딪힌 것들
- **[docs/sudoers.md](docs/sudoers.md)** — sudoers를 안전하게 건드리는 법

## 라이선스

MIT — [LICENSE](LICENSE)
