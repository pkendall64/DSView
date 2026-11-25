#!/bin/bash
# Builds a self-contained DSView.app and a .dmg from a CMake build directory.
#
#   installer/macos/make-app.sh <build-dir> <output-dir> <version>
#
# Needs: macdeployqt (Qt 6), dylibbundler, rsvg-convert (librsvg), and the
# Python framework DSView was linked against (Homebrew python@3.x). This is
# what the macOS job in .github/workflows/build.yml runs.
#
# Layout inside the bundle:
#   Contents/MacOS/DSView, dsview-ctl
#   Contents/share/DSView/...               res, demo, lang (GetAppDataDir)
#   Contents/share/libsigrokdecode4DSL/...  decoders (GetDecodeScriptDir)
#   Contents/Frameworks/                    Qt, glib, libusb, fftw, Python
# The app looks for its data in ../share relative to the executable, the same
# as an installed Unix layout, so no source changes are needed.

set -euo pipefail

BUILD="$(cd "$1" && pwd)"
OUT="$2"
VERSION="$3"
SRC="$(cd "$(dirname "$0")/../.." && pwd)"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

APP="$OUT/DSView.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"

#--- Binaries and data --------------------------------------------------------
cmake --install "$BUILD" --prefix "$STAGE/prefix"
cp "$STAGE/prefix/bin/DSView" "$STAGE/prefix/bin/dsview-ctl" "$CONTENTS/MacOS/"
mkdir -p "$CONTENTS/share"
cp -R "$STAGE/prefix/share/DSView" "$STAGE/prefix/share/libsigrokdecode4DSL" "$CONTENTS/share/"
find "$CONTENTS/share" -name '__pycache__' -prune -exec rm -rf {} +

#--- Icon ---------------------------------------------------------------------
ICONSET="$STAGE/DSView.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    rsvg-convert -w $size -h $size "$SRC/DSView/icons/logo.svg" -o "$ICONSET/icon_${size}x${size}.png"
    rsvg-convert -w $((size * 2)) -h $((size * 2)) "$SRC/DSView/icons/logo.svg" -o "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/DSView.icns"

#--- Info.plist ---------------------------------------------------------------
cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>DSView</string>
    <key>CFBundleDisplayName</key>          <string>DSView</string>
    <key>CFBundleExecutable</key>           <string>DSView</string>
    <key>CFBundleIdentifier</key>           <string>io.github.mrehkopf.dsview</string>
    <key>CFBundleIconFile</key>             <string>DSView.icns</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>${VERSION}</string>
    <key>CFBundleVersion</key>              <string>${VERSION}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>       <string>$(vtool -show-build "$CONTENTS/MacOS/DSView" | awk '/minos/ {print $2; exit}')</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSPrincipalClass</key>             <string>NSApplication</string>
</dict>
</plist>
EOF

#--- Python -------------------------------------------------------------------
# DSView embeds Python for the protocol decoders. macdeployqt mangles the path
# of Homebrew's Python.framework, so deploy it here first: the library, plus
# the standard library in its usual place (Versions/X.Y/lib/pythonX.Y). At
# startup DSView sets PYTHONHOME to Versions/Current (see appcontrol.cpp).
PYLIB="$(otool -L "$CONTENTS/MacOS/DSView" | awk '/Python.framework/ {print $1; exit}')"
PYVER="$(echo "$PYLIB" | sed -nE 's|.*/Versions/([0-9]+\.[0-9]+)/Python$|\1|p')"
[ -n "$PYVER" ] || { echo "DSView is not linked against a Python framework" >&2; exit 1; }
PYFW="$CONTENTS/Frameworks/Python.framework"
PYFWSRC="${PYLIB%/Versions/*}"
mkdir -p "$PYFW/Versions/${PYVER}/Resources"
cp "$PYLIB" "$PYFW/Versions/${PYVER}/Python"
cp "$PYFWSRC/Versions/${PYVER}/Resources/Info.plist" "$PYFW/Versions/${PYVER}/Resources/"
ln -s "${PYVER}" "$PYFW/Versions/Current"
ln -s Versions/Current/Python "$PYFW/Python"
ln -s Versions/Current/Resources "$PYFW/Resources"
chmod u+w "$PYFW/Versions/${PYVER}/Python"
PYID="@executable_path/../Frameworks/Python.framework/Versions/${PYVER}/Python"
install_name_tool -id "$PYID" "$PYFW/Versions/${PYVER}/Python"
install_name_tool -change "$PYLIB" "$PYID" "$CONTENTS/MacOS/DSView"

PYSRC="$PYFWSRC/Versions/${PYVER}/lib/python${PYVER}"
PYDEST="$PYFW/Versions/${PYVER}/lib/python${PYVER}"
mkdir -p "$PYDEST"
rsync -a \
    --exclude 'test' --exclude 'idlelib' --exclude 'tkinter' --exclude 'turtledemo' \
    --exclude 'ensurepip' --exclude 'site-packages' --exclude '__pycache__' \
    --exclude 'lib-dynload/_tkinter*' \
    "$PYSRC/" "$PYDEST/"

# Some extension modules link Homebrew libraries (OpenSSL, mpdecimal, xz, ...).
# Copy those into Frameworks and point the modules at them.
DYNLOAD="$PYDEST/lib-dynload"
EXTS=()
for so in "$DYNLOAD"/*.so; do
    if otool -L "$so" | tail -n +2 | grep -qE '^\s*/(opt/homebrew|usr/local)/'; then
        EXTS+=(-x "$so")
    fi
