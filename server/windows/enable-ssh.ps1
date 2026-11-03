# Turns on SSH so the Mac can deploy the Minutes server with `docker compose`, and opens the
# server's port. Both are reachable from the local network only, and login is by key only.
#
#   .\enable-ssh.ps1 -PublicKey "ssh-ed25519 AAAA... minutes-mac-to-pc"
#
# Re-launches itself as administrator if needed. Safe to run again: every step checks first.
param(
    [string]$PublicKey = '',
    [int]$ServerPort = 8765
)
$ErrorActionPreference = 'Stop'

# Microsoft's own build of OpenSSH for Windows, used when the Windows feature isn't installed:
# a 7 MB download with a progress bar, instead of Windows Update's often-stalled feature install.
$MsiUrl = 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.4.0.0p1-Preview/OpenSSH-Win64-v10.4.0.0.msi'

function Step($number, $text) { Write-Host "`n[$number/6] $text" -ForegroundColor Cyan }
function Done($text) { Write-Host "      OK  $text" -ForegroundColor Green }
function Note($text) { Write-Host "      $text" }

if (-not $PublicKey.StartsWith('ssh-')) { throw 'Pass the Mac''s public key: -PublicKey "ssh-ed25519 AAAA..."' }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'This needs administrator rights. Approve the prompt; the rest runs in the new window.' -ForegroundColor Yellow
    $shell = (Get-Process -Id $PID).Path
    Start-Process $shell -Verb RunAs -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`" -PublicKey `"$PublicKey`" -ServerPort $ServerPort"
    return
}

Step 1 'OpenSSH Server'
if (Get-Service sshd -ErrorAction SilentlyContinue) {
    Done 'already installed'
} else {
    $msi = Join-Path $env:TEMP 'OpenSSH-Win64.msi'
    Note 'Downloading from github.com/PowerShell/Win32-OpenSSH...'
    curl.exe -L --fail --progress-bar -o $msi $MsiUrl
    if ($LASTEXITCODE -ne 0) { throw "Download failed (curl exit $LASTEXITCODE)." }
    $signature = Get-AuthenticodeSignature $msi
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "The download isn't signed by Microsoft ($($signature.Status)); not installing it."
    }
    Note 'Installing (signed by Microsoft)...'
    $install = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" ADDLOCAL=Server /qn /norestart" -Wait -PassThru
    if ($install.ExitCode -notin 0, 3010) { throw "The installer failed with code $($install.ExitCode)." }
    Remove-Item $msi -ErrorAction SilentlyContinue
    Done 'installed'
}

Step 2 'Start SSH now and at every boot'
Set-Service sshd -StartupType Automatic
Start-Service sshd
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -PropertyType String -Force `
    -Value "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" | Out-Null
Done 'sshd running; commands over SSH run in PowerShell'

Step 3 "Firewall: ports 22 and $ServerPort, this network only"
foreach ($rule in @(
    @{ Name = 'OpenSSH-Server-In-TCP'; DisplayName = 'OpenSSH Server (sshd)'; Port = 22 },
    @{ Name = 'Minutes-Server-In-TCP'; DisplayName = 'Minutes server'; Port = $ServerPort }
)) {
    if (-not (Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $rule.Name -DisplayName $rule.DisplayName -Direction Inbound -Protocol TCP `
            -LocalPort $rule.Port -Action Allow | Out-Null
    }
    Set-NetFirewallRule -Name $rule.Name -Enabled True -Profile Any -RemoteAddress LocalSubnet
}
# The installer may add its own sshd rule open to any address; narrow that one too.
Get-NetFirewallRule -DisplayName '*OpenSSH*' -ErrorAction SilentlyContinue |
    Where-Object Direction -eq 'Inbound' | Set-NetFirewallRule -RemoteAddress LocalSubnet
Done 'only devices on this network can connect'

Step 4 'Authorize the Mac''s key'
# The gotcha: for an account in the Administrators group, sshd ignores ~\.ssh\authorized_keys
# and reads only C:\ProgramData\ssh\administrators_authorized_keys, and only if that file is
# writable by Administrators and SYSTEM alone; otherwise it's silently skipped. Write both.
$adminKeys = "$env:ProgramData\ssh\administrators_authorized_keys"
$userKeys = "$env:USERPROFILE\.ssh\authorized_keys"
foreach ($file in $adminKeys, $userKeys) {
    New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
    if (-not ((Test-Path $file) -and (Select-String -Path $file -SimpleMatch $PublicKey -Quiet))) {
        Add-Content -Path $file -Value $PublicKey -Encoding ascii
    }
}
icacls.exe $adminKeys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
Done "key in $adminKeys (Administrators + SYSTEM only) and $userKeys"

Step 5 'Restart SSH and check it'
Restart-Service sshd
Start-Sleep -Seconds 1
$listening = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue
if ((Get-Service sshd).Status -ne 'Running' -or -not $listening) { throw 'sshd is not listening on port 22.' }
Done 'listening on port 22'

Step 6 'Docker and GPU'
if (Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue) { Done 'Docker Desktop is running' }
else { Note 'Docker Desktop is not running. Start it, and turn on Settings > General > Start Docker Desktop when you sign in.' }
$gpu = if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    & nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
}
if ($gpu) { Done "NVIDIA: $gpu" } else { Note 'No NVIDIA driver found: the server will run on the CPU.' }

$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.InterfaceAlias -notlike 'vEthernet*'
} | Select-Object -First 1).IPAddress
Write-Host "`nAll set. From the Mac:  ssh -i ~/.ssh/minutes_pc $env:USERNAME@$ip" -ForegroundColor Green
