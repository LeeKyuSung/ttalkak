# 비밀번호 없이 오디오 재시작 — sudoers 설계

AudioFix의 선택 기능 하나에 대한 설명. **기본값은 꺼져 있고**, 우클릭 메뉴에서 사용자가 직접 눌러야
설치된다. sudo 인증을 우회하는 설정이므로 자동으로 하지 않는다.

## 왜 필요한가

`coreaudiod`는 `_coreaudiod` 사용자로 돌기 때문에 죽이려면 root여야 한다. 기본 동작은 클릭할 때마다
관리자 암호를 묻는 것이다(`NSAppleScript`의 `do shell script … with administrator privileges`).
소리가 끊길 때마다 암호를 치는 게 번거로우면, 이 명령 하나만 암호 없이 허용하도록 규칙을 넣을 수 있다.

## 무엇이 설치되나

`/etc/sudoers.d/audiofix-coreaudio` (0440, root:wheel):

```text
# AudioFix - restart coreaudiod without a password.
# Managed by AudioFix. Delete this file to revoke.
Cmnd_Alias AUDIOFIX_KILL = /usr/bin/killall coreaudiod
Cmnd_Alias AUDIOFIX_PROBE = /usr/bin/true ""
<사용자명> ALL=(root) NOPASSWD: AUDIOFIX_KILL, AUDIOFIX_PROBE
```

사용자명은 `NSUserName()`으로 런타임에 채워진다. 소스에 박혀 있지 않다.

허용되는 것은 **인자까지 정확히 일치하는 두 명령뿐**이다. sudoers는 명령 경로와 인자를 함께 검사하므로
`killall`로 다른 프로세스를 죽이는 데 쓸 수 없다. `PROBE`는 규칙이 살아 있는지 확인하는 용도다
(`sudo -n /usr/bin/true`).

설치 전에 실제 스크립트를 눈으로 확인할 수 있다. 아무것도 실행하지 않고 출력만 한다.

```bash
/Applications/AudioFix.app/Contents/MacOS/AudioFix --print-installer
/Applications/AudioFix.app/Contents/MacOS/AudioFix --print-uninstaller
```

## sudoers를 건드릴 때 지킨 것들

sudoers를 잘못 만지면 **sudo 자체를 못 쓰게 된다.** 복구하려면 복구 모드로 부팅해야 한다.
그래서 안전장치를 겹겹이 뒀다.

### 1. 백업이 먼저다

`/etc/sudoers`를 복사해 두지 못하면 아무것도 건드리지 않고 중단한다.

```bash
if ! /bin/cp -p "$SUDOERS_MAIN" "$BAK"; then
  /bin/echo AUDIOFIX_ERR_BACKUP
  exit 0
fi
```

### 2. `/etc`와 `/private/etc`를 둘 다 인정한다

macOS에서 `/etc`는 `private/etc`의 심볼릭 링크다. Apple이 출하하는 `/etc/sudoers`는 includedir를
**물리 경로**로 적어 둔다.

```text
#includedir /private/etc/sudoers.d
```

`/etc/sudoers.d`만 찾으면 "includedir가 없다"고 오판해서 한 줄을 덧붙이게 된다. 그러면 같은 디렉터리를
두 번 읽어 `duplicate Cmnd_Alias`가 나고 **sudoers 전체가 파싱 불능**이 된다. 두 표기를 모두 본다.

```bash
/usr/bin/grep -qE '^[[:space:]]*[#@]includedir[[:space:]]+/(private/)?etc/sudoers\.d[[:space:]]*$'
```

> Swift의 `"""` 리터럴도 백슬래시를 처리하므로 소스에는 `\\.`로 써야 셸에 `\.`가 도달한다.
> 한 겹만 쓰면 `.`가 되어 아무 글자나 매칭된다.

### 3. 조각만 검사하는 걸로는 부족하다

새로 만든 규칙 파일이 단독으로 `visudo -cf`를 통과해도, 조립된 전체 설정에서는 실패할 수 있다
(다른 조각과 이름이 겹치는 `Cmnd_Alias` 등). `visudo`는 `@includedir`를 따라 들어가므로
**마지막에 `/etc/sudoers` 전체를 검증**하고, 실패하면 백업으로 되돌린다.

```bash
if ! /usr/sbin/visudo -cf "$SUDOERS_MAIN" >/dev/null 2>&1; then
  /bin/rm -f "$RULE"
  /bin/cat "$BAK" > "$SUDOERS_MAIN"
  /bin/echo AUDIOFIX_ERR_ROLLBACK
  exit 0
fi
```

