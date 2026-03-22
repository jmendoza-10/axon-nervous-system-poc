#!/usr/bin/env bash
# ============================================================================
# Axon Nervous System - Raspberry Pi SD Card Flasher
# ============================================================================
# Flashes Raspberry Pi OS Lite (64-bit) onto an SD card and pre-configures
# it for headless SSH access with your settings.
#
# Usage:
#   ./flash_pi_sd.sh [OPTIONS]
#
# Options:
#   --hostname NAME    Set the Pi hostname (default: axon-node)
#   --user NAME        Set the username (default: axon)
#   --password PASS    Set the password (default: prompted)
#   --wifi-ssid SSID   Configure WiFi SSID
#   --wifi-pass PASS   Configure WiFi password
#   --role ROLE        Node role: command | room (default: room)
#   --room-id ID       Room identifier for room nodes (default: room_a)
#   --board BOARD      Target board: pi4 | pi5 (default: pi4)
#   --skip-download    Skip image download if already cached
#   --help             Show this help
#
# Requires: macOS with diskutil, or Linux with lsblk
# ============================================================================
set -euo pipefail

# --- Defaults ---
HOSTNAME="axon-node"
USERNAME="axon"
PASSWORD=""
WIFI_SSID=""
WIFI_PASS=""
ROLE="room"
ROOM_ID="room_a"
BOARD="pi4"
SKIP_DOWNLOAD=false

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../.cache"

# Image URLs per board target
IMAGE_URL_PI4="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-11-19/2024-11-19-raspios-bookworm-arm64-lite.img.xz"
IMAGE_URL_PI5="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-02-06/2025-02-06-raspios-bookworm-arm64-lite.img.xz"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --hostname)   HOSTNAME="$2"; shift 2;;
        --user)       USERNAME="$2"; shift 2;;
        --password)   PASSWORD="$2"; shift 2;;
        --wifi-ssid)  WIFI_SSID="$2"; shift 2;;
        --wifi-pass)  WIFI_PASS="$2"; shift 2;;
        --role)       ROLE="$2"; shift 2;;
        --room-id)    ROOM_ID="$2"; shift 2;;
        --board)         BOARD="$2"; shift 2;;
        --skip-download) SKIP_DOWNLOAD=true; shift;;
        --help)
            sed -n '2,/^# ====/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0;;
        *) error "Unknown option: $1"; exit 1;;
    esac
done

# --- Validate board ---
if [[ "$BOARD" != "pi4" && "$BOARD" != "pi5" ]]; then
    error "Invalid board '$BOARD'. Use 'pi4' or 'pi5'."
    exit 1
fi

if [[ "$BOARD" == "pi5" ]]; then
    IMAGE_URL="$IMAGE_URL_PI5"
    IMAGE_FILENAME="raspios-bookworm-arm64-lite-pi5.img.xz"
    IMAGE_UNCOMPRESSED="raspios-bookworm-arm64-lite-pi5.img"
else
    IMAGE_URL="$IMAGE_URL_PI4"
    IMAGE_FILENAME="raspios-bookworm-arm64-lite.img.xz"
    IMAGE_UNCOMPRESSED="raspios-bookworm-arm64-lite.img"
fi

# --- Validate role ---
if [[ "$ROLE" != "command" && "$ROLE" != "room" ]]; then
    error "Invalid role '$ROLE'. Use 'command' or 'room'."
    exit 1
fi

# Auto-set hostname based on role if still default
if [[ "$HOSTNAME" == "axon-node" ]]; then
    if [[ "$ROLE" == "command" ]]; then
        HOSTNAME="axon-command"
    else
        HOSTNAME="axon-${ROOM_ID//_/-}"
    fi
fi

# --- Prompt for password if not provided ---
if [[ -z "$PASSWORD" ]]; then
    echo -n "Enter password for user '$USERNAME': "
    read -rs PASSWORD
    echo
    if [[ -z "$PASSWORD" ]]; then
        error "Password cannot be empty."
        exit 1
    fi
fi

