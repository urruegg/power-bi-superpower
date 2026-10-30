#Requires -Version 7.4
# Pester 5 tests: definition parts (exclusions, base64), report binding and semantic model parameters (offline).

BeforeAll {
    Import-Module "$PSScriptRoot/../../scripts/modules/PbiSuperpower/PbiSuperpower.psd1" -Force

    function New-TestFile {
        param(
            [string] $Path,
            [string] $Content = ''
        )
        $directory = Split-Path -Path $Path -Parent
        if (-not (Test-Path -LiteralPath $directory)) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }
        [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    }

    function New-Part {
        param(
            [string] $Path,
            [string] $Text
        )
        return @{ path = $Path; payload = [System.Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($Text)); payloadType = 'InlineBase64' }
    }

    function Get-PartText {
        param(
            [object[]] $Part,
            [string] $Path
        )
        $match = @($Part | Where-Object { $_['path'] -eq $Path })
        $match.Count | Should -Be 1
        return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($match[0]['payload']))
    }

    $script:modelId = '11111111-2222-3333-4444-555555555555'
}

Describe 'Get-PbipDefinitionPart' {
    BeforeAll {
        $script:item = Join-Path $TestDrive 'Sales.SemanticModel'
        New-TestFile -Path (Join-Path $script:item 'definition.pbism') -Content '{ "version": "4.2" }'
        New-TestFile -Path (Join-Path $script:item 'definition/model.tmdl') -Content "model Model`n"
        New-TestFile -Path (Join-Path $script:item 'definition/database.tmdl') -Content "database Sales`n"
        New-TestFile -Path (Join-Path $script:item 'definition/tables/Sales.tmdl') -Content "table Sales`n"
        New-TestFile -Path (Join-Path $script:item 'diagramLayout.json') -Content '{}'
        New-TestFile -Path (Join-Path $script:item '.pbi/localSettings.json') -Content '{}'
        New-TestFile -Path (Join-Path $script:item '.pbi/editorSettings.json') -Content '{}'
        New-TestFile -Path (Join-Path $script:item '.platform') -Content '{}'
        New-TestFile -Path (Join-Path $script:item 'DAXQueries/Measures.ALL.Tests.dax') -Content 'EVALUATE ROW("x", 1)'
        New-TestFile -Path (Join-Path $script:item 'TMDLScripts/script.tmdl') -Content 'createOrReplace'
        New-TestFile -Path (Join-Path $script:item 'item.metadata.json') -Content '{}'
        New-TestFile -Path (Join-Path $script:item 'item.config.json') -Content '{}'
        New-TestFile -Path (Join-Path $script:item 'definition/nested/.pbi/cache.json') -Content '{}'
        New-TestFile -Path (Join-Path $script:item 'cache.abf') -Content 'binary'
    }

    It 'applies the default exclusions and orders the parts by path' {
        $parts = @(Get-PbipDefinitionPart -ItemPath $script:item)
        $paths = @($parts | ForEach-Object { $_['path'] })
        ($paths -join '|') | Should -BeExactly 'definition.pbism|definition/database.tmdl|definition/model.tmdl|definition/tables/Sales.tmdl|diagramLayout.json'
    }

    It 'uses forward slashes and InlineBase64 payloads' {
        $parts = @(Get-PbipDefinitionPart -ItemPath $script:item)
        foreach ($part in $parts) {
            $part['path'] | Should -Not -BeLike '*\*'
            $part['payloadType'] | Should -Be 'InlineBase64'
        }
    }

    It 'round-trips the raw bytes through base64 (BOM, CRLF and non-ASCII preserved)' {
        $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes("table 'Umsatz' `u{00E4}`r`n`tmeasure x = 1`r`n"))
        [System.IO.File]::WriteAllBytes((Join-Path $script:item 'definition/tables/Sales.tmdl'), $bytes)
        $part = @(Get-PbipDefinitionPart -ItemPath $script:item | Where-Object { $_['path'] -eq 'definition/tables/Sales.tmdl' })[0]
        $decoded = [System.Convert]::FromBase64String($part['payload'])
        $decoded.Length | Should -Be $bytes.Length
        [System.Convert]::ToBase64String($decoded) | Should -Be ([System.Convert]::ToBase64String($bytes))
    }

    It 'replaces the default exclusions when -Exclude is given' {
        $parts = @(Get-PbipDefinitionPart -ItemPath $script:item -Exclude @('\.abf$'))
        $paths = @($parts | ForEach-Object { $_['path'] })
        $paths | Should -Contain '.platform'
        $paths | Should -Contain '.pbi/localSettings.json'
        $paths | Should -Not -Contain 'cache.abf'
    }

    It 'throws for a missing folder' {
        { Get-PbipDefinitionPart -ItemPath (Join-Path $TestDrive 'Missing.SemanticModel') } | Should -Throw -ExpectedMessage '*not found*'
    }
}

