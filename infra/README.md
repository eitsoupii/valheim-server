# Valheim server infrastructure

`main.bicep` deploys an Ubuntu 24.04 VM, its virtual network and subnet, a network
security group, a network interface, and a Standard static IPv4 public address.
It opens UDP ports 2456–2458 for Valheim and restricts SSH access to the supplied
source CIDR. The template provisions the VM infrastructure; installing and
configuring the Valheim dedicated server is a separate step.

## Prerequisites

- Azure CLI logged in with permission to deploy resources to a resource group.
- An existing resource group in the target Azure subscription.
- An SSH key pair. Generate one with `ssh-keygen -t ed25519` if needed.
- Your trusted public IP address in CIDR notation (usually `/32`) for
  `sshSourceAddressPrefix`.

## Deploy

From the repository root in PowerShell, set the resource group and SSH key:

```powershell
$resourceGroup = "valheim-server-rg"
$sshPublicKey = (Get-Content "$HOME\.ssh\id_ed25519.pub" -Raw).Trim()
$sshSource = "<your-public-ip>/32"
```

Create the resource group if it does not exist:

```powershell
az group create --name $resourceGroup --location eastus
```

Review the deployment before creating resources:

```powershell
az deployment group what-if `
  --resource-group $resourceGroup `
  --template-file infra/main.bicep `
  --parameters vmName=valheim-server adminUsername=azureuser `
    adminPublicKey="$sshPublicKey" sshSourceAddressPrefix="$sshSource"
```

Deploy after reviewing the what-if output:

```powershell
az deployment group create `
  --resource-group $resourceGroup `
  --template-file infra/main.bicep `
  --parameters vmName=valheim-server adminUsername=azureuser `
    adminPublicKey="$sshPublicKey" sshSourceAddressPrefix="$sshSource"
```

The deployment outputs the VM resource ID, static public IP address, and an SSH
command. `vmSize`, `location`, network address prefixes, and tags can be
overridden as Bicep parameters.

## Parameters

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `vmName` | Yes | — | Name used for the VM and related network resources. |
| `adminUsername` | Yes | — | Linux administrator account name. |
| `adminPublicKey` | Yes | — | SSH public key contents; password authentication is disabled. |
| `sshSourceAddressPrefix` | Yes | — | Source CIDR allowed to connect to SSH port 22. |
| `location` | No | Resource group location | Azure deployment region. |
| `vmSize` | No | `Standard_B2s` | VM size; confirm availability and quota in the chosen region. |
| `vnetAddressPrefix` | No | `10.0.0.0/16` | Virtual network address space. |
| `subnetAddressPrefix` | No | `10.0.0.0/24` | VM subnet address space. |
| `tags` | No | `{}` | Tags applied to deployed resources. |

## Cleanup

If the resource group is dedicated to this server, remove it and its resources with:

```powershell
az group delete --name $resourceGroup --yes --no-wait
```
