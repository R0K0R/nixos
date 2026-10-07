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
# Hops between this PC and the gateway, nearest first; space- or
# comma-separated, each [user@]host[:port]. Empty means dial the gateway
# directly. GT_JUMP (singular) is still read for older globaltun.env files.
$JumpsRaw  = if ($cfg['GT_JUMPS']) { $cfg['GT_JUMPS'] } else { $cfg['GT_JUMP'] }
$Jumps     = @($JumpsRaw -split '[,\s]+' | Where-Object { $_ -and $_ -ne '-' })
$LPort     = if ($cfg['GT_LPORT'])      { $cfg['GT_LPORT'] }      else { '11080' }
$LocalPort = if ($cfg['GT_LOCAL_PORT']) { $cfg['GT_LOCAL_PORT'] } else { '1081' }
$SingBox   = if ($cfg['GT_SINGBOX'])    { $cfg['GT_SINGBOX'] }    else { Join-Path $Here 'sing-box.exe' }
$Python    = if ($cfg['GT_PYTHON'])     { $cfg['GT_PYTHON'] }     else { 'python' }
$SbConf    = Join-Path $Here 'sing-box-windows.json'
$GtLocal   = if (Test-Path (Join-Path $Here 'gtlocal.py')) { Join-Path $Here 'gtlocal.py' } else { Join-Path $Here '..\gtlocal.py' }
$RSocks    = if (Test-Path (Join-Path $Here 'rsocks.py'))  { Join-Path $Here 'rsocks.py' }  else { Join-Path $Here '..\rsocks.py' }
# Static relay binaries for the gateway, if this bundle carries them. Optional:
# without them the gateway needs its own python3, which is the prerequisite
# they exist to remove.
$RelayDir  = @($Here, (Join-Path $Here '..')) |
             Where-Object { (Test-Path (Join-Path $_ 'gtrelay-linux-amd64')) -or
                            (Test-Path (Join-Path $_ 'gtrelay-linux-arm64')) } |
             Select-Object -First 1

$State   = Join-Path $env:ProgramData 'globaltun'
$SshCfg  = Join-Path $State 'ssh_config'
$SshPid  = Join-Path $State 'ssh.pid'
$GlPid   = Join-Path $State 'gtlocal.pid'
$SbPid   = Join-Path $State 'sing-box.pid'
$GlLog   = Join-Path $State 'gtlocal.log'
$SbLog   = Join-Path $State 'sing-box.log'
New-Item -ItemType Directory -Force -Path $State | Out-Null

# The host whose route must not be swallowed by the tun: the host this PC
# actually opens a socket to, which is the FIRST jump when there is one and the
# gateway itself when there is not. Strips both user@ and :port.
$CarrierSpec = if ($Jumps.Count) { $Jumps[0] } else { $RHost }
$CarrierHost = (($CarrierSpec -split '@')[-1] -split ':')[0]

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
  if ($Jumps.Count) { $a += @('-F', $SshCfg, '-o', "ProxyJump=gt-hop-$($Jumps.Count)") }
  $a
}

# One Host block per hop, chained with ProxyJump, written once per run.
#
# The key has to be handed to every hop explicitly: ssh(1) applies
# command-line options to the DESTINATION only, so under a plain -J list each
# hop falls back to password auth on every connection. A generated config says
# it once per hop instead of nesting a ProxyCommand inside a ProxyCommand,
# where the quoting and the %h:%p expansion both go wrong silently.
function Write-SshConfig {
  if (-not $Jumps.Count) { return }
  $lines = foreach ($i in 0..($Jumps.Count - 1)) {
    $e = $Jumps[$i]
    $u = if ($e -match '@') { ($e -split '@')[0] } else { $null }
    $hp = ($e -split '@')[-1]
    $h  = ($hp -split ':')[0]
    $pt = if ($hp -match ':') { ($hp -split ':')[1] } else { '22' }
    "Host gt-hop-$($i + 1)"
    "  HostName $h"
    if ($u) { "  User $u" }
    "  Port $pt"
    "  IdentityFile `"$Key`""
    '  IdentitiesOnly yes'
    '  StrictHostKeyChecking accept-new'
    '  ConnectTimeout 120'
    '  ServerAliveInterval 30'
    '  ServerAliveCountMax 10'
    if ($i -gt 0) { "  ProxyJump gt-hop-$i" }
  }
  Set-Content -Path $SshCfg -Value $lines -Encoding ASCII
}

# Run a multi-line script on the gateway in /bin/sh.
#
# Via a temp file and -RedirectStandardInput, not a pipeline: piping to a native
# command re-encodes the text in the console code page and ends every line with
# CRLF, and a stray CR makes /bin/sh fail on lines that look perfectly fine in
# the error message.
function Invoke-RemoteScript($script) {
  $f = Join-Path $State 'remote.sh'
  [IO.File]::WriteAllText($f, ($script -replace "`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))
  $a = (Get-SshArgs) + @($RHost, '/bin/sh')
  $p = Start-Process ssh -ArgumentList $a -RedirectStandardInput $f -NoNewWindow -Wait -PassThru
  Remove-Item $f -ErrorAction SilentlyContinue
  # Set, not returned: an uncaptured return value would be written to the host,
  # printing a bare exit code under the relay's own output.
  $global:LASTEXITCODE = $p.ExitCode
}

