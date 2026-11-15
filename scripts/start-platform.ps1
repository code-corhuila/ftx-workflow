# Starts the whole Futbolix platform in order, from the clones that sit next to ftx-workflow:
# database -> migrations -> broker and services -> gateway. Safe to run again.
. "$PSScriptRoot\common.ps1"

Step '1/6 Checking the repositories next to ftx-workflow'
$repos = 'ftx-infra-postgres','ftx-customers-db','ftx-courts-db','ftx-schedules-db','ftx-reservations-db',
         'ftx-customers-api','ftx-courts-api','ftx-schedules-api','ftx-reservations-api','ftx-api-gateway'
$missing = $repos | Where-Object { -not (Test-Path (Join-Path $Parent $_)) }
if ($missing) { throw "Clone these next to ftx-workflow first: $($missing -join ', ')" }
if (-not (Test-Path $InfraEnv)) { throw "Missing $InfraEnv (env file of ftx-infra-postgres, see its README)" }
Ok 'all repositories found'

Step '2/6 Local secrets of ftx-workflow (env/dev.env, never versioned)'
if (-not (Test-Path $LocalEnv)) {
    $bytes = New-Object byte[] 18; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $password = [Convert]::ToBase64String($bytes) -replace '[+/=]', 'x'
    Set-Content -Path $LocalEnv -Value @("RABBITMQ_USER=futbolix", "RABBITMQ_PASSWORD=$password") -Encoding ASCII
    Ok 'env/dev.env created with a random broker password'
} else { Ok 'env/dev.env already exists' }
$infra = Read-EnvFile $InfraEnv
$network = $infra['PLATFORM_NETWORK']; if (-not $network) { $network = 'platform' }

Step "3/6 Network '$network' and the single PostgreSQL instance (ftx-infra-postgres)"
& docker network inspect $network *> $null
if ($LASTEXITCODE -ne 0) { & docker network create $network | Out-Null }
Push-Location $InfraDir
try {
    & docker compose --env-file env/dev.env up -d --wait postgres
    if ($LASTEXITCODE -ne 0) { throw 'ftx-infra-postgres did not start' }
} finally { Pop-Location }
Ok 'postgres is up'

Step '4/6 Login user of the reservations domain'
if (-not $infra['RESERVATIONS_APP_PASSWORD']) {
    throw 'Add RESERVATIONS_APP_PASSWORD=<random> to ftx-infra-postgres/env/dev.env (see ftx-reservations-db README)'
}
$exists = Psql "SELECT 1 FROM pg_roles WHERE rolname = 'reservations_app'"
if ($exists -ne '1') {
    # Normally created by ftx-infra-postgres/postgres/init; created here only if that is still missing.
    Psql "CREATE ROLE reservations_app LOGIN PASSWORD '$($infra['RESERVATIONS_APP_PASSWORD'])'" | Out-Null
    Warn 'reservations_app created by this script: add it to the init script of ftx-infra-postgres'
} else { Ok 'reservations_app exists' }

Step '5/6 Migrations of every domain (Flyway, one schema each)'
foreach ($db in 'customers','courts','schedules','reservations') {
    $file = Join-Path $Parent "ftx-$db-db\deploy\compose.yml"
    & docker compose -f $file --env-file $InfraEnv run --rm "$db-db-migrate"
    if ($LASTEXITCODE -ne 0) { throw "migrations of ftx-$db-db failed" }
    Ok "ftx-$db-db migrated"
}

Step '6/6 Broker, services and gateway (build + wait until healthy)'
Compose-Platform @('up', '-d', '--build', '--wait')
$health = Invoke-Api 'GET' '/health'
Ok "gateway /health: $($health.Body.status)"
$health.Body.upstreams.PSObject.Properties | ForEach-Object { Write-Host "       $($_.Name): $($_.Value)" }
Write-Host ''
Write-Host 'Futbolix is running:  API http://localhost:8080   RabbitMQ UI http://localhost:15672' -ForegroundColor Green
