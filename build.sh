#!/bin/bash
#
# 세 개의 메뉴 막대 앱을 빌드한다. 몇 번을 다시 실행해도 같은 결과가 나온다.
#
#   ./build.sh                    # 셋 다 빌드
#   ./build.sh MicRecorder        # 하나만 빌드
#   SIGN_ID="-" ./build.sh        # 강제 ad-hoc 서명 (TCC 권한이 매 빌드마다 초기화됨)
#
set -euo pipefail

DEPLOY="14.0"   # AVCaptureDevice.DeviceType.microphone 이 macOS 14.0+ 이라 13.0 으로 낮출 수 없다

# 포크해서 쓸 때는 자기 것으로 바꾸면 된다: BUNDLE_PREFIX=com.example ./build.sh
# 주의 — 이 값을 바꾸면 macOS 가 다른 앱으로 인식해서 이미 허용된 TCC 권한(마이크·자동화)이 초기화된다.
BUNDLE_PREFIX="${BUNDLE_PREFIX:-kr.leekyusung}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="$ROOT/Shared/Shared.swift"
BUILD="$ROOT/build"

# ---- 서명 ID 결정 -----------------------------------------------------------
# ad-hoc 서명은 designated requirement 가 bare cdhash 라서, 소스가 한 글자만 바뀌어도
# 새 앱으로 취급된다 → 마이크/자동화 TCC 권한이 매 빌드마다 초기화된다.
SIGN_ID="${SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
             | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
SIGN_ID="${SIGN_ID:--}"
if [ "$SIGN_ID" = "-" ]; then
  echo "WARNING: ad-hoc 서명입니다 — 소스를 수정할 때마다 TCC 권한이 초기화됩니다" >&2
fi

SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"

