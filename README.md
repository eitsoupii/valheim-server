# valheim-server

Install and run a Valheim dedicated server on an Ubuntu Azure VM.

## Azure infrastructure

The Bicep template in [`infra/main.bicep`](infra/main.bicep) deploys an Ubuntu VM
with a static public IP, a virtual network, and network rules for SSH and Valheim
game traffic. See [`infra/README.md`](infra/README.md) for prerequisites and
deployment instructions.

## Install

The installer supports Ubuntu 22.04 and 24.04 on amd64. It installs SteamCMD
(the Steam command-line client; the graphical Steam client is not needed),
downloads the Valheim dedicated server, and configures it as a systemd service.

### Steam account

No personal Steam account or Steam password is needed on the VM. The installer
downloads the dedicated server through SteamCMD using its `anonymous` login.
The Linux service runs as a separate, unprivileged local user named `steam`;
that is not a Steam account. Keep your personal Steam credentials off the
server.

Players connect with their own platform accounts and copies of Valheim. With
crossplay enabled, players on supported platforms can join using the server's
join code; crossplay does not require entering a Steam account on the VM.

### Server configuration

The defaults are name `Valheim Server`, world `Dedicated`, port `2456`, public
listing enabled, and crossplay disabled. Configure the server name, world name,
port, visibility, crossplay mode, and password with the corresponding
`VALHEIM_*` environment variables when running the installer. For example, to
configure crossplay and a private server:

```bash
read -rsp "Server password: " VALHEIM_PASSWORD; echo
sudo env \
  VALHEIM_PASSWORD="$VALHEIM_PASSWORD" \
  VALHEIM_NAME="My Valheim World" \
  VALHEIM_WORLD="MyWorld" \
  VALHEIM_PUBLIC=0 \
  VALHEIM_CROSSPLAY=1 \
  bash scripts/install-valheim-server.sh
unset VALHEIM_PASSWORD
```

The installer writes these settings to `/etc/valheim/server.conf`. To change
them after installation, edit that root-only file with `sudoedit
/etc/valheim/server.conf` and restart the service with `sudo systemctl restart
valheim-server`. The world data is kept separately in `/opt/valheim/saves`.
The installer accepts `VALHEIM_NAME`, `VALHEIM_WORLD`, `VALHEIM_PORT`,
`VALHEIM_PUBLIC`, and `VALHEIM_CROSSPLAY`; crossplay uses Valheim's
`-crossplay` option when set to `1`. It validates these values before writing
the service configuration and can be rerun to update the server and settings.

The installer starts the service at the end. Use `systemctl status
valheim-server` to check it and `journalctl -u valheim-server -f` to follow its
logs. Stop or start it with `sudo systemctl stop valheim-server` and `sudo
systemctl start valheim-server`.

Allow inbound UDP traffic on the configured port and the next two ports
(`2456-2458/udp` by default) in both the VM firewall and the Azure network
security group. Keep the server password private; the installer stores it in
`/etc/valheim/server.conf`, readable only by root.
