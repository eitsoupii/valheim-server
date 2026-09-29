param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$AutomationAccountName,

    [string]$ShutdownTime = '23:00',

    [string]$TimeZone = 'UTC'
)

$ErrorActionPreference = 'Stop'

$requiredCommands = @(
    'Connect-AzAccount',
    'Get-AzContext',
    'Set-AzContext',
    'New-AzResourceGroupDeployment',
    'Import-AzAutomationRunbook',
    'Get-AzAutomationSchedule',
    'New-AzAutomationSchedule',
    'Register-AzAutomationScheduledRunbook',
    'New-AzAutomationWebhook'
)
foreach ($commandName in $requiredCommands) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Required Az PowerShell command '$commandName' is unavailable. Install the Az.Accounts, Az.Resources, and Az.Automation modules."
    }
}
if (-not (Get-Command 'bicep' -ErrorAction SilentlyContinue)) {
    throw 'The Bicep CLI is required to deploy infra/automation.bicep with Azure PowerShell. Install it and make sure bicep is on PATH.'
}

$parsedShutdownTime = [TimeSpan]::Zero
if (-not [TimeSpan]::TryParseExact(
        $ShutdownTime,
        'hh\:mm',
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsedShutdownTime
    )) {
    throw "ShutdownTime must be in 24-hour HH:mm format, for example '23:00'."
}

$timeZoneInfo = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZone)
if ($AutomationAccountName -notmatch '^[A-Za-z][A-Za-z0-9-]{4,48}[A-Za-z0-9]$') {
    throw 'AutomationAccountName must be 6-50 characters, start with a letter, end with a letter or number, and contain only letters, numbers, or hyphens.'
}

if (-not (Get-AzContext)) {
    Connect-AzAccount | Out-Null
}
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

$templatePath = Join-Path $PSScriptRoot '..\infra\automation.bicep'
$deployment = New-AzResourceGroupDeployment `
    -Name "valheim-automation-$(Get-Date -Format 'yyyyMMddHHmmss')" `
    -ResourceGroupName $ResourceGroupName `
    -TemplateFile $templatePath `
    -vmName $VMName `
    -automationAccountName $AutomationAccountName
if ($deployment.ProvisioningState -ne 'Succeeded') {
    throw "Automation infrastructure deployment did not succeed (state: $($deployment.ProvisioningState))."
}

$runbookDirectory = Join-Path $PSScriptRoot '..\automation\runbooks'
$runbooks = @(
    @{
        Name = 'Start-ValheimVm'
        Path = Join-Path $runbookDirectory 'Start-ValheimVm.ps1'
    },
    @{
        Name = 'Stop-ValheimVm'
        Path = Join-Path $runbookDirectory 'Stop-ValheimVm.ps1'
    }
)

foreach ($runbook in $runbooks) {
    Import-AzAutomationRunbook `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $runbook.Name `
        -Type PowerShell `
        -Path $runbook.Path `
        -LogProgress $true `
        -LogVerbose $true `
        -Force `
        -Published | Out-Null
}

$scheduleName = 'Daily-Valheim-VM-Shutdown'
$schedule = Get-AzAutomationSchedule `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -Name $scheduleName `
    -ErrorAction SilentlyContinue

if (-not $schedule) {
    $nowInTimeZone = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $timeZoneInfo)
    $nextShutdown = [DateTime]::SpecifyKind(
        $nowInTimeZone.Date.Add($parsedShutdownTime),
        [DateTimeKind]::Unspecified
    )
    if ($nextShutdown -le $nowInTimeZone.DateTime) {
        $nextShutdown = $nextShutdown.AddDays(1)
    }

    $startTimeOffset = [DateTimeOffset]::new(
        $nextShutdown,
        $timeZoneInfo.GetUtcOffset($nextShutdown)
    )
    $schedule = New-AzAutomationSchedule `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $scheduleName `
        -StartTime $startTimeOffset `
        -DayInterval 1 `
        -TimeZone $timeZoneInfo.Id `
        -Description "Deallocates the Valheim VM daily at $ShutdownTime ($($timeZoneInfo.Id))."

    Register-AzAutomationScheduledRunbook `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -RunbookName 'Stop-ValheimVm' `
        -ScheduleName $scheduleName `
        -Parameters @{
            ResourceGroupName = $ResourceGroupName
            VMName = $VMName
        } | Out-Null
} else {
    Write-Warning "The '$scheduleName' schedule already exists and was left unchanged. Remove it in Azure Automation before changing its time or VM."
}

$webhookName = "Start-ValheimVm-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture))"
$webhook = New-AzAutomationWebhook `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -Name $webhookName `
    -RunbookName 'Start-ValheimVm' `
    -IsEnabled $true `
    -ExpiryTime ([DateTime]::UtcNow.AddYears(1)) `
    -Parameters @{
        ResourceGroupName = $ResourceGroupName
        VMName = $VMName
    }

Write-Output ''
Write-Output 'Setup completed. Save this webhook URL in a password manager; Azure will not show it again:'
Write-Output $webhook.WebhookUri
Write-Output ''
Write-Output "The webhook expires at $($webhook.ExpiryTime). Re-run setup before it expires to create another URL, then revoke the old webhook."
