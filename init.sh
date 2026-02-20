#!/bin/bash

set -e

colorized_echo() {
    local color=$1
    local text=$2

    case $color in
        "red")
        printf "\e[91m${text}\e[0m\n";;
        "green")
        printf "\e[92m${text}\e[0m\n";;
        "yellow")
        printf "\e[93m${text}\e[0m\n";;
        "blue")
        printf "\e[94m${text}\e[0m\n";;
        "magenta")
        printf "\e[95m${text}\e[0m\n";;
        "cyan")
        printf "\e[96m${text}\e[0m\n";;
        *)
            echo "${text}"
        ;;
    esac
}

installing() {
    check_running_as_root
    detect_os
    detect_and_update_package_manager
    install_package
    install_go
    install_awg_awg_tools
    install_awg_manager
    install_warp
    init_awg_server
    print_summary
}

print_summary() {
    echo ""
    colorized_echo green "╔══════════════════════════════════════════════╗"
    colorized_echo green "║    awg-warp installation complete!           ║"
    colorized_echo green "║    Client → AWG → VPS → WARP → Internet      ║"
    colorized_echo green "╚══════════════════════════════════════════════╝"
    echo ""
    colorized_echo cyan "Next steps:"
    colorized_echo cyan "  1. Create a user:"
    echo "       bash /etc/amnezia/amneziawg/awg-manager.sh -c -u <username>"
    echo ""
    colorized_echo cyan "  2. Get config for the user:"
    echo "       bash /etc/amnezia/amneziawg/awg-manager.sh -q -u <username>   # QR code"
    echo "       bash /etc/amnezia/amneziawg/awg-manager.sh -p -u <username>   # text config"
    echo "       cat /root/awg-warp/<username>.conf                            # copy-paste config"
    echo ""
}
check_running_as_root() {
    if [ "$(id -u)" != "0" ]; then
        colorized_echo red "This command must be run as root."
        exit 1
    fi
}
detect_os() {
    # Detect the operating system
    if [ -f /etc/lsb-release ]; then
        OS=$(lsb_release -si)
        elif [ -f /etc/os-release ]; then
        OS=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"')
        elif [ -f /etc/redhat-release ]; then
        OS=$(cat /etc/redhat-release | awk '{print $1}')
        elif [ -f /etc/arch-release ]; then
        OS="Arch"
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}
detect_and_update_package_manager() {
    colorized_echo blue "Updating package manager"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        PKG_MANAGER="apt-get"
        $PKG_MANAGER update
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}
install_package () {
    if [ -z $PKG_MANAGER ]; then
        detect_and_update_package_manager
    fi
    colorized_echo blue "Installing Package"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        $PKG_MANAGER -y install build-essential \
        curl \
        make \
        git \
        wget \
        qrencode \
        jq \
        wireguard-tools
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

install_go() {
    # Ensure /usr/local/go/bin is in PATH for already-installed Go
    export PATH=$PATH:/usr/local/go/bin

    if command -v go &> /dev/null; then
        colorized_echo green "Go already installed: $(go version)"
        return 0
    fi

    colorized_echo blue "Installing Go..."

    # Fetch the latest stable Go version from the official API
    local GO_VERSION
    GO_VERSION=$(curl -fsSL "https://go.dev/dl/?mode=json" 2>/dev/null | jq -r '.[0].version' | sed 's/^go//')
    if [ -z "$GO_VERSION" ]; then
        colorized_echo yellow "Could not fetch latest Go version, using fallback 1.23.6"
        GO_VERSION="1.23.6"
    fi
    colorized_echo blue "Go version to install: ${GO_VERSION}"

    local GO_ARCHIVE="go${GO_VERSION}.linux-amd64.tar.gz"
    local TEMP_DIR
    TEMP_DIR=$(mktemp -d)

    cd "$TEMP_DIR"
    wget -q "https://go.dev/dl/${GO_ARCHIVE}" || {
        colorized_echo red "Failed to download Go ${GO_VERSION}"
        rm -rf "$TEMP_DIR"
        exit 1
    }

    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$GO_ARCHIVE" || {
        colorized_echo red "Failed to extract Go"
        rm -rf "$TEMP_DIR"
        exit 1
    }

    # Cleanup temp directory
    cd /
    rm -rf "$TEMP_DIR"

    # Add to PATH persistently
    if ! grep -q '/usr/local/go/bin' /etc/profile; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
    fi
    export PATH=$PATH:/usr/local/go/bin

    if command -v go &> /dev/null; then
        colorized_echo green "Go installed successfully: $(go version)"
    else
        colorized_echo red "Go installation failed"
        exit 1
    fi
}
install_awg_awg_tools() {
    # Ensure Go is in PATH (may have been installed in this session)
    export PATH=$PATH:/usr/local/go/bin

    # Check if awg and amneziawg-go are already installed
    if command -v awg &> /dev/null && command -v amneziawg-go &> /dev/null; then
        colorized_echo green "AmneziaWG already installed"
        return 0
    fi

    # Install amneziawg-go
    if ! command -v amneziawg-go &> /dev/null; then
        colorized_echo blue "Installing amneziawg-go..."

        rm -rf /opt/amnezia-go
        git clone https://github.com/amnezia-vpn/amneziawg-go.git /opt/amnezia-go || {
            colorized_echo red "Failed to clone amneziawg-go"
            exit 1
        }

        cd /opt/amnezia-go
        make || {
            colorized_echo red "Failed to build amneziawg-go"
            exit 1
        }

        cp /opt/amnezia-go/amneziawg-go /usr/bin/amneziawg-go
        chmod +x /usr/bin/amneziawg-go

        # Cleanup
        cd /
        rm -rf /opt/amnezia-go

        if command -v amneziawg-go &> /dev/null; then
            colorized_echo green "amneziawg-go installed successfully"
        else
            colorized_echo red "amneziawg-go installation failed"
            exit 1
        fi
    else
        colorized_echo green "amneziawg-go already installed"
    fi

    # Install awg-tools
    if ! command -v awg &> /dev/null; then
        colorized_echo blue "Installing awg-tools..."

        rm -rf /opt/amnezia-tools
        git clone https://github.com/amnezia-vpn/amneziawg-tools.git /opt/amnezia-tools || {
            colorized_echo red "Failed to clone amneziawg-tools"
            exit 1
        }

        cd /opt/amnezia-tools/src
        make || {
            colorized_echo red "Failed to build awg-tools"
            exit 1
        }
        make install || {
            colorized_echo red "Failed to install awg-tools"
            exit 1
        }

        # Cleanup
        cd /
        rm -rf /opt/amnezia-tools

        if command -v awg &> /dev/null; then
            colorized_echo green "awg-tools installed successfully"
        else
            colorized_echo red "awg-tools installation failed"
            exit 1
        fi
    else
        colorized_echo green "awg-tools already installed"
    fi
}
install_awg_manager() {
    local AWG_DIR="/etc/amnezia/amneziawg"
    local AWG_SCRIPT="${AWG_DIR}/awg-manager.sh"

    if [ -f "$AWG_SCRIPT" ]; then
        colorized_echo green "awg-manager.sh already installed"
        return 0
    fi

    colorized_echo blue "Installing awg-manager..."

    mkdir -p "$AWG_DIR" || {
        colorized_echo red "Failed to create directory ${AWG_DIR}"
        exit 1
    }

    wget -q -O "$AWG_SCRIPT" https://raw.githubusercontent.com/He-no3opbc9l/awg-warp/main/awg-manager.sh || {
        colorized_echo red "Failed to download awg-manager.sh"
        exit 1
    }

    chmod 700 "$AWG_SCRIPT"

    if [ -f "$AWG_SCRIPT" ]; then
        colorized_echo green "awg-manager.sh installed successfully"
    else
        colorized_echo red "awg-manager.sh installation failed"
        exit 1
    fi
}
install_warp() {
    local WARP_SETUP="/etc/amnezia/warp/warp_setup.sh"
    local WARP_DIR="/etc/amnezia/warp"

    colorized_echo blue "Installing WARP tunnel setup..."

    mkdir -p "$WARP_DIR" || {
        colorized_echo red "Failed to create directory ${WARP_DIR}"
        exit 1
    }

    # Download warp_setup.sh
    local SCRIPT_URL="https://raw.githubusercontent.com/He-no3opbc9l/awg-warp/main/warp_setup.sh"
    wget -q -O "$WARP_SETUP" "$SCRIPT_URL" || {
        colorized_echo red "Failed to download warp_setup.sh"
        exit 1
    }
    chmod 700 "$WARP_SETUP"
    colorized_echo green "WARP setup script installed to ${WARP_SETUP}"

    if [ -f "${WARP_DIR}/credentials.json" ]; then
        colorized_echo green "WARP already registered, bringing tunnel up..."
        bash "$WARP_SETUP" up
        return 0
    fi

    # Register WARP and bring up warp0
    bash "$WARP_SETUP" install
}

