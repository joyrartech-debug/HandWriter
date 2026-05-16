#!/usr/bin/env bash
# Build a .deb package for HandWriter (Linux desktop).
#
# Layout:
#   /usr/lib/handwriter/             — Flutter bundle (binary + lib/ + data/)
#   /usr/bin/handwriter              — wrapper symlink → /usr/lib/handwriter/handwriter
#   /usr/share/applications/handwriter.desktop
#   /usr/share/icons/hicolor/{512x512,192x192}/apps/handwriter.png
#
# The Flutter binary's RUNPATH is `$ORIGIN/lib`, so it finds its bundled
# .so files relative to itself — no LD_LIBRARY_PATH wrapper needed.
#
# Usage:
#   ./tool/build_deb.sh            # build using existing release bundle
#   ./tool/build_deb.sh --rebuild  # `flutter build linux --release` first

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

REBUILD=0
[[ "${1:-}" == "--rebuild" ]] && REBUILD=1

# Version from pubspec.yaml — `0.36.9+38` → deb version `0.36.9-38`.
PUBSPEC_VER=$(grep -E '^version:' pubspec.yaml | awk '{print $2}')
VER_BASE=${PUBSPEC_VER%+*}
VER_BUILD=${PUBSPEC_VER#*+}
DEB_VER="${VER_BASE}-${VER_BUILD}"
ARCH="amd64"
PKG="handwriter_${DEB_VER}_${ARCH}"

BUNDLE="${PROJECT_ROOT}/build/linux/x64/release/bundle"

if (( REBUILD )) || [[ ! -x "${BUNDLE}/handwriter" ]]; then
  echo "→ flutter build linux --release"
  flutter build linux --release
fi

STAGE="${PROJECT_ROOT}/build/deb/${PKG}"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/DEBIAN"
mkdir -p "${STAGE}/usr/lib/handwriter"
mkdir -p "${STAGE}/usr/bin"
mkdir -p "${STAGE}/usr/share/applications"
mkdir -p "${STAGE}/usr/share/icons/hicolor/512x512/apps"
mkdir -p "${STAGE}/usr/share/icons/hicolor/192x192/apps"

echo "→ Staging bundle"
cp -r "${BUNDLE}/handwriter" "${BUNDLE}/lib" "${BUNDLE}/data" "${STAGE}/usr/lib/handwriter/"
ln -sf "/usr/lib/handwriter/handwriter" "${STAGE}/usr/bin/handwriter"

echo "→ Icons"
cp "${PROJECT_ROOT}/web/icons/Icon-512.png" \
   "${STAGE}/usr/share/icons/hicolor/512x512/apps/handwriter.png"
cp "${PROJECT_ROOT}/web/icons/Icon-192.png" \
   "${STAGE}/usr/share/icons/hicolor/192x192/apps/handwriter.png"

echo "→ .desktop"
cat > "${STAGE}/usr/share/applications/handwriter.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=HandWriter
Comment=Handwriting note-taking app with Nextcloud sync
Exec=handwriter %F
Icon=handwriter
Categories=Office;Graphics;
StartupNotify=true
Terminal=false
EOF

# Compute installed size (KB).
INSTALLED_SIZE=$(du -sk "${STAGE}/usr" | awk '{print $1}')

echo "→ DEBIAN/control"
cat > "${STAGE}/DEBIAN/control" <<EOF
Package: handwriter
Version: ${DEB_VER}
Section: graphics
Priority: optional
Architecture: ${ARCH}
Installed-Size: ${INSTALLED_SIZE}
Depends: libc6, libstdc++6, libgtk-3-0t64 | libgtk-3-0, libsecret-1-0, libsqlite3-0
Recommends: poppler-utils
Maintainer: HandWriter <noreply@handwriter.local>
Description: Handwriting note-taking app with Nextcloud sync
 HandWriter is a desktop handwriting note-taking application with
 PDF import, multi-page notebooks, and bidirectional sync to a
 Nextcloud server via WebDAV. Optimised for stylus input on Linux.
EOF

cat > "${STAGE}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
exit 0
EOF
chmod 0755 "${STAGE}/DEBIAN/postinst"

echo "→ dpkg-deb --build"
mkdir -p "${PROJECT_ROOT}/build/deb"
fakeroot dpkg-deb --build "${STAGE}" "${PROJECT_ROOT}/build/deb/${PKG}.deb"

echo ""
echo "═══ Done ═══"
ls -lh "${PROJECT_ROOT}/build/deb/${PKG}.deb"
echo ""
echo "Install:    sudo apt install ./build/deb/${PKG}.deb"
echo "Uninstall:  sudo apt remove handwriter"