Describe 'Set-PbipReportBinding' {
    It 'writes byConnection with semanticmodelid for the 2.0.0 schema and removes byPath' {
        $pbir = '{ "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/2.0.0/schema.json", "version": "4.0", "datasetReference": { "byPath": { "path": "../Sales.SemanticModel" } } }'
        $other = New-Part -Path 'definition/report.json' -Text '{}'
        $parts = @((New-Part -Path 'definition.pbir' -Text $pbir), $other)
        $result = @(Set-PbipReportBinding -Part $parts -SemanticModelId $script:modelId)
        $json = Get-PartText -Part $result -Path 'definition.pbir' | ConvertFrom-Json
        $json.'$schema' | Should -BeLike '*/definitionProperties/2.0.0/schema.json'
        $json.version | Should -Be '4.0'
        $json.datasetReference.byConnection.connectionString | Should -Be "semanticmodelid=$($script:modelId)"
        $json.datasetReference.PSObject.Properties['byPath'] | Should -BeNullOrEmpty
        @($json.datasetReference.byConnection.PSObject.Properties).Count | Should -Be 1
        [object]::ReferenceEquals(@($result | Where-Object { $_['path'] -eq 'definition/report.json' })[0], $other) | Should -BeTrue
    }

    It 'writes the XMLA-style byConnection for the 1.0.0 schema' {
        $pbir = '{ "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/1.0.0/schema.json", "version": "1.0", "datasetReference": { "byPath": { "path": "../Sales.SemanticModel" }, "byConnection": null } }'
        $result = @(Set-PbipReportBinding -Part @(New-Part -Path 'definition.pbir' -Text $pbir) -SemanticModelId $script:modelId)
        $json = Get-PartText -Part $result -Path 'definition.pbir' | ConvertFrom-Json
        $json.'$schema' | Should -BeLike '*/definitionProperties/1.0.0/schema.json'
        $json.version | Should -Be '1.0'
        $connection = $json.datasetReference.byConnection
        $connection.connectionString | Should -BeNullOrEmpty
        $connection.pbiServiceModelId | Should -BeNullOrEmpty
        $connection.pbiModelVirtualServerName | Should -Be 'sobe_wowvirtualserver'
        $connection.pbiModelDatabaseName | Should -Be $script:modelId
        $connection.name | Should -Be 'EntityDataSource'
        $connection.connectionType | Should -Be 'pbiServiceXmlaStyleLive'
        $json.datasetReference.PSObject.Properties['byPath'] | Should -BeNullOrEmpty
    }

    It 'adds the 2.0.0 schema when the schema is missing' {
        $pbir = '{ "version": "4.0", "datasetReference": { "byPath": { "path": "../Sales.SemanticModel" } } }'
        $result = @(Set-PbipReportBinding -Part @(New-Part -Path 'definition.pbir' -Text $pbir) -SemanticModelId $script:modelId)
        $json = Get-PartText -Part $result -Path 'definition.pbir' | ConvertFrom-Json
        $json.'$schema' | Should -Be 'https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/2.0.0/schema.json'
        $json.datasetReference.byConnection.connectionString | Should -Be "semanticmodelid=$($script:modelId)"
    }

    It 'does not modify the input parts' {
        $pbir = '{ "version": "4.0", "datasetReference": { "byPath": { "path": "../Sales.SemanticModel" } } }'
        $part = New-Part -Path 'definition.pbir' -Text $pbir
        $before = $part['payload']
        $null = Set-PbipReportBinding -Part @($part) -SemanticModelId $script:modelId
        $part['payload'] | Should -Be $before
    }

    It 'throws when definition.pbir is missing' {
        { Set-PbipReportBinding -Part @(New-Part -Path 'definition/report.json' -Text '{}') -SemanticModelId $script:modelId } | Should -Throw -ExpectedMessage '*definition.pbir*'
    }
}

