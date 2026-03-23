#!/usr/bin/env bash
# Deploy updated Python source to all Pi nodes via SCP + restart services
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

USER="axon"
REMOTE_DIR="axon-nervous-system"

COMMAND_HOST="axon-command.local"
ROOM_A_HOST="axon-room-a.local"
ROOM_B_HOST="axon-room-b.local"

usage() {
    echo "Usage: $0 [command|room-a|room-b|all]"
    echo ""
    echo "  command  - Deploy to command node only"
    echo "  room-a   - Deploy to room A node only"
    echo "  room-b   - Deploy to room B node only"
    echo "  all      - Deploy to all nodes (default)"
    echo ""
    echo "Examples:"
    echo "  $0"
    echo "  $0 command"
    echo "  $0 room-a"
    exit 0
}

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    usage
fi

TARGET="${1:-all}"

deploy_command() {
    local host="$COMMAND_HOST"
    echo ""
    echo "=== Deploying to command node ($host) ==="

    echo "  Copying pi/command_node/..."
    scp -r "$PROJECT_DIR/pi/command_node/" "$USER@$host:$REMOTE_DIR/pi/"

    echo "  Resetting evidence chain..."
    ssh "$USER@$host" "rm -f $REMOTE_DIR/pi/command_node/evidence_store/evidence_chain.jsonl"

    echo "  Restarting axon-dashboard..."
    ssh "$USER@$host" "sudo systemctl restart axon-dashboard"

    echo "  Waiting for service to come up..."
    sleep 3
    ssh "$USER@$host" "sudo systemctl is-active axon-dashboard"
    echo "  OK: axon-dashboard running on $host"
}

deploy_room() {
    local host="$1"
    local label="$2"
    echo ""
    echo "=== Deploying to $label ($host) ==="

    echo "  Copying pi/room_node/..."
    scp -r "$PROJECT_DIR/pi/room_node/" "$USER@$host:$REMOTE_DIR/pi/"

    echo "  Restarting axon-csi-processor and axon-reticulum-bridge..."
    ssh "$USER@$host" "sudo systemctl restart axon-csi-processor axon-reticulum-bridge"

    echo "  Waiting for services to come up..."
    sleep 3
    ssh "$USER@$host" "sudo systemctl is-active axon-csi-processor axon-reticulum-bridge"
    echo "  OK: services running on $host"
}

case "$TARGET" in
    command)
        deploy_command
        ;;
    room-a)
        deploy_room "$ROOM_A_HOST" "room A"
        ;;
    room-b)
        deploy_room "$ROOM_B_HOST" "room B"
        ;;
    all)
        deploy_command
        deploy_room "$ROOM_A_HOST" "room A"
        # Deploy room B only if reachable
        if ssh -o ConnectTimeout=5 -o BatchMode=yes "$USER@$ROOM_B_HOST" true 2>/dev/null; then
            deploy_room "$ROOM_B_HOST" "room B"
        else
            echo ""
            echo "  Skipping room B ($ROOM_B_HOST) — not reachable"
        fi
        ;;
    *)
        usage
        ;;
esac

echo ""
echo "=== Deploy complete ==="
