# Release demo of Futbolix v3.0.0: the reservation flow end to end, with INJECTED FAILURES.
# Every check prints PASS or FAIL, and the whole run is saved to demo-output-<date>.txt as evidence.
#
#   A. Happy path through the gateway: availability -> reservation (PENDING) -> same Idempotency-Key
#      -> look-up by code -> ReservationCreated published to futbolix.events.
#   B. Failure 1, the broker dies: reservations are still created; the event waits in the outbox
#      and is published when RabbitMQ comes back (ADR-006). Nothing is lost.
#   C. Failure 2, ftx-schedules-api dies: availability fails fast with 503, but look-up and
#      cancellation by code keep working. The gateway reports "degraded".
#   D. Double booking: 5 simultaneous requests for one slot -> exactly one 201, the rest 409.
#   E. Security at the edge: no token / spoofed X-User-Role -> 401; a client-sent amount -> 400.
. "$PSScriptRoot\common.ps1"

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$transcript = Join-Path $Root "demo-output-$stamp.txt"
Start-Transcript -Path $transcript | Out-Null
$script:passed = 0; $script:failed = 0
function Check($ok, $text) {
    if ($ok) { $script:passed++; Write-Host "    PASS  $text" -ForegroundColor Green }
    else     { $script:failed++; Write-Host "    FAIL  $text" -ForegroundColor Red }
}

$court = 'c0000000-0000-4000-8000-000000000001'
$date  = (Get-Date).AddDays(1).ToString('yyyy-MM-dd')
$local = Read-EnvFile $LocalEnv
$rabbitAuth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($local['RABBITMQ_USER']):$($local['RABBITMQ_PASSWORD'])"))

function Rabbit($method, $path, $body = $null) {
    $p = @{ Method = $method; Uri = "http://localhost:15672/api$path"; Headers = @{ Authorization = $rabbitAuth }; UseBasicParsing = $true }
    if ($body -ne $null) { $p.Body = ($body | ConvertTo-Json -Compress); $p.ContentType = 'application/json' }
    $r = Invoke-WebRequest @p
    if ($r.Content) { return $r.Content | ConvertFrom-Json }
}
function Pending-Events { return [int](Psql 'SELECT count(*) FROM reservations.outbox_event WHERE published_at IS NULL') }
function Demo-Queue-Count {
    # Informative only: the management statistics refresh every few seconds.
    try { Start-Sleep -Seconds 6; return [int](Rabbit 'GET' '/queues/%2F/demo.reservation-events').messages } catch { return -1 }
}
function Free-Slots {
    $a = Invoke-Api 'GET' "/api/v1/availability?courtId=$court&date=$date"
    return @($a.Body.slots | Where-Object { $_.available })
}
function New-Reservation($slot, $key = [guid]::NewGuid().ToString()) {
    return Invoke-Api 'POST' '/api/v1/reservations' @{
        courtId = $court; reservationDate = $date; startTime = $slot.startTime; endTime = $slot.endTime
        customerName = 'Demo Customer'; customerEmail = 'demo@example.test'; customerPhone = '3000000000'
    } @{ 'Idempotency-Key' = $key }
}

# A queue only for the demo, bound to the reservation events, so the audience can SEE them arrive.
try {
    Rabbit 'PUT' '/queues/%2F/demo.reservation-events' @{ durable = $false; auto_delete = $false } | Out-Null
    Rabbit 'POST' '/bindings/%2F/e/futbolix.events/q/demo.reservation-events' @{ routing_key = 'reservation.*' } | Out-Null
} catch { Warn 'could not create the demo queue in RabbitMQ; the outbox checks still prove the publication' }

# ── A ────────────────────────────────────────────────────────────────────────────────────────────
Step "A. Happy path through the gateway (court 1, $date)"
$slots = Free-Slots
Check ($slots.Count -ge 3) "availability answers with free slots ($($slots.Count))"
$before = Demo-Queue-Count
$key = [guid]::NewGuid().ToString()
$created = New-Reservation $slots[0] $key
Check ($created.Status -eq 201 -and $created.Body.status -eq 'PENDING') "reservation created: 201 PENDING, amount $($created.Body.amount.amount) COP (computed by the server)"
$again = New-Reservation $slots[0] $key
Check ($again.Body.id -eq $created.Body.id) 'same Idempotency-Key returns the same reservation, no duplicate'
$code = $created.Body.reservationCode
$lookup = Invoke-Api 'GET' "/api/v1/reservations/$code"
Check ($lookup.Status -eq 200) 'look-up by reservation code: 200'
Check ((Invoke-Api 'GET' '/api/v1/reservations/ZZZZZZZZZZ').Status -eq 404) 'unknown code: generic 404'
Start-Sleep -Seconds 3
Check ((Pending-Events) -eq 0) 'outbox empty: ReservationCreated was published'
$after = Demo-Queue-Count
if ($after -ge 0 -and $before -ge 0) { Check ($after -gt $before) "the event is in RabbitMQ (queue demo.reservation-events: $after messages)" }
else { Warn 'RabbitMQ statistics not available; open http://localhost:15672 to see the exchange futbolix.events' }

