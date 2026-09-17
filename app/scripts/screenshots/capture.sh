#!/bin/bash
#
# App Store 申請用のスクリーンショットを撮る。
#
#   使い方: app/scripts/screenshots/capture.sh <デバイスUDID> [ラベル]
#   例:     app/scripts/screenshots/capture.sh CDE5C2E2-... iphone-6.7
#
# 中身は架空。BDBridge/DemoData.swift の偽レコーダーと偽番組表で起動するので、実機も
# レコーダーも要らず、誰の録画一覧も写らない。撮るのは BDBridgeUITests/ScreenshotTests.swift。
#
set -euo pipefail

UDID="${1:?デバイスの UDID を渡してください（xcrun simctl list devices available）}"
LABEL="${2:-iphone}"

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${BDBRIDGE_SHOT_WORK:-$APP_DIR/build/screenshots}"
OUT="${BDBRIDGE_SHOT_OUT:-$HOME/Pictures/BDBridge-AppStore}"

BUNDLE="$WORK/res_${LABEL}.xcresult"
DEST="$OUT/$LABEL"
mkdir -p "$WORK" "$DEST"
rm -rf "$BUNDLE"

# ステータスバーを整える。時刻はいまの時刻にする: 番組表には現在時刻の赤い線が引かれるので、
# 9:41 に固定すると画面のなかで時計と番組表が食い違う
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
xcrun simctl status_bar "$UDID" override \
    --time "$(date +%-H:%M)" \
    --batteryState discharging --batteryLevel 100 \
    --cellularMode active --cellularBars 4 \
    --wifiMode active --wifiBars 3

cd "$APP_DIR"
BDBRIDGE_SHOTS=1 TEST_RUNNER_BDBRIDGE_SHOTS=1 \
xcodebuild test \
    -project BDBridge.xcodeproj -scheme BDBridge \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:BDBridgeUITests/ScreenshotTests \
    -derivedDataPath "$WORK/DerivedData" \
    -resultBundlePath "$BUNDLE" \
    > "$WORK/log_${LABEL}.txt" 2>&1

EXPORT="$WORK/export_${LABEL}"
rm -rf "$EXPORT"
xcrun xcresulttool export attachments --path "$BUNDLE" --output-path "$EXPORT" >/dev/null

python3 - "$EXPORT" "$DEST" <<'PY'
import json, pathlib, re, shutil, sys
export, dest = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
manifest = json.loads((export / "manifest.json").read_text())
for test in manifest:
    for a in test.get("attachments", []):
        name = a["suggestedHumanReadableName"]
        if not name.endswith(".png"):
            continue
        # 「01_guide_grid_1_<UUID>.png」から連番の接尾辞を落とす
        base = re.sub(r"_\d+_[0-9A-F-]+\.png$", ".png", name)
        shutil.copy(export / a["exportedFileName"], dest / base)
        print(dest / base)
PY

# 開発中のシミュレータに設定を残さない
xcrun simctl status_bar "$UDID" clear 2>/dev/null || true

echo "完了: $LABEL -> $DEST"
