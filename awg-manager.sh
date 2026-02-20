#!/bin/bash -e

APP=$(basename $0)
LOCKFILE="/tmp/$APP.lock"

trap "rm -f ${LOCKFILE}; exit" INT TERM EXIT
if ! ln -s $APP $LOCKFILE 2>/dev/null; then
    echo "ERROR: script LOCKED" >&2
    exit 15
fi

function usage {
  echo "Usage: $0 [<options>] [command [arg]]"
  echo "Options:"
  echo " -i : Init (Create server keys and configs)"
  echo " -c : Create new user"
  echo " -d : Delete user"
  echo " -L : Lock user"
  echo " -U : Unlock user"
  echo " -p : Print user config"
  echo " -q : Print user QR code"
  echo " -u <user> : User identifier (uniq field for vpn account)"
  echo " -s <server> : Server host for user connection"
  echo " -N <name> : AWG server name (default: auto-detect, e.g. awg0, awg1)"
  echo " -I : Interface (default auto)"
  echo " -h : Usage"
  exit 1
}

unset USER
umask 0077

HOME_DIR="/etc/amnezia/amneziawg"

# ── Auto-detect free SERVER_NAME, IP prefix and port ──────────────────────
# Find the first free awgN name (awg0, awg1, awg2 ...)
_auto_server_name() {
    for i in $(seq 0 99); do
        local name="awg${i}"
        # Not already running AND no config exists
        if ! ip link show "$name" &>/dev/null && [ ! -f "${HOME_DIR}/${name}.conf" ]; then
            echo "$name"
            return
        fi
    done
    echo "awg0"  # fallback
}

# Find a free random 10.X.Y.0/24 subnet that doesn't collide with existing AWG configs
_auto_ip_prefix() {
    declare -A USED_PREFIXES

    # Collect all prefixes already used by existing AWG configs
    for conf in "${HOME_DIR}"/awg*.conf; do
        [ -f "$conf" ] || continue
        local addr
        addr=$(grep -i '^\s*Address\s*=' "$conf" | head -1 | sed 's/Address\s*=\s*//i; s/\/.*//' | tr -d ' ')
        if [ -n "$addr" ]; then
            # Extract first 3 octets: "10.0.1.1" -> "10.0.1"
            local prefix
            prefix=$(echo "$addr" | grep -oP '^\d+\.\d+\.\d+')
            [ -n "$prefix" ] && USED_PREFIXES["$prefix"]=1
        fi
    done

    # Also check running interfaces
    for iface in $(ip -o link show type wireguard 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//'); do
        local addr
        addr=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+')
        if [ -n "$addr" ]; then
            local prefix
            prefix=$(echo "$addr" | grep -oP '^\d+\.\d+\.\d+')
            [ -n "$prefix" ] && USED_PREFIXES["$prefix"]=1
        fi
    done

    # Pick a random free 10.X.Y (X: 0-255, Y: 0-255, excluding 0.0 and reserved ranges)
    local attempts=0
    while [ $attempts -lt 200 ]; do
        local oct2=$(( RANDOM % 256 ))
        local oct3=$(( RANDOM % 256 ))
        local candidate="10.${oct2}.${oct3}"
        if [ -z "${USED_PREFIXES[$candidate]}" ]; then
            echo "$candidate"
            return
        fi
        attempts=$(( attempts + 1 ))
    done

    # Fallback: sequential scan if random keeps hitting used prefixes
    for i in $(seq 1 254); do
        local candidate="10.0.${i}"
        if [ -z "${USED_PREFIXES[$candidate]}" ]; then
            echo "$candidate"
            return
        fi
    done

    echo "10.0.1"  # last resort fallback
}

# Find a free UDP port starting from base
_auto_port() {
    declare -A USED_PORTS

    # Collect ports from existing AWG configs
    for conf in "${HOME_DIR}"/awg*.conf; do
        [ -f "$conf" ] || continue
        local port
        port=$(grep -i '^\s*ListenPort\s*=' "$conf" | head -1 | sed 's/ListenPort\s*=\s*//i' | tr -d ' ')
        [ -n "$port" ] && USED_PORTS["$port"]=1
    done

    # Also check actually listening UDP ports
    while read -r port; do
        [ -n "$port" ] && USED_PORTS["$port"]=1
    done < <(ss -ulnp 2>/dev/null | awk 'NR>1{split($5,a,":"); print a[length(a)]}')

    local base=39548
    for i in $(seq 0 100); do
        local candidate=$((base + i))
        if [ -z "${USED_PORTS[$candidate]}" ]; then
            echo "$candidate"
            return
        fi
    done

    echo "$base"  # fallback
}

# Check if this is a fresh install (no existing config) → auto-detect
# If already initialized (config exists) → use existing SERVER_NAME
_detect_existing_server() {
    # If there's exactly one awg config managed by us, use it
    local count=0
    local found=""
    for conf in "${HOME_DIR}"/awg*.conf; do
        [ -f "$conf" ] || continue
        found=$(basename "$conf" .conf)
        count=$((count + 1))
    done

    if [ "$count" -eq 1 ] && [ -n "$found" ]; then
        echo "$found"
        return 0
    elif [ "$count" -gt 1 ]; then
        # Multiple servers — can't auto-detect, need -N flag
        return 1
    fi
    return 1
}

# Determine SERVER_NAME: use existing if found, otherwise auto-pick free one
if _detect_existing_server >/dev/null 2>&1; then
    SERVER_NAME=$(_detect_existing_server)
    # Read existing settings from config
    SERVER_IP_PREFIX=$(grep -i '^\s*Address\s*=' "${HOME_DIR}/${SERVER_NAME}.conf" 2>/dev/null | head -1 | sed 's/Address\s*=\s*//i; s/\.[0-9]*\/.*//' | tr -d ' ')
    SERVER_PORT=$(grep -i '^\s*ListenPort\s*=' "${HOME_DIR}/${SERVER_NAME}.conf" 2>/dev/null | head -1 | sed 's/ListenPort\s*=\s*//i' | tr -d ' ')
    [ -z "$SERVER_IP_PREFIX" ] && SERVER_IP_PREFIX=$(_auto_ip_prefix)
    [ -z "$SERVER_PORT" ] && SERVER_PORT=$(_auto_port)
else
    SERVER_NAME=$(_auto_server_name)
    SERVER_IP_PREFIX=$(_auto_ip_prefix)
    SERVER_PORT=$(_auto_port)
fi

SERVER_INTERFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

while getopts ":icdpqhLUu:I:s:N:" opt; do
  case $opt in
     i) INIT=1 ;;
     c) CREATE=1 ;;
     d) DELETE=1 ;;
     L) LOCK=1 ;;
     U) UNLOCK=1 ;;
     p) PRINT_USER_CONFIG=1 ;;
     q) PRINT_QR_CODE=1 ;;
     u) USER="$OPTARG" ;;
     I) SERVER_INTERFACE="$OPTARG" ;;
     N) EXPLICIT_SERVER_NAME="$OPTARG" ;;
     h) usage ;;
     s) SERVER_ENDPOINT="$OPTARG" ;;
    \?) echo "Invalid option: -$OPTARG" ; exit 1 ;;
     :) echo "Option -$OPTARG requires an argument" ; exit 1 ;;
  esac
