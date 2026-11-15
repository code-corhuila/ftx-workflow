# Stops the services and the broker. Never removes volumes: the data is the history (Annex J.5.4).
. "$PSScriptRoot\common.ps1"
Step 'Stopping broker, services and gateway'
Compose-Platform @('down')
Ok 'stopped (the database of ftx-infra-postgres keeps running; stop it from that repository)'
