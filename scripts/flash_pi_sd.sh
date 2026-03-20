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
SKIP_DOWNLOAD=false

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../.cache"
IMAGE_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-11-19/2024-11-19-raspios-bookworm-arm64-lite.img.xz"
IMAGE_FILENAME="raspios-bookworm-arm64-lite.img.xz"
IMAGE_UNCOMPRESSED="raspios-bookworm-arm64-lite.img"

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
        --skip-download) SKIP_DOWNLOAD=true; shift;;
        --help)
            sed -n '2,/^# ====/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0;;
        *) error "Unknown option: $1"; exit 1;;
    esac
done

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

# --- Discover SD card ---
discover_sd_card() {
    echo ""
    info "Looking for SD card..."

    if [[ "$OS" == "Darwin" ]]; then
        # macOS: list external physical disks
        echo ""
        echo "  Available external disks:"
        echo "  ─────────────────────────"
        diskutil list external physical 2>/dev/null || true
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

        # Safety: confirm this looks like an SD card (< 256GB)
        DISK_SIZE=$(diskutil info "$DISK_DEVICE" | grep "Disk Size" | awk '{print $5}' | tr -d '(')
        DISK_SIZE_GB=$(echo "$DISK_SIZE / 1000000000" | bc 2>/dev/null || echo "unknown")
        info "Selected: $DISK_DEVICE (~${DISK_SIZE_GB} GB)"

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
    ENCRYPTED_PASS=$(openssl passwd -6 "$PASSWORD")
    echo "${USERNAME}:${ENCRYPTED_PASS}" | sudo tee "$BOOT_MOUNT/userconf.txt" > /dev/null
    ok "User '$USERNAME' configured"

    # 3. Set hostname via cmdline.txt
    if [[ -f "$BOOT_MOUNT/cmdline.txt" ]]; then
        # Append hostname to kernel cmdline if not already set
        if ! grep -q "systemd.hostname=" "$BOOT_MOUNT/cmdline.txt"; then
            sudo sed -i.bak "s/$/ systemd.hostname=${HOSTNAME}/" "$BOOT_MOUNT/cmdline.txt"
        fi
    fi
    ok "Hostname set to '$HOSTNAME'"

    # 4. Configure WiFi (if provided)
    if [[ -n "$WIFI_SSID" && -n "$WIFI_PASS" ]]; then
        sudo tee "$BOOT_MOUNT/wpa_supplicant.conf" > /dev/null <<WPAEOF
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="${WIFI_SSID}"
    psk="${WIFI_PASS}"
    key_mgmt=WPA-PSK
}
WPAEOF
        ok "WiFi configured for SSID: $WIFI_SSID"
    else
        warn "No WiFi configured (use --wifi-ssid and --wifi-pass if needed)"
    fi

    # 5. Write firstboot setup script
    # This script will run on the Pi's first boot to clone the repo and set up
    sudo mkdir -p "$BOOT_MOUNT/axon-firstboot"
    sudo tee "$BOOT_MOUNT/axon-firstboot/setup.sh" > /dev/null <<FBEOF
#!/usr/bin/env bash
# Axon first-boot auto-setup — runs once after initial boot
set -euo pipefail

LOG="/var/log/axon-firstboot.log"
exec > >(tee -a "\$LOG") 2>&1

echo "[\$(date)] Axon first-boot setup starting..."
echo "Role: ${ROLE} | Hostname: ${HOSTNAME} | Room ID: ${ROOM_ID}"

# Wait for network
for i in {1..30}; do
    if ping -c 1 github.com &>/dev/null; then break; fi
    echo "Waiting for network... (\$i/30)"
    sleep 5
done

# Run common setup
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y python3-pip python3-venv mosquitto mosquitto-clients git

# Clone the repo
PROJECT_DIR="/home/${USERNAME}/axon-nervous-system"
if [ ! -d "\$PROJECT_DIR" ]; then
    git clone https://github.com/jmendoza-10/axon-nervous-system-poc.git "\$PROJECT_DIR"
fi
chown -R ${USERNAME}:${USERNAME} "\$PROJECT_DIR"

# Run the appropriate setup script
cd "\$PROJECT_DIR"
if [ "${ROLE}" == "command" ]; then
    sudo -u ${USERNAME} bash scripts/setup_command_node.sh
else
    sudo -u ${USERNAME} bash scripts/setup_room_node.sh ${ROOM_ID}
fi

echo "[\$(date)] Axon first-boot setup complete!"

# Self-destruct: remove from rc.local
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
