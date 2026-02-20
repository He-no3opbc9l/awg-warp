#!/bin/bash

# =============================================================================
# WARP Setup Script — runs on VPS to create a WARP tunnel (warp0 interface)
# Traffic from AWG clients will be routed through this tunnel.
#
# Usage: bash warp_setup.sh [install|up|down|status|uninstall]
# =============================================================================

set -e

WARP_DIR="/etc/amnezia/warp"
WARP_CONF="${WARP_DIR}/warp0.conf"
WARP_IFACE="warp0"
WARP_TABLE="51820"
WARP_FWMARK="51820"
AWG_CONF_DIR="/etc/amnezia/amneziawg"

API="https://api.cloudflareclient.com/v0i1909051800"

# Discover all AWG interface names managed by awg-manager.
# Each awg-manager instance writes its SERVER_NAME into a marker file.
# Fallback: scan for awgN.conf files in the config directory.
get_awg_interfaces() {
    local ifaces=()

    # Method 1: read marker files written by awg-manager at init time
    if ls "${AWG_CONF_DIR}"/.awg_iface_* &>/dev/null; then
        for f in "${AWG_CONF_DIR}"/.awg_iface_*; do
            local name
            name=$(cat "$f" 2>/dev/null)
            [ -n "$name" ] && ifaces+=("$name")
        done
    fi

    # Method 2: scan for awgN.conf files
    if [ ${#ifaces[@]} -eq 0 ] && [ -d "$AWG_CONF_DIR" ]; then
        for f in "${AWG_CONF_DIR}"/awg*.conf; do
            [ -f "$f" ] || continue
            local name
            name=$(basename "$f" .conf)
            ifaces+=("$name")
        done
    fi

    # Method 3: detect running awg interfaces from the kernel
    if [ ${#ifaces[@]} -eq 0 ]; then
        while IFS= read -r line; do
            ifaces+=("$line")
        done < <(ip -o link show type wireguard 2>/dev/null | awk -F': ' '/awg/{print $2}' | sed 's/@.*//')
    fi

    # Deduplicate
    printf '%s\n' "${ifaces[@]}" | sort -u
}

colorized_echo() {
    local color=$1
    local text=$2
    case $color in
        "red")    printf "\e[91m${text}\e[0m\n" ;;
        "green")  printf "\e[92m${text}\e[0m\n" ;;
        "yellow") printf "\e[93m${text}\e[0m\n" ;;
        "blue")   printf "\e[94m${text}\e[0m\n" ;;
        "cyan")   printf "\e[96m${text}\e[0m\n" ;;
        *)        echo "${text}" ;;
    esac
}

