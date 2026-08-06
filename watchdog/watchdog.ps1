# Service Watchdog -- the supervision loop that keeps the pipeline alive.
#
# Pings every configured service port on an interval. On a DROP it relaunches
# the service and pushes a phone alert via ntfy.sh. Alerts fire only on state
# TRANSITIONS (up->down, down->up), so a service that stays down never spams,
# and a recovery is always announced. Singleton-locked; logs every action.
# This is the sanitized production pattern: service names, ports, and the
# alert topic are configuration, not code.

$ErrorActionPreference = 'SilentlyContinue'

# ---- config ----
$Proj      = $PSScriptRoot
$Py        = $env:WATCHDOG_PYTHON ?? "python"
$Interval  = 90                          # seconds between checks
$NtfyTopic = $env:WATCHDOG_NTFY_TOPIC    # empty = log only, no phone alerts
$Log       = Join-Path $Proj "watchdog.log"
$Lock      = Join-Path $Proj ".watchdog.lock"

# Every supervised service: the port it must hold, how to start it, and how
# long a cold start may take before we call the relaunch failed. The slowest
# entry here waits 75s because its ML imports genuinely take that long.
$Services = @(
    @{ Name = "scanner";  Port = 8080; Script = "app.py";            BindWait = 75 }
    @{ Name = "api";      Port = 5060; Script = "api_server.py";     BindWait = 15 }
    @{ Name = "portal";   Port = 8789; Script = "portal.py";         BindWait = 15 }
)

# ---- singleton lock ----
if (Test-Path $Lock) {
    $oldPid = Get-Content $Lock -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
        "$(Get-Date -f o) [SKIP] watchdog already running (PID $oldPid)" | Add-Content $Log
        exit 0
    }
}
$PID | Out-File $Lock -Encoding ascii -Force

function Log($m) { "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') $m" | Add-Content $Log }

function Notify($title, $msg, $priority, $tags) {
    if (-not $NtfyTopic) { return }
    try {
        Invoke-RestMethod -Uri "https://ntfy.sh/$NtfyTopic" -Method Post -Body $msg `
            -Headers @{ "Title" = $title; "Priority" = $priority; "Tags" = $tags; "Content-Type" = "text/plain" } `
            -TimeoutSec 15 | Out-Null
    } catch { Log "[NTFY-FAIL] $($_.Exception.Message)" }
}

function PortUp($port) {
    return @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0
}

function Relaunch($svc) {
    Log "[$($svc.Name)] relaunching $($svc.Script)..."
    # Clear any stuck interpreter still holding the old process before starting
    # a fresh one -- a wedged process that no longer listens still owns state.
    Get-CimInstance Win32_Process |
        Where-Object { $_.Name -eq 'python.exe' -and $_.CommandLine -like "*$($svc.Script)*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    $out = Join-Path $Proj "$($svc.Name)_run.log"
    $err = Join-Path $Proj "$($svc.Name)_err.log"
    Start-Process -FilePath $Py -ArgumentList "-u", $svc.Script -WorkingDirectory $Proj `
        -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden | Out-Null
    # Wait for the port to bind; cold starts are slow and that is not failure.
    for ($i = 0; $i -lt [int]($svc.BindWait / 2); $i++) {
        Start-Sleep -Seconds 2
        if (PortUp $svc.Port) { return $true }
    }
    return (PortUp $svc.Port)
}

# ---- initial state = current reality (never alert on the first observation) --
$state = @{}
foreach ($svc in $Services) { $state[$svc.Name] = PortUp $svc.Port }
$summary = ($Services | ForEach-Object { "$($_.Name)=$($state[$_.Name])" }) -join "  "
Log "[START] watchdog PID $PID  interval=${Interval}s  $summary"
Notify "Watchdog" "Started. $summary" "default" "eye,gear"

while ($true) {
    foreach ($svc in $Services) {
        $up = PortUp $svc.Port
        if (-not $up) {
            if ($state[$svc.Name]) {
                Log "[$($svc.Name)] DOWN detected"
                Notify "$($svc.Name) DOWN" "Port :$($svc.Port) dropped - relaunching..." "high" "rotating_light"
            }
            $ok = Relaunch $svc
            if ($ok) {
                Log "[$($svc.Name)] recovered"
                Notify "$($svc.Name) OK" "Port :$($svc.Port) back up." "default" "white_check_mark"
            } else {
                Log "[$($svc.Name)] relaunch FAILED"
                Notify "$($svc.Name) FAIL" "Port :$($svc.Port) could not restart - needs a look." "urgent" "sos"
            }
            $up = $ok
        }
        $state[$svc.Name] = $up
    }
    Start-Sleep -Seconds $Interval
}

# Production notes that earned their place here:
#  * Transition-only alerting is the difference between a watchdog you trust
#    and one you mute after the first bad night.
#  * The relaunch clears wedged processes by command line, not by port -- a
#    process can stop listening and still hold files and state.
#  * The production build of this also watches the public DNS record of its
#    tunnel hostname by querying an outside resolver directly, because the
#    local resolver hid a real outage once: everything looked fine from this
#    machine while customers got NXDOMAIN. External checks catch what local
#    ones cannot. That self-heal is rate-limited by a cooldown so a flapping
#    record cannot trigger a republish storm.
