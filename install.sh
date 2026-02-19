#!/usr/bin/env bash
# Media Manager - Interactive Installer / Updater / Uninstaller
# Supports macOS and Linux (Debian/Ubuntu, Fedora/RHEL, Arch)
# Version: 1.0.0
#
# Usage:
#   Install/Upgrade: curl -sL <url>/install.sh | bash
#   Or locally:      ./install.sh [install|upgrade|uninstall]

set -euo pipefail

# ---------- Constants ----------
VERSION="1.0.0"
APP_NAME="Media Manager"
SERVICE_NAME="media-manager"
REPO_URL="https://github.com/ronaldjonkers/PlexScripts.git"

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- Helpers ----------
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}\n"; }

confirm() {
    local prompt="$1" default="${2:-n}"
    local yn
    if [ "$default" = "y" ]; then
        read -p "$(echo -e "${BOLD}$prompt [Y/n]:${NC} ")" -r yn
        yn="${yn:-y}"
    else
        read -p "$(echo -e "${BOLD}$prompt [y/N]:${NC} ")" -r yn
        yn="${yn:-n}"
    fi
    [[ "$yn" =~ ^[Yy] ]]
}

detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)  echo "linux" ;;
        *)      echo "unknown" ;;
    esac
}

detect_linux_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|pop|linuxmint) echo "debian" ;;
            fedora|rhel|centos|rocky|alma) echo "redhat" ;;
            arch|manjaro|endeavouros) echo "arch" ;;
            *) echo "unknown" ;;
        esac
    else
        echo "unknown"
    fi
}

# ---------- Dependency Installation ----------
install_homebrew() {
    if ! command -v brew >/dev/null 2>&1; then
        info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        # Add to PATH for Apple Silicon
        if [ -f "/opt/homebrew/bin/brew" ]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
        ok "Homebrew installed"
    else
        ok "Homebrew already installed"
    fi
}

install_deps_macos() {
    header "Installing Dependencies (macOS)"
    install_homebrew

    # Ensure svt-av1 is installed (HandBrakeCLI depends on it)
    if ! brew list svt-av1 >/dev/null 2>&1; then
        info "Installing svt-av1 (HandBrake dependency)..."
        brew install svt-av1
    else
        ok "svt-av1 already installed"
    fi

    local deps=("handbrake" "ffmpeg" "python3")
    local brew_deps=("handbrake" "ffmpeg" "python3")

    for i in "${!deps[@]}"; do
        local name="${deps[$i]}"
        local pkg="${brew_deps[$i]}"
        if [ "$name" = "handbrake" ]; then
            if command -v HandBrakeCLI >/dev/null 2>&1; then
                # Verify it actually works (not broken deps)
                if HandBrakeCLI --version 2>&1 | grep -q "Library not loaded"; then
                    warn "HandBrakeCLI has broken dependencies, reinstalling..."
                    brew reinstall svt-av1 handbrake 2>/dev/null || true
                else
                    ok "HandBrakeCLI already installed and working"
                fi
            else
                info "Installing HandBrakeCLI..."
                brew install handbrake 2>/dev/null || brew install --cask handbrake 2>/dev/null || {
                    warn "Could not auto-install HandBrakeCLI"
                    warn "Please install manually: https://handbrake.fr/downloads2.php"
                }
            fi
        elif [ "$name" = "python3" ]; then
            if command -v python3 >/dev/null 2>&1; then
                ok "python3 already installed"
            else
                info "Installing python3..."
                brew install python3
            fi
        else
            if command -v "$name" >/dev/null 2>&1; then
                ok "$name already installed"
            elif command -v ffprobe >/dev/null 2>&1 && [ "$name" = "ffmpeg" ]; then
                ok "ffprobe already installed (via ffmpeg)"
            else
                info "Installing $pkg..."
                brew install "$pkg"
            fi
        fi
    done
}

