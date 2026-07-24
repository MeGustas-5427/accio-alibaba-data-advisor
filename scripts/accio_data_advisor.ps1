[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('status', 'update-token', 'self-test', 'refresh-tools', 'list-tools', 'shop-summary', 'visitor-detail', 'call-tool')]
    [string]$Action,

    [string]$StartDate,
    [string]$EndDate,
    [string]$ToolSearch,
    [string]$ToolName,
    [string]$ArgumentsJson = '{}',

    [ValidateSet('day', 'week', 'month')]
    [string]$StatisticsType = 'day',

    [ValidateSet('true', 'false')]
    [string]$IsMcFb = 'true',

    [ValidateRange(1, 2147483647)]
    [int]$PageNo = 1,

    [ValidateRange(1, 100)]
    [int]$PageSize = 20,

    [switch]$AllowAccioStopped
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$SkillDir = Split-Path -Parent $PSScriptRoot
$StateDir = Join-Path $SkillDir 'state'
$CredentialFile = Join-Path $StateDir 'credentials.dpapi'
$ToolCatalogFile = Join-Path $SkillDir 'references\tools_catalog.json'
$RemoteUrl = 'https://phoenix-gw.alibaba.com/api/mcp/proxy'
$EntropyText = 'accio-alibaba-data-advisor:v1'

function Redact-Text {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $null }
    $safe = $Text
    $safe = $safe -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]+', '$1[REDACTED]'
    $safe = $safe -replace '(?i)((?:access[_-]?token|refresh[_-]?token|authorization|cookie|password|secret|credential|connectId|sessionKey)\s*[:=]\s*)("[^"]*"|''[^'']*''|[^\s,;&]+)', '$1[REDACTED]'
    return $safe
}

function Test-SensitiveKey {
    param([string]$Name)
    return $Name -match '(?i)^(authorization|cookie|set-cookie|password|secret|credential|access[_-]?token|refresh[_-]?token|token|api[_-]?key|connectId|sessionKey)$'
}

function ConvertTo-SafeValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (Redact-Text $Value) }
    if ($Value -is [ValueType] -or $Value -is [DateTime] -or $Value -is [DateTimeOffset]) { return $Value }

    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $name = [string]$key
            $copy[$name] = if (Test-SensitiveKey $name) { '[REDACTED]' } else { ConvertTo-SafeValue $Value[$key] }
        }
        return $copy
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = foreach ($item in $Value) { ConvertTo-SafeValue $item }
        return ,@($items)
    }

    $properties = @($Value.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property') })
    if ($properties.Count -gt 0) {
        $copy = [ordered]@{}
        foreach ($property in $properties) {
            $copy[$property.Name] = if (Test-SensitiveKey $property.Name) { '[REDACTED]' } else { ConvertTo-SafeValue $property.Value }
        }
        return [pscustomobject]$copy
    }

    return $Value
}

function Write-Json {
    param([Parameter(Mandatory = $true)]$Value)
    $safe = ConvertTo-SafeValue $Value
    $safe | ConvertTo-Json -Depth 100
}

function Redact-CatalogText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $null }
    $safe = $Text
    $safe = $safe -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]{16,}', '$1[REDACTED]'
    $safe = $safe -replace '\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\b', '[REDACTED]'
    $safe = $safe -replace '(?i)((?:access[_-]?token|refresh[_-]?token|authorization|cookie|password|secret|credential|connectId|sessionKey)\s*[:=]\s*["'']?)[A-Za-z0-9._~+/=-]{16,}', '$1[REDACTED]'
    return $safe
}

