<#
  globaltun-windows.ps1 -- Windows client.

  Closer to the Linux hosts than to Android: sing-box has a native Windows build
  that owns a Wintun device and the routing table, and Administrator is actually
  obtainable. So one process does what `sing-box` + `ip route` do on Linux, and
  this script supplies the carrier and the UDP mux around it.

      sing-box (Wintun tun, auto_route)
           |  socks5 127.0.0.1:GT_LOCAL_PORT
           v
      gtlocal.py ................. UDP-ASSOCIATE over loopback
           |  one TCP stream
           v
      ssh -L  ->  rsocks.py on the gateway

  Two things differ from the Linux scripts and both matter:

    * Windows OpenSSH has NO ControlMaster -- there is no control socket to
      check or close. The carrier is a plain `ssh -N -L` process tracked by
      PID, and tearing the remote relay down needs its own connection.

    * The carrier must be kept off the tun by a real routing-table entry.
      sing-box's own `direct` outbound protects only traffic it sees; ssh.exe
      is a separate process whose packets would be captured by auto_route. The
      /32 goes in ActiveStore so a reboot clears it.

  ICMP is not carried: gticmp.py needs a second tun and `ip rule`, neither of
  which exists here. sing-box answers pings itself.

  Usage (elevated):  .\globaltun-windows.ps1 up | down | status
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Position = 0)][ValidateSet('up', 'down', 'status')][string]$Action = 'status')

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Same globaltun.env as every other platform, so one format is learned once.
$EnvFile = Join-Path $Here 'globaltun.env'
if (-not (Test-Path $EnvFile)) {
  Write-Error "no globaltun.env beside this script -- start from the template:`n  copy globaltun.env.example globaltun.env"
}
$cfg = @{}
foreach ($line in Get-Content $EnvFile) {
  if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"?([^"#]*?)"?\s*(?:#.*)?$') {
    $cfg[$Matches[1]] = $Matches[2].Trim()
  }
}
function Need($k) { if (-not $cfg[$k]) { Write-Error "$k is not set in $EnvFile" }; $cfg[$k] }

$RHost     = Need 'GT_RHOST'
$Key       = Need 'GT_KEY'
$RelayPort = Need 'GT_REMOTE_SOCKS_PORT'
$RPort     = if ($cfg['GT_RPORT'])      { $cfg['GT_RPORT'] }      else { '8022' }
$Jump      = $cfg['GT_JUMP']
$LPort     = if ($cfg['GT_LPORT'])      { $cfg['GT_LPORT'] }      else { '11080' }
$LocalPort = if ($cfg['GT_LOCAL_PORT']) { $cfg['GT_LOCAL_PORT'] } else { '1081' }
$SingBox   = if ($cfg['GT_SINGBOX'])    { $cfg['GT_SINGBOX'] }    else { Join-Path $Here 'sing-box.exe' }
$Python    = if ($cfg['GT_PYTHON'])     { $cfg['GT_PYTHON'] }     else { 'python' }
$SbConf    = Join-Path $Here 'sing-box-windows.json'
$GtLocal   = if (Test-Path (Join-Path $Here 'gtlocal.py')) { Join-Path $Here 'gtlocal.py' } else { Join-Path $Here '..\gtlocal.py' }
$RSocks    = if (Test-Path (Join-Path $Here 'rsocks.py'))  { Join-Path $Here 'rsocks.py' }  else { Join-Path $Here '..\rsocks.py' }

$State   = Join-Path $env:ProgramData 'globaltun'
$SshPid  = Join-Path $State 'ssh.pid'
$GlPid   = Join-Path $State 'gtlocal.pid'
$SbPid   = Join-Path $State 'sing-box.pid'
$GlLog   = Join-Path $State 'gtlocal.log'
$SbLog   = Join-Path $State 'sing-box.log'
New-Item -ItemType Directory -Force -Path $State | Out-Null

# The host whose route must not be swallowed by the tun: the jump when there is
# one, otherwise the gateway itself.
$CarrierHost = if ($Jump) { ($Jump -split '@')[-1] } else { ($RHost -split '@')[-1] }

function Resolve-Carrier {
  try { ([System.Net.Dns]::GetHostAddresses($CarrierHost) |
         Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).IPAddressToString }
  catch { Write-Error "cannot resolve carrier $CarrierHost" }
}