# --- Detect OS ---
OS="$(uname -s)"
info "Detected OS: $OS"

# --- Check macOS requirements ---
check_requirements_macos() {
    info "Checking macOS requirements..."
    local missing=0

    _require() {
        local cmd="$1" install="$2" note="${3:-}"
        if command -v "$cmd" &>/dev/null; then
            ok "  $cmd"
        else
            error "  MISSING: $cmd  →  brew install $install"
            [[ -n "$note" ]] && echo "           $note"
            (( missing++ ))
        fi
    }

    # Check openssl supports -6 (SHA-512) — macOS ships LibreSSL which does not
    _check_openssl() {
        local found_openssl=""
        for candidate in \
            "openssl" \
            "/opt/homebrew/opt/openssl/bin/openssl" \
            "/usr/local/opt/openssl/bin/openssl"; do
            if command -v "$candidate" &>/dev/null 2>&1 && \
               "$candidate" passwd -6 "test" &>/dev/null 2>&1; then
                found_openssl="$candidate"
                break
            fi
        done
        if [[ -n "$found_openssl" ]]; then
            ok "  openssl (SHA-512)  [$found_openssl]"
        else
            error "  MISSING: openssl with SHA-512 (-6) support"
            error "           macOS ships LibreSSL which does not support -6"
            echo  "           Fix: brew install openssl"
            (( missing++ ))
        fi
    }

    echo ""
    echo "  Required:"
    _require curl   curl
    _require xz     xz     "(decompress .img.xz images)"
    _check_openssl
    echo ""
    echo "  Built-in (no install needed):"
    ok "  diskutil, dd, bc, python3"
    echo ""

    if [[ $missing -gt 0 ]]; then
        error "$missing missing requirement(s). Install with Homebrew then re-run."
        echo ""
        echo "  Install all at once:"
        echo "    brew install openssl xz"
        echo ""
        exit 1
    fi

    ok "All requirements satisfied."
    echo ""
}

[[ "$OS" == "Darwin" ]] && check_requirements_macos