### 4. 임시 파일은 같은 디렉터리에, 점으로 시작하게

`/etc/sudoers.d` 안에 `.audiofix.XXXXXX`로 만든다. 같은 파일시스템이라 `mv`가 원자적 `rename()`이 되고,
점으로 시작하므로 쓰다 만 상태에서도 sudo가 읽지 않는다(`@includedir`는 점으로 시작하는 파일을 건너뛴다).

### 5. `mv`가 아니라 `cat` 리다이렉트로 쓴다

`/etc/sudoers` 본문을 고칠 때 `mv`로 덮으면 inode·소유자·모드가 바뀐다. `cat`으로 내용만 덮어쓴다.
대신 쓰다가 실패하면(디스크 가득) 파일이 잘린 채 남으므로 그 경우도 즉시 되돌린다.

### 6. 종료 코드가 아니라 stdout 토큰으로 알린다

`do shell script`가 0이 아닌 종료를 AppleScript 오류로 바꿔 버려서 stdout이 안 온다.
그래서 항상 `exit 0`이고 결과는 토큰으로 전달한다.

| 토큰 | 뜻 |
| --- | --- |
| `AUDIOFIX_OK` | 성공 |
| `AUDIOFIX_ERR_BACKUP` | 백업 실패 — 아무것도 안 건드림 |
| `AUDIOFIX_ERR_INCLUDEDIR` | includedir 줄 추가 시 문법 검사 실패 |
| `AUDIOFIX_ERR_WRITE` | `/etc/sudoers` 쓰기 실패 — 되돌림 |
| `AUDIOFIX_ERR_VISUDO` | 규칙 조각이 문법 검사 실패 — 설치 취소 |
| `AUDIOFIX_ERR_ROLLBACK` | 전체 설정 검증 실패 — 원상 복구 |

## 설치가 건드리는 것 전부

| 대상 | 무엇을 | 해제 시 되돌리나 |
| --- | --- | --- |
| `/etc/sudoers.d/audiofix-coreaudio` | 규칙 파일 생성 | 예 |
| `/etc/sudoers` | `@includedir` 줄이 **없을 때만** 한 줄 추가 | 예 (표식이 있을 때만) |
| `/etc/sudoers.d/.audiofix-includedir-added` | 위 줄을 우리가 추가했다는 표식 | 예 |
| `/etc/sudoers.audiofix.bak` | 작업 중 임시 백업 | 성공·실패 모두 삭제 |

표식 파일이 핵심이다. 이게 없으면 해제할 때 **원래 있던 `@includedir` 줄까지 지워버릴** 수 있고,
그러면 다른 앱이 넣어 둔 sudoers 규칙이 전부 무효가 된다. 우리가 추가한 경우에만 되돌린다.

## 손으로 되돌리기

메뉴의 "비밀번호 없이 재시작 해제"가 정상 경로다. 직접 하려면:

```bash
sudo rm -f /etc/sudoers.d/audiofix-coreaudio

# 아래는 표식 파일이 있을 때만. 없으면 그 줄은 원래 있던 것이므로 건드리지 말 것.
ls -l /etc/sudoers.d/.audiofix-includedir-added

sudo sed -i '' '/^[[:space:]]*@includedir[[:space:]]*\/etc\/sudoers\.d[[:space:]]*$/d' /etc/sudoers
sudo visudo -c                                  # 반드시 확인
sudo rm -f /etc/sudoers.d/.audiofix-includedir-added
```

`visudo -c`가 통과하지 않으면 그 상태로 로그아웃하지 마라. 같은 터미널에서 바로 되돌려야 한다.

## 검증

설치·해제 스크립트는 경로를 샌드박스로 바꾸고 `chown`을 스텁으로 대체해서 아래 시나리오를 돌려 확인했다.

| 시나리오 | 기대 결과 |
| --- | --- |
| 기본 macOS (`#includedir /private/...`) | `OK`, includedir 중복 없음 |
| includedir 줄 자체가 없음 | `OK`, 표식 생성 |
| 같은 설치를 반복 | `OK` (멱등) |
| 해제 → 재해제 | `OK`, 잔여물 없음 |
| 전체 설정 충돌 | `ERR_ROLLBACK`, 원본과 동일 |
| 조각 문법 오류 | `ERR_VISUDO`, 변경 없음 |
| 백업 생성 실패 | `ERR_BACKUP`, 변경 없음 |
| sudoers 쓰기 불가 | `ERR_WRITE`, 원본과 동일 |

모든 실패 경로에서 임시 파일이 남지 않는 것도 함께 확인했다.
