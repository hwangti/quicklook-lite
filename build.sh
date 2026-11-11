#!/bin/zsh
# 빌드 → 서명 → /Applications 설치 → Quick Look 등록(마크다운·코드)
# ./build.sh --default-md 로 실행하면 .md 기본 앱으로도 지정한다
set -euo pipefail
cd "$(dirname "$0")"

APP=build/QuickLookLite.app
APPEX=$APP/Contents/PlugIns/QuickLookLitePreview.appex
rm -rf build && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources $APPEX/Contents/MacOS

cp Info.plist $APP/Contents/
cp AppIcon.icns $APP/Contents/Resources/  # swift icon.swift 로 생성
cp PreviewInfo.plist $APPEX/Contents/Info.plist

swiftc -O -module-name QuickLookLite Sources/main.swift Sources/Markdown.swift -o $APP/Contents/MacOS/QuickLookLite
swiftc -O -module-name QuickLookLitePreview -parse-as-library -application-extension \
  Sources/Preview.swift Sources/Markdown.swift -framework QuickLookUI \
  -Xlinker -e -Xlinker _NSExtensionMain -o $APPEX/Contents/MacOS/QuickLookLitePreview

# 개발자 인증서 있으면 사용, 없으면 ad-hoc
ID=$(security find-identity -v -p codesigning | awk -F'"' 'NR==1 && /"/ {print $2}')
codesign -f -s "${ID:--}" --entitlements preview.entitlements $APPEX
codesign -f -s "${ID:--}" $APP

DEST=/Applications/QuickLookLite.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
rm -rf $DEST && cp -R $APP $DEST
# 빌드 사본은 지운다 (남겨 두면 macOS 가 앱으로 기록해 "다음으로 열기"에 두 번 보인다)
$LSREGISTER -u $APP 2>/dev/null || true
rm -rf build
$LSREGISTER -f $DEST
pluginkit -a $DEST/Contents/PlugIns/QuickLookLitePreview.appex
# 등록이 비동기라 바로 켜면 무시될 때가 있다 — 목록에 보일 때까지 기다렸다 켠다
for _ in {1..20}; do pluginkit -m -i kr.hwangti.quicklooklite.preview | grep -q . && break; sleep 0.5; done
pluginkit -e use -i kr.hwangti.quicklooklite.preview
qlmanage -r >/dev/null && qlmanage -r cache >/dev/null

[[ "${1:-}" == --default-md ]] && swift - <<'SWIFT'
import AppKit
let done = DispatchSemaphore(value: 0)
NSWorkspace.shared.setDefaultApplication(at: URL(fileURLWithPath: "/Applications/QuickLookLite.app"),
                                         toOpen: .init("net.daringfireball.markdown")!) { _ in done.signal() }
done.wait()
SWIFT
echo "설치 완료: $DEST"