# --- Discover SD card ---
discover_sd_card() {
    echo ""
    info "Looking for SD card..."

    if [[ "$OS" == "Darwin" ]]; then
        # macOS: skip synthesized (APFS virtual) disks; show physical disks
        # under 256 GB. Size comes from the `0:` line's *NNN GB column.
        # The built-in SD card reader shows as (internal, physical) on Mac
        # Studio/Mini, so we cannot filter by (external) alone.
        echo ""
        echo "  Available disks (<256 GB):"
        echo "  ────────────────────────────────────────────────────"
        printf "  %-10s %-12s %-30s\n" "DISK" "SIZE" "NAME"
        echo "  ────────────────────────────────────────────────────"
        _list_found=false
        _cur=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^(/dev/disk[0-9]+) ]]; then
                _cur="${BASH_REMATCH[1]}"
                [[ "$line" == *"synthesized"* ]] && _cur=""
            elif [[ -n "$_cur" && "$line" =~ ^[[:space:]]+0:[[:space:]] ]]; then
                _id="${_cur#/dev/}"  # save before clearing
                _cur=""
                # Physical disks use * prefix; APFS containers use + — skip the latter
                _size=$(echo "$line" | grep -oE '\*[0-9]+(\.[0-9]+)? [KMGT]B' | tr -d '*')
                [[ -z "$_size" ]] && continue
                _size_num=$(echo "$_size" | grep -oE '^[0-9]+')
                _size_unit=$(echo "$_size" | grep -oE '[A-Z]+$')
                [[ "$_size_unit" == "TB" ]] && continue
                [[ "$_size_unit" == "GB" && "${_size_num:-999}" -ge 256 ]] && continue
                _name=$(diskutil info "/dev/$_id" 2>/dev/null \
                    | awk -F: '/Media Name/{gsub(/^ +/,"",$2);print $2}' | head -1)
                printf "  %-10s %-12s %-30s\n" "$_id" "$_size" "${_name:-Unknown}"
                _list_found=true
            fi
        done < <(diskutil list)
        $_list_found || echo "  (none found — insert SD card and retry)"
        echo "  ────────────────────────────────────────────────────"
        echo ""
        echo -n "  Enter the disk identifier (e.g., disk4): "
        read -r DISK_ID
        DISK_DEVICE="/dev/${DISK_ID}"
        RAW_DEVICE="/dev/r${DISK_ID}"

        # Validate the disk exists
        if ! diskutil info "$DISK_DEVICE" &>/dev/null; then
            error "Disk $DISK_DEVICE not found."
            exit 1
        fi

        DISK_SIZE=$(diskutil list "$DISK_DEVICE" \
            | awk '/[[:space:]]0:[[:space:]]/ {match($0,/\*[0-9]+(\.[0-9]+)? [KMGT]B/); print substr($0,RSTART+1,RLENGTH-1)}')
        info "Selected: $DISK_DEVICE (${DISK_SIZE:-unknown size})"

    elif [[ "$OS" == "Linux" ]]; then
        echo ""
        echo "  Available removable block devices:"
        echo "  ───────────────────────────────────"
        lsblk -d -o NAME,SIZE,TYPE,TRAN | grep -E "usb|mmc" || echo "  (none found)"
        echo ""
        echo -n "  Enter the device name (e.g., sdb or mmcblk0): "
        read -r DISK_ID
        DISK_DEVICE="/dev/${DISK_ID}"
        RAW_DEVICE="$DISK_DEVICE"

        if [[ ! -b "$DISK_DEVICE" ]]; then
            error "Device $DISK_DEVICE not found."
            exit 1
        fi
    else
        error "Unsupported OS: $OS"
        exit 1
    fi

    # Final confirmation
    echo ""
    warn "⚠️  ALL DATA ON $DISK_DEVICE WILL BE ERASED!"
    echo -n "  Type 'YES' to continue: "
    read -r CONFIRM
    if [[ "$CONFIRM" != "YES" ]]; then
        info "Aborted."
        exit 0
    fi
}

# --- Download image ---
download_image() {
    mkdir -p "$CACHE_DIR"

    if [[ -f "$CACHE_DIR/$IMAGE_UNCOMPRESSED" && "$SKIP_DOWNLOAD" == true ]]; then
        ok "Using cached image: $CACHE_DIR/$IMAGE_UNCOMPRESSED"
        return
    fi

    if [[ ! -f "$CACHE_DIR/$IMAGE_FILENAME" ]]; then
        info "Downloading Raspberry Pi OS Lite (arm64)..."
        info "URL: $IMAGE_URL"
        curl -L --progress-bar -o "$CACHE_DIR/$IMAGE_FILENAME" "$IMAGE_URL"
        ok "Download complete."
    else
        ok "Image archive already cached."
    fi

    if [[ ! -f "$CACHE_DIR/$IMAGE_UNCOMPRESSED" ]]; then
        info "Decompressing image..."
        if command -v xz &>/dev/null; then
            xz -dk "$CACHE_DIR/$IMAGE_FILENAME"
        elif command -v unxz &>/dev/null; then
            unxz -k "$CACHE_DIR/$IMAGE_FILENAME"
        else
            error "xz not found. Install with: brew install xz (macOS) or apt install xz-utils (Linux)"
            exit 1
        fi
        ok "Decompressed to $CACHE_DIR/$IMAGE_UNCOMPRESSED"
    fi
}

# --- Flash image ---
flash_image() {
    info "Flashing image to $DISK_DEVICE..."

    if [[ "$OS" == "Darwin" ]]; then
        # Unmount all partitions on the disk
        diskutil unmountDisk "$DISK_DEVICE"
        # Use raw device for faster writes on macOS
        sudo dd if="$CACHE_DIR/$IMAGE_UNCOMPRESSED" of="$RAW_DEVICE" bs=4m status=progress
        sleep 2
    else
        # Linux: unmount any mounted partitions
        for part in "${DISK_DEVICE}"*; do
            sudo umount "$part" 2>/dev/null || true
        done
        sudo dd if="$CACHE_DIR/$IMAGE_UNCOMPRESSED" of="$DISK_DEVICE" bs=4M status=progress conv=fsync
        sync
        sleep 2
    fi

    ok "Image flashed successfully."
}