# ── B ────────────────────────────────────────────────────────────────────────────────────────────
Step 'B. INJECTED FAILURE 1: the broker (RabbitMQ) goes down'
Compose-Platform @('stop', 'rabbitmq'); Start-Sleep -Seconds 2
$during = New-Reservation $slots[1]
Check ($during.Status -eq 201) 'a reservation is still created while the broker is down'
Start-Sleep -Seconds 3
$waiting = Pending-Events
Check ($waiting -ge 1) "its event waits in the outbox ($waiting pending), it is not lost"
$health = (Invoke-WebRequest -UseBasicParsing 'http://localhost:8083/api/v1/health').Content | ConvertFrom-Json
Check ($health.dependencies.broker -ne 'ok') "reservations health reports the broker as '$($health.dependencies.broker)'"
Write-Host '    ... bringing RabbitMQ back'
Compose-Platform @('start', 'rabbitmq')
$deadline = (Get-Date).AddSeconds(60)
do { Start-Sleep -Seconds 3; $left = Pending-Events } while ($left -gt 0 -and (Get-Date) -lt $deadline)
Check ($left -eq 0) 'broker back: the outbox relay published the pending event'

# ── C ────────────────────────────────────────────────────────────────────────────────────────────
Step 'C. INJECTED FAILURE 2: ftx-schedules-api goes down'
Compose-Platform @('stop', 'ftx-schedules-api')
$watch = [Diagnostics.Stopwatch]::StartNew()
$avail = Invoke-Api 'GET' "/api/v1/availability?courtId=$court&date=$date"
$watch.Stop()
Check ($avail.Status -eq 503) "availability fails fast: 503 in $([int]$watch.ElapsedMilliseconds) ms (no guessing)"
Check ((Invoke-Api 'GET' "/api/v1/reservations/$code").Status -eq 200) 'look-up by code still works'
$cancel = Invoke-Api 'POST' "/api/v1/reservations/$code/cancellation" @{ reason = 'Demo' }
Check ($cancel.Status -eq 200 -and $cancel.Body.status -eq 'CANCELLED') 'cancellation by code still works'
$gw = Invoke-Api 'GET' '/health'
Check ($gw.Body.status -eq 'degraded') "gateway health: degraded (ftx-schedules-api: $($gw.Body.upstreams.'ftx-schedules-api'))"
Write-Host '    ... bringing ftx-schedules-api back'
Compose-Platform @('start', 'ftx-schedules-api')
Compose-Platform @('up', '-d', '--wait', 'ftx-schedules-api')
Check ((Invoke-Api 'GET' "/api/v1/availability?courtId=$court&date=$date").Status -eq 200) 'availability recovered'

# ── D ────────────────────────────────────────────────────────────────────────────────────────────
Step 'D. Double booking: 5 simultaneous requests for the same slot'
$target = (Free-Slots)[2]
$jobs = 1..5 | ForEach-Object {
    Start-Job -ArgumentList $Gateway, $court, $date, $target.startTime, $target.endTime -ScriptBlock {
        param($gw, $court, $date, $start, $end)
        $body = @{ courtId = $court; reservationDate = $date; startTime = $start; endTime = $end
                   customerName = 'Race Customer'; customerEmail = 'race@example.test'; customerPhone = '3000000000' } | ConvertTo-Json
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Method POST -Uri "$gw/api/v1/reservations" -Body $body `
                -ContentType 'application/json' -Headers @{ 'Idempotency-Key' = [guid]::NewGuid().ToString() }
            [int]$r.StatusCode
        } catch { [int]$_.Exception.Response.StatusCode }
    }
}
$codes = $jobs | Wait-Job | Receive-Job; $jobs | Remove-Job
$wins = @($codes | Where-Object { $_ -eq 201 }).Count
$conflicts = @($codes | Where-Object { $_ -eq 409 }).Count
Check ($wins -eq 1 -and $conflicts -eq 4) "exactly one 201 and four 409 RESERVATION_SLOT_UNAVAILABLE (got: $($codes -join ', '))"

# ── E ────────────────────────────────────────────────────────────────────────────────────────────
Step 'E. Security at the edge'
Check ((Invoke-Api 'GET' '/api/v1/admin/reservations').Status -eq 401) 'administrator list without a token: 401'
Check ((Invoke-Api 'GET' '/api/v1/admin/reservations' $null @{ 'X-User-Id' = 'x'; 'X-User-Role' = 'ADMINISTRATOR' }).Status -eq 401) 'spoofed X-User-Role header: 401 (the gateway strips it)'
$cheap = Invoke-Api 'POST' '/api/v1/reservations' @{
    courtId = $court; reservationDate = $date; startTime = $target.startTime; endTime = $target.endTime
    customerName = 'Cheap'; customerEmail = 'cheap@example.test'; customerPhone = '3000000000'
    amount = @{ amount = 1; currency = 'COP' } } @{ 'Idempotency-Key' = [guid]::NewGuid().ToString() }
Check ($cheap.Status -eq 400) 'a client that sends its own amount: 400 (the price is never taken from the client)'

Write-Host ''
$color = 'Green'; if ($script:failed -gt 0) { $color = 'Red' }
Write-Host "RESULT: $($script:passed) PASS, $($script:failed) FAIL" -ForegroundColor $color
try { Rabbit 'DELETE' '/queues/%2F/demo.reservation-events' | Out-Null } catch { }
Stop-Transcript | Out-Null
Write-Host "Evidence saved in $transcript"
