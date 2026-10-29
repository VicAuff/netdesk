#!/bin/zsh
# Builds the app with the Command Line Tools only. The name is set once, in APP_NAME.
# Optional settings in local.env (not versioned, see local.env.example):
#   BUNDLE_ID                     identifier of the app
#   SIGN_IDENTITY                 code signing identity; without it the app is signed ad hoc
#   SIGN_KEYCHAIN                 keychain holding that identity
#   SIGN_KEYCHAIN_PASSWORD_FILE   file holding that keychain's password
# A stable identity keeps Full Disk Access from one build to the next; ad hoc signing loses it at each build.
# --install also copies the app to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f local.env ]] && source ./local.env
APP_NAME="NetDesk"
BUNDLE_ID="${BUNDLE_ID:-com.example.$APP_NAME}"
APP=".build/$APP_NAME.app"

swift build -c release --product "$APP_NAME"

if [[ ! -f Resources/AppIcon.icns ]]; then
  ICONSET=".build/AppIcon.iconset"
  swift scripts/make-icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleExecutable $APP_NAME" \
  -c "Set :CFBundleName $APP_NAME" -c "Set :CFBundleDisplayName $APP_NAME" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${SIGN_IDENTITY:-}" && -n "${SIGN_KEYCHAIN:-}" ]]; then
  security unlock-keychain -p "$(cat "$SIGN_KEYCHAIN_PASSWORD_FILE")" "$SIGN_KEYCHAIN"
  codesign --force --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_IDENTITY" "$APP"
elif [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$APP_NAME.app"
  ditto "$APP" "$HOME/Applications/$APP_NAME.app"
  echo "Installé : ~/Applications/$APP_NAME.app"
fi