install_deps_linux() {
    header "Installing Dependencies (Linux)"
    local distro
    distro="$(detect_linux_distro)"

    case "$distro" in
        debian)
            info "Detected Debian/Ubuntu-based system"
            sudo apt-get update -qq
            sudo apt-get install -y -qq ffmpeg python3 handbrake-cli 2>/dev/null || {
                warn "handbrake-cli not in repos, trying flatpak/snap..."
                sudo apt-get install -y -qq ffmpeg python3
                if command -v flatpak >/dev/null 2>&1; then
                    flatpak install -y flathub fr.handbrake.ghb 2>/dev/null || true
                fi
                if ! command -v HandBrakeCLI >/dev/null 2>&1; then
                    warn "Please install HandBrakeCLI manually: https://handbrake.fr/downloads2.php"
                fi
            }
            ;;
        redhat)
            info "Detected Fedora/RHEL-based system"
            sudo dnf install -y ffmpeg python3 2>/dev/null || sudo yum install -y ffmpeg python3
            sudo dnf install -y HandBrake-cli 2>/dev/null || {
                warn "Please install HandBrakeCLI manually: https://handbrake.fr/downloads2.php"
            }
            ;;
        arch)
            info "Detected Arch-based system"
            sudo pacman -Syu --noconfirm ffmpeg python handbrake-cli 2>/dev/null || {
                sudo pacman -Syu --noconfirm ffmpeg python
                warn "Please install handbrake-cli from AUR"
            }
            ;;
        *)
            warn "Unknown Linux distribution"
            warn "Please install manually: ffmpeg, python3, HandBrakeCLI"
            ;;
    esac
}

install_dependencies() {
    local os
    os="$(detect_os)"
    case "$os" in
        macos) install_deps_macos ;;
        linux) install_deps_linux ;;
        *)     error "Unsupported OS"; exit 1 ;;
    esac

    # Verify all dependencies
    header "Verifying Dependencies"
    local all_ok=true
    for cmd in HandBrakeCLI ffprobe python3; do
        if command -v "$cmd" >/dev/null 2>&1; then
            ok "$cmd found: $(command -v "$cmd")"
        else
            error "$cmd NOT found"
            all_ok=false
        fi
    done
    if [ "$all_ok" = false ]; then
        warn "Some dependencies are missing. The service may not work correctly."
        if ! confirm "Continue anyway?"; then
            exit 1
        fi
    fi
}

# ---------- Quality Profile Selection ----------
select_quality_profile() {
    header "Quality Profile Selection"
    echo -e "Choose a quality profile for video encoding:\n"
    echo -e "  ${BOLD}1) UltraSaver${NC}    - 2160p: 7 Mbps  | 1080p: 3 Mbps  | 720p: 1 Mbps"
    echo -e "  ${BOLD}2) DataDiet${NC}      - 2160p: 8 Mbps  | 1080p: 4 Mbps  | 720p: 1.5 Mbps"
    echo -e "  ${BOLD}3) StreamSaver${NC}   - 2160p: 10 Mbps | 1080p: 5 Mbps  | 720p: 2.5 Mbps"
    echo -e "  ${BOLD}4) Netflix-ish${NC}   - 2160p: 12 Mbps | 1080p: 6 Mbps  | 720p: 3 Mbps"
    echo -e "  ${BOLD}5) CrispCable${NC}    - 2160p: 16 Mbps | 1080p: 8 Mbps  | 720p: 4 Mbps"
    echo -e "  ${BOLD}6) ArchivalLite${NC}  - 2160p: 20 Mbps | 1080p: 10 Mbps | 720p: 5 Mbps"
    echo -e "  ${BOLD}7) MaxPunch${NC}      - 2160p: 24 Mbps | 1080p: 12 Mbps | 720p: 6 Mbps"
    echo -e "  ${BOLD}8) Custom${NC}        - Enter your own bitrates"
    echo ""

    local choice
    read -p "$(echo -e "${BOLD}Choose profile [1-8]:${NC} ")" -r choice

    case "$choice" in
        1) PROFILE_NAME="UltraSaver";   VB2160=7000;  VB1080=3000;  VB720=1000  ;;
        2) PROFILE_NAME="DataDiet";     VB2160=8000;  VB1080=4000;  VB720=1500  ;;
        3) PROFILE_NAME="StreamSaver";  VB2160=10000; VB1080=5000;  VB720=2500  ;;
        4) PROFILE_NAME="Netflix-ish";  VB2160=12000; VB1080=6000;  VB720=3000  ;;
        5) PROFILE_NAME="CrispCable";   VB2160=16000; VB1080=8000;  VB720=4000  ;;
        6) PROFILE_NAME="ArchivalLite"; VB2160=20000; VB1080=10000; VB720=5000  ;;
        7) PROFILE_NAME="MaxPunch";     VB2160=24000; VB1080=12000; VB720=6000  ;;
        8)
            PROFILE_NAME="Custom"
            read -p "$(echo -e "${BOLD}2160p bitrate (kbps) [12000]:${NC} ")" -r VB2160
            VB2160="${VB2160:-12000}"
            read -p "$(echo -e "${BOLD}1080p bitrate (kbps) [6000]:${NC} ")" -r VB1080
            VB1080="${VB1080:-6000}"
            read -p "$(echo -e "${BOLD}720p bitrate (kbps) [3000]:${NC} ")" -r VB720
            VB720="${VB720:-3000}"
            ;;
        *) error "Invalid choice"; exit 1 ;;
    esac

    ok "Profile: ${PROFILE_NAME} (2160p=${VB2160}kbps, 1080p=${VB1080}kbps, 720p=${VB720}kbps)"
}

