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

## Start and stop automation

The Valheim installer enables the `valheim-server` systemd service at boot, so
starting the VM also starts the game server. The optional Azure Automation setup
adds:

- A system-assigned managed identity with the **Virtual Machine Contributor**
  role scoped to this VM only.
- A daily runbook schedule that stops and deallocates the VM.
- A start runbook exposed through an HTTPS webhook. The webhook URL contains a
  bearer SAS secret and can be invoked with an HTTP `POST`.

The runbooks require the Automation account's PowerShell runtime to have the
`Az.Accounts` and `Az.Compute` modules available.

### Configure

Use a unique Automation account name of 6–50 characters, containing only
letters, numbers, and hyphens, starting with a letter and ending with a letter
or number. Install the Az PowerShell modules and sign in to the same Azure
subscription as the VM. Also install the [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install)
and ensure `bicep` is on `PATH`. The deploying identity needs permission to
create the Automation account and assign the VM-scoped role (for example,
Owner, or Contributor plus Role Based Access Control Administrator):

```powershell
Install-Module -Name Az.Accounts, Az.Resources, Az.Automation -Scope CurrentUser
Connect-AzAccount
```

Then run the setup script from the repository root. Shutdown defaults to 23:00
UTC; supply a time zone ID recognized by the local PowerShell host to use local
time instead:

```powershell
.\scripts\setup-valheim-automation.ps1 `
  -SubscriptionId "<subscription-id>" `
  -ResourceGroupName "valheim-server-rg" `
  -VMName "valheim-server" `
  -AutomationAccountName "valheim-server-automation" `
  -ShutdownTime "23:00" `
  -TimeZone "UTC"
```

The script deploys `infra/automation.bicep`, imports and publishes the runbooks,
creates the daily shutdown schedule, and prints the startup webhook URL once.
Allow several minutes for the VM-scoped role assignment to propagate before
calling the webhook for the first time.
The webhook expires after one year. Store it as a secret; do not commit it,
include it in logs, or share it. Re-running setup creates a new webhook but
does not revoke prior webhooks. Revoke old URLs in the Automation account.
An existing daily schedule is retained unchanged on subsequent runs.

### Start the VM

Send an HTTPS `POST` to the saved webhook URL. The URL itself is the bearer
credential; no request body is needed:

```powershell
Invoke-RestMethod -Method Post -Uri $env:VALHEIM_START_WEBHOOK_URL
```

Set `VALHEIM_START_WEBHOOK_URL` from a secret store before invoking the request.
The webhook starts the VM; once Ubuntu is up, systemd starts Valheim. Startup
may take several minutes.

### Cost

Azure Automation charges for runbook job execution time; the account, managed
identity, and role assignment do not require an always-running compute
instance. With one short daily shutdown job and occasional start requests, job
runtime should be small, but charges depend on the subscription and current
regional pricing. Deallocating the VM stops its compute billing, but its managed
disk and static public IP may continue to incur charges.

## Cleanup

If the resource group is dedicated to this server, remove it and its resources with:

```powershell
az group delete --name $resourceGroup --yes --no-wait
```
