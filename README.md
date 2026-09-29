# valheim-server

Install and run a Valheim dedicated server on an Ubuntu Azure VM.

## Prerequisites

For the automated deployment from Windows, have the following ready:

- **Windows PowerShell 5.1 or later.** The deployment script is
  `scripts/deploy-valheim-server.ps1`.
- **Azure CLI**, installed and signed in to the subscription where you want to
  create the server. Install it using the
  [Azure CLI instructions](https://learn.microsoft.com/cli/azure/install-azure-cli-windows),
  then run `az login`. Your account needs permission to create a resource group
  and deploy virtual machines, networking, public IP addresses, and network
  security groups in the subscription. Confirm the subscription with
  `az account show`.
- **OpenSSH client**, including both `ssh` and `scp`. On Windows, install the
  OpenSSH Client optional feature if those commands are not already available.
- **An SSH key pair** for logging in to the VM. The script defaults to
  `~\.ssh\id_ed25519` and `~\.ssh\id_ed25519.pub`. Create one in PowerShell if
  needed:

  ```powershell
  ssh-keygen -t ed25519
  ```

- **Your current public IPv4 address in CIDR notation**, to restrict SSH access
  to your connection. A single address typically uses `/32`, for example
  `203.0.113.10/32`. If your ISP changes your public IP, update the network
  security group before connecting from the new address.
- **An available Azure region and VM quota.** The default VM size is
  `Standard_B2s`; availability and quota depend on your subscription and region.

The deployment script installs and configures the server on the remote Ubuntu
VM. You do not need SteamCMD, Linux, or Valheim installed on your Windows
machine. The VM needs outbound internet access to download Ubuntu packages and
the dedicated server files.

## Azure infrastructure

The Bicep template in [`infra/main.bicep`](infra/main.bicep) deploys an Ubuntu VM
with a static public IP, a virtual network, and network rules for SSH and Valheim
game traffic. See [`infra/README.md`](infra/README.md) for prerequisites and
deployment instructions.

### Deploy infrastructure and server from PowerShell

For a complete deployment from your local Windows machine, use
[`scripts/deploy-valheim-server.ps1`](scripts/deploy-valheim-server.ps1). It
creates the resource group if necessary, deploys the Bicep template, waits for
SSH to become available, and runs the server installer on the VM.

Install and sign in to the [Azure CLI](https://learn.microsoft.com/cli/azure/)
and ensure OpenSSH (`ssh` and `scp`) is available. Then run from the repository
root:

```powershell
az login
.\scripts\deploy-valheim-server.ps1 `
  -ResourceGroupName valheim-server-rg `
  -Location eastus `
  -SshSourceAddressPrefix "203.0.113.10/32"
```

Replace the example CIDR with the public source address range your ISP assigns
to your connection. A single current public IP is commonly entered as `/32`;
use a wider CIDR only if you specifically want to permit that whole range.
SSH is restricted to this CIDR in the Azure network security group. If your
public IP changes, update the `sshSourceAddressPrefix` parameter by redeploying
the Bicep template before connecting from the new address.

The script uses `~\.ssh\id_ed25519.pub` and its matching private key by default;
override `-SshPublicKeyPath` and `-SshPrivateKeyPath` if your SSH key is elsewhere.
It prompts for the Valheim server password without echoing it, sends it to the
VM over the SSH input stream, and does not put it in the Azure deployment or
remote command arguments. Server name, world, public listing, and crossplay can
be set with `-ServerName`, `-WorldName`, `-Public`, and `-Crossplay`. Use
`-WhatIf` to skip all Azure resource creation and server installation.

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
