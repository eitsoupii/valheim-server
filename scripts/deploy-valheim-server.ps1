[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName,

    [string] $Location = 'eastus',

    [string] $VmName = 'valheim-server',

    [string] $AdminUsername = 'azureuser',

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $SshSourceAddressPrefix,

    [string] $SshPublicKeyPath = (Join-Path $HOME '.ssh\id_ed25519.pub'),

    [string] $SshPrivateKeyPath,

    [string] $ServerName = 'Valheim Server',

    [string] $WorldName = 'Dedicated',

    [ValidateSet('0', '1')]
    [string] $Public = '1',

    [ValidateSet('0', '1')]
    [string] $Crossplay = '0'
)

$ErrorActionPreference = 'Stop'

function Invoke-Az {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)

    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed with exit code $LASTEXITCODE."
    }
}

function ConvertTo-PlainText {
    param([Parameter(Mandatory = $true)][Security.SecureString] $Value)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

if ($VmName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,58}$') {
    throw 'VmName must be 1-59 characters and contain only letters, numbers, and hyphens.'
}
if ($AdminUsername -notmatch '^[a-z_][a-z0-9_-]*[$]?$') {
    throw 'AdminUsername must be a valid Linux account name.'
}
if ($ServerName -notmatch '^[A-Za-z0-9_. -]+$') {
    throw 'ServerName may contain only letters, numbers, spaces, dots, underscores, and hyphens.'
}
if ($WorldName -notmatch '^[A-Za-z0-9_.-]+$') {
    throw 'WorldName may contain only letters, numbers, dots, underscores, and hyphens.'
}
if ($SshSourceAddressPrefix -notmatch '^(.+)/(\d{1,2})$') {
    throw 'SshSourceAddressPrefix must be an IPv4 CIDR range, such as 203.0.113.10/32.'
}
$sourceAddress = $null
if (-not [Net.IPAddress]::TryParse($Matches[1], [ref]$sourceAddress) -or
    $sourceAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
    [int]$Matches[2] -gt 32) {
    throw 'SshSourceAddressPrefix must be a valid IPv4 CIDR range with a prefix length from 0 to 32.'
}

foreach ($tool in @('az', 'ssh', 'scp')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required command '$tool' was not found. Install Azure CLI and OpenSSH, then retry."
    }
}

if (-not (Test-Path -LiteralPath $SshPublicKeyPath -PathType Leaf)) {
    throw "SSH public key not found: $SshPublicKeyPath"
}
if (-not $SshPrivateKeyPath) {
    if ($SshPublicKeyPath -notmatch '\.pub$') {
        throw 'Specify SshPrivateKeyPath when the public key filename does not end in .pub.'
    }
    $SshPrivateKeyPath = $SshPublicKeyPath -replace '\.pub$', ''
}
if (-not (Test-Path -LiteralPath $SshPrivateKeyPath -PathType Leaf)) {
    throw "SSH private key not found: $SshPrivateKeyPath"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$templatePath = Join-Path $repoRoot 'infra\main.bicep'
$installerPath = Join-Path $PSScriptRoot 'install-valheim-server.sh'
foreach ($path in @($templatePath, $installerPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required deployment file not found: $path"
    }
}

$accountId = (& az account show --query id --output tsv 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $accountId) {
    throw 'Azure CLI is not logged in. Run az login and retry.'
}
Write-Host "Using Azure subscription: $accountId"

$target = "resource group '$ResourceGroupName' in '$Location' with VM '$VmName'"
if (-not $PSCmdlet.ShouldProcess($target, 'Create Azure resources and install Valheim')) {
    return
}

$securePassword = Read-Host 'Valheim server password (at least 5 letters, numbers, _ or -)' -AsSecureString
$serverPassword = ConvertTo-PlainText $securePassword
$securePassword = $null
if ($serverPassword -notmatch '^[A-Za-z0-9_-]{5,}$') {
    $serverPassword = $null
    throw 'The server password must be at least 5 letters, numbers, underscores, or hyphens.'
}

try {
    Invoke-Az @('group', 'create', '--name', $ResourceGroupName, '--location', $Location, '--output', 'none')
    Invoke-Az @(
        'deployment', 'group', 'create',
        '--resource-group', $ResourceGroupName,
        '--name', 'valheim-server',
        '--template-file', $templatePath,
        '--parameters',
        "vmName=$VmName",
        "adminUsername=$AdminUsername",
        "adminPublicKey=$((Get-Content -LiteralPath $SshPublicKeyPath -Raw).Trim())",
        "sshSourceAddressPrefix=$SshSourceAddressPrefix"
    )

    $publicIp = (& az deployment group show --resource-group $ResourceGroupName --name valheim-server --query 'properties.outputs.publicIpAddress.value' --output tsv)
    if ($LASTEXITCODE -ne 0 -or -not $publicIp) {
        throw 'Could not retrieve the VM public IP address from the deployment.'
    }

    $sshTarget = "${AdminUsername}@${publicIp}"
    $sshOptions = @(
        '-i', $SshPrivateKeyPath,
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=10',
        '-o', 'StrictHostKeyChecking=accept-new'
    )

    Write-Host "Waiting for SSH on $publicIp..."
    $sshReady = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        & ssh @sshOptions $sshTarget 'true' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $sshReady = $true
            break
        }
        Start-Sleep -Seconds 10
    }
    if (-not $sshReady) {
        throw "SSH did not become available at $publicIp within 10 minutes."
    }

    & scp @sshOptions $installerPath "${sshTarget}:/tmp/install-valheim-server.sh"
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not copy the Valheim installer to the VM.'
    }

    $remoteCommand = "sudo -n bash -c 'set -e; trap `"rm -f /tmp/install-valheim-server.sh`" EXIT; IFS= read -r VALHEIM_PASSWORD; export VALHEIM_PASSWORD; VALHEIM_NAME=`"$ServerName`" VALHEIM_WORLD=$WorldName VALHEIM_PUBLIC=$Public VALHEIM_CROSSPLAY=$Crossplay bash /tmp/install-valheim-server.sh'"
    $serverPassword | & ssh @sshOptions $sshTarget $remoteCommand
    $sshExitCode = $LASTEXITCODE
    $serverPassword = $null
    if ($sshExitCode -ne 0) {
        throw "The Valheim installer failed on the VM with exit code $sshExitCode."
    }

    Write-Host ''
    Write-Host 'Valheim server deployment completed.'
    Write-Host "Public IP: $publicIp"
    Write-Host "Connect with: ssh -i `"$SshPrivateKeyPath`" $sshTarget"
    Write-Host "Server status: ssh -i `"$SshPrivateKeyPath`" $sshTarget 'sudo systemctl status valheim-server'"
}
finally {
    $serverPassword = $null
}
