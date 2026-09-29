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

if ($powerState -eq 'PowerState/deallocated') {
    Write-Output "VM '$VMName' is already deallocated."
    return
}

Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force | Out-Null
Write-Output "VM '$VMName' has been stopped and deallocated."