done
if [ ${#EXTS[@]} -gt 0 ]; then
    dylibbundler -of -b "${EXTS[@]}" -d "$CONTENTS/Frameworks" -p '@executable_path/../Frameworks/'
fi

#--- Qt and the other linked libraries ----------------------------------------
# macdeployqt copies Qt with its plugins (cocoa, qsvg, styles, ...) and every
# other non-system dylib the executables link (glib, libusb, fftw, ...), and
# rewrites their install names to @loader_path. It reports errors for plugins
# of Qt modules that are installed but unused; the check below catches any
# dependency that is really missing.
macdeployqt "$APP" -executable="$CONTENTS/MacOS/dsview-ctl" -always-overwrite || true

# --headless needs the offscreen platform plugin, which macdeployqt skips.
QTPLUGINS="$(qtpaths6 --query QT_INSTALL_PLUGINS 2>/dev/null || qmake6 -query QT_INSTALL_PLUGINS)"
OFFSCREEN="$CONTENTS/PlugIns/platforms/libqoffscreen.dylib"
cp "$QTPLUGINS/platforms/libqoffscreen.dylib" "$OFFSCREEN"
chmod u+w "$OFFSCREEN"
for dep in $(otool -L "$OFFSCREEN" | awk '/(@rpath|\/opt\/homebrew|\/usr\/local).*Qt[A-Za-z]*\.framework/ {print $1}'); do
    install_name_tool -change "$dep" "@loader_path/../../Frameworks/Qt${dep##*/Qt}.framework/${dep#*.framework/}" "$OFFSCREEN"
done

# With the full Homebrew "qt" formula installed, macdeployqt also picks up the
# virtual keyboard input plugin (which pulls in QML/Quick) and the PDF image
# format. DSView needs neither; drop them and the frameworks only they used.
rm -rf "$CONTENTS/PlugIns/platforminputcontexts" "$CONTENTS/PlugIns/imageformats/libqpdf.dylib"
for fw in QtQml QtQmlMeta QtQmlModels QtQmlWorkerScript QtQuick QtOpenGL QtPdf QtVirtualKeyboard QtVirtualKeyboardQml; do
    rm -rf "$CONTENTS/Frameworks/${fw}.framework"
done

# Homebrew dylibs that macdeployqt copied keep @rpath references to each other
# but rpaths like @loader_path/../lib, which do not exist in the bundle. They
# all sit flat in Frameworks, so let them search their own directory.
for f in "$CONTENTS/Frameworks"/*.dylib; do
    if otool -L "$f" | tail -n +2 | grep -q '@rpath/'; then
        chmod u+w "$f"
        install_name_tool -add_rpath @loader_path "$f" 2>/dev/null || true
    fi
done

#--- Check and sign -----------------------------------------------------------
# Every dependency must resolve inside the bundle or to the system: no
# references to the build machine's libraries, and none to a missing file.
resolve() {  # resolve <path> <loading file>
    local p="$1" f="$2"
    p="${p/#@executable_path/$CONTENTS/MacOS}"
    p="${p/#@loader_path/$(dirname "$f")}"
    echo "$p"
}
LEFT=0
while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then
        id="$(otool -D "$f" | tail -n +2)"
        deps="$(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -vxF -- "${id:-/nonexistent}" || true)"
        rpaths="$(otool -l "$f" | awk '/cmd LC_RPATH/ {getline; getline; print $2}')"
        for dep in $deps; do
            case "$dep" in
                /System/*|/usr/lib/*) continue ;;
                @executable_path/*|@loader_path/*)
                    [ -e "$(resolve "$dep" "$f")" ] && continue ;;
                @rpath/*)
                    found=0
                    for rp in $rpaths; do
                        case "$rp" in @executable_path*|@loader_path*) ;; *) continue ;; esac
                        if [ -e "$(resolve "$rp" "$f")/${dep#@rpath/}" ]; then found=1; break; fi
                    done
                    [ "$found" -eq 1 ] && continue ;;
            esac
            # Absolute paths outside the system, or rpaths that point outside
            # the bundle, would not load on a machine without Homebrew.
            echo "$f: unresolved $dep" >&2
            LEFT=1
        done
    fi
done < <(find "$APP" -type f -print0)
[ "$LEFT" -eq 0 ] || { echo "Unbundled library references remain" >&2; exit 1; }

# install_name_tool invalidated the original signatures. Apple Silicon refuses
# to load unsigned code, so sign everything ad hoc, innermost first.
while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then
        codesign --force --sign - "$f"
    fi
done < <(find "$CONTENTS/Frameworks" "$CONTENTS/PlugIns" "$CONTENTS/share" -type f -print0)
find "$CONTENTS/Frameworks" -maxdepth 1 -name '*.framework' -print0 | xargs -0 -n1 codesign --force --sign -
codesign --force --sign - "$CONTENTS/MacOS/dsview-ctl"
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

#--- Disk image ---------------------------------------------------------------
DMGROOT="$STAGE/dmg"
mkdir -p "$DMGROOT"
cp -R "$APP" "$DMGROOT/"
ln -s /Applications "$DMGROOT/Applications"
DMG="$OUT/DSView-${VERSION}-macos-$(uname -m).dmg"
rm -f "$DMG"
hdiutil create -volname "DSView ${VERSION}" -srcfolder "$DMGROOT" -format UDZO -ov "$DMG"
echo "Created $DMG"
