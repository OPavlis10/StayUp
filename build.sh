#!/bin/bash
# Sestavení Stay Up přímo překladačem swiftc (stačí Command Line Tools).
# Běžná cesta je Xcode – viz README: otevřít StayUp.xcodeproj, nebo
#   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
#     -project StayUp.xcodeproj -scheme StayUp -configuration Release -derivedDataPath build/DerivedData build
#   ./build.sh           sestaví build/Stay Up.app
#   ./build.sh run       sestaví a spustí
#   ./build.sh install   sestaví a zkopíruje do /Applications/Stay Up.app
set -euo pipefail

cd "$(dirname "$0")"

ACTION="${1:-build}"
case "$ACTION" in
  build|run|install) ;;
  *) echo "Použití: $0 [run|install]" >&2; exit 2 ;;
esac

APP_ID="cz.stayup.StayUp"
HELPER_ID="cz.stayup.StayUp.helper"
DAEMON_PLIST="Helper/cz.stayup.StayUp.helper.plist"
TARGET="arm64-apple-macos26.0"
APP="build/Stay Up.app"
CONTENTS="$APP/Contents"

# --- SDK -------------------------------------------------------------------
# SDK 27 z Command Line Tools neumí makra SwiftUI, proto má přednost 26.5.
SDK_DIR="/Library/Developer/CommandLineTools/SDKs"
SDK=""
if [[ -d "$SDK_DIR/MacOSX26.5.sdk" ]]; then
  SDK="$SDK_DIR/MacOSX26.5.sdk"
else
  SDK="$(ls -d "$SDK_DIR"/MacOSX26*.sdk 2>/dev/null | sort -V | tail -n 1 || true)"
fi
if [[ -z "$SDK" ]]; then
  SDK="$(xcrun --show-sdk-path)"
fi
echo "SDK: $SDK"

# Plné Xcode (kvůli xcstringstool): to, které je vybrané, jinak /Applications/Xcode.app.
XCODE_DEV_DIR=""
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV_DIR" == *.app/Contents/Developer ]]; then
  XCODE_DEV_DIR="$DEV_DIR"
elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  XCODE_DEV_DIR="/Applications/Xcode.app/Contents/Developer"
fi
if [[ -n "$XCODE_DEV_DIR" ]]; then
  echo "Poznámka: je k dispozici plné Xcode. Běžná cesta sestavení je:"
  echo "  DEVELOPER_DIR=$XCODE_DEV_DIR xcodebuild -project StayUp.xcodeproj -scheme StayUp -configuration Release -derivedDataPath build/DerivedData build"
fi

# --- Zdroje ----------------------------------------------------------------
APP_SOURCES=()
while IFS= read -r f; do APP_SOURCES+=("$f"); done < <(find App Shared -name '*.swift' | sort)
HELPER_SOURCES=()
while IFS= read -r f; do HELPER_SOURCES+=("$f"); done < <(find Helper Shared -name '*.swift' | sort)

if ! find App -name '*.swift' | grep -q .; then
  echo "Chyba: ve složce App nejsou žádné zdrojové soubory Swift." >&2; exit 1
fi
if ! find Helper -name '*.swift' 2>/dev/null | grep -q .; then
  echo "Chyba: ve složce Helper nejsou žádné zdrojové soubory Swift." >&2; exit 1
fi
for required in App/Info.plist App/StayUp.entitlements Helper/Info.plist "$DAEMON_PLIST"; do
  [[ -f "$required" ]] || { echo "Chyba: chybí $required" >&2; exit 1; }
done

# main.swift => kód na nejvyšší úrovni, bez -parse-as-library; jinak (@main) s ním.
if [[ -z "${HELPER_PARSE_AS_LIBRARY:-}" ]]; then
  if [[ -f Helper/main.swift ]]; then HELPER_PARSE_AS_LIBRARY=0; else HELPER_PARSE_AS_LIBRARY=1; fi
