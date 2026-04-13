#!/bin/ksh

set -u
umask 022

PROGRAM_NAME="baycat-build.ksh"
APP_SOURCE_NAME="baycat.pl"
APP_BIN_NAME="baycat"
PROJECT_NAME="neofelis"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_FILE="$SCRIPT_DIR/$APP_SOURCE_NAME"
INSTALL_BIN_DIR="/usr/local/bin"
INSTALL_BIN_FILE="$INSTALL_BIN_DIR/$APP_BIN_NAME"
INSTALL_APP_DIR="/usr/local/share/$APP_BIN_NAME"
DESKTOP_DIR="/usr/local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/$APP_BIN_NAME.desktop"
PACKAGES="perl perl-gtk3 xorg-xrandr xdg-utils desktop-file-utils hicolor-icon-theme"
ROOT_RUNNER=""

say() {
    print -- "$*"
}

info() {
    say "==> $*"
}

warn() {
    say "==> Warning: $*"
}

fail() {
    say "==> Error: $*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
        return $?
    fi

    if [ -n "$ROOT_RUNNER" ]; then
        "$ROOT_RUNNER" "$@"
        return $?
    fi

    fail "Administrator access is required for installation. Please install sudo or doas, or run this script as root."
}

choose_root_runner() {
    if [ "$(id -u)" -eq 0 ]; then
        ROOT_RUNNER=""
        return 0
    fi

    if command -v sudo >/dev/null 2>&1; then
        ROOT_RUNNER="sudo"
        return 0
    fi

    if command -v doas >/dev/null 2>&1; then
        ROOT_RUNNER="doas"
        return 0
    fi

    ROOT_RUNNER=""
}

validate_platform() {
    [ -r /etc/os-release ] || fail "This system does not expose /etc/os-release."

    OS_ID=$(awk -F= '/^ID=/{gsub(/"/, "", $2); print $2}' /etc/os-release 2>/dev/null)
    [ "$OS_ID" = "artix" ] || fail "This installer only supports Artix Linux."

    command -v rc-service >/dev/null 2>&1 || fail "OpenRC tools were not found. This installer only supports Artix OpenRC."
    command -v pacman >/dev/null 2>&1 || fail "pacman was not found."
}

validate_source() {
    [ -f "$SOURCE_FILE" ] || fail "Could not find $APP_SOURCE_NAME beside this installer."
    [ -s "$SOURCE_FILE" ] || fail "$APP_SOURCE_NAME exists but is empty."
    [ -r "$SOURCE_FILE" ] || fail "$APP_SOURCE_NAME is not readable."
}

install_dependencies() {
    info "Installing required Artix packages."
    run_root pacman -Sy --needed --noconfirm $PACKAGES || fail "Package installation failed."
}

validate_runtime() {
    info "Checking the Perl application."
    perl -c "$SOURCE_FILE" >/dev/null 2>&1 || fail "Perl validation failed for $APP_SOURCE_NAME."
}

install_application() {
    info "Preparing installation folders."
    run_root mkdir -p "$INSTALL_BIN_DIR" "$INSTALL_APP_DIR" "$DESKTOP_DIR" || fail "Could not prepare installation folders."

    info "Installing the application files."
    run_root install -m 0755 "$SOURCE_FILE" "$INSTALL_BIN_FILE" || fail "Could not install the application launcher."
    run_root install -m 0644 "$SOURCE_FILE" "$INSTALL_APP_DIR/$APP_SOURCE_NAME" || fail "Could not install the source copy."
}

write_desktop_entry() {
    TMP_DESKTOP=$(mktemp "${TMPDIR:-/tmp}/baycat.desktop.XXXXXX") || fail "Could not create a temporary desktop file."

    cat > "$TMP_DESKTOP" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Neofelis Screen Manager
Comment=Friendly monitor manager for X11 screens
Exec=$INSTALL_BIN_FILE
Icon=video-display
Terminal=false
Categories=Settings;HardwareSettings;GTK;
Keywords=screen;monitor;display;xrandr;mirror;
StartupNotify=true
DESKTOP

    info "Installing the desktop launcher."
    run_root install -m 0644 "$TMP_DESKTOP" "$DESKTOP_FILE" || {
        rm -f "$TMP_DESKTOP"
        fail "Could not install the desktop launcher."
    }

    rm -f "$TMP_DESKTOP"

    if command -v update-desktop-database >/dev/null 2>&1; then
        run_root update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || warn "Desktop database refresh did not complete, but the launcher file was installed."
    fi
}

finish_message() {
    say ""
    say "Neofelis is installed."
    say ""
    say "Run it with:"
    say "  $INSTALL_BIN_FILE"
    say ""
    say "Or launch it from your graphical application menu as:"
    say "  Neofelis Screen Manager"
    say ""
    say "Installed files:"
    say "  Binary : $INSTALL_BIN_FILE"
    say "  Source : $INSTALL_APP_DIR/$APP_SOURCE_NAME"
    say "  Desktop: $DESKTOP_FILE"
}

main() {
    info "Starting Neofelis setup for Artix OpenRC."
    need_command awk
    need_command install
    need_command mkdir
    need_command mktemp
    choose_root_runner
    validate_platform
    validate_source
    install_dependencies
    validate_runtime
    install_application
    write_desktop_entry
    finish_message
}

main "$@"