# ---------- Watch Directory Configuration ----------
configure_watch_dirs() {
    header "Watch Directory Configuration"
    echo -e "Add directories to watch for media files."
    echo -e "For each directory, specify the media type: ${BOLD}movies${NC}, ${BOLD}series${NC}, or ${BOLD}auto${NC} (auto-detect).\n"

    WATCH_DIRS=()
    local adding=true

    while [ "$adding" = true ]; do
        local dir type
        read -p "$(echo -e "${BOLD}Directory path:${NC} ")" -r dir
        dir="$(echo "$dir" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        if [ -z "$dir" ]; then
            if [ ${#WATCH_DIRS[@]} -eq 0 ]; then
                warn "You must add at least one directory"
                continue
            fi
            break
        fi

        if [ ! -d "$dir" ]; then
            warn "Directory does not exist: $dir"
            if ! confirm "Add anyway? (it may be mounted later)"; then
                continue
            fi
        fi

        echo -e "  Media type: ${BOLD}1)${NC} movies  ${BOLD}2)${NC} series  ${BOLD}3)${NC} auto-detect"
        read -p "$(echo -e "${BOLD}Choose type [1-3]:${NC} ")" -r type_choice
        case "$type_choice" in
            1) type="movies" ;;
            2) type="series" ;;
            3) type="auto"   ;;
            *) type="auto"   ;;
        esac

        WATCH_DIRS+=("${dir}|${type}")
        ok "Added: ${dir} (${type})"
        echo ""

        if ! confirm "Add another directory?" "n"; then
            adding=false
        fi
    done
}

# ---------- Additional Settings ----------
configure_settings() {
    header "Additional Settings"

    # Delete originals
    if confirm "Delete original files after successful encoding?" "n"; then
        DELETE_ORIGINALS="yes"
    else
        DELETE_ORIGINALS="no"
    fi

    # Scan interval
    read -p "$(echo -e "${BOLD}Scan interval in seconds [300]:${NC} ")" -r SCAN_INTERVAL
    SCAN_INTERVAL="${SCAN_INTERVAL:-300}"

    # Encoder preset
    local os
    os="$(detect_os)"
    if [ "$os" = "macos" ]; then
        echo -e "\nVideoToolbox preset: ${BOLD}1)${NC} fast  ${BOLD}2)${NC} balanced  ${BOLD}3)${NC} quality"
        read -p "$(echo -e "${BOLD}Choose preset [1-3, default=3]:${NC} ")" -r vt_choice
        case "$vt_choice" in
            1) VT_PRESET="fast"     ;;
            2) VT_PRESET="balanced" ;;
            *) VT_PRESET="quality"  ;;
        esac
    else
        VT_PRESET="quality"
    fi

    echo -e "\nx265 software preset: ${BOLD}1)${NC} fast  ${BOLD}2)${NC} medium  ${BOLD}3)${NC} slow  ${BOLD}4)${NC} veryslow"
    read -p "$(echo -e "${BOLD}Choose preset [1-4, default=3]:${NC} ")" -r x265_choice
    case "$x265_choice" in
        1) X265_PRESET="fast"     ;;
        2) X265_PRESET="medium"   ;;
        4) X265_PRESET="veryslow" ;;
        *) X265_PRESET="slow"     ;;
    esac

    ok "Settings configured"
}