Describe 'Set-PbipSemanticModelParameter' {
    BeforeAll {
        $script:expressions = @(
            '/// Deployment environment'
            'expression Environment = "Local" meta [IsParameterQuery=true, Type="Text", IsParameterQueryRequired=true]'
            ''
            "expression 'Row Limit' = 100 meta [IsParameterQuery=true, Type=""Number"", IsParameterQueryRequired=true]"
            ''
            'expression IsTest = false meta [IsParameterQuery=true, Type="Logical", IsParameterQueryRequired=true]'
            ''
            'expression Source ='
            "`t`tlet x = 1 in x"
        ) -join "`n"
    }

    It 'sets a text parameter (quotes escaped)' {
        $parts = @(New-Part -Path 'definition/expressions.tmdl' -Text $script:expressions)
        $result = @(Set-PbipSemanticModelParameter -Part $parts -Parameter @{ Environment = 'DE"V' })
        $text = Get-PartText -Part $result -Path 'definition/expressions.tmdl'
        $text | Should -BeLike '*expression Environment = "DE""V" meta `[IsParameterQuery=true*'
        $text | Should -BeLike '*/// Deployment environment*'
    }

    It 'sets a number parameter with a quoted name' {
        $parts = @(New-Part -Path 'definition/expressions.tmdl' -Text $script:expressions)
        $result = @(Set-PbipSemanticModelParameter -Part $parts -Parameter @{ 'Row Limit' = 2500 })
        $text = Get-PartText -Part $result -Path 'definition/expressions.tmdl'
        $text | Should -BeLike "*expression 'Row Limit' = 2500 meta*"
    }

    It 'writes decimals with the invariant culture and booleans raw' {
        $parts = @(New-Part -Path 'definition/expressions.tmdl' -Text $script:expressions)
        $result = @(Set-PbipSemanticModelParameter -Part $parts -Parameter ([ordered]@{ 'Row Limit' = 12.5; IsTest = $true }))
        $text = Get-PartText -Part $result -Path 'definition/expressions.tmdl'
        $text | Should -BeLike "*expression 'Row Limit' = 12.5 meta*"
        $text | Should -BeLike '*expression IsTest = true meta*'
    }

    It 'accepts parameters from JSON configuration (PSCustomObject)' {
        $parts = @(New-Part -Path 'definition/expressions.tmdl' -Text $script:expressions)
        $parameters = ConvertFrom-Json -InputObject '{ "Environment": "TEST" }'
        $result = @(Set-PbipSemanticModelParameter -Part $parts -Parameter $parameters)
        Get-PartText -Part $result -Path 'definition/expressions.tmdl' | Should -BeLike '*expression Environment = "TEST" meta*'
    }

    It 'throws when a parameter does not exist' {
        $parts = @(New-Part -Path 'definition/expressions.tmdl' -Text $script:expressions)
        { Set-PbipSemanticModelParameter -Part $parts -Parameter @{ NotThere = 'x' } } | Should -Throw -ExpectedMessage '*NotThere*'
    }

    It 'does not treat a non-parameter expression as a parameter' {
        $parts = @(New-Part -Path 'definition/expressions.tmdl' -Text $script:expressions)
        { Set-PbipSemanticModelParameter -Part $parts -Parameter @{ Source = 'x' } } | Should -Throw -ExpectedMessage '*Source*'
    }

    It 'leaves the input parts unchanged and keeps other parts' {
        $expressionPart = New-Part -Path 'definition/expressions.tmdl' -Text $script:expressions
        $modelPart = New-Part -Path 'definition/model.tmdl' -Text 'model Model'
        $before = $expressionPart['payload']
        $result = @(Set-PbipSemanticModelParameter -Part @($expressionPart, $modelPart) -Parameter @{ Environment = 'DEV' })
        $expressionPart['payload'] | Should -Be $before
        $result.Count | Should -Be 2
        [object]::ReferenceEquals(@($result | Where-Object { $_['path'] -eq 'definition/model.tmdl' })[0], $modelPart) | Should -BeTrue
    }

    It 'throws when expressions.tmdl is missing' {
        { Set-PbipSemanticModelParameter -Part @(New-Part -Path 'definition/model.tmdl' -Text 'model Model') -Parameter @{ Environment = 'DEV' } } | Should -Throw -ExpectedMessage '*expressions.tmdl*'
    }
}