function ConvertTo-SafeCatalogValue {
    param(
        [AllowNull()]$Value,
        [switch]$PropertyMap,
        [switch]$SensitiveSchemaDefinition
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (Redact-CatalogText $Value) }
    if ($Value -is [ValueType] -or $Value -is [DateTime] -or $Value -is [DateTimeOffset]) { return $Value }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Collections.IDictionary]) {
        $items = foreach ($item in $Value) {
            ConvertTo-SafeCatalogValue $item -SensitiveSchemaDefinition:$SensitiveSchemaDefinition
        }
        return ,@($items)
    }

    $isDictionary = $Value -is [System.Collections.IDictionary]
    $properties = @(if ($isDictionary) {
        $Value.Keys | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_; Value = $Value[$_] }
        }
    }
    else {
        $Value.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property') }
    })
    if ($properties.Count -eq 0) { return $Value }

    $copy = [ordered]@{}
    foreach ($property in $properties) {
        $name = [string]$property.Name
        $child = $property.Value
        if ($PropertyMap) {
            $copy[$name] = ConvertTo-SafeCatalogValue $child -SensitiveSchemaDefinition:(Test-SensitiveKey $name)
        }
        elseif ($SensitiveSchemaDefinition -and $name -in @('default', 'example', 'examples', 'const', 'enum')) {
            $copy[$name] = '[REDACTED]'
        }
        elseif (Test-SensitiveKey $name) {
            $copy[$name] = '[REDACTED]'
        }
        else {
            $copy[$name] = ConvertTo-SafeCatalogValue `
                $child `
                -PropertyMap:($name -ceq 'properties') `
                -SensitiveSchemaDefinition:$SensitiveSchemaDefinition
        }
    }
    return [pscustomobject]$copy
}

function ConvertTo-IsoUtcString {
    param([Parameter(Mandatory = $true)]$Value)
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime.ToString('o') }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString('o') }
    $parsed = [DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
    return $parsed.UtcDateTime.ToString('o')
}

function Write-JsonFileAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Value | ConvertTo-Json -Depth 100
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-Entropy {
    return [Text.Encoding]::UTF8.GetBytes($EntropyText)
}

function Convert-ExpiresAt {
    param([Parameter(Mandatory = $true)][Int64]$Milliseconds)
    return [DateTimeOffset]::FromUnixTimeMilliseconds($Milliseconds)
}

function Assert-CredentialShape {
    param([Parameter(Mandatory = $true)]$Credential)
    if ([string]::IsNullOrWhiteSpace([string]$Credential.accessToken)) { throw 'Credential has no access token.' }
    if ([string]::IsNullOrWhiteSpace([string]$Credential.refreshToken)) { throw 'Credential has no refresh token.' }
    if ($null -eq $Credential.expiresAt -or [Int64]$Credential.expiresAt -le 0) { throw 'Credential has no valid expiry.' }
}

function Assert-CredentialUsable {
    param([Parameter(Mandatory = $true)]$Credential)
    Assert-CredentialShape $Credential
    $expiry = Convert-ExpiresAt ([Int64]$Credential.expiresAt)
    if ($expiry -le [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        throw "Stored token is expired or expires within 5 minutes. Open Accio and run update-token."
    }
}

function Read-SkillCredential {
    if (-not (Test-Path -LiteralPath $CredentialFile)) {
        throw "Skill credential is missing. Open Accio and run update-token."
    }

    $protected = $null
    $plain = $null
    $entropy = $null
    try {
        $protected = [IO.File]::ReadAllBytes($CredentialFile)
        $entropy = Get-Entropy
        $plain = [Security.Cryptography.ProtectedData]::Unprotect(
            $protected,
            $entropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $credential = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
        Assert-CredentialShape $credential
        return $credential
    }
    finally {
        if ($plain) { [Array]::Clear($plain, 0, $plain.Length) }
        if ($entropy) { [Array]::Clear($entropy, 0, $entropy.Length) }
        $protected = $null
        $plain = $null
        $entropy = $null
    }
}

function Read-AccioCredential {
    $base = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Accio'
    $credentialPath = Join-Path $base 'credentials.enc'
    $localStatePath = Join-Path $base 'Local State'

    if (-not (Test-Path -LiteralPath $credentialPath)) { throw "Accio credential file not found: $credentialPath" }
    if (-not (Test-Path -LiteralPath $localStatePath)) { throw "Accio Local State not found: $localStatePath" }

    $masterKey = $null
    $plain = $null
    $aes = $null
    try {
        $localState = Get-Content -Raw -LiteralPath $localStatePath | ConvertFrom-Json
        $wrappedKey = [Convert]::FromBase64String([string]$localState.os_crypt.encrypted_key)
        if ($wrappedKey.Length -le 5 -or [Text.Encoding]::ASCII.GetString($wrappedKey, 0, 5) -ne 'DPAPI') {
            throw 'Unexpected Accio Local State key format.'
        }

        $protectedKey = New-Object byte[] ($wrappedKey.Length - 5)
        [Array]::Copy($wrappedKey, 5, $protectedKey, 0, $protectedKey.Length)
        $masterKey = [Security.Cryptography.ProtectedData]::Unprotect(
            $protectedKey,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )

        $encrypted = [IO.File]::ReadAllBytes($credentialPath)
        if ($encrypted.Length -le 31 -or [Text.Encoding]::ASCII.GetString($encrypted, 0, 3) -ne 'v10') {
            throw 'Unexpected Accio credentials format.'
        }

        $nonce = New-Object byte[] 12
        [Array]::Copy($encrypted, 3, $nonce, 0, 12)
        $cipherLength = $encrypted.Length - 31
        $cipher = New-Object byte[] $cipherLength
        [Array]::Copy($encrypted, 15, $cipher, 0, $cipherLength)
        $tag = New-Object byte[] 16
        [Array]::Copy($encrypted, 15 + $cipherLength, $tag, 0, 16)
        $plain = New-Object byte[] $cipherLength

        $aes = [Security.Cryptography.AesGcm]::new($masterKey, 16)
        $aes.Decrypt($nonce, $cipher, $tag, $plain, $null)
        $credential = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
        Assert-CredentialShape $credential
        return $credential
    }
    finally {
        if ($aes) { $aes.Dispose() }
        if ($masterKey) { [Array]::Clear($masterKey, 0, $masterKey.Length) }
        if ($plain) { [Array]::Clear($plain, 0, $plain.Length) }
        $masterKey = $null
        $plain = $null
        $aes = $null
    }
}

function Save-SkillCredential {
    param([Parameter(Mandatory = $true)]$Credential)
    Assert-CredentialUsable $Credential

    [IO.Directory]::CreateDirectory($StateDir) | Out-Null
    $payload = [ordered]@{
        schemaVersion = 1
        accessToken = [string]$Credential.accessToken
        refreshToken = [string]$Credential.refreshToken
        expiresAt = [Int64]$Credential.expiresAt
        syncedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }

    $plain = $null
    $protected = $null
    $entropy = $null
    $temporary = Join-Path $StateDir ('.credentials-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $plain = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress))
        $entropy = Get-Entropy
        $protected = [Security.Cryptography.ProtectedData]::Protect(
            $plain,
            $entropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        [IO.File]::WriteAllBytes($temporary, $protected)
        [IO.File]::Move($temporary, $CredentialFile, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        if ($plain) { [Array]::Clear($plain, 0, $plain.Length) }
        if ($protected) { [Array]::Clear($protected, 0, $protected.Length) }
        if ($entropy) { [Array]::Clear($entropy, 0, $entropy.Length) }
        $plain = $null
        $protected = $null
        $entropy = $null
    }
}

function Invoke-RemoteMcp {
    param(
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)]$Request
    )

    $body = [ordered]@{ accessToken = $AccessToken; request = $Request } | ConvertTo-Json -Depth 30 -Compress
    $response = Invoke-WebRequest `
        -Uri $RemoteUrl `
        -Method Post `
        -ContentType 'application/json' `
        -Headers @{ Accept = 'application/json, text/event-stream'; 'x-language' = 'zh-CN'; 'x-source' = 'ACCIO_DESKTOP' } `
        -Body $body `
        -TimeoutSec 45

    $raw = [string]$response.Content
    $candidates = @()
    foreach ($line in ($raw -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed.StartsWith('data:')) { continue }
        $json = $trimmed.Substring(5).Trim()
        if (-not $json) { continue }
        try { $candidates += ,($json | ConvertFrom-Json -Depth 100) } catch { }
    }

    if ($candidates.Count -gt 0) {
        $parsed = $candidates | Where-Object {
            $null -ne $_.PSObject.Properties['result'] -or
            $null -ne $_.PSObject.Properties['error']
        } | Select-Object -First 1
        if ($null -eq $parsed) { $parsed = $candidates[0] }
    }
    else {
        $parsed = $raw | ConvertFrom-Json -Depth 100
    }

    if (
        $null -ne $parsed.PSObject.Properties['success'] -and
        $null -ne $parsed.PSObject.Properties['data']
    ) {
        if (-not [bool]$parsed.success) { throw "Remote MCP rejected the request: $(Redact-Text ([string]$parsed.message))" }
        $parsed = $parsed.data
    }
    if ($null -ne $parsed.PSObject.Properties['error'] -and $null -ne $parsed.error) {
        throw "Remote MCP error: $(Redact-Text (($parsed.error | ConvertTo-Json -Compress -Depth 20)))"
    }
    return $parsed
}

function New-RpcRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)]$Params
    )
    return [ordered]@{
        jsonrpc = '2.0'
        id = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        method = $Method
        params = $Params
    }
}

function Get-RemoteCatalog {
    param([Parameter(Mandatory = $true)][string]$AccessToken)
    $request = New-RpcRequest -Method 'tools/list' -Params @{}
    $response = Invoke-RemoteMcp -AccessToken $AccessToken -Request $request
    $tools = @($response.result.tools)
    if ($tools.Count -eq 0) { throw 'Remote MCP returned no tools.' }
    return $tools
}

function Save-ToolCatalog {
    param([Parameter(Mandatory = $true)]$Tools)

    $toolArray = @($Tools)
    if ($toolArray.Count -eq 0) { throw 'Cannot cache an empty tool catalog.' }

    $payload = [ordered]@{
        schemaVersion = 1
        fetchedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        remoteUrl = $RemoteUrl
        toolCount = $toolArray.Count
        tools = @($toolArray | ForEach-Object { ConvertTo-SafeCatalogValue $_ })
    }
    Write-JsonFileAtomically -Path $ToolCatalogFile -Value $payload
    return [pscustomobject]$payload
}

function Read-ToolCatalog {
    if (-not (Test-Path -LiteralPath $ToolCatalogFile)) {
        throw 'Tool catalog cache is missing. Run refresh-tools once.'
    }

    $catalog = Get-Content -Raw -LiteralPath $ToolCatalogFile -Encoding UTF8 | ConvertFrom-Json -Depth 100
    if ($null -eq $catalog.PSObject.Properties['schemaVersion'] -or [int]$catalog.schemaVersion -ne 1) {
        throw 'Tool catalog cache has an unsupported schema version.'
    }
    if ($null -eq $catalog.PSObject.Properties['fetchedAtUtc']) {
        throw 'Tool catalog cache has no fetchedAtUtc value.'
    }
    if ($null -eq $catalog.PSObject.Properties['tools']) { throw 'Tool catalog cache has no tools array.' }
    $tools = @($catalog.tools)
    if ($tools.Count -eq 0) { throw 'Tool catalog cache is empty.' }
    if (
        $null -eq $catalog.PSObject.Properties['toolCount'] -or
        [int]$catalog.toolCount -ne $tools.Count
    ) {
        throw 'Tool catalog cache count does not match its tools array.'
    }
    $catalog.fetchedAtUtc = ConvertTo-IsoUtcString $catalog.fetchedAtUtc
    return $catalog
}

function Assert-ToolCached {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'ToolName is required.' }

    $catalog = Read-ToolCatalog
    $matches = @($catalog.tools | Where-Object { [string]$_.name -ceq $Name })
    if ($matches.Count -eq 0) {
        $caseInsensitive = @($catalog.tools | Where-Object { [string]$_.name -eq $Name })
        if ($caseInsensitive.Count -eq 1) {
            throw "Tool names are case-sensitive. Use: $([string]$caseInsensitive[0].name)"
        }
        throw "Tool is not present in the cached catalog: $Name"
    }
    if ($matches.Count -gt 1) { throw "Cached catalog contains duplicate tool names: $Name" }
}

function Convert-StrictDate {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Name is required." }
    $parsed = [DateTime]::MinValue
    $ok = [DateTime]::TryParseExact(
        $Value,
        'yyyy-MM-dd',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$parsed
    )
    if (-not $ok) { throw "$Name must use YYYY-MM-DD." }
    return $parsed
}

function Get-QueryDates {
    $start = Convert-StrictDate -Value $StartDate -Name 'StartDate'
    $end = Convert-StrictDate -Value $EndDate -Name 'EndDate'
    if ($start -gt $end) { throw 'StartDate must not be after EndDate.' }
    return @($start, $end)
}

function Invoke-AccioTool {
    param(
        [Parameter(Mandatory = $true)][string]$ToolName,
        [Parameter(Mandatory = $true)]$Arguments
    )
    Assert-ToolCached -Name $ToolName

    $credential = Read-SkillCredential
    Assert-CredentialUsable $credential
    $request = New-RpcRequest -Method 'tools/call' -Params ([ordered]@{ name = $ToolName; arguments = $Arguments })
    $response = Invoke-RemoteMcp -AccessToken ([string]$credential.accessToken) -Request $request
    $result = $response.result
    if ($null -ne $result.PSObject.Properties['isError'] -and [bool]$result.isError) {
        throw "Accio tool returned an error: $(Redact-Text (($result.content | ConvertTo-Json -Compress -Depth 20)))"
    }

    $content = @($result.content)
    if ($content.Count -eq 1 -and $null -ne $content[0].PSObject.Properties['text']) {
        $text = [string]$content[0].text
        try { $payload = $text | ConvertFrom-Json -Depth 100 }
        catch { return (Redact-Text $text) }
        if ($null -ne $payload.PSObject.Properties['success'] -and -not [bool]$payload.success) {
            $reason = if ($null -ne $payload.PSObject.Properties['errorMsg']) { [string]$payload.errorMsg } else { 'unknown error' }
            throw "Accio tool rejected the request: $(Redact-Text $reason)"
        }
        return $payload
    }
    return $result
}

try {
    switch ($Action) {
        'status' {
            if (-not (Test-Path -LiteralPath $CredentialFile)) {
                Write-Json ([ordered]@{
                    action = 'status'
                    credentialFile = $CredentialFile
                    exists = $false
                    ready = $false
                    nextAction = 'Open and sign in to Accio, then run update-token.'
                })
                break
            }

            $credential = Read-SkillCredential
            $expiry = Convert-ExpiresAt ([Int64]$credential.expiresAt)
            $remaining = [Math]::Floor(($expiry - [DateTimeOffset]::UtcNow).TotalMinutes)
            Write-Json ([ordered]@{
                action = 'status'
                credentialFile = $CredentialFile
                exists = $true
                decryptable = $true
                ready = $remaining -gt 5
                expiresAtUtc = $expiry.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
                remainingMinutes = $remaining
                remoteUrl = $RemoteUrl
            })
        }

        'update-token' {
            if (-not $AllowAccioStopped -and @(Get-Process -Name 'Accio' -ErrorAction SilentlyContinue).Count -eq 0) {
                throw 'Accio is not running. Open and sign in to Accio before update-token.'
            }

            $source = Read-AccioCredential
            Assert-CredentialUsable $source
            $tools = Get-RemoteCatalog -AccessToken ([string]$source.accessToken)
            Save-SkillCredential $source
            $catalog = Save-ToolCatalog $tools
            $expiry = Convert-ExpiresAt ([Int64]$source.expiresAt)
            Write-Json ([ordered]@{
                action = 'update-token'
                updated = $true
                credentialFile = $CredentialFile
                protection = 'Windows CurrentUser DPAPI'
                expiresAtUtc = $expiry.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
                toolCount = $tools.Count
                toolCatalogFile = $ToolCatalogFile
                catalogFetchedAtUtc = $catalog.fetchedAtUtc
            })
        }

        'self-test' {
            $credential = Read-SkillCredential
            Assert-CredentialUsable $credential
            $catalog = Read-ToolCatalog
            $expiry = Convert-ExpiresAt ([Int64]$credential.expiresAt)
            Write-Json ([ordered]@{
                action = 'self-test'
                ready = $true
                accioRunning = @(Get-Process -Name 'Accio' -ErrorAction SilentlyContinue).Count -gt 0
                usesLocalhost4097 = $false
                remoteUrl = $RemoteUrl
                toolCount = [int]$catalog.toolCount
                toolCatalogFile = $ToolCatalogFile
                catalogFetchedAtUtc = [string]$catalog.fetchedAtUtc
                remoteCatalogRequest = $false
                expiresAtUtc = $expiry.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
            })
        }

        'refresh-tools' {
            $credential = Read-SkillCredential
            Assert-CredentialUsable $credential
            $tools = Get-RemoteCatalog -AccessToken ([string]$credential.accessToken)
            $catalog = Save-ToolCatalog $tools
            Write-Json ([ordered]@{
                action = 'refresh-tools'
                refreshed = $true
                toolCatalogFile = $ToolCatalogFile
                fetchedAtUtc = $catalog.fetchedAtUtc
                count = $tools.Count
            })
        }

        'list-tools' {
            $catalog = Read-ToolCatalog
            $matches = @($catalog.tools)
            if (-not [string]::IsNullOrWhiteSpace($ToolSearch)) {
                $matches = @($matches | Where-Object {
                    $haystack = ([string]$_.name) + "`n" + ([string]$_.description)
                    $haystack.IndexOf($ToolSearch, [StringComparison]::OrdinalIgnoreCase) -ge 0
                })
            }
            Write-Json ([ordered]@{
                action = 'list-tools'
                source = 'cache'
                toolCatalogFile = $ToolCatalogFile
                fetchedAtUtc = [string]$catalog.fetchedAtUtc
                totalCount = [int]$catalog.toolCount
                search = $ToolSearch
                count = $matches.Count
                tools = $matches
            })
        }

        'shop-summary' {
            $dates = Get-QueryDates
            $arguments = [ordered]@{
                advisorQueryParam = [ordered]@{
                    startDate = $dates[0].ToString('yyyy-MM-dd')
                    endDate = $dates[1].ToString('yyyy-MM-dd')
                    statisticsType = $StatisticsType
                }
            }
            $data = Invoke-AccioTool -ToolName 'data_advisor_shop_summary' -Arguments $arguments
            Write-Json ([ordered]@{
                action = 'shop-summary'
                tool = 'data_advisor_shop_summary'
                request = $arguments
                data = $data
            })
        }

        'visitor-detail' {
            $dates = Get-QueryDates
            $arguments = [ordered]@{
                visitorQueryParam = [ordered]@{
                    startDate = $dates[0].ToString('yyyy-MM-dd')
                    endDate = $dates[1].ToString('yyyy-MM-dd')
                    isMcFb = [Convert]::ToBoolean($IsMcFb)
                    pageNO = $PageNo
                    pageSize = $PageSize
                }
            }
            $data = Invoke-AccioTool -ToolName 'data_advisor_visitor_detail' -Arguments $arguments
            Write-Json ([ordered]@{
                action = 'visitor-detail'
                tool = 'data_advisor_visitor_detail'
                request = $arguments
                data = $data
            })
        }

        'call-tool' {
            if ([string]::IsNullOrWhiteSpace($ToolName)) { throw 'ToolName is required.' }
            try {
                $arguments = $ArgumentsJson | ConvertFrom-Json -Depth 100 -AsHashtable
            }
            catch {
                throw "ArgumentsJson must be a valid JSON object: $($_.Exception.Message)"
            }
            if ($arguments -isnot [System.Collections.IDictionary]) {
                throw 'ArgumentsJson must decode to a JSON object.'
            }

            $data = Invoke-AccioTool -ToolName $ToolName -Arguments $arguments
            Write-Json ([ordered]@{
                action = 'call-tool'
                tool = $ToolName
                request = $arguments
                data = $data
            })
        }
    }
}
catch {
    $message = Redact-Text $_.Exception.Message
    [Console]::Error.WriteLine(([ordered]@{
        success = $false
        action = $Action
        error = $message
    } | ConvertTo-Json -Compress))
    exit 1
}
