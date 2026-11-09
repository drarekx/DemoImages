#!/bin/bash
# DemoImages installer.
#   curl -fsSL https://raw.githubusercontent.com/drarekx/DemoImages/main/install.sh | bash
# Options (pass after `bash -s --`):
#   --no-deps   don't install the image encoders with Homebrew
set -euo pipefail

NAME="DemoImages"
REPO="drarekx/DemoImages"
URL="https://github.com/$REPO/releases/latest/download/$NAME.zip"
# Same encoders Squoosh uses: libwebp, libavif, libjxl, MozJPEG, OxiPNG, libimagequant.
FORMULAE=(webp libavif jpeg-xl mozjpeg oxipng pngquant)
INSTALL_DEPS=1
for arg in "$@"; do
    [[ "$arg" == "--no-deps" ]] && INSTALL_DEPS=0
done

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
fail() { printf "\033[31mError:\033[0m %s\n" "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "$NAME solo funciona en macOS."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || fail "$NAME necesita macOS 14 (Sonoma) o posterior. Tienes $(sw_vers -productVersion)."

bold "Descargando $NAME…"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fL --progress-bar "$URL" -o "$tmp/$NAME.zip" || fail "No se pudo descargar $URL"
ditto -x -k "$tmp/$NAME.zip" "$tmp"
[[ -d "$tmp/$NAME.app" ]] || fail "El archivo descargado no contiene $NAME.app"

# Close a running copy so it can be replaced.
if pgrep -x "$NAME" >/dev/null; then
    bold "Cerrando $NAME…"
    osascript -e "quit app \"$NAME\"" 2>/dev/null || true
    sleep 1
    pkill -x "$NAME" 2>/dev/null || true
fi

dest="/Applications"
if [[ ! -w "$dest" ]]; then
    dest="$HOME/Applications"
    mkdir -p "$dest"
fi
rm -rf "$dest/$NAME.app"
mv "$tmp/$NAME.app" "$dest/"
# The app is not notarized; skip the Gatekeeper prompt for this copy.
xattr -dr com.apple.quarantine "$dest/$NAME.app" 2>/dev/null || true
bold "Instalado en $dest/$NAME.app"

if (( INSTALL_DEPS )); then
    brew=""
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew "$(command -v brew 2>/dev/null || true)"; do
        [[ -n "$candidate" && -x "$candidate" ]] && { brew="$candidate"; break; }
    done
    if [[ -n "$brew" ]]; then
        missing=()
        for formula in "${FORMULAE[@]}"; do
            "$brew" list --formula "$formula" >/dev/null 2>&1 || missing+=("$formula")
        done
        if (( ${#missing[@]} )); then
            bold "Instalando ${missing[*]} (codificadores WebP, AVIF, JPEG XL, MozJPEG y PNG)…"
            "$brew" install "${missing[@]}"
        fi
    else
        echo
        echo "Para optimizar a WebP, AVIF y JPEG XL, $NAME usa codificadores de Homebrew."
        echo "Instala Homebrew (https://brew.sh) y luego ejecuta:  brew install ${FORMULAE[*]}"
        echo "Sin ellos funcionan la biblioteca y la optimización a HEIC, JPEG y PNG."
    fi
fi

open "$dest/$NAME.app"
bold "¡Listo!"