# --- Mount boot partition ---
mount_boot() {
    info "Mounting boot partition for headless config..."

    if [[ "$OS" == "Darwin" ]]; then
        # macOS auto-mounts after dd; eject and re-insert or just wait
        diskutil mountDisk "$DISK_DEVICE" 2>/dev/null || true
        sleep 3
        BOOT_MOUNT=$(diskutil info "${DISK_DEVICE}s1" 2>/dev/null | grep "Mount Point" | awk -F: '{print $2}' | xargs)
        if [[ -z "$BOOT_MOUNT" || ! -d "$BOOT_MOUNT" ]]; then
            # Try common paths
            for candidate in "/Volumes/bootfs" "/Volumes/boot"; do
                if [[ -d "$candidate" ]]; then
                    BOOT_MOUNT="$candidate"
                    break
                fi
            done
        fi
    else
        # Linux: re-read partition table and mount
        sudo partprobe "$DISK_DEVICE" 2>/dev/null || true
        sleep 2
        BOOT_MOUNT="/tmp/axon-boot"
        mkdir -p "$BOOT_MOUNT"
        BOOT_PART="${DISK_DEVICE}p1"
        [[ ! -b "$BOOT_PART" ]] && BOOT_PART="${DISK_DEVICE}1"
        sudo mount "$BOOT_PART" "$BOOT_MOUNT"
    fi

    if [[ -z "${BOOT_MOUNT:-}" || ! -d "$BOOT_MOUNT" ]]; then
        error "Could not find boot partition mount point."
        error "Manually mount the SD card's boot partition and re-run with --skip-download."
        exit 1
    fi

    ok "Boot partition mounted at: $BOOT_MOUNT"
}

# --- Configure headless settings ---
configure_headless() {
    info "Configuring headless settings..."

    # 1. Enable SSH
    sudo touch "$BOOT_MOUNT/ssh"
    ok "SSH enabled"

    # 2. Create user account (Pi OS Bookworm+ method)
    # macOS LibreSSL doesn't support -6 (SHA-512). Try several approaches:
    #   1. System openssl (works on Linux)
    #   2. Homebrew openssl (Apple Silicon / Intel paths)
    #   3. Python crypt module (removed in Python 3.13)
    ENCRYPTED_PASS=""
    if openssl passwd -6 "test" &>/dev/null 2>&1; then
        ENCRYPTED_PASS=$(openssl passwd -6 "$PASSWORD")
    elif /opt/homebrew/opt/openssl/bin/openssl passwd -6 "test" &>/dev/null 2>&1; then
        ENCRYPTED_PASS=$(/opt/homebrew/opt/openssl/bin/openssl passwd -6 "$PASSWORD")
    elif /usr/local/opt/openssl/bin/openssl passwd -6 "test" &>/dev/null 2>&1; then
        ENCRYPTED_PASS=$(/usr/local/opt/openssl/bin/openssl passwd -6 "$PASSWORD")
    else
        ENCRYPTED_PASS=$(python3 -c "
import sys
try:
    import crypt
    print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))
except (ImportError, AttributeError):
    sys.exit(1)
