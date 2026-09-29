# valheim-server
Install and run a Valheim dedicated server on an Azure VM

## Azure infrastructure

The Bicep template in [`infra/main.bicep`](infra/main.bicep) deploys an Ubuntu VM
with a static public IP, a virtual network, and network rules for SSH and Valheim
game traffic. See [`infra/README.md`](infra/README.md) for prerequisites and
deployment instructions.
