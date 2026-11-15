# Shared helpers of the ftx-workflow scripts (Windows PowerShell 5.1 compatible).
$ErrorActionPreference = 'Stop'
$Root      = Split-Path -Parent $PSScriptRoot          # ftx-workflow
$Parent    = Split-Path -Parent $Root                  # folder with every ftx-* clone
$InfraDir  = Join-Path $Parent 'ftx-infra-postgres'
$InfraEnv  = Join-Path $InfraDir 'env\dev.env'
$LocalEnv  = Join-Path $Root 'env\dev.env'
$Gateway   = 'http://localhost:8080'

function Step($text) { Write-Host ''; Write-Host "==> $text" -ForegroundColor Cyan }
function Ok($text)   { Write-Host "    OK  $text" -ForegroundColor Green }
function Warn($text) { Write-Host "    !!  $text" -ForegroundColor Yellow }

function Read-EnvFile($path) {
    $values = @{}
    foreach ($line in Get-Content $path) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') { $values[$Matches[1]] = $Matches[2] }
    }
    return $values
}

function Compose-Platform([string[]]$arguments) {
    & docker compose --project-directory $Root -f (Join-Path $Root 'compose.yml') `
        --env-file $InfraEnv --env-file $LocalEnv @arguments
    if ($LASTEXITCODE -ne 0) { throw "docker compose $($arguments -join ' ') failed" }
}

function Invoke-Api($method, $path, $body = $null, $headers = @{}) {
    $params = @{ Method = $method; Uri = "$Gateway$path"; Headers = $headers; UseBasicParsing = $true }
    if ($body -ne $null) { $params.Body = ($body | ConvertTo-Json -Compress); $params.ContentType = 'application/json' }
    try {
        $r = Invoke-WebRequest @params
        $content = $null; if ($r.Content) { $content = $r.Content | ConvertFrom-Json }
        return @{ Status = [int]$r.StatusCode; Body = $content; Headers = $r.Headers }
    } catch {
        # Windows PowerShell 5.1 throws WebException, PowerShell 7 HttpResponseException: both carry Response.
        $resp = $_.Exception.Response
        if ($resp -eq $null) { return @{ Status = 0; Body = $null; Headers = @{} } }
        $text = $_.ErrorDetails.Message
        if (-not $text -and ($resp -is [System.Net.WebResponse])) {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream()); $text = $reader.ReadToEnd()
        }
        $parsed = $null
        try { $parsed = $text | ConvertFrom-Json } catch { }
        return @{ Status = [int]$resp.StatusCode; Body = $parsed; Headers = @{} }
    }
}

function Psql($sql) {
    $infra = Read-EnvFile $InfraEnv
    $network = $infra['PLATFORM_NETWORK']; if (-not $network) { $network = 'platform' }
    $url = "postgresql://$($infra['PG_ADMIN_USER']):$($infra['PG_ADMIN_PASSWORD'])@postgres:5432/$($infra['PG_DATABASE'])"
    $out = & docker run --rm --network $network postgres:16-alpine psql $url -tA -v ON_ERROR_STOP=1 -c $sql
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $sql" }
    return $out
}