" "$PASSWORD" 2>/dev/null) || true
    fi

    if [[ -z "$ENCRYPTED_PASS" || "$ENCRYPTED_PASS" != '$6$'* ]]; then
        error "Could not generate a SHA-512 password hash."
        error "Fix: brew install openssl"
        error "Then re-run with --skip-download."
        exit 1
    fi

    echo "${USERNAME}:${ENCRYPTED_PASS}" | sudo tee "$BOOT_MOUNT/userconf.txt" > /dev/null

    # Verify the file was written correctly
    if [[ ! -f "$BOOT_MOUNT/userconf.txt" ]]; then
        error "userconf.txt was not written to $BOOT_MOUNT"
        exit 1
    fi
    ok "User '$USERNAME' configured (hash: ${ENCRYPTED_PASS:0:10}...)"

    # 3. Set hostname via cmdline.txt
    if [[ -f "$BOOT_MOUNT/cmdline.txt" ]]; then
        # Append hostname to kernel cmdline if not already set
        if ! grep -q "systemd.hostname=" "$BOOT_MOUNT/cmdline.txt"; then
            sudo sed -i.bak "s/$/ systemd.hostname=${HOSTNAME}/" "$BOOT_MOUNT/cmdline.txt"
        fi
    fi
    ok "Hostname set to '$HOSTNAME'"

    # 4. Zero-config WiFi + auto-run via two-boot strategy:
    #
    #   Boot 1 — systemd.run= fires firstrun.sh before NM starts.
    #            It only WRITES FILES (safe at this stage — no NM needed):
    #              - /etc/modprobe.d/cfg80211.conf  (WiFi regulatory domain)
    #              - /etc/NetworkManager/system-connections/ (NM keyfile)
    #              - /etc/systemd/system/axon-firstboot.service
    #            Then reboots.
    #
    #   Boot 2 — NM starts, finds the keyfile, WiFi connects.
    #            axon-firstboot.service runs setup.sh after network is online.
    #            No manual SSH required.
    if [[ -n "$WIFI_SSID" && -n "$WIFI_PASS" ]]; then
        WIFI_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")

        sudo tee "$BOOT_MOUNT/firstrun.sh" > /dev/null <<FIRSTRUNEOF
#!/bin/bash
set +e

# Remove ourselves from cmdline.txt first — prevents reboot loops on failure
sed -i 's| systemd\.run=[^ ]*||g; s| systemd\.run_success_action=[^ ]*||g; s| systemd\.run_failure_action=[^ ]*||g' \
    /boot/firmware/cmdline.txt

# 1. Set WiFi regulatory domain via raspi-config and unblock rfkill
raspi-config nonint do_wifi_country US || true
rfkill unblock all || true

# 2. Write NM keyfile directly (NM picks this up on next boot automatically)
mkdir -p /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/axon-wifi.nmconnection <<NMEOF
[connection]
id=axon-wifi
uuid=${WIFI_UUID}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${WIFI_SSID}

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=${WIFI_PASS}

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto
NMEOF
chmod 600 /etc/NetworkManager/system-connections/axon-wifi.nmconnection

# 3. Install a systemd service so setup.sh runs automatically on boot 2
cat > /etc/systemd/system/axon-firstboot.service <<SVCEOF
[Unit]
Description=Axon Nervous System First Boot Setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=/boot/firmware/axon-firstboot/setup.sh

[Service]
Type=oneshot
ExecStart=/bin/bash /boot/firmware/axon-firstboot/setup.sh
ExecStartPost=/bin/systemctl disable axon-firstboot.service
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl enable axon-firstboot.service

rm -f /boot/firmware/firstrun.sh
FIRSTRUNEOF
        sudo chmod +x "$BOOT_MOUNT/firstrun.sh"

        # Trigger firstrun.sh on boot 1 via systemd.run=
        if [[ -f "$BOOT_MOUNT/cmdline.txt" ]]; then
            if ! grep -q "systemd.run=" "$BOOT_MOUNT/cmdline.txt"; then
                sudo sed -i.bak \
                    's|$| systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.run_failure_action=reboot|' \
                    "$BOOT_MOUNT/cmdline.txt"
            fi
        fi
        ok "WiFi + auto-run configured (2-boot strategy)"
    else
        warn "No WiFi credentials — Pi will need eth0 and manual firstboot run"
    fi

    # 5. Write firstboot setup script
    # This script will run on the Pi's first boot to clone the repo and set up
    sudo mkdir -p "$BOOT_MOUNT/axon-firstboot"
    sudo tee "$BOOT_MOUNT/axon-firstboot/setup.sh" > /dev/null <<FBEOF