# ---- 앱 하나 빌드 -----------------------------------------------------------
# $1 앱 이름(= 디렉터리명 = 실행 파일명)
# $2 표시 이름
# $3 마이크 필요 여부 (yes/no)
# $4 애플이벤트 사용 설명 필요 여부 (yes/no)
build_app() {
  local name="$1" display="$2" needs_mic="$3" needs_ae="$4"
  local bundle_id="$BUNDLE_PREFIX.$name"
  local src="$ROOT/$name/$name.swift"
  local app="$BUILD/$name.app"
  local ent="$BUILD/$name.entitlements"

  [ -f "$src" ] || { echo "FATAL: 소스가 없습니다: $src" >&2; return 1; }

  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0">'
    echo '<dict>'
    echo "	<key>CFBundleName</key><string>$name</string>"
    echo "	<key>CFBundleDisplayName</key><string>$display</string>"
    echo "	<key>CFBundleExecutable</key><string>$name</string>"
    echo "	<key>CFBundleIdentifier</key><string>$bundle_id</string>"
    echo '	<key>CFBundlePackageType</key><string>APPL</string>'
    echo '	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>'
    echo '	<key>CFBundleShortVersionString</key><string>1.0</string>'
    echo '	<key>CFBundleVersion</key><string>1</string>'
    echo "	<key>LSMinimumSystemVersion</key><string>$DEPLOY</string>"
    echo '	<key>LSUIElement</key><true/>'
    echo '	<key>NSHighResolutionCapable</key><true/>'
    if [ "$needs_mic" = "yes" ]; then
      echo '	<key>NSMicrophoneUsageDescription</key>'
      echo "	<string>${display}이(가) 회의·메모를 녹음하려면 마이크 접근 권한이 필요합니다.</string>"
    fi
    if [ "$needs_ae" = "yes" ]; then
      echo '	<key>NSAppleEventsUsageDescription</key>'
      echo "	<string>${display}이(가) 시스템 외형을 전환하려면 System Events 제어 권한이 필요합니다.</string>"
    fi
    echo '</dict>'
    echo '</plist>'
  } > "$app/Contents/Info.plist"

  # NSMicrophoneUsageDescription 이 빠지면 TCC 가 프로세스를 SIGABRT 시킨다. lint 로 조기에 잡는다.
  plutil -lint "$app/Contents/Info.plist" >/dev/null

  # -framework 플래그는 필요 없다. import 만으로 autolink 된다.
  # 공용 파일과 앱 파일을 한 번에 컴파일한다 (@main 은 앱 파일에만 있다).
  swiftc -parse-as-library -O -whole-module-optimization \
    -target "arm64-apple-macos$DEPLOY" \
    -sdk "$SDK_PATH" \
    -module-name "$name" \
    -o "$app/Contents/MacOS/$name" \
    "$SHARED" "$src"

  # Hardened Runtime(--options runtime) 아래에서 마이크에 접근하려면
  # com.apple.security.device.audio-input 이 반드시 있어야 한다. 없으면 TCC 가 동의 대화상자조차
  # 띄우지 않고 즉시 거부하고, 상태가 영구 .denied 로 굳어 시스템 설정에서 켜도 소용없다.
  #
  # 반면 자동화(Apple Events)는 엔타이틀먼트가 필요 없다:
  # 외형 전환은 /usr/bin/osascript 서브프로세스로 하고, osascript 가 자체 권한으로 프롬프트를 띄운다.
  if [ "$needs_mic" = "yes" ]; then
    {
      echo '<?xml version="1.0" encoding="UTF-8"?>'
      echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
      echo '<plist version="1.0">'
      echo '<dict>'
      echo '	<key>com.apple.security.device.audio-input</key><true/>'
      echo '</dict>'
      echo '</plist>'
    } > "$ent"
    plutil -lint "$ent" >/dev/null

    # swiftc 링커가 이미 Identifier=<실행파일명> 으로 ad-hoc 서명해 두기 때문에
    # --identifier 로 번들 ID 를 명시해서 다시 서명해야 codesign --verify 가 통과한다.
    codesign --force --options runtime --entitlements "$ent" \
      --sign "$SIGN_ID" --identifier "$bundle_id" "$app"
    codesign --verify --strict "$app"

    # 엔타이틀먼트가 실제로 박혔는지 확인한다. 조용히 빠지면 녹음이 통째로 죽는다.
    if ! codesign -d --entitlements - "$app" 2>&1 | grep -q 'com.apple.security.device.audio-input'; then
      echo "FATAL: $name — audio-input 엔타이틀먼트가 서명에 포함되지 않았습니다" >&2
      return 1
    fi
  else
    codesign --force --options runtime \
      --sign "$SIGN_ID" --identifier "$bundle_id" "$app"
    codesign --verify --strict "$app"
  fi

  echo "  OK  $display  ($name.app)"
}

# ---- 실행 -------------------------------------------------------------------
mkdir -p "$BUILD"

TARGET="${1:-all}"
echo "빌드 시작 (서명: $SIGN_ID)"

case "$TARGET" in
  all)
    build_app AudioFix    "오디오 재시작" no  no
    build_app ThemeToggle "다크·라이트"   no  yes
    build_app MicRecorder "녹음"          yes no
    ;;
  AudioFix)    build_app AudioFix    "오디오 재시작" no  no ;;
  ThemeToggle) build_app ThemeToggle "다크·라이트"   no  yes ;;
  MicRecorder) build_app MicRecorder "녹음"          yes no ;;
  *)
    echo "알 수 없는 대상: $TARGET (AudioFix | ThemeToggle | MicRecorder | all)" >&2
    exit 1
    ;;
esac

echo
echo "빌드 위치: $BUILD"
echo
echo "설치:"
echo "  for a in AudioFix ThemeToggle MicRecorder; do"
echo "    ditto \"$BUILD/\$a.app\" \"/Applications/\$a.app\" && open \"/Applications/\$a.app\""
echo "  done"
echo
echo "이전 빌드에서 마이크가 거부(.denied)로 굳었다면 한 번만:"
echo "  tccutil reset Microphone $BUNDLE_PREFIX.MicRecorder"