fi
HELPER_FLAGS=()
if [[ "$HELPER_PARSE_AS_LIBRARY" == "1" ]]; then HELPER_FLAGS+=(-parse-as-library); fi

SWIFT_FLAGS=(-swift-version 6 -strict-concurrency=complete -O -sdk "$SDK" -target "$TARGET")

# --- Balíček ---------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Library/LaunchDaemons"

echo "Překládám aplikaci (${#APP_SOURCES[@]} souborů)…"
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -module-name StayUp \
  "${APP_SOURCES[@]}" -o "$CONTENTS/MacOS/StayUp"

echo "Překládám pomocný program (${#HELPER_SOURCES[@]} souborů, parse-as-library=$HELPER_PARSE_AS_LIBRARY)…"
swiftc "${SWIFT_FLAGS[@]}" ${HELPER_FLAGS[@]+"${HELPER_FLAGS[@]}"} -module-name StayUpHelper \
  "${HELPER_SOURCES[@]}" -o "$CONTENTS/MacOS/StayUpHelper" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Helper/Info.plist

cp App/Info.plist "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
cp "$DAEMON_PLIST" "$CONTENTS/Library/LaunchDaemons/"

# --- Lokalizace ------------------------------------------------------------
if [[ -f App/Localizable.xcstrings ]]; then
  # xcstringstool je jen v plném Xcode; Command Line Tools ho nemají.
  XCSTRINGSTOOL=""
  if [[ -n "$XCODE_DEV_DIR" ]]; then
    XCSTRINGSTOOL="$(DEVELOPER_DIR="$XCODE_DEV_DIR" xcrun -f xcstringstool 2>/dev/null || true)"
  fi
  if [[ -n "$XCSTRINGSTOOL" && -x "$XCSTRINGSTOOL" ]]; then
    DEVELOPER_DIR="$XCODE_DEV_DIR" "$XCSTRINGSTOOL" compile App/Localizable.xcstrings \
      --output-directory "$CONTENTS/Resources"
    # Katalog má jen češtinu a klíče jsou přímo české texty, takže tabulky mohou být prázdné.
    echo "Lokalizace: katalog přeložen nástrojem xcstringstool do $CONTENTS/Resources."
  else
    # Zdrojový jazyk je čeština a klíče jsou přímo české texty, takže aplikace funguje i bez tabulek.
    echo "Lokalizace: xcstringstool není k dispozici (jen s Xcode), katalog přeskakuji."
  fi
else
  echo "Lokalizace: App/Localizable.xcstrings neexistuje, přeskakuji."
fi
# Prázdná složka cs.lproj stačí, aby systém bral češtinu jako jazyk aplikace.
mkdir -p "$CONTENTS/Resources/cs.lproj"
# Ikona aplikace (Finder, Spotlight). Vzniká skriptem Tools/make-icon.swift.
if [ -f App/AppIcon.icns ]; then
  cp App/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
fi

# --- Podpis (ad hoc) -------------------------------------------------------
codesign --force --sign - --options runtime --identifier "$HELPER_ID" "$CONTENTS/MacOS/StayUpHelper"
codesign --force --sign - --options runtime --identifier "$APP_ID" \
  --entitlements App/StayUp.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "OK: $APP"

quit_running() {
  if pgrep -x StayUp >/dev/null 2>&1; then
    echo "Ukončuji běžící Stay Up…"
    osascript -e "tell application id \"$APP_ID\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -x StayUp >/dev/null 2>&1 || return 0
      sleep 0.5
    done
    pkill -x StayUp >/dev/null 2>&1 || true
    sleep 1
  fi
}

case "$ACTION" in
  run)
    quit_running
    open "$APP"
    ;;
  install)
    quit_running
    DEST="/Applications/Stay Up.app"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    codesign --verify --deep --strict "$DEST"
    echo "Nainstalováno: $DEST"
    echo "Spuštění: open \"$DEST\""
    ;;
esac