#!/usr/bin/env bash
# Axon first-boot auto-setup — runs once after initial boot

# ── Logging: set up BEFORE strict mode so nothing can kill it early ───────────
if echo "" >> /var/log/axon-firstboot.log 2>/dev/null; then
    LOG="/var/log/axon-firstboot.log"
    STATUS="/var/log/axon-firstboot.status"
else
    LOG="/tmp/axon-firstboot.log"
    STATUS="/tmp/axon-firstboot.status"
fi

log() {
    local msg="[\$(date '+%Y-%m-%d %H:%M:%S')] \$*"
    echo "\$msg" | tee -a "\$LOG"
    logger -t axon-firstboot "\$*" 2>/dev/null || true
}
step() { log ""; log ">>> STEP: \$*"; echo "\$(date "+%Y-%m-%d %H:%M:%S") STARTED  \$*" >> "\$STATUS"; }
ok()   { log "    OK: \$*";     sed -i "\$ s/STARTED /OK      /" "\$STATUS"; }
fail() { log "    FAILED: \$*"; sed -i "\$ s/STARTED /FAILED  /" "\$STATUS"; }

# Write first entry immediately — if this line appears in the log, the script ran
log "SCRIPT STARTED (pid=\$\$, user=\$(whoami), script=\$0)"

# NOW enable strict mode
set -euo pipefail

_on_error() {
    local code=\$? line=\$BASH_LINENO
    log "UNEXPECTED EXIT at line \$line (exit code \$code)"
    sed -i "s/STARTED /FAILED  /" "\$STATUS" 2>/dev/null || true
    echo "\$(date "+%Y-%m-%d %H:%M:%S") ABORTED  line \$line" >> "\$STATUS"
}
trap _on_error ERR

# Header
log "=================================================="
log " Axon Nervous System — First-Boot Setup"
log " Role:     ${ROLE}"
log " Hostname: ${HOSTNAME}"
log " Room ID:  ${ROOM_ID}"
log " Log:      \$LOG"
log " Status:   \$STATUS"
log "=================================================="
echo "\$(date '+%Y-%m-%d %H:%M:%S') STARTED  first-boot setup" > "\$STATUS"

# Snapshot initial network state
log "Network interfaces at start:"
ip -brief addr show 2>&1 | while IFS= read -r l; do log "  \$l"; done || true

# ── Step 1: Hostname ──────────────────────────────────────────────────────────
step "Set hostname to ${HOSTNAME}"
sudo hostnamectl set-hostname "${HOSTNAME}"
if grep -q "127.0.1.1" /etc/hosts; then
    sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${HOSTNAME}/" /etc/hosts
else
    echo -e "127.0.1.1\t${HOSTNAME}" | sudo tee -a /etc/hosts
fi
sudo systemctl restart avahi-daemon
ok "hostname=\$(hostname)"

# ── Step 2: WiFi ──────────────────────────────────────────────────────────────
step "Verify WiFi (configured in boot 1 via firstrun.sh)"
WLAN_IP=\$(ip -4 addr show wlan0 2>/dev/null | awk '/inet / {print \$2}')
if [[ -n "\$WLAN_IP" ]]; then
    ok "wlan0 up — \$WLAN_IP"
else
    log "  wlan0 not up yet, current interface state:"
    ip -brief addr show 2>&1 | while IFS= read -r l; do log "  \$l"; done || true
    log "  nmcli device status:"
    nmcli device status 2>&1 | while IFS= read -r l; do log "  \$l"; done || true
    fail "wlan0 has no IP — WiFi may not be configured. Check /etc/NetworkManager/system-connections/"
fi

# ── Step 3: Network reachability ─────────────────────────────────────────────
step "Wait for internet connectivity"
for i in \$(seq 1 30); do
    if ping -c 1 -W 3 github.com &>/dev/null; then
        ok "github.com reachable (attempt \$i)"
        break
    fi
    log "  Waiting for network... (\$i/30)"
    sleep 5
    if [[ \$i -eq 30 ]]; then
        fail "No internet after 150s — check network config"
        log "Final interface state:"; ip -brief addr show || true
    fi