done

[ $# -lt 1 ] && usage

# Override SERVER_NAME if explicitly specified with -N
if [ -n "${EXPLICIT_SERVER_NAME:-}" ]; then
    SERVER_NAME="$EXPLICIT_SERVER_NAME"
    # If config exists for this name, read its settings
    if [ -f "${HOME_DIR}/${SERVER_NAME}.conf" ]; then
        SERVER_IP_PREFIX=$(grep -i '^\s*Address\s*=' "${HOME_DIR}/${SERVER_NAME}.conf" 2>/dev/null | head -1 | sed 's/Address\s*=\s*//i; s/\.[0-9]*\/.*//' | tr -d ' ')
        SERVER_PORT=$(grep -i '^\s*ListenPort\s*=' "${HOME_DIR}/${SERVER_NAME}.conf" 2>/dev/null | head -1 | sed 's/ListenPort\s*=\s*//i' | tr -d ' ')
    else
        # New explicit name — auto-pick free prefix/port
        SERVER_IP_PREFIX=$(_auto_ip_prefix)
        SERVER_PORT=$(_auto_port)
    fi
fi

function reload_server {
    awg syncconf ${SERVER_NAME} <(awg-quick strip ${SERVER_NAME})
}

function get_new_ip {
    declare -A IP_EXISTS

    for IP in $(grep -ril 'Address\s*=\s*' keys/ 2>/dev/null | grep '\.conf$' | xargs grep -ih 'Address\s*=\s*' 2>/dev/null | sed 's/\/[0-9]\+$//' | grep -Po '\d+$')
    do
        IP_EXISTS[$IP]=1
    done

    for IP in {2..255}
    do
        [ ${IP_EXISTS[$IP]} ] || break
    done

    if [ $IP -eq 255 ]; then
        echo "ERROR: can't determine new address" >&2
        exit 3
    fi

    echo "${SERVER_IP_PREFIX}.${IP}/32"
}

function add_user_to_server {
    if [ ! -f "keys/${USER}/public.key" ]; then
        echo "ERROR: User not exists" >&2
        exit 1
    fi

    local USER_PUB_KEY=$(cat "keys/${USER}/public.key")
    local USER_PSK_KEY=$(cat "keys/$USER/psk.key")
    local USER_IP=$(grep -i Address "keys/${USER}/${USER}.conf" | sed 's/Address\s*=\s*//i; s/\/.*//')

    if grep "# BEGIN ${USER}$" "$SERVER_NAME.conf" >/dev/null ; then
        echo "User already exists"
        exit 0
    fi

cat <<EOF >> "$SERVER_NAME.conf"
# BEGIN ${USER}
[Peer]
PublicKey = ${USER_PUB_KEY}
AllowedIPs = ${USER_IP}
PresharedKey = ${USER_PSK_KEY}
# END ${USER}
EOF

    ip -4 route add ${USER_IP}/32 dev ${SERVER_NAME} || true
}

function remove_user_from_server {
    sed -i "/# BEGIN ${USER}$/,/# END ${USER}$/d" "$SERVER_NAME.conf"
    if [ -f "keys/${USER}/${USER}.conf" ]; then
        local USER_IP=$(grep -i Address "keys/${USER}/${USER}.conf" | sed 's/Address\s*=\s*//i; s/\/.*//')
        ip -4 route del ${USER_IP}/32 dev ${SERVER_NAME} || true
    fi
}

function init {
    if [ -z "$SERVER_ENDPOINT" ]; then
        echo "ERROR: Server required" >&2
        exit 1
    fi

    if [ -z "$SERVER_INTERFACE" ]; then
        echo "ERROR: Can't determine server interface" >&2
        echo "DEBUG: 'ip route':"
        ip route
        exit 1
    fi

    echo "Interface: $SERVER_INTERFACE"
    echo "AWG server: ${SERVER_NAME}"
    echo "Subnet: ${SERVER_IP_PREFIX}.0/24"
    echo "Listen port: ${SERVER_PORT}"

    mkdir -p "keys/${SERVER_NAME}"
    echo -n "$SERVER_ENDPOINT" > "keys/.server"

    # Write marker file so warp_setup.sh can discover this AWG interface
    echo -n "${SERVER_NAME}" > "${HOME_DIR}/.awg_iface_${SERVER_NAME}"

    if [ ! -f "keys/${SERVER_NAME}/private.key" ]; then
        awg genkey | tee "keys/${SERVER_NAME}/private.key" | awg pubkey > "keys/${SERVER_NAME}/public.key"
    fi

    if [ -f "$SERVER_NAME.conf" ]; then
        echo "Server already initialized"
        exit 0
    fi

    SERVER_PVT_KEY=$(cat "keys/$SERVER_NAME/private.key")

    # Check if WARP tunnel is available for double tunneling
    local USE_WARP=0
    if [ -f "/etc/amnezia/warp/warp0.conf" ]; then
        USE_WARP=1
        echo "WARP tunnel detected — enabling double tunneling (AWG → WARP → Internet)"
    else
        echo "WARP tunnel not found — using direct routing via ${SERVER_INTERFACE}"
    fi

    if [ "$USE_WARP" -eq 1 ]; then
        # Double tunnel mode: route this AWG server's client traffic through WARP (warp0)
        # Uses SERVER_NAME (${SERVER_NAME}) instead of hardcoded awg0 to support
        # multiple AWG servers on the same VPS.
        local WARP_HELPER="/etc/amnezia/warp/warp_add_iface.sh"
cat <<EOF > "$SERVER_NAME.conf"
[Interface]
Address = ${SERVER_IP_PREFIX}.1/32
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PVT_KEY}
PostUp = iptables -t nat -A POSTROUTING -o warp0 -s ${SERVER_IP_PREFIX}.0/24 -j MASQUERADE
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_INTERFACE} -j MASQUERADE
PostUp = iptables -A FORWARD -i ${SERVER_NAME} -o warp0 -j ACCEPT
PostUp = iptables -A FORWARD -i warp0 -o ${SERVER_NAME} -m state --state RELATED,ESTABLISHED -j ACCEPT
PostUp = bash ${WARP_HELPER} add ${SERVER_NAME} 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -o warp0 -s ${SERVER_IP_PREFIX}.0/24 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${SERVER_NAME} -o warp0 -j ACCEPT || true
PostDown = iptables -D FORWARD -i warp0 -o ${SERVER_NAME} -m state --state RELATED,ESTABLISHED -j ACCEPT || true
PostDown = bash ${WARP_HELPER} del ${SERVER_NAME} 2>/dev/null || true
Jc = 2
Jmin = 10
Jmax = 50
S1 = 78
S2 = 63
H1 = 1909976304
H2 = 379167011
H3 = 1086133991
H4 = 1090042050