init_awg_server() {
    local AWG_MANAGER="/etc/amnezia/amneziawg/awg-manager.sh"
    local AWG_CONF_DIR="/etc/amnezia/amneziawg"

    # Skip if already initialized
    if ls "${AWG_CONF_DIR}"/awg*.conf &>/dev/null 2>&1; then
        colorized_echo green "AWG server already initialized"
        return 0
    fi

    colorized_echo blue "Detecting public IP for AWG server..."

    # Try to get public IPv4 only (-4 forces IPv4 transport)
    local PUBLIC_IP
    PUBLIC_IP=$(curl -fsSL -4 --max-time 5 https://ifconfig.me 2>/dev/null \
        || curl -fsSL -4 --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -fsSL -4 --max-time 5 https://icanhazip.com 2>/dev/null \
        || true)
    PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '[:space:]')
    # Reject if result looks like IPv6
    if echo "$PUBLIC_IP" | grep -q ':'; then
        PUBLIC_IP=""
    fi

    if [ -z "$PUBLIC_IP" ]; then
        colorized_echo red "Could not detect public IP automatically."
        colorized_echo yellow "Please run manually: bash ${AWG_MANAGER} -i -s <YOUR_SERVER_IP>"
        return 0
    fi

    colorized_echo green "Detected public IP: ${PUBLIC_IP}"
    colorized_echo blue "Initializing AWG server..."
    bash "$AWG_MANAGER" -i -s "$PUBLIC_IP"
}