function Test-Port([int]$Port) {
  $c = New-Object Net.Sockets.TcpClient
  try { $c.Connect('127.0.0.1', $Port); $true } catch { $false } finally { $c.Dispose() }
}

function Get-Pid($file) {
  if (-not (Test-Path $file)) { return $null }
  $id = (Get-Content $file -Raw).Trim()
  if ($id -and (Get-Process -Id $id -ErrorAction SilentlyContinue)) { [int]$id } else { $null }
}

function Stop-Tracked($file, $label) {
  $id = Get-Pid $file
  if ($id) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue; Write-Host "  stopped $label ($id)" }
  Remove-Item $file -ErrorAction SilentlyContinue
}

function Get-SshArgs {
  $a = @('-i', $Key, '-p', $RPort,
         '-o', 'StrictHostKeyChecking=accept-new',
         '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=10',
         '-o', 'ExitOnForwardFailure=yes')
  if ($Jump) {
    # The key must be handed to the jump hop explicitly: ssh(1) applies
    # command-line options to the destination only, so plain -J falls back to
    # password auth on every connection.
    $a += @('-o', "ProxyCommand=ssh -i `"$Key`" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=120 -W %h:%p $Jump")
  }
  $a
}

function Pin-Carrier {
  $ip = Resolve-Carrier
  $route = Find-NetRoute -RemoteIPAddress $ip -ErrorAction Stop |
           Where-Object { $_.PSObject.Properties.Name -contains 'NextHop' } | Select-Object -First 1
  if (-not $route) { Write-Error "no route to carrier $ip" }
  Remove-NetRoute -DestinationPrefix "$ip/32" -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
  # ActiveStore: this is a temporary tunnel, so the pin must not survive a reboot.
  New-NetRoute -DestinationPrefix "$ip/32" -InterfaceIndex $route.InterfaceIndex `
               -NextHop $route.NextHop -RouteMetric 1 -PolicyStore ActiveStore | Out-Null
  Write-Host "  carrier $ip pinned via $($route.NextHop) ifIndex $($route.InterfaceIndex)"
  $ip
}

function Up {
  Write-Host '== pinning the carrier (before anything creates the tun)'
  $carrierIp = Pin-Carrier

  Write-Host '== carrier'
  if (Get-Pid $SshPid) {
    Write-Host '  already running'
  } else {
    if (Test-Port ([int]$LPort)) { Write-Error "port $LPort already in use -- run 'down' first" }
    $a = (Get-SshArgs) + @('-N', '-L', "127.0.0.1:${LPort}:127.0.0.1:${RelayPort}", $RHost)
    $p = Start-Process ssh -ArgumentList $a -PassThru -WindowStyle Hidden
    $p.Id | Set-Content $SshPid
    # proot logins on the gateway are slow and vary wildly; give it room.
    for ($i = 0; $i -lt 60 -and -not (Test-Port ([int]$LPort)); $i++) { Start-Sleep 2 }
    if (-not (Test-Port ([int]$LPort))) {
      Stop-Tracked $SshPid 'ssh'
      Write-Error "carrier did not come up -- forward on $LPort never bound"
    }
    Write-Host "  up (-L 127.0.0.1:$LPort -> gateway 127.0.0.1:$RelayPort)"
  }

  Write-Host '== remote relay'
  # No ControlMaster on Windows, so this is its own connection.
  $remote = @"
P=/tmp/globaltun-server-$RelayPort.pid
[ -f `$P ] && kill `$(cat `$P) 2>/dev/null; rm -f `$P
: > /tmp/globaltun-server-$RelayPort.log
RSOCKS_PORT=$RelayPort setsid python3 -u /tmp/rsocks-$RelayPort.py >/tmp/globaltun-server-$RelayPort.log 2>&1 </dev/null &
echo `$! > `$P
sleep 2
(exec 3<>/dev/tcp/127.0.0.1/$RelayPort) 2>/dev/null && echo "  relay up: `$(head -1 /tmp/globaltun-server-$RelayPort.log)" || { echo '  relay FAILED'; cat /tmp/globaltun-server-$RelayPort.log; exit 1; }
"@
  Get-Content $RSocks -Raw | & ssh @(Get-SshArgs) $RHost "cat > /tmp/rsocks-$RelayPort.py"
  & ssh @(Get-SshArgs) $RHost $remote
  if ($LASTEXITCODE -ne 0) { Write-Error 'remote relay failed to start' }

  Write-Host '== gtlocal'
  Stop-Tracked $GlPid 'gtlocal'
  $env:GT_LOCAL_PORT = $LocalPort; $env:GT_REMOTE_PORT = $LPort
  $p = Start-Process $Python -ArgumentList @('-u', $GtLocal) -PassThru -WindowStyle Hidden `
         -RedirectStandardOutput $GlLog -RedirectStandardError "$GlLog.err"
  $p.Id | Set-Content $GlPid
  Start-Sleep 2
  if (-not (Test-Port ([int]$LocalPort))) {
    Get-Content $GlLog, "$GlLog.err" -ErrorAction SilentlyContinue | Write-Host
    Write-Error "gtlocal did not bind $LocalPort"
  }
  Write-Host "  up on 127.0.0.1:$LocalPort"

  Write-Host '== sing-box (Wintun tun + routing)'
  if (-not (Test-Path $SingBox)) {
    Write-Error "sing-box not found at $SingBox -- set GT_SINGBOX, and keep wintun.dll beside the exe"
  }
  Stop-Tracked $SbPid 'sing-box'
  $p = Start-Process $SingBox -ArgumentList @('run', '-c', $SbConf) -PassThru -WindowStyle Hidden `
         -RedirectStandardOutput $SbLog -RedirectStandardError "$SbLog.err"
  $p.Id | Set-Content $SbPid
  Start-Sleep 3
  if (-not (Get-Pid $SbPid)) {
    Get-Content $SbLog, "$SbLog.err" -ErrorAction SilentlyContinue | Write-Host
    Write-Error 'sing-box exited -- wintun.dll missing, or not elevated'
  }
  Write-Host '  up'
  Write-Host "`nup. Verify with: .\globaltun-windows.ps1 status"
}

function Down {
  Stop-Tracked $SbPid 'sing-box'
  Stop-Tracked $GlPid 'gtlocal'
  try {
    & ssh @(Get-SshArgs) $RHost "P=/tmp/globaltun-server-$RelayPort.pid; [ -f `$P ] && kill `$(cat `$P) 2>/dev/null; rm -f `$P; true"
  } catch { Write-Host '  (could not stop the remote relay; it will idle)' }
  Stop-Tracked $SshPid 'ssh'
  $ip = try { Resolve-Carrier } catch { $null }
  if ($ip) {
    Remove-NetRoute -DestinationPrefix "$ip/32" -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "  carrier pin $ip/32 removed"
  }
  Write-Host 'down'
}

function Status {
  Write-Host "--- carrier    : $(if (Get-Pid $SshPid) { 'running' } else { 'not running' })"
  Write-Host "--- forward    : $(if (Test-Port ([int]$LPort)) { ":$LPort open" } else { "no :$LPort listener" })"
  Write-Host "--- gtlocal    : $(if (Test-Port ([int]$LocalPort)) { ":$LocalPort open" } else { 'not listening' })"
  Write-Host "--- sing-box   : $(if (Get-Pid $SbPid) { 'running' } else { 'not running' })"
  $ip = try { Resolve-Carrier } catch { $null }
  if ($ip) {
    $r = Get-NetRoute -DestinationPrefix "$ip/32" -PolicyStore ActiveStore -ErrorAction SilentlyContinue
    Write-Host "--- carrier pin: $(if ($r) { "$ip/32 via $($r.NextHop)" } else { "MISSING -- the carrier may be riding the tunnel" })"
  }
  Write-Host '--- egress'
  try {
    (Invoke-WebRequest -Uri 'https://1.1.1.1/cdn-cgi/trace' -UseBasicParsing -TimeoutSec 20).Content `
      -split "`n" | Where-Object { $_ -match '^(ip|loc)=' } | ForEach-Object { "    $_" }
  } catch { Write-Host '    unreachable' }
}

switch ($Action) { 'up' { Up } 'down' { Down } 'status' { Status } }
