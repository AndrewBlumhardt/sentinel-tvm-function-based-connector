targetScope = 'resourceGroup'

@description('Name of the existing Log Analytics workspace used by Microsoft Sentinel.')
param workspaceName string

@description('Dataset definitions loaded from the shared dataset catalog.')
param datasets array

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource customTables 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = [for dataset in datasets: {
  parent: workspace
  name: dataset.destinationTable
  properties: {
    plan: 'Analytics'
    schema: {
      name: dataset.destinationTable
      columns: [
        {
          name: 'TimeGenerated'
          type: 'dateTime'
        }
        {
          name: 'SnapshotTime'
          type: 'dateTime'
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
    }
    retentionInDays: 30
    totalRetentionInDays: 30
  }
}]
