#!/bin/zsh
# Builds Editroom (Release) and packs it into a drag-to-Applications DMG with the film-strip background.
#   scripts/make-dmg.sh            build, then make build/Editroom.dmg
#   scripts/make-dmg.sh --no-build use the last Release build in /tmp/editroom-dd
# Needs create-dmg (brew install create-dmg). The first run asks to let Terminal control Finder,
# which create-dmg uses to lay out the window.
# Not notarized yet: this is for looking at the window and passing builds around by hand.
set -e
root="${0:A:h:h}"
dd=/tmp/editroom-dd
app="$dd/Build/Products/Release/Editroom.app"
out="$root/build/Editroom.dmg"
art="$root/scripts/dmg"

command -v create-dmg >/dev/null || { echo "create-dmg is missing: brew install create-dmg"; exit 1 }

if [[ "$1" != "--no-build" ]]; then
  xcodebuild -project "$root/Editroom.xcodeproj" -scheme Editroom -configuration Release \
    -derivedDataPath "$dd" build -quiet
fi
[[ -d "$app" ]] || { echo "No build at $app"; exit 1 }

# Background: one TIFF holding the 600×380 and 1200×760 images, so Retina screens get the sharp one.
work="$(mktemp -d)"
sips -s dpiWidth 72 -s dpiHeight 72 "$art/background.png" --out "$work/background.png" >/dev/null
sips -s dpiWidth 144 -s dpiHeight 144 "$art/background@2x.png" --out "$work/background@2x.png" >/dev/null
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" -out "$work/background.tiff" >/dev/null
mkdir "$work/src"
cp -R "$app" "$work/src/"

mkdir -p "${out:h}"
rm -f "$out"
# Window is 600×412 points: the 380pt background plus the 32pt title bar. Icons sit in the usual
# spots across the middle. At 148pt the app's tile (about 118pt) covers the dark square in the
# background, which marks where it goes.
create-dmg \
  --volname "Editroom" \
  --background "$work/background.tiff" \
  --window-pos 200 120 \
  --window-size 600 412 \
  --icon-size 148 \
  --text-size 13 \
  --icon "Editroom.app" 161 180 \
  --app-drop-link 440 180 \
  --hide-extension "Editroom.app" \
  --no-internet-enable \
  "$out" "$work/src" >/dev/null

rm -rf "$work"
echo "Made $out"