usage() {
    echo "Usage: $0 {install|remove}"
    echo ""
    echo "  install  - Install and configure awg-warp (WARP + AWG server)"
    echo "  remove   - Remove awg-warp components (keeps third-party AWG servers intact)"
    exit 1
}

removing() {
    check_running_as_root
    local AWG_CONF_DIR="/etc/amnezia/amneziawg"

    colorized_echo blue "Removing awg-warp components..."

    # Stop and remove only AWG interfaces created by awg-warp (identified by .awg_iface_* markers)
    for marker in "${AWG_CONF_DIR}"/.awg_iface_*; do
        [ -f "$marker" ] || continue
        local name
        name=$(cat "$marker")
        colorized_echo blue "Stopping AWG interface: ${name}"
        awg-quick down "$name" 2>/dev/null || true
        systemctl disable "awg-quick@${name}.service" 2>/dev/null || true
        rm -f "${AWG_CONF_DIR}/${name}.conf"
        rm -rf "${AWG_CONF_DIR}/keys/${name}"
        rm -f "$marker"
    done

    # Remove user keys and awg-manager only if no third-party configs remain
    if ! ls "${AWG_CONF_DIR}"/awg*.conf &>/dev/null 2>&1; then
        rm -rf "${AWG_CONF_DIR}/keys"
        rm -f "${AWG_CONF_DIR}/awg-manager.sh"
        rmdir "${AWG_CONF_DIR}" 2>/dev/null || true
        colorized_echo green "AWG config directory removed"
    else
        colorized_echo yellow "Third-party AWG configs detected — keeping ${AWG_CONF_DIR}"
    fi

    # Stop and remove WARP tunnel
    colorized_echo blue "Stopping WARP tunnel..."
    wg-quick down /etc/amnezia/warp/warp0.conf 2>/dev/null || true
    systemctl disable wg-quick@warp0.service 2>/dev/null || true
    rm -f /etc/systemd/system/wg-quick@warp0.service
    systemctl daemon-reload
    rm -rf /etc/amnezia/warp
    colorized_echo green "WARP tunnel removed"

    # Remove /etc/amnezia if now empty
    rmdir /etc/amnezia 2>/dev/null || true

    # Clean up leftover WARP ip rules
    ip rule del fwmark 51820 lookup main suppress_prefixlength 0 priority 90 2>/dev/null || true
    ip rule list | grep 'lookup 51820' | awk '{print $1}' | sed 's/://' | \
        xargs -I{} ip rule del prio {} 2>/dev/null || true

    colorized_echo green "awg-warp removed successfully"
    colorized_echo yellow "Packages (wireguard-tools, amneziawg-go, awg) were NOT removed"
}

case "$1" in
    install)
    shift; installing "$@";;
    remove)
    shift; removing "$@";;
    *)
    usage;;
esac
