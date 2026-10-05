<#
.SYNOPSIS
    Crea en el MikroTik un pool de IPs y un PPP profile para un sector nuevo,
    siguiendo la misma convención que los profiles existentes:

        pool-vpn-<sector>      ranges=172.20.X.10-172.20.X.100
        vpn-profile-<sector>   local-address=172.20.X.1
                               remote-address=pool-vpn-<sector>
                               dns-server / wins-server = 10.0.1.3
                               use-encryption=required

.EXAMPLE
    .\new-ppp-profile.ps1 -Name comercial -DryRun
    (muestra qué haría, sin tocar nada)

    .\new-ppp-profile.ps1 -Name comercial
    (elige solo el próximo 172.20.X libre y pide confirmación)

    .\new-ppp-profile.ps1 -Name comercial -Octet 4 -Yes
    (fuerza 172.20.4.0/24 y no pregunta)

.NOTES
    -Name acepta "comercial" o "vpn-profile-comercial".
    Si no se pasa -Octet, busca el menor 172.20.X que no esté usado por
    ningún pool, PPP profile ni dirección IP del router.
    El .ovpn ya enruta 172.20.0.0/16, así que no hace falta tocar los perfiles
    de cliente. No crea reglas de firewall.
#>
param(
    [Parameter(Mandatory=$true)][string]$Name,
    [ValidateRange(0,255)][int]$Octet = -1,
    [string]$RouterUser = "",
    [string]$RouterHost = "10.1.1.1",
    [string]$DnsServer = "10.0.1.3",
    [string]$WinsServer = "10.0.1.3",
    [ValidateSet("required","yes","no","default")][string]$UseEncryption = "required",
    [switch]$DryRun,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"

$sector = $Name.ToLower() -replace '^vpn-profile-', ''
if ($sector -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
    throw "Nombre inválido: '$Name'. Usar solo minúsculas, números y guiones (ej: comercial)."
}
foreach ($ip in $DnsServer, $WinsServer) {
    if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "IP inválida: '$ip'." }
}
$profileName = "vpn-profile-$sector"
$poolName    = "pool-vpn-$sector"
$target      = if ($RouterUser) { "$RouterUser@$RouterHost" } else { $RouterHost }

# Corre un comando en el router. Corta si ssh falla o si RouterOS devuelve un error,
# en vez de seguir con una salida vacía.
function Invoke-Remote {
    param([string]$Cmd)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { $out = & ssh -o ConnectTimeout=10 $target $Cmd 2>&1 }
    finally { $ErrorActionPreference = $prev }
    $text = (($out | ForEach-Object { "$_" }) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Falló la conexión SSH (exit $LASTEXITCODE).`n$text"
    }
    if ($text -match '(?m)^(failure:|bad command|syntax error|expected |input does not match|no such item)') {
        throw "RouterOS devolvió un error:`n$text"
    }
    return $text
}

# --- 1. Leer el estado actual (una sola conexión) ---
Write-Host "Consultando el router..."
$read = Invoke-Remote (
    ':put [:len [/ppp profile find name=' + $profileName + ']]; ' +
    ':put [:len [/ip pool find name=' + $poolName + ']]; ' +
    ':foreach i in=[/ip pool find] do={:put [/ip pool get $i ranges]}; ' +
    ':foreach i in=[/ppp profile find] do={:put [/ppp profile get $i local-address]}; ' +
    ':foreach i in=[/ip address find] do={:put [/ip address get $i address]}'
)
$lines = $read -split "`n" | ForEach-Object { $_.Trim() }
if ($lines.Count -lt 2 -or $lines[0] -notmatch '^\d+$' -or $lines[1] -notmatch '^\d+$') {
    throw "Respuesta inesperada del router:`n$read"
}
if ($lines[0] -ne "0") { throw "Ya existe el PPP profile '$profileName'." }
if ($lines[1] -ne "0") { throw "Ya existe el pool '$poolName'." }

$used = @{}
foreach ($m in [regex]::Matches(($lines | Select-Object -Skip 2) -join "`n", '172\.20\.(\d{1,3})\.')) {
    $used[[int]$m.Groups[1].Value] = $true
}

# --- 2. Elegir la subred ---
if ($Octet -ge 0) {
    if ($used.ContainsKey($Octet)) { throw "172.20.$Octet.0/24 ya está en uso." }
} else {
    $Octet = 0..255 | Where-Object { -not $used.ContainsKey($_) } | Select-Object -First 1
    if ($null -eq $Octet) { throw "No quedan subredes 172.20.X libres." }
}
$net        = "172.20.$Octet"
$localAddr  = "$net.1"
$ranges     = "$net.10-$net.100"

$cmdPool    = "/ip pool add name=$poolName ranges=$ranges"
$cmdProfile = "/ppp profile add name=$profileName local-address=$localAddr remote-address=$poolName " +
              "dns-server=$DnsServer wins-server=$WinsServer use-encryption=$UseEncryption"

Write-Host ""
Write-Host "Subredes 172.20.X ya usadas: $((($used.Keys | Sort-Object) -join ', '))"
Write-Host "Se va a crear:"
Write-Host "  Pool:    $poolName  ($ranges)"
Write-Host "  Profile: $profileName  (local $localAddr, DNS $DnsServer, WINS $WinsServer, encryption $UseEncryption)"
Write-Host ""
Write-Host "Comandos:"
Write-Host "  $cmdPool"
Write-Host "  $cmdProfile"
Write-Host ""

if ($DryRun) {
    Write-Host "DryRun: no se modificó nada."
    return
}
if (-not $Yes) {
    $ok = Read-Host "¿Aplicar en el router? (s/N)"
    if ($ok -notmatch '^[sS]') { Write-Host "Cancelado."; return }
}

# --- 3. Crear pool y profile ---
# :put [add ...] devuelve el id interno (*NN); si no vuelve eso, algo falló.
Write-Host "Creando pool y profile..."
$res = Invoke-Remote (':put [' + $cmdPool + ']; :put [' + $cmdProfile + ']')
$ids = @($res -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($ids.Count -ne 2 -or ($ids | Where-Object { $_ -notmatch '^\*[0-9A-F]+$' })) {
    throw "No se pudo confirmar la creación. Revisar a mano /ip pool y /ppp profile.`n$res"
}

# --- 4. Verificar ---
Write-Host ""
Write-Host (Invoke-Remote ('/ip pool print detail without-paging where name=' + $poolName))
Write-Host (Invoke-Remote ('/ppp profile print detail without-paging where name=' + $profileName))
Write-Host ""
Write-Host "Listo. Para dar de alta un usuario con este profile:"
Write-Host "  .\gen-ovpn-profile.ps1 -User <usuario> -PppProfile $profileName"
