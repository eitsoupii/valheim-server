#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root (for example: sudo bash scripts/install-valheim-server.sh)." >&2
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo "Cannot determine the operating system." >&2
    exit 1
fi

# shellcheck source=/etc/os-release
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" || ! "${VERSION_ID:-}" =~ ^(22\.04|24\.04)$ ]]; then
    echo "This installer supports Ubuntu 22.04 and 24.04." >&2
    exit 1
fi

if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
    echo "Valheim dedicated server requires an amd64 VM." >&2
    exit 1
fi

VALHEIM_NAME="${VALHEIM_NAME:-Valheim Server}"
VALHEIM_WORLD="${VALHEIM_WORLD:-Dedicated}"
VALHEIM_PORT="${VALHEIM_PORT:-2456}"
VALHEIM_PUBLIC="${VALHEIM_PUBLIC:-1}"
VALHEIM_CROSSPLAY="${VALHEIM_CROSSPLAY:-0}"
VALHEIM_PASSWORD="${VALHEIM_PASSWORD:-}"

if [[ ! "${VALHEIM_NAME}" =~ ^[A-Za-z0-9_.\ -]+$ ]]; then
    echo "VALHEIM_NAME may contain only letters, numbers, spaces, dots, underscores, and hyphens." >&2
    exit 1
fi
if [[ ! "${VALHEIM_WORLD}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "VALHEIM_WORLD may contain only letters, numbers, dots, underscores, and hyphens." >&2
    exit 1
fi
if [[ ! "${VALHEIM_PASSWORD}" =~ ^[A-Za-z0-9_-]{5,}$ ]]; then
    echo "Set VALHEIM_PASSWORD to at least 5 letters, numbers, underscores, or hyphens." >&2
    exit 1
fi
if [[ ! "${VALHEIM_PORT}" =~ ^[0-9]+$ || ${#VALHEIM_PORT} -gt 5 ]]; then
    echo "VALHEIM_PORT must be a number between 1024 and 65532." >&2
    exit 1
fi
VALHEIM_PORT_NUMBER=$((10#${VALHEIM_PORT}))
if (( VALHEIM_PORT_NUMBER < 1024 || VALHEIM_PORT_NUMBER > 65532 )); then
    echo "VALHEIM_PORT must be a number between 1024 and 65532." >&2
    exit 1
fi
VALHEIM_PORT="${VALHEIM_PORT_NUMBER}"
if [[ "${VALHEIM_PUBLIC}" != "0" && "${VALHEIM_PUBLIC}" != "1" ]]; then
    echo "VALHEIM_PUBLIC must be 0 (not listed) or 1 (listed)." >&2
    exit 1
fi
if [[ "${VALHEIM_CROSSPLAY}" != "0" && "${VALHEIM_CROSSPLAY}" != "1" ]]; then
    echo "VALHEIM_CROSSPLAY must be 0 (disabled) or 1 (enabled)." >&2
    exit 1
fi

STEAM_USER="steam"
STEAMCMD_DIR="/opt/steamcmd"
VALHEIM_DIR="/opt/valheim"
SERVER_DIR="${VALHEIM_DIR}/server"
SAVEDIR="${VALHEIM_DIR}/saves"
CONFIG_DIR="/etc/valheim"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl lib32gcc-s1 lib32stdc++6 libatomic1 libpulse0 tar

if ! id "${STEAM_USER}" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "${VALHEIM_DIR}" --shell /usr/sbin/nologin "${STEAM_USER}"
fi

install -d -o "${STEAM_USER}" -g "${STEAM_USER}" "${STEAMCMD_DIR}" "${SERVER_DIR}" "${SAVEDIR}"
curl --fail --location --silent --show-error \
    https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    --output "${TEMP_DIR}/steamcmd_linux.tar.gz"
tar -xzf "${TEMP_DIR}/steamcmd_linux.tar.gz" -C "${STEAMCMD_DIR}"
chown -R "${STEAM_USER}:${STEAM_USER}" "${STEAMCMD_DIR}"

if systemctl is-active --quiet valheim-server.service; then
    systemctl stop valheim-server.service
fi

runuser -u "${STEAM_USER}" -- "${STEAMCMD_DIR}/steamcmd.sh" \
    +force_install_dir "${SERVER_DIR}" \
    +login anonymous \
    +app_update 896660 validate \
    +quit
if [[ ! -x "${SERVER_DIR}/valheim_server.x86_64" ]]; then
    echo "SteamCMD did not install the Valheim dedicated server executable." >&2
    exit 1
fi

cat > "${TEMP_DIR}/launch-server.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/valheim/server
crossplay_args=()
if [[ "${VALHEIM_CROSSPLAY}" == "1" ]]; then
    crossplay_args+=(-crossplay)
fi
exec ./valheim_server.x86_64 \
    -name "${VALHEIM_NAME}" \
    -port "${VALHEIM_PORT}" \
    -world "${VALHEIM_WORLD}" \
    -password "${VALHEIM_PASSWORD}" \
    -public "${VALHEIM_PUBLIC}" \
    -savedir /opt/valheim/saves \
    "${crossplay_args[@]}"
EOF
install -o root -g root -m 0755 "${TEMP_DIR}/launch-server.sh" "${VALHEIM_DIR}/launch-server.sh"

install -d -o root -g root -m 0755 "${CONFIG_DIR}"
cat > "${CONFIG_DIR}/server.conf" <<EOF
VALHEIM_NAME="${VALHEIM_NAME}"
VALHEIM_WORLD="${VALHEIM_WORLD}"
VALHEIM_PORT="${VALHEIM_PORT}"
VALHEIM_PASSWORD="${VALHEIM_PASSWORD}"
VALHEIM_PUBLIC="${VALHEIM_PUBLIC}"
VALHEIM_CROSSPLAY="${VALHEIM_CROSSPLAY}"
EOF
chown root:root "${CONFIG_DIR}/server.conf"
chmod 0600 "${CONFIG_DIR}/server.conf"

cat > /etc/systemd/system/valheim-server.service <<EOF
[Unit]
Description=Valheim Dedicated Server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${STEAM_USER}
Group=${STEAM_USER}
WorkingDirectory=${SERVER_DIR}
EnvironmentFile=${CONFIG_DIR}/server.conf
ExecStart=${VALHEIM_DIR}/launch-server.sh
Restart=on-failure
RestartSec=10
KillSignal=SIGINT
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now valheim-server.service

echo "Valheim dedicated server is installed and enabled."
echo "Check status with: systemctl status valheim-server"
echo "View logs with: journalctl -u valheim-server -f"
echo "Allow inbound UDP ports ${VALHEIM_PORT}-$((VALHEIM_PORT + 2)) in the VM firewall and cloud network rules."