# ---------- Write Config ----------
write_config() {
    local config_file="$1"
    local config_dir
    config_dir="$(dirname "$config_file")"
    mkdir -p "$config_dir"

    cat > "$config_file" <<CONF
# Media Manager Configuration
# Generated by install.sh on $(date)

# ---------- Quality Profile ----------
PROFILE_NAME="${PROFILE_NAME}"
VB2160=${VB2160}
VB1080=${VB1080}
VB720=${VB720}

# ---------- Encoding Settings ----------
VT_PRESET="${VT_PRESET}"
X265_PRESET="${X265_PRESET}"
TOL_PCT=5

# ---------- File Management ----------
DELETE_ORIGINALS="${DELETE_ORIGINALS}"

# ---------- Service Settings ----------
SCAN_INTERVAL=${SCAN_INTERVAL}
ENABLE_LOGGING="true"
LOG_FILE="${INSTALL_DIR}/logs/media-manager.log"

# ---------- Watch Directories ----------
WATCH_DIRS=(
CONF

    for entry in "${WATCH_DIRS[@]}"; do
        echo "    \"${entry}\"" >> "$config_file"
    done

    echo ")" >> "$config_file"

    ok "Config written to: $config_file"
}

# ---------- Service Installation ----------
install_service() {
    local os
    os="$(detect_os)"

    if ! confirm "Start Media Manager automatically at boot?" "y"; then
        info "Skipping service installation"
        return 0
    fi

    header "Installing Service"

    if [ "$os" = "macos" ]; then
        local plist_src="${INSTALL_DIR}/service/com.media-manager.plist"
        local plist_dst="${HOME}/Library/LaunchAgents/com.media-manager.plist"
        local log_dir="${INSTALL_DIR}/logs"
        mkdir -p "$log_dir"
        mkdir -p "$(dirname "$plist_dst")"

        # Generate plist with actual paths
        sed -e "s|__INSTALL_DIR__|${INSTALL_DIR}|g" \
            -e "s|__CONFIG_DIR__|${INSTALL_DIR}/config|g" \
            -e "s|__LOG_DIR__|${log_dir}|g" \
            "$plist_src" > "$plist_dst"

        # Unload if already loaded
        launchctl unload "$plist_dst" 2>/dev/null || true
        launchctl load "$plist_dst"
        ok "LaunchAgent installed and loaded"
        info "Service will start automatically at login"

    elif [ "$os" = "linux" ]; then
        local service_src="${INSTALL_DIR}/service/media-manager.service"
        local service_dir="${HOME}/.config/systemd/user"
        local service_dst="${service_dir}/media-manager.service"
        mkdir -p "$service_dir"

        sed -e "s|__INSTALL_DIR__|${INSTALL_DIR}|g" \
            -e "s|__CONFIG_DIR__|${INSTALL_DIR}/config|g" \
            "$service_src" > "$service_dst"

        systemctl --user daemon-reload
        systemctl --user enable media-manager.service
        ok "Systemd user service installed and enabled"
        info "Service will start automatically at login"
    fi
}

uninstall_service() {
    local os
    os="$(detect_os)"

    if [ "$os" = "macos" ]; then
        local plist="${HOME}/Library/LaunchAgents/com.media-manager.plist"
        if [ -f "$plist" ]; then
            launchctl unload "$plist" 2>/dev/null || true
            rm -f "$plist"
            ok "LaunchAgent removed"
        fi
    elif [ "$os" = "linux" ]; then
        local service="${HOME}/.config/systemd/user/media-manager.service"
        if [ -f "$service" ]; then
            systemctl --user stop media-manager.service 2>/dev/null || true
            systemctl --user disable media-manager.service 2>/dev/null || true
            rm -f "$service"
            systemctl --user daemon-reload
            ok "Systemd service removed"
        fi
    fi
}

start_service_now() {
    if confirm "Start Media Manager now?" "y"; then
        local os
        os="$(detect_os)"
        if [ "$os" = "macos" ]; then
            local plist="${HOME}/Library/LaunchAgents/com.media-manager.plist"
            if [ -f "$plist" ]; then
                launchctl unload "$plist" 2>/dev/null || true
                launchctl load "$plist"
                ok "Service started via LaunchAgent"
                return 0
            fi
        elif [ "$os" = "linux" ]; then
            if systemctl --user is-enabled media-manager.service >/dev/null 2>&1; then
                systemctl --user restart media-manager.service
                ok "Service started via systemd"
                return 0
            fi
        fi

        # Fallback: start directly in background
        info "Starting in background..."
        nohup "${INSTALL_DIR}/bin/media-manager" start \
            -c "${INSTALL_DIR}/config/media-manager.conf" \
            > "${INSTALL_DIR}/logs/media-manager.log" 2>&1 &
        ok "Service started (PID: $!)"
    fi
}

# ---------- Install / Upgrade ----------
do_install() {
    header "${APP_NAME} v${VERSION} - Installer"

    echo -e "This installer will:"
    echo -e "  1. Install required dependencies (ffmpeg, HandBrake, python3)"
    echo -e "  2. Configure quality profiles and watch directories"
    echo -e "  3. Optionally set up as a system service"
    echo ""

    if ! confirm "Continue with installation?" "y"; then
        info "Installation cancelled"
        exit 0
    fi

    # Determine install directory
    local script_dir
    if [ -f "${BASH_SOURCE[0]}" ]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    else
        script_dir="$(pwd)"
    fi

    # Check if running from repo
    if [ -f "${script_dir}/bin/media-manager" ]; then
        INSTALL_DIR="$script_dir"
    else
        INSTALL_DIR="${HOME}/.media-manager"
        info "Cloning repository to ${INSTALL_DIR}..."
        if [ -d "$INSTALL_DIR" ]; then
            cd "$INSTALL_DIR" && git pull
        else
            git clone "$REPO_URL" "$INSTALL_DIR"
        fi
    fi

    ok "Install directory: ${INSTALL_DIR}"

    # Make binaries executable
    chmod +x "${INSTALL_DIR}/bin/media-manager"

    # Install dependencies
    install_dependencies

    # Configure
    select_quality_profile
    configure_watch_dirs
    configure_settings

    # Write config
    write_config "${INSTALL_DIR}/config/media-manager.conf"

    # Create log directory
    mkdir -p "${INSTALL_DIR}/logs"

    # Install service
    install_service

    # Summary
    header "Installation Complete"
    echo -e "  ${BOLD}Install dir:${NC}  ${INSTALL_DIR}"
    echo -e "  ${BOLD}Config:${NC}       ${INSTALL_DIR}/config/media-manager.conf"
    echo -e "  ${BOLD}Logs:${NC}         ${INSTALL_DIR}/logs/media-manager.log"
    echo -e "  ${BOLD}Profile:${NC}      ${PROFILE_NAME}"
    echo -e "  ${BOLD}Directories:${NC}  ${#WATCH_DIRS[@]} configured"
    echo ""
    echo -e "  ${BOLD}Commands:${NC}"
    echo -e "    Start:   ${CYAN}${INSTALL_DIR}/bin/media-manager start${NC}"
    echo -e "    Scan:    ${CYAN}${INSTALL_DIR}/bin/media-manager scan${NC}"
    echo -e "    Status:  ${CYAN}${INSTALL_DIR}/bin/media-manager status${NC}"
    echo -e "    Stop:    ${CYAN}${INSTALL_DIR}/bin/media-manager stop${NC}"
    echo ""

    # Optionally start now
    start_service_now
}

do_upgrade() {
    header "${APP_NAME} - Upgrade"

    local script_dir
    if [ -f "${BASH_SOURCE[0]}" ]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    else
        script_dir="$(pwd)"
    fi

    if [ -f "${script_dir}/bin/media-manager" ]; then
        INSTALL_DIR="$script_dir"
    elif [ -d "${HOME}/.media-manager" ]; then
        INSTALL_DIR="${HOME}/.media-manager"
    else
        error "Media Manager installation not found"
        exit 1
    fi

    info "Upgrading in: ${INSTALL_DIR}"

    # Pull latest
    if [ -d "${INSTALL_DIR}/.git" ]; then
        cd "$INSTALL_DIR" && git pull
        ok "Updated to latest version"
    fi

    # Update dependencies
    install_dependencies

    # Make binaries executable
    chmod +x "${INSTALL_DIR}/bin/media-manager"

    # Restart service if running
    if "${INSTALL_DIR}/bin/media-manager" status >/dev/null 2>&1; then
        info "Restarting service..."
        "${INSTALL_DIR}/bin/media-manager" stop
        sleep 2
        start_service_now
    fi

    ok "Upgrade complete"
}

do_uninstall() {
    header "${APP_NAME} - Uninstall"

    if ! confirm "Are you sure you want to uninstall ${APP_NAME}?" "n"; then
        info "Uninstall cancelled"
        exit 0
    fi

    local script_dir
    if [ -f "${BASH_SOURCE[0]}" ]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    else
        script_dir="$(pwd)"
    fi

    if [ -f "${script_dir}/bin/media-manager" ]; then
        INSTALL_DIR="$script_dir"
    elif [ -d "${HOME}/.media-manager" ]; then
        INSTALL_DIR="${HOME}/.media-manager"
    else
        error "Media Manager installation not found"
        exit 1
    fi

    # Stop service
    "${INSTALL_DIR}/bin/media-manager" stop 2>/dev/null || true

    # Remove service files
    uninstall_service

    # Remove config (ask first)
    if confirm "Remove configuration files?" "n"; then
        rm -f "${INSTALL_DIR}/config/media-manager.conf"
        ok "Config removed"
    fi

    # Remove logs
    if confirm "Remove log files?" "y"; then
        rm -rf "${INSTALL_DIR}/logs"
        ok "Logs removed"
    fi

    # Remove installation if cloned
    if [ "$INSTALL_DIR" = "${HOME}/.media-manager" ]; then
        if confirm "Remove entire installation directory (${INSTALL_DIR})?" "n"; then
            rm -rf "$INSTALL_DIR"
            ok "Installation directory removed"
        fi
    fi

    ok "Uninstall complete"
}

# ---------- Main ----------
header "${APP_NAME} v${VERSION}"
echo -e "  OS: $(detect_os) ($(uname -m))"
if [ "$(detect_os)" = "linux" ]; then
    echo -e "  Distro: $(detect_linux_distro)"
fi
echo ""

COMMAND="${1:-}"

if [ -z "$COMMAND" ]; then
    echo -e "  ${BOLD}1)${NC} Install / Setup"
    echo -e "  ${BOLD}2)${NC} Upgrade"
    echo -e "  ${BOLD}3)${NC} Uninstall"
    echo ""
    read -p "$(echo -e "${BOLD}Choose action [1-3]:${NC} ")" -r action
    case "$action" in
        1) COMMAND="install"   ;;
        2) COMMAND="upgrade"   ;;
        3) COMMAND="uninstall" ;;
        *) error "Invalid choice"; exit 1 ;;
    esac
fi

case "$COMMAND" in
    install)   do_install   ;;
    upgrade)   do_upgrade   ;;
    uninstall) do_uninstall ;;
    *)         error "Unknown command: $COMMAND"; echo "Usage: $0 [install|upgrade|uninstall]"; exit 1 ;;
esac
