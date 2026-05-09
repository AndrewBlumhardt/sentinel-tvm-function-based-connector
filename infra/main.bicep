targetScope = 'resourceGroup'

var datasetConfig = loadJsonContent('../datasets.json')
var datasets = datasetConfig.datasets
var scheduleDefaults = {
  Schedule_DeviceTvmSoftwareInventory: '0 0 1 * * *'
  Schedule_DeviceTvmSoftwareVulnerabilities: '0 10 1 * * *'
  Schedule_DeviceTvmSoftwareVulnerabilitiesKB: '0 20 1 * * *'
  Schedule_DeviceTvmSecureConfigurationAssessment: '0 30 1 * * *'
  Schedule_DeviceTvmSecureConfigurationAssessmentKB: '0 40 1 * * *'
  Schedule_DeviceTvmSoftwareEvidenceBeta: '0 50 1 * * *'
  Schedule_DeviceTvmBrowserExtensions: '0 0 2 * * *'
  Schedule_DeviceTvmBrowserExtensionsKB: '0 10 2 * * *'
  Schedule_DeviceTvmCertificateInfo: '0 20 2 * * *'
  Schedule_DeviceTvmHardwareFirmware: '0 30 2 * * *'
  Schedule_DeviceTvmInfoGathering: '0 40 2 * * *'
  Schedule_DeviceTvmInfoGatheringKB: '0 50 2 * * *'
  Schedule_ApiSoftwareVulnerabilitiesByMachine: '0 15 1 * * *'
  Schedule_ApiMachines: '0 0 3 * * *'
  Schedule_ApiSoftwareInventoryByMachine: '0 10 3 * * *'
  Schedule_ApiNonCpeSoftwareInventory: '0 20 3 * * *'
  Schedule_ApiRecommendations: '0 30 3 * * *'
  Schedule_ApiSecureConfigurationAssessmentByMachine: '0 40 3 * * *'
  Schedule_ApiVulnerabilitiesCatalog: '0 50 3 * * *'
  Schedule_ApiBrowserExtensionsInventory: '0 0 4 * * *'
  Schedule_ApiBrowserExtensionPermissions: '0 10 4 * * *'
  Schedule_ApiCertificateInventoryAssessment: '0 20 4 * * *'
  Schedule_ApiHardwareFirmwareAssessment: '0 30 4 * * *'
  Schedule_NistCveCatalog: '0 0 2 * * 0'
  Schedule_NistCpeConfigurations: '0 30 2 * * 0'
}
var locationName = empty(location) ? resourceGroup().location : location
var planName = '${namePrefix}-plan'
var dceName = empty(dataCollectionEndpointName) ? '${namePrefix}-dce' : dataCollectionEndpointName
var dcrName = empty(dataCollectionRuleName) ? '${namePrefix}-dcr' : dataCollectionRuleName
var appInsightsName = '${namePrefix}-appi'
var standardStreamColumns = [
  {
    name: 'TimeGenerated'
    type: 'string'
  }
  {
    name: 'SnapshotTime'
    type: 'string'
  }
  {
    name: 'RunId'
    type: 'string'
  }
  {
    name: 'DatasetName'
    type: 'string'
  }
  {
    name: 'SourceType'
    type: 'string'
  }
  {
    name: 'SourceName'
    type: 'string'
  }
  {
    name: 'DestinationTable'
    type: 'string'
  }
  {
    name: 'CollectionMode'
    type: 'string'
  }
  {
    name: 'CollectorVersion'
    type: 'string'
  }
  {
    name: 'PayloadJson'
    type: 'string'
  }
]
var streamDeclarations = reduce(datasets, {}, (state, dataset) => union(state, {
  '${dataset.dcrStreamName}': {
    columns: standardStreamColumns
  }
}))
var scheduleAppSettings = [for dataset in datasets: {
  name: dataset.scheduleSetting
  value: scheduleDefaults[dataset.scheduleSetting] ?? '0 0 1 * * *'
}]
var commonAppSettings = [
  {
    name: 'FUNCTIONS_WORKER_RUNTIME'
    value: 'python'
  }
  {
    name: 'FUNCTIONS_EXTENSION_VERSION'
    value: '~4'
  }
  {
    name: 'AzureWebJobsFeatureFlags'
    value: 'EnableWorkerIndexing'
  }
  {
    name: 'WEBSITE_RUN_FROM_PACKAGE'
    value: '1'
  }
  {
    name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
    value: 'true'
  }
  {
    name: 'PYTHON_ISOLATE_WORKER_DEPENDENCIES'
    value: '1'
  }
  {
    name: 'DatasetConfigPath'
    value: 'datasets.json'
  }
  {
    name: 'CollectorVersion'
    value: string(datasetConfig.collectorVersion)
  }
  {
    name: 'LogsIngestion__Endpoint'
    value: dataCollectionEndpoint.properties.logsIngestion.endpoint
  }
  {
    name: 'LogsIngestion__RuleId'
    value: dataCollectionRule.properties.immutableId
  }
  {
    name: 'ManagedIdentity__ClientId'
    value: ''
  }
  {
    name: 'Nist__ApiKey'
    value: ''
  }
]
var datasetToggleSettings = [for dataset in datasets: {
  name: 'Dataset__${dataset.name}__enabled'
  value: string(bool(dataset.enabled))
}]
var mergedAppSettings = concat(commonAppSettings, datasetToggleSettings, scheduleAppSettings)

