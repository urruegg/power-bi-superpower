#Requires -Version 7.4
# Pester 5 tests: Invoke-PbiFabricApi / Invoke-PbiFabricApiPaged with Invoke-WebRequest mocked (offline).

BeforeAll {
    Import-Module "$PSScriptRoot/../../scripts/modules/PbiSuperpower/PbiSuperpower.psd1" -Force
}

Describe 'Invoke-PbiFabricApi' {
    BeforeEach {
        Mock -CommandName Get-PbiAccessToken -ModuleName PbiSuperpower -MockWith { 'fake-token' }
        Mock -CommandName Start-Sleep -ModuleName PbiSuperpower -MockWith { }
        Mock -CommandName Write-Host -ModuleName PbiSuperpower -MockWith { }
    }

    It 'retries after HTTP 429 (honouring Retry-After) and returns the parsed body' {
        $script:responses = [System.Collections.Queue]::new()
        $script:responses.Enqueue([pscustomobject]@{ StatusCode = 429; Headers = @{ 'Retry-After' = @('1') }; Content = '' })
        $script:responses.Enqueue([pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '{ "id": "abc", "displayName": "Sales" }' })
        Mock -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -MockWith { $script:responses.Dequeue() }

        $result = Invoke-PbiFabricApi -Method Get -Path 'workspaces/abc'

        $result.id | Should -Be 'abc'
        Should -Invoke -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -Times 2 -Exactly
        Should -Invoke -CommandName Start-Sleep -ModuleName PbiSuperpower -Times 1 -Exactly -ParameterFilter { $Milliseconds -ge 1000 -and $Milliseconds -le 3000 }
    }

    It 'sends the bearer token, JSON body and content type' {
        Mock -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -MockWith {
            [pscustomobject]@{ StatusCode = 201; Headers = @{}; Content = '{ "id": "new" }' }
        }
        $result = Invoke-PbiFabricApi -Method Post -Path 'workspaces' -Body @{ displayName = 'Sales [DEV]' }
        $result.id | Should -Be 'new'
        Should -Invoke -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -Times 1 -Exactly -ParameterFilter {
            $Headers['Authorization'] -eq 'Bearer fake-token' -and
            $ContentType -like 'application/json*' -and
            ([System.Text.Encoding]::UTF8.GetString([byte[]]$Body)) -eq '{"displayName":"Sales [DEV]"}' -and
            $Uri.AbsoluteUri -eq 'https://api.fabric.microsoft.com/v1/workspaces'
        }
    }

    It 'uses the Power BI base URL for -Resource PowerBI' {
        Mock -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -MockWith {
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '{ "value": [] }' }
        }
        $null = Invoke-PbiFabricApi -Method Get -Path 'groups' -Resource PowerBI
        Should -Invoke -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -Times 1 -Exactly -ParameterFilter { $Uri.AbsoluteUri -eq 'https://api.powerbi.com/v1.0/myorg/groups' }
        Should -Invoke -CommandName Get-PbiAccessToken -ModuleName PbiSuperpower -Times 1 -Exactly -ParameterFilter { $Resource -eq 'PowerBI' }
    }

    It 'polls a long-running operation (202) until Succeeded and returns the operation result' {
        $script:operationStates = [System.Collections.Queue]::new()
        $script:operationStates.Enqueue('{ "status": "Running", "percentComplete": 50 }')
        $script:operationStates.Enqueue('{ "status": "Succeeded", "percentComplete": 100 }')
        Mock -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -ParameterFilter { $Method -eq 'Post' } -MockWith {
            [pscustomobject]@{
                StatusCode = 202
                Headers    = @{
                    'Location'          = @('https://api.fabric.microsoft.com/v1/operations/op-1')
                    'x-ms-operation-id' = @('op-1')
                    'Retry-After'       = @('2')
                }
                Content    = ''
            }
        }
        Mock -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -ParameterFilter { $Method -eq 'Get' -and $Uri.AbsoluteUri -like '*/operations/op-1' } -MockWith {
            [pscustomobject]@{ StatusCode = 200; Headers = @{ 'Retry-After' = @('1') }; Content = $script:operationStates.Dequeue() }
        }
        Mock -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -ParameterFilter { $Method -eq 'Get' -and $Uri.AbsoluteUri -like '*/operations/op-1/result' } -MockWith {
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '{ "id": "model-1", "displayName": "Sales" }' }
        }

        $result = Invoke-PbiFabricApi -Method Post -Path 'workspaces/ws/semanticModels' -Body @{ displayName = 'Sales' }

        $result.id | Should -Be 'model-1'
        Should -Invoke -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -Times 2 -Exactly -ParameterFilter { $Method -eq 'Get' -and $Uri.AbsoluteUri -like '*/operations/op-1' }
        Should -Invoke -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -Times 1 -Exactly -ParameterFilter { $Method -eq 'Get' -and $Uri.AbsoluteUri -like '*/operations/op-1/result' }
        Should -Invoke -CommandName Start-Sleep -ModuleName PbiSuperpower -Times 1 -Exactly -ParameterFilter { $Seconds -eq 2 }
    }

    It 'returns the 202 response without polling when -NoLongRunning is used' {
        Mock -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -MockWith {
            [pscustomobject]@{ StatusCode = 202; Headers = @{ 'Location' = @('https://api.powerbi.com/v1.0/myorg/groups/ws/datasets/ds/refreshes/r-1') }; Content = '' }
        }
        $response = Invoke-PbiFabricApi -Method Post -Path 'groups/ws/datasets/ds/refreshes' -Resource PowerBI -NoLongRunning -PassThruResponse -Body @{ type = 'full' }
        $response.StatusCode | Should -Be 202
        @($response.Headers['Location'])[0] | Should -BeLike '*/refreshes/r-1'
        $response.Body | Should -BeNullOrEmpty
        Should -Invoke -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -Times 1 -Exactly
    }

    It 'throws with the error code and message when the operation fails' {
        Mock -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -ParameterFilter { $Method -eq 'Post' } -MockWith {
            [pscustomobject]@{ StatusCode = 202; Headers = @{ 'x-ms-operation-id' = @('op-2') }; Content = '' }
        }
        Mock -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -ParameterFilter { $Method -eq 'Get' } -MockWith {
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '{ "status": "Failed", "error": { "errorCode": "InvalidDefinition", "message": "TMDL could not be parsed." } }' }
        }
        { Invoke-PbiFabricApi -Method Post -Path 'workspaces/ws/semanticModels' -Body @{ displayName = 'Sales' } } | Should -Throw -ExpectedMessage '*InvalidDefinition*TMDL could not be parsed*'
    }

    It 'throws on HTTP errors with method, masked path, status and service error but never the token' {
        Mock -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -MockWith {
            [pscustomobject]@{ StatusCode = 404; Headers = @{}; Content = '{ "requestId": "r", "errorCode": "ItemNotFound", "message": "The requested item was not found." }' }
        }
        $message = $null
        try {
            Invoke-PbiFabricApi -Method Get -Path 'workspaces/11111111-2222-3333-4444-555555555555/items'
        } catch {
            $message = $_.Exception.Message
        }
        $message | Should -BeLike 'GET workspaces/<id>/items failed with HTTP 404: ItemNotFound - The requested item was not found.*'
        $message | Should -Not -BeLike '*11111111-2222*'
        $message | Should -Not -BeLike '*fake-token*'
    }

    It 'gives up after MaxRetries throttled attempts' {
        Mock -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -MockWith {
            [pscustomobject]@{ StatusCode = 429; Headers = @{}; Content = '{ "errorCode": "TooManyRequests", "message": "Slow down." }' }
        }
        { Invoke-PbiFabricApi -Method Get -Path 'workspaces' -MaxRetries 2 } | Should -Throw -ExpectedMessage '*HTTP 429*TooManyRequests*'
        Should -Invoke -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -Times 3 -Exactly
    }
}