# Pick the relay the gateway can actually execute, pushing it if it is not
# already there. Returns the command that starts it.
function Get-RelayCommand {
  $fallback = "python3 -u /tmp/rsocks-$RelayPort.py"
  if (-not $RelayDir) { return $fallback }
  $arch = (& ssh @(Get-SshArgs) $RHost "/bin/sh -c 'uname -m'") -join '' -replace '\s',''
  $bin = switch -Regex ($arch) {
    '^(x86_64|amd64)$'          { Join-Path $RelayDir 'gtrelay-linux-amd64' }
    '^(aarch64|arm64|armv[89])' { Join-Path $RelayDir 'gtrelay-linux-arm64' }
    default                     { $null }
  }
  if (-not $bin -or -not (Test-Path $bin)) {
    Write-Host "  no binary for gateway arch '$arch', using python3"
    return $fallback
  }
  # Content-addressed, so the 2MB push happens once per gateway.
  $sum = (Get-FileHash $bin -Algorithm SHA256).Hash.ToLower().Substring(0, 16)
  $rp  = "/tmp/gtrelay-$sum"
  # Every remote command goes through /bin/sh: `ssh host "script"` hands the
  # string to the gateway user's LOGIN shell, which may be fish or csh, where
  # none of this parses. `test` rather than `[` for the same reason -- it is
  # also a real binary.
  & ssh @(Get-SshArgs) $RHost "/bin/sh -c 'test -x $rp'" 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  pushing $arch relay -> $rp"
    # Start-Process with -RedirectStandardInput, not a pipeline: PowerShell
    # pipelines carry text and would re-encode the binary into garbage.
    $pushArgs = (Get-SshArgs) + @($RHost, "/bin/sh -c 'cat > $rp.part && chmod +x $rp.part && mv $rp.part $rp'")
    $p = Start-Process ssh -ArgumentList $pushArgs -RedirectStandardInput $bin `
                       -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -ne 0) { Write-Host '  push failed, using python3'; return $fallback }
  }
  # -check exits at once without binding, so this proves the gateway can
  # EXECUTE the file -- a noexec /tmp fails exactly here.
  & ssh @(Get-SshArgs) $RHost "/bin/sh -c '$rp -check'" 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  gateway will not execute $rp, using python3"
    return $fallback
  }
  Write-Host "  static $arch relay at $rp"
  $rp
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
  Write-SshConfig
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
  $relay = Get-RelayCommand
  if ($relay -like 'python3*') {
    Get-Content $RSocks -Raw | & ssh @(Get-SshArgs) $RHost "/bin/sh -c 'cat > /tmp/rsocks-$RelayPort.py'"
  }
  # No ControlMaster on Windows, so this is its own connection.
  #
  # The readiness check is the relay's own listening line, printed only after
  # bind() succeeded, into a log truncated a moment earlier. `exec 3<>/dev/tcp`
  # would be shorter but it is a bash feature, and /bin/sh here is dash.
  $remote = @"
P=/tmp/globaltun-server-$RelayPort.pid
[ -f `$P ] && kill `$(cat `$P) 2>/dev/null; rm -f `$P
: > /tmp/globaltun-server-$RelayPort.log
D=`$(command -v setsid || command -v nohup || true)
RSOCKS_PORT=$RelayPort `$D $relay >/tmp/globaltun-server-$RelayPort.log 2>&1 </dev/null &
echo `$! > `$P
sleep 2
grep -q 'listening on' /tmp/globaltun-server-$RelayPort.log 2>/dev/null && echo "  relay up: `$(head -1 /tmp/globaltun-server-$RelayPort.log)" || { echo '  relay FAILED'; cat /tmp/globaltun-server-$RelayPort.log; exit 1; }
"@
  Invoke-RemoteScript $remote
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
    Invoke-RemoteScript "P=/tmp/globaltun-server-$RelayPort.pid`n[ -f `$P ] && kill `$(cat `$P) 2>/dev/null; rm -f `$P; true"
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