done

# ── Step 4: System packages ───────────────────────────────────────────────────
step "apt update + upgrade"
export DEBIAN_FRONTEND=noninteractive
# --force-confdef: use default action on config conflicts (no prompt)
# --force-confold: keep existing config if it's been modified
APT_OPTS='-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold'
sudo apt-get update -qq
sudo apt-get upgrade -y -qq \$APT_OPTS
ok "system packages up to date"

step "Install dependencies"
sudo apt-get install -y -qq \$APT_OPTS python3-pip python3-venv mosquitto mosquitto-clients git
ok "python3-pip python3-venv mosquitto git installed"

# ── Step 5: Clone repo ────────────────────────────────────────────────────────
step "Clone axon-nervous-system repo"
PROJECT_DIR="/home/${USERNAME}/axon-nervous-system"
if [ ! -d "\$PROJECT_DIR" ]; then
    git clone https://github.com/jmendoza-10/axon-nervous-system-poc.git "\$PROJECT_DIR"
fi
chown -R ${USERNAME}:${USERNAME} "\$PROJECT_DIR"
ok "repo at \$PROJECT_DIR"

# ── Step 6: Node setup ────────────────────────────────────────────────────────
step "Run ${ROLE} node setup script"
cd "\$PROJECT_DIR"
if [ "${ROLE}" == "command" ]; then
    sudo -u ${USERNAME} bash scripts/setup_command_node.sh
else
    sudo -u ${USERNAME} bash scripts/setup_room_node.sh ${ROOM_ID}
fi
ok "${ROLE} node setup complete"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "=================================================="
echo " First-boot setup COMPLETE"
echo " Check status:  cat \$STATUS"
echo " Full log:      cat \$LOG"
echo "=================================================="
echo "\$(date '+%Y-%m-%d %H:%M:%S') COMPLETE first-boot setup" >> "\$STATUS"

sudo sed -i '/axon-firstboot/d' /etc/rc.local 2>/dev/null || true
FBEOF
    sudo chmod +x "$BOOT_MOUNT/axon-firstboot/setup.sh"

    # 6. Add firstboot to rc.local (runs on first boot)
    # We'll create a small script that can be triggered manually since
    # modern Raspberry Pi OS doesn't always use rc.local
    sudo tee "$BOOT_MOUNT/axon-firstboot/README.txt" > /dev/null <<READMEEOF
AXON NERVOUS SYSTEM - FIRST BOOT SETUP
=======================================
After the Pi boots for the first time:

1. SSH in:  ssh ${USERNAME}@${HOSTNAME}.local
2. Run:     sudo bash /boot/firmware/axon-firstboot/setup.sh

This will automatically:
  - Install all dependencies
  - Clone the Axon repo
  - Configure this Pi as a ${ROLE} node
  - Start all services

Role: ${ROLE}
Hostname: ${HOSTNAME}
Room ID: ${ROOM_ID}
READMEEOF

    ok "First-boot setup script written"
}