check_deps() {
    local missing_pkgs=()

    command -v wg      &>/dev/null || missing_pkgs+=("wireguard-tools")
    command -v curl    &>/dev/null || missing_pkgs+=("curl")
    command -v jq      &>/dev/null || missing_pkgs+=("jq")

    if [ ${#missing_pkgs[@]} -eq 0 ]; then
        return 0
    fi

    colorized_echo yellow "Installing missing dependencies: ${missing_pkgs[*]}"

    if command -v apt-get &>/dev/null; then
        apt-get update -y -qq
        apt-get install -y -qq "${missing_pkgs[@]}"
    elif command -v apt &>/dev/null; then
        apt update -y -qq
        apt install -y -qq "${missing_pkgs[@]}"
    else
        colorized_echo red "Cannot auto-install: apt not found."
        colorized_echo yellow "Please install manually: ${missing_pkgs[*]}"
        exit 1
    fi

    # Verify after install
    local still_missing=()
    command -v wg   &>/dev/null || still_missing+=("wg (wireguard-tools)")
    command -v curl &>/dev/null || still_missing+=("curl")
    command -v jq   &>/dev/null || still_missing+=("jq")

    if [ ${#still_missing[@]} -gt 0 ]; then
        colorized_echo red "Failed to install: ${still_missing[*]}"
        exit 1
    fi

    colorized_echo green "Dependencies installed successfully"
}

# Register a new WARP device and get credentials
register_warp() {
    colorized_echo blue "Generating WireGuard keypair..."
    local priv
    priv=$(wg genkey)
    local pub
    pub=$(printf "%s" "${priv}" | wg pubkey)

    colorized_echo blue "Registering with Cloudflare WARP API..."
    local response
    response=$(curl -s \
        -H 'User-Agent: okhttp/3.12.1' \
        -H 'Content-Type: application/json' \
        -X POST "${API}/reg" \
        -d "{\"install_id\":\"\",\"tos\":\"$(date -u +%FT%TZ)\",\"key\":\"${pub}\",\"fcm_token\":\"\",\"type\":\"ios\",\"locale\":\"en_US\"}")

    local id token
    id=$(echo "$response" | jq -r '.result.id')
    token=$(echo "$response" | jq -r '.result.token')

    if [ "$id" = "null" ] || [ -z "$id" ] || [ "$token" = "null" ] || [ -z "$token" ]; then
        colorized_echo red "WARP registration failed:"
        echo "$response" | jq .
        exit 1
    fi

    colorized_echo blue "Enabling WARP..."
    response=$(curl -s \
        -H 'User-Agent: okhttp/3.12.1' \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer ${token}" \
        -X PATCH "${API}/reg/${id}" \
        -d '{"warp_enabled":true}')

    local peer_pub client_ipv4 client_ipv6
    peer_pub=$(echo "$response" | jq -r '.result.config.peers[0].public_key')
    client_ipv4=$(echo "$response" | jq -r '.result.config.interface.addresses.v4')
    client_ipv6=$(echo "$response" | jq -r '.result.config.interface.addresses.v6')

    if [ "$peer_pub" = "null" ] || [ -z "$peer_pub" ]; then
        colorized_echo red "Failed to get WARP config:"
        echo "$response" | jq .
        exit 1
    fi

    colorized_echo green "WARP registered successfully!"
    colorized_echo cyan "  Client IPv4: ${client_ipv4}"
    colorized_echo cyan "  Client IPv6: ${client_ipv6}"
    colorized_echo cyan "  Peer PubKey: ${peer_pub}"

    # Save credentials
    mkdir -p "$WARP_DIR"

    cat > "${WARP_DIR}/credentials.json" <<EOF
{
    "id": "${id}",
    "token": "${token}",
    "private_key": "${priv}",
    "public_key": "${pub}",
    "peer_public_key": "${peer_pub}",
    "client_ipv4": "${client_ipv4}",
    "client_ipv6": "${client_ipv6}"
}
EOF
    chmod 600 "${WARP_DIR}/credentials.json"

    # Generate WireGuard config for warp0 interface
    # We use FwMark + Table to avoid routing loops:
    #   - warp0 traffic is marked and uses a separate routing table
    #   - AWG client traffic (coming from awg interfaces) gets routed INTO warp0
    #   - warp0's own encapsulated UDP goes directly to Cloudflare via the default route
    # Build PostUp / PostDown rules dynamically for each AWG interface.
    # This avoids hardcoding "awg0" and works with any number of AWG tunnels.
    local awg_ifaces
    awg_ifaces=$(get_awg_interfaces)

    local postup_rules=""
    local postdown_rules=""

    if [ -n "$awg_ifaces" ]; then
        while IFS= read -r iface; do
            postup_rules+="PostUp = ip rule add iif ${iface} table ${WARP_TABLE} priority 100\n"
            postdown_rules+="PostDown = ip rule del iif ${iface} table ${WARP_TABLE} priority 100 || true\n"
        done <<< "$awg_ifaces"
    else
        colorized_echo yellow "WARNING: No AWG interfaces detected yet."
        colorized_echo yellow "         Will add a helper script to set up rules when AWG starts."
    fi

    # Always add the fwmark suppress rule (prevents routing loops for WARP itself)
    postup_rules+="PostUp = ip rule add fwmark ${WARP_FWMARK} lookup main suppress_prefixlength 0 priority 90 || true"
    postdown_rules+="PostDown = ip rule del fwmark ${WARP_FWMARK} lookup main suppress_prefixlength 0 priority 90 || true"

    cat > "$WARP_CONF" <<EOF
[Interface]
PrivateKey = ${priv}
Address = ${client_ipv4}/32, ${client_ipv6}/128
DNS = 1.1.1.1
Table = ${WARP_TABLE}
FwMark = ${WARP_FWMARK}
MTU = 1280

# Routing rules: route traffic from AWG client interfaces through WARP
$(echo -e "$postup_rules")
$(echo -e "$postdown_rules")

[Peer]
PublicKey = ${peer_pub}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 162.159.192.1:500
PersistentKeepalive = 25
EOF

    # Create a helper script that awg-manager can call to add/remove ip rules
    # for a specific AWG interface. This handles the case when new AWG servers
    # are created after WARP is already running.
    cat > "${WARP_DIR}/warp_add_iface.sh" <<'HELPER'
#!/bin/bash
# Usage: warp_add_iface.sh <add|del> <awg_interface_name>
ACTION="$1"
IFACE="$2"
TABLE="51820"

if [ -z "$ACTION" ] || [ -z "$IFACE" ]; then
    echo "Usage: $0 <add|del> <interface_name>"
    exit 1
fi

if [ "$ACTION" = "add" ]; then
    # Check if rule already exists
    if ! ip rule list | grep -q "iif $IFACE lookup $TABLE"; then
        ip rule add iif "$IFACE" table "$TABLE" priority 100
        echo "Added ip rule for $IFACE -> WARP table $TABLE"
    fi
elif [ "$ACTION" = "del" ]; then
    ip rule del iif "$IFACE" table "$TABLE" priority 100 2>/dev/null || true
    echo "Removed ip rule for $IFACE -> WARP table $TABLE"
fi
HELPER
    chmod 700 "${WARP_DIR}/warp_add_iface.sh"
    chmod 600 "$WARP_CONF"

    colorized_echo green "WARP config saved to ${WARP_CONF}"
}

# Create systemd service for warp0
install_service() {
    colorized_echo blue "Creating systemd service for warp0..."

    cat > /etc/systemd/system/wg-quick@warp0.service <<'EOF'
[Unit]
Description=WireGuard WARP Tunnel (warp0)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/wg-quick up /etc/amnezia/warp/warp0.conf
ExecStop=/usr/bin/wg-quick down /etc/amnezia/warp/warp0.conf

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wg-quick@warp0.service
    colorized_echo green "Service wg-quick@warp0 enabled"
}

warp_up() {
    if ip link show "$WARP_IFACE" &>/dev/null; then
        colorized_echo yellow "WARP interface ${WARP_IFACE} is already up"
        return 0
    fi

    if [ ! -f "$WARP_CONF" ]; then
        colorized_echo red "WARP config not found at ${WARP_CONF}. Run 'install' first."
        exit 1
    fi

    colorized_echo blue "Bringing up WARP tunnel..."
    wg-quick up "$WARP_CONF"
    colorized_echo green "WARP tunnel is UP"
}

warp_down() {
    if ! ip link show "$WARP_IFACE" &>/dev/null; then
        colorized_echo yellow "WARP interface ${WARP_IFACE} is already down"
        return 0
    fi

    colorized_echo blue "Bringing down WARP tunnel..."
    wg-quick down "$WARP_CONF"
    colorized_echo green "WARP tunnel is DOWN"
}

warp_status() {
    if ip link show "$WARP_IFACE" &>/dev/null; then
        colorized_echo green "WARP interface ${WARP_IFACE}: UP"
        wg show "$WARP_IFACE"
        echo ""
        colorized_echo blue "Routing rules:"
        ip rule list | grep -E "awg|${WARP_TABLE}|${WARP_FWMARK}" || echo "  (none)"
        echo ""
        colorized_echo blue "WARP routing table ${WARP_TABLE}:"
        ip route show table "$WARP_TABLE" 2>/dev/null || echo "  (empty)"
        echo ""
        colorized_echo blue "Testing exit IP via WARP..."
        # Force curl through warp0 source IP
        local warp_ip
        warp_ip=$(jq -r '.client_ipv4' "${WARP_DIR}/credentials.json" 2>/dev/null | cut -d/ -f1)
        if [ -n "$warp_ip" ] && [ "$warp_ip" != "null" ]; then
            curl -s --interface "$WARP_IFACE" --max-time 5 https://ifconfig.me 2>/dev/null || echo "(timeout)"
        fi
    else
        colorized_echo red "WARP interface ${WARP_IFACE}: DOWN"
    fi
}

warp_install() {
    check_deps
    if [ -f "${WARP_DIR}/credentials.json" ]; then
        colorized_echo yellow "WARP already registered. Use 'reinstall' to re-register."
        colorized_echo blue "Ensuring tunnel is up..."
        warp_up
        return 0
    fi
    register_warp
    install_service
    warp_up
    colorized_echo green "========================================"
    colorized_echo green "  WARP double-tunnel setup complete!"
    colorized_echo green "  Client → AWG → VPS → WARP → Internet"
    colorized_echo green "========================================"
    echo ""
    colorized_echo cyan "Next steps:"
    colorized_echo cyan "  1. Create a user:"
    echo "       bash /etc/amnezia/amneziawg/awg-manager.sh -c -u <username>"
    colorized_echo cyan "  2. Get config for the user:"
    echo "       bash /etc/amnezia/amneziawg/awg-manager.sh -q -u <username>   # QR code"
    echo "       bash /etc/amnezia/amneziawg/awg-manager.sh -p -u <username>   # text config"
    echo "       cat /root/awg-warp/<username>.conf                            # copy-paste config"
}

warp_uninstall() {
    warp_down || true
    systemctl disable wg-quick@warp0.service 2>/dev/null || true
    rm -f /etc/systemd/system/wg-quick@warp0.service
    systemctl daemon-reload
    rm -rf "$WARP_DIR"
    colorized_echo green "WARP completely removed"
}

warp_reinstall() {
    warp_uninstall
    warp_install
}

usage() {
    echo "Usage: $0 {install|up|down|status|uninstall|reinstall}"
    echo ""
    echo "  install    - Register WARP, create warp0 config, enable service, bring up"
    echo "  up         - Bring up warp0 interface"
    echo "  down       - Bring down warp0 interface"
    echo "  status     - Show warp0 status and routing"
    echo "  uninstall  - Remove WARP completely"
    echo "  reinstall  - Re-register WARP and reconfigure"
    exit 1
}

case "${1:-}" in
    install)    warp_install ;;
    up)         warp_up ;;
    down)       warp_down ;;
    status)     warp_status ;;
    uninstall)  warp_uninstall ;;
    reinstall)  warp_reinstall ;;
    *)          usage ;;
esac
