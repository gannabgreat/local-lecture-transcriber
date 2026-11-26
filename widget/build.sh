#!/bin/zsh
# 수업 전사 위젯 빌드·설치. Xcode Command Line Tools 만 있으면 된다(macOS 26+).
#   zsh widget/build.sh            빌드 → ~/Applications/수업전사.app, 로그인 때 자동으로 켜지게 등록, 바로 켬
#   zsh widget/build.sh --remove   로그인 자동 켜기 해제 + 앱 삭제
# 앱은 이 저장소의 live/live.py 를 부른다(경로를 Info.plist 에 넣음 — 저장소를 옮기면 다시 빌드).
set -eu
D="${0:A:h}"
APP="$HOME/Applications/수업전사.app"
LABEL=com.local-transcriber.widget
PL="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x LectureWidget 2>/dev/null || true
if [ "${1:-}" = "--remove" ]; then rm -f "$PL"; rm -rf "$APP"; echo "🗑 위젯 제거"; exit 0; fi

mkdir -p "$APP/Contents/MacOS" "$HOME/Library/LaunchAgents"
xcrun swiftc -parse-as-library -O "$D/LectureWidget.swift" -o "$APP/Contents/MacOS/LectureWidget"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.local-transcriber.widget-app</string>
  <key>CFBundleName</key><string>수업전사</string>
  <key>CFBundleExecutable</key><string>LectureWidget</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>수업 소리를 맥 안에서 받아쓰기 위해 마이크를 씁니다.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>캘린더 일정에서 지금 수업·회의를 찾습니다.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>온디바이스 받아쓰기(SpeechAnalyzer)를 씁니다.</string>
  <key>LiveScript</key><string>${D:h}/live/live.py</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - "$APP" >/dev/null 2>&1

cat > "$PL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PLIST
plutil -lint "$PL" >/dev/null
launchctl bootstrap "gui/$(id -u)" "$PL"
echo "✅ $APP — 켜짐, 로그인 때 자동으로 켜짐"