# --- Validate boot partition contents ---
validate_boot() {
    info "Validating boot partition contents..."
    local errors=0

    # userconf.txt — must exist and contain a valid SHA-512 hash
    if [[ ! -f "$BOOT_MOUNT/userconf.txt" ]]; then
        error "MISSING: userconf.txt not found on boot partition"
        (( errors++ ))
    else
        local userconf_content
        userconf_content=$(cat "$BOOT_MOUNT/userconf.txt")
        if [[ "$userconf_content" != *':'* ]]; then
            error "INVALID: userconf.txt missing colon separator: $userconf_content"
            (( errors++ ))
        elif [[ "$userconf_content" != *'$6$'* ]]; then
            error "INVALID: userconf.txt does not contain a SHA-512 hash (\$6\$...)"
            error "         Got: ${userconf_content:0:40}..."
            (( errors++ ))
        else
            local stored_user stored_hash
            stored_user="${userconf_content%%:*}"
            stored_hash="${userconf_content#*:}"
            ok "userconf.txt  user=${stored_user}  hash=${stored_hash:0:12}..."
        fi
    fi

    # ssh — must exist (enables SSH on first boot)
    if [[ ! -f "$BOOT_MOUNT/ssh" ]]; then
        error "MISSING: ssh file not found — SSH will not be enabled"
        (( errors++ ))
    else
        ok "ssh           present (SSH enabled)"
    fi

    # cmdline.txt — must exist and contain the hostname
    if [[ ! -f "$BOOT_MOUNT/cmdline.txt" ]]; then
        error "MISSING: cmdline.txt not found"
        (( errors++ ))
    elif ! grep -q "systemd.hostname=${HOSTNAME}" "$BOOT_MOUNT/cmdline.txt"; then
        warn "cmdline.txt   systemd.hostname not set (hostname may default to 'raspberrypi')"
    else
        ok "cmdline.txt   hostname=${HOSTNAME}"
    fi

    # firstboot script
    if [[ ! -f "$BOOT_MOUNT/axon-firstboot/setup.sh" ]]; then
        error "MISSING: axon-firstboot/setup.sh not found"
        (( errors++ ))
    else
        ok "firstboot     setup.sh present"
    fi

    # WiFi — firstrun.sh handles boot 1 setup
    if [[ -n "$WIFI_SSID" ]]; then
        if [[ ! -f "$BOOT_MOUNT/firstrun.sh" ]]; then
            error "MISSING: firstrun.sh — WiFi will not be configured on boot 1"
            (( errors++ ))
        elif ! grep -q "$WIFI_SSID" "$BOOT_MOUNT/firstrun.sh"; then
            warn "firstrun.sh exists but SSID '${WIFI_SSID}' not found in it"
        else
            ok "firstrun.sh          SSID=${WIFI_SSID} + axon-firstboot.service"
        fi
        if ! grep -q "systemd.run=" "$BOOT_MOUNT/cmdline.txt" 2>/dev/null; then
            warn "cmdline.txt missing systemd.run= — firstrun.sh will not trigger"
        fi
    fi

    echo ""
    if [[ $errors -gt 0 ]]; then
        error "Validation failed with $errors error(s). SD card may not boot correctly."
        error "Re-flash or manually copy the missing files to: $BOOT_MOUNT"
        exit 1
    fi

    ok "All checks passed — boot partition looks good."
}

# --- Cleanup and eject ---
cleanup() {
    info "Cleaning up..."

    if [[ "$OS" == "Darwin" ]]; then
        diskutil eject "$DISK_DEVICE" 2>/dev/null || true
    else
        sudo umount "$BOOT_MOUNT" 2>/dev/null || true
        sudo eject "$DISK_DEVICE" 2>/dev/null || true
    fi

    ok "SD card ejected safely."
}

# ==========================================================================
# Main
# ==========================================================================
echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║   Axon Nervous System — SD Card Flasher      ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""
echo "  Configuration:"
echo "    Board:     ${BOARD}"
echo "    Role:      ${ROLE}"
echo "    Hostname:  ${HOSTNAME}"
echo "    Username:  ${USERNAME}"
echo "    Room ID:   ${ROOM_ID}"
echo "    WiFi:      ${WIFI_SSID:-<not set>}"
echo ""

discover_sd_card
download_image
flash_image
mount_boot
configure_headless
validate_boot
cleanup

echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║   ✅ SD card ready!                           ║"
echo "  ╠══════════════════════════════════════════════╣"
echo "  ║                                              ║"
echo "  ║  1. Insert SD card into ${HOSTNAME}          ║"
echo "  ║  2. Power on the Pi                          ║"
echo "  ║  3. SSH in:                                  ║"
echo "  ║     ssh ${USERNAME}@${HOSTNAME}.local        ║"
echo "  ║  4. Run first-boot setup:                    ║"
echo "  ║     sudo bash /boot/firmware/axon-firstboot/setup.sh"
echo "  ║                                              ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""