Describe 'Invoke-PbiFabricApiPaged' {
    BeforeEach {
        Mock -CommandName Get-PbiAccessToken -ModuleName PbiSuperpower -MockWith { 'fake-token' }
        Mock -CommandName Start-Sleep -ModuleName PbiSuperpower -MockWith { }
    }

    It 'follows continuationToken (URL-encoded) and accumulates all items' {
        Mock -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -ParameterFilter { $Uri.OriginalString -notlike '*continuationToken=*' } -MockWith {
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '{ "value": [ { "id": "1" }, { "id": "2" } ], "continuationToken": "abc+def=" }' }
        }
        Mock -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -ParameterFilter { $Uri.OriginalString -like '*continuationToken=*' } -MockWith {
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '{ "value": [ { "id": "3" } ] }' }
        }

        $items = @(Invoke-PbiFabricApiPaged -Path 'workspaces/ws/items?type=Report')

        $items.Count | Should -Be 3
        ($items | ForEach-Object { $_.id }) -join ',' | Should -Be '1,2,3'
        Should -Invoke -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -Times 1 -Exactly -ParameterFilter {
            $Uri.OriginalString -eq 'https://api.fabric.microsoft.com/v1/workspaces/ws/items?type=Report&continuationToken=abc%2Bdef%3D'
        }
    }

    It 'follows an absolute continuationUri' {
        Mock -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -ParameterFilter { $Uri.OriginalString -notlike '*page=2*' } -MockWith {
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '{ "value": [ { "id": "a" } ], "continuationUri": "https://api.fabric.microsoft.com/v1/workspaces?page=2" }' }
        }
        Mock -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -ParameterFilter { $Uri.OriginalString -like '*page=2*' } -MockWith {
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '{ "value": [ { "id": "b" } ], "continuationUri": null }' }
        }
        $items = @(Invoke-PbiFabricApiPaged -Path 'workspaces')
        ($items | ForEach-Object { $_.id }) -join ',' | Should -Be 'a,b'
    }

    It 'returns an empty array for an empty list' {
        Mock -CommandName Invoke-WebRequest -ModuleName PbiSuperpower -MockWith {
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '{ "value": [] }' }
        }
        @(Invoke-PbiFabricApiPaged -Path 'capacities').Count | Should -Be 0
    }
}
