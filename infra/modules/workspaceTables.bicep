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
      columns: [for col in dataset.columns: {
        name: col.name
        type: replace(col.type, 'datetime', 'dateTime')
      }]
    }
    // -1 = inherit the workspace's default retention (interactive + total).
    // Per Microsoft docs for Microsoft.OperationalInsights/workspaces/tables.
    retentionInDays: -1
    totalRetentionInDays: -1
  }
}]