EOF
    else
        # Standard mode: direct MASQUERADE to external interface
cat <<EOF > "$SERVER_NAME.conf"
[Interface]
Address = ${SERVER_IP_PREFIX}.1/32
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PVT_KEY}
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_INTERFACE} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_INTERFACE} -j MASQUERADE
Jc = 2
Jmin = 10
Jmax = 50
S1 = 78
S2 = 63
H1 = 1909976304
H2 = 379167011
H3 = 1086133991
H4 = 1090042050

EOF
    fi

    if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
        echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf
    fi
    sysctl -w net.ipv4.ip_forward=1

    systemctl enable awg-quick@${SERVER_NAME}
    awg-quick up ${SERVER_NAME} || true

    # If WARP tunnel is running, register this AWG interface for WARP routing
    local WARP_HELPER="/etc/amnezia/warp/warp_add_iface.sh"
    if [ -f "$WARP_HELPER" ] && ip link show warp0 &>/dev/null; then
        bash "$WARP_HELPER" add "${SERVER_NAME}"
    fi

    echo "Server initialized successfully"
    exit 0
}

function create {
    if [ -f "keys/${USER}/${USER}.conf" ]; then
        echo "WARNING: key ${USER}.conf already exists" >&2
        return 0
    fi

    SERVER_ENDPOINT=$(cat "keys/.server")
    USER_IP=$( get_new_ip )

    mkdir "keys/${USER}"
    awg genkey | tee "keys/${USER}/private.key" | awg pubkey > "keys/${USER}/public.key"
    awg genpsk > "keys/${USER}/psk.key"

    USER_PVT_KEY=$(cat "keys/${USER}/private.key")
    USER_PUB_KEY=$(cat "keys/${USER}/public.key")
    USER_PSK_KEY=$(cat "keys/${USER}/psk.key")
    SERVER_PUB_KEY=$(cat "keys/$SERVER_NAME/public.key")

cat <<EOF > "keys/${USER}/${USER}.conf"
[Interface]
PrivateKey = ${USER_PVT_KEY}
Address = ${USER_IP}
DNS = 8.8.8.8, 8.8.4.4
Jc = 2
Jmin = 10
Jmax = 50
S1 = 78
S2 = 63
H1 = 1909976304
H2 = 379167011
H3 = 1086133991
H4 = 1090042050

[Peer]
PublicKey = ${SERVER_PUB_KEY}
Endpoint = ${SERVER_ENDPOINT}:${SERVER_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 20
PresharedKey = ${USER_PSK_KEY}
EOF
    add_user_to_server
    reload_server

    # Copy user config to awg-warp directory
    local CONFIGS_DIR="/root/awg-warp"
    mkdir -p "$CONFIGS_DIR"
    cp "keys/${USER}/${USER}.conf" "${CONFIGS_DIR}/${USER}.conf"
    echo "Config copied to ${CONFIGS_DIR}/${USER}.conf"
}

cd $HOME_DIR

if [ $INIT ]; then
    init
    exit 0;
fi

if [ ! -f "keys/$SERVER_NAME/public.key" ]; then
    echo "ERROR: Run init script before" >&2
    exit 2
fi

if [ -z "${USER}" ]; then
    echo "ERROR: User required" >&2
    exit 1
fi

if [ $CREATE ]; then
    create
fi

if [ $DELETE ]; then
    remove_user_from_server
    reload_server
    rm -rf "keys/${USER}"
    exit 0
fi

if [ $LOCK ]; then
    remove_user_from_server
    reload_server
    exit 0
fi

if [ $UNLOCK ]; then
    add_user_to_server
    reload_server
    exit 0
fi

if [ $PRINT_USER_CONFIG ]; then
    cat "keys/${USER}/${USER}.conf"
elif [ $PRINT_QR_CODE ]; then
    qrencode -t ansiutf8 < "keys/${USER}/${USER}.conf"
fi


exit 0
