param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$VMName
)

$ErrorActionPreference = 'Stop'

Connect-AzAccount -Identity | Out-Null

$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
$powerState = ($vm.Statuses | Where-Object Code -like 'PowerState/*').Code

if ($powerState -eq 'PowerState/running') {
    Write-Output "VM '$VMName' is already running."
    return
}

Start-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -NoWait | Out-Null
Write-Output "Start requested for VM '$VMName'. The enabled systemd service starts Valheim when Ubuntu boots."
