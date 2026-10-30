#
# Module manifest for PbiSuperpower - PowerShell automation for the power-bi-superpower repository.
#
@{
    RootModule           = 'PbiSuperpower.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'a32077ab-3b33-4c72-aaf4-c20cdbe0a35f' # pbi-allow-guid (module identity, not a tenant or workspace id)
    Author               = 'power-bi-superpower contributors'
    CompanyName          = 'power-bi-superpower'
    Copyright            = '(c) power-bi-superpower contributors.'
    Description          = 'Power BI as code: environment configuration, Fabric and Power BI REST deployment (PBIP: TMDL + PBIR), quality gates, DAX tests and evidence for GitHub Copilot driven sprints.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Set-PbiLogMode'
        'Write-PbiLog'
        'Write-PbiWarning'
        'Get-PbiLogWarning'
        'Split-PbiListArgument'
        'Invoke-PbiNativeCommand'
        'Read-PbiTextFile'
        'Write-PbiTextFile'
        'Read-PbiJsonFile'
        'Get-PbiRelativePath'
        'ConvertTo-PbiVersion'
        'Get-PbiContentHash'
        'Get-PbiRepoRoot'
        'Get-PbiProperty'
        'Expand-PbiPlaceholder'
        'Get-PbiEnvironmentConfig'
        'Get-PbiGateConfig'
        'Get-PbiToolVersions'
        'Get-PbiProject'
        'Get-PbiGitContext'
        'Assert-PbiDeploymentGuard'
        'Connect-PbiFabric'
        'Get-PbiAccessToken'
        'Invoke-PbiFabricApi'
        'Invoke-PbiFabricApiPaged'
        'Get-PbiCapacity'
        'Get-PbiWorkspace'
        'Deploy-PbiWorkspace'
        'Get-PbipDefinitionPart'
        'Set-PbipSemanticModelParameter'
        'Set-PbipReportBinding'
        'Get-PbiItem'
        'Publish-PbiSemanticModel'
        'Publish-PbiReport'
        'Invoke-PbiDatasetRefresh'
        'Invoke-PbiDaxQuery'
        'Get-PbiDesktopInstance'
        'Import-PbiAdomdClient'
        'Invoke-PbiLocalDaxQuery'
        'Get-PbiDaxTestFile'
        'Get-PbiDaxTestDirective'
        'Invoke-PbiDaxTestSuite'
        'New-PbiFinding'
        'Test-PbiRepoHygiene'
        'Test-PbipProjectStructure'
        'Test-PbiTmdlConvention'
        'Test-PbiReportConvention'
        'Test-PbiAgentAsset'
        'Test-PbiMcpConfigParity'
        'Test-PbiModelBpa'
        'Test-PbiSuperpowersManifest'
        'Test-PbiQualityGate'
        'New-PbiEvidence'
        'ConvertTo-PbiEvidenceMarkdown'
        'Protect-PbiText'
        'Invoke-PbiGh'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags = @('PowerBI', 'Fabric', 'PBIP', 'TMDL', 'PBIR', 'DAX', 'IaC', 'GitHubCopilot')
        }
    }
}