@description('Prefix used for generated resource names.')
param namePrefix string = 'sentinel-tvm'

@description('Azure region for the Function App, DCR, and DCE.')
param location string = resourceGroup().location

@description('Name of the Function App to create.')
param functionAppName string = '${namePrefix}-func'

@description('Name of the existing Log Analytics workspace used by Microsoft Sentinel.')
param workspaceName string

@description('Resource group containing the existing Log Analytics workspace.')
param workspaceResourceGroupName string = resourceGroup().name

@description('Name of the Data Collection Endpoint. Leave empty to use the default convention.')
param dataCollectionEndpointName string = ''

@description('Name of the Data Collection Rule. Leave empty to use the default convention.')
param dataCollectionRuleName string = ''

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  scope: resourceGroup(workspaceResourceGroupName)
  name: workspaceName
}

resource appInsights 'microsoft.insights/components@2020-02-02' = {
  name: appInsightsName
  location: locationName
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'stg${uniqueString(resourceGroup().id, functionAppName)}'
  location: locationName
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: locationName
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  kind: 'functionapp'
  properties: {
    reserved: true
  }
}

resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: locationName
  kind: 'Linux'
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

module workspaceTables './modules/workspaceTables.bicep' = {
  name: 'workspaceTables'
  scope: resourceGroup(workspaceResourceGroupName)
  params: {
    workspaceName: workspaceName
    datasets: datasets
  }
}

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: locationName
  kind: 'Direct'
  properties: {
    dataCollectionEndpointId: dataCollectionEndpoint.id
    streamDeclarations: streamDeclarations
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: workspace.id
          name: 'sentinelWorkspace'
        }
      ]
    }
    dataFlows: [for dataset in datasets: {
      streams: [
        dataset.dcrStreamName
      ]
      destinations: [
        'sentinelWorkspace'
      ]
      outputStream: 'Custom-${dataset.destinationTable}'
      transformKql: 'source | project TimeGenerated=todatetime(TimeGenerated), SnapshotTime=todatetime(SnapshotTime), RunId=tostring(RunId), DatasetName=tostring(DatasetName), SourceType=tostring(SourceType), SourceName=tostring(SourceName), DestinationTable=tostring(DestinationTable), CollectionMode=tostring(CollectionMode), CollectorVersion=tostring(CollectorVersion), PayloadJson=tostring(PayloadJson)'
    }]
  }
  dependsOn: [
    workspaceTables
  ]
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: locationName
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    reserved: true
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: concat(mergedAppSettings, [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storage.listKeys().keys[0].value}'
        }
      ])
    }
  }
}

output functionAppName string = functionApp.name
output functionPrincipalId string = functionApp.identity.principalId
output dataCollectionEndpointResourceId string = dataCollectionEndpoint.id
output dataCollectionRuleImmutableId string = dataCollectionRule.properties.immutableId
output logsIngestionEndpoint string = dataCollectionEndpoint.properties.logsIngestion.endpoint
output workspaceId string = workspace.id
