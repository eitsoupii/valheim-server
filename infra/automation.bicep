@description('Name of the existing Valheim VM.')
param vmName string

@description('Name for the Azure Automation account.')
@minLength(6)
@maxLength(50)
param automationAccountName string

@description('Azure region. Defaults to the resource group region.')
param location string = resourceGroup().location

@description('Tags applied to the Automation account.')
param tags object = {}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: vmName
}

resource automation 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
  }
}

var virtualMachineContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b24988ac-6180-42a0-ab88-20f7382dd24c'
)

resource automationVmRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vm.id, automation.id, virtualMachineContributorRoleId)
  scope: vm
  properties: {
    roleDefinitionId: virtualMachineContributorRoleId
    principalId: automation.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output automationAccountName string = automation.name
output automationAccountId string = automation.id
output automationPrincipalId string = automation.identity.principalId
