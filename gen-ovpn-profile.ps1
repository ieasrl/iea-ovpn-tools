<#
.SYNOPSIS
    Genera (si hace falta) el PPP secret y el certificado firmado de un
    usuario VPN en el MikroTik, y arma el .ovpn completo y autocontenido.
    Usa comandos SSH individuales y simples (no un script multilínea, que
    no viaja bien a través de ssh).

.EXAMPLE
    .\gen-ovpn-profile.ps1 -User jperez
    (te pregunta tu usuario del MikroTik y después los PPP profiles disponibles)

    .\gen-ovpn-profile.ps1 -User jperez -RouterUser mariano -PppProfile vpn-profile-ing
    (salta ambas preguntas)

.NOTES
    Si no pasás -RouterUser, te lo pregunta al arrancar. Es TU usuario de
    acceso al MikroTik (el que usás para entrar por SSH/WinBox), no el
    nombre del usuario VPN que estás generando. Cada persona del equipo
    usa el suyo.

    Requiere el cliente OpenSSH de Windows (ssh.exe). Te va a pedir tu
    password varias veces (una por cada comando remoto), porque el
    ControlMaster de OpenSSH en Windows no anduvo de forma confiable.
    Configurar autenticación por clave pública en el router elimina esto.
    El script avisa qué está haciendo antes de cada paso que pide password.

    Si no pasás -PppProfile, el script consulta los PPP profiles del router
    y los muestra numerados para elegir. Solo se pregunta cuando el PPP
    secret es NUEVO; si ya existe, se respeta el profile que tenga.
#>
param(
    [Parameter(Mandatory=$true)][string]$User,
    [string]$RouterUser = "",
    [string]$RouterHost = "10.1.1.1",
    [string]$CaName = "ca_iearl_router",
    [string]$PppProfile = ""
)

if (-not $RouterUser) {
    $RouterUser = Read-Host "Tu usuario de acceso al MikroTik"
}

$ErrorActionPreference = "Stop"

function New-RandomPassword {
    param([int]$Length = 16)
    # Sin caracteres ambiguos (0/O, 1/l/I) ni espacios/comillas/simbolos raros.
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789-_'
    $bytes = New-Object byte[] $Length
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function Invoke-Remote {
    param([string]$Cmd)
    $out = & ssh "$RouterUser@$RouterHost" $Cmd 2>$null
    return (($out -join "`n").Trim())
}

Write-Host "Conectando al router..."
# --- 1. PPP secret: crear si no existe, o reusar el que ya esta ---
    Write-Host "[1/6] Verificando si existe el PPP secret de '$User'..."
    $secretExists = Invoke-Remote (':put [:len [/ppp secret find name="' + $User + '"]]')
    $isNewSecret = $false
    if ($secretExists -eq "0") {
        if (-not $PppProfile) {
            Write-Host "Consultando los PPP profiles disponibles en el router..."
            $profilesRaw = Invoke-Remote (':foreach i in=[/ppp profile find] do={:put [/ppp profile get $i name]}')
            $profileList = $profilesRaw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
            if ($profileList.Count -eq 0) {
                throw "No se pudo traer la lista de PPP profiles del router."
            }
            Write-Host ""
            Write-Host "Profiles disponibles:"
            for ($i = 0; $i -lt $profileList.Count; $i++) {
                Write-Host "  [$($i+1)] $($profileList[$i])"
            }
            $choice = Read-Host "Elegí el número del profile a usar para '$User'"
            $idx = [int]$choice - 1
            if ($idx -lt 0 -or $idx -ge $profileList.Count) {
                throw "Opción inválida: '$choice'."
            }
            $PppProfile = $profileList[$idx]
            Write-Host "Usando profile: $PppProfile"
            Write-Host ""
        }
        $candidatePass = New-RandomPassword
        Write-Host "[2/6] Creando PPP secret nuevo para '$User' (profile=$PppProfile)..."
        Invoke-Remote ('/ppp secret add name=' + $User + ' password=' + $candidatePass + ' service=ovpn profile=' + $PppProfile) | Out-Null
        Start-Sleep -Seconds 1
        $pass = $candidatePass
        $isNewSecret = $true
    } else {
        Write-Host "[2/6] Trayendo la password del PPP secret existente..."
        $pass = Invoke-Remote (':put [/ppp secret get [/ppp secret find name="' + $User + '"] password]')
    }

    if ($isNewSecret) {
        Write-Host "Se creó un PPP secret nuevo para '$User' con password generada."
    } else {
        Write-Host "Se reutilizó el PPP secret existente de '$User'."
    }

    if ([string]::IsNullOrWhiteSpace($pass)) {
        throw "No se pudo obtener la password del PPP secret de '$User'."
    }

    # --- 2. Certificado del cliente: generar+firmar+exportar si no existe ---
    Write-Host "[3/6] Verificando si existe el certificado de '$User'..."
    $certExists = Invoke-Remote (':put [:len [/certificate find name="' + $User + '"]]')
    if ($certExists -eq "0") {
        Write-Host "[4/6] Generando, firmando y exportando el certificado (puede tardar unos segundos)..."
        Invoke-Remote ('/certificate add name=' + $User + ' common-name=' + $User + ' key-size=2048 days-valid=3650 key-usage=tls-client') | Out-Null
        Start-Sleep -Seconds 1
        Invoke-Remote ('/certificate sign ' + $User + ' ca=' + $CaName) | Out-Null
        Start-Sleep -Seconds 2
        Invoke-Remote ('/certificate export-certificate ' + $User + ' export-passphrase=' + $pass + ' type=pem') | Out-Null
        Start-Sleep -Seconds 2
    } else {
        Write-Host "[4/6] El certificado ya existía, no hace falta generarlo de nuevo."
    }

    Write-Host "[5/6] Confirmando que los archivos se generaron bien..."
    $crtFile = "cert_export_$User.crt"
    $keyFile = "cert_export_$User.key"
    $caFile  = "cert_export_$CaName.crt"

    $crtOk = Invoke-Remote (':put [:len [/file find name="' + $crtFile + '"]]')
    $keyOk = Invoke-Remote (':put [:len [/file find name="' + $keyFile + '"]]')
    if ($crtOk -eq "0" -or $keyOk -eq "0") {
        throw "No se generaron $crtFile / $keyFile en el router. Revisar manualmente con /file print."
    }

    # --- 3. CA publica compartida: exportar una sola vez ---
    $caOk = Invoke-Remote (':put [:len [/file find name="' + $caFile + '"]]')
    if ($caOk -eq "0") {
        Write-Host "Exportando la CA pública compartida (primera vez, se reutiliza después)..."
        Invoke-Remote ('/certificate export-certificate ' + $CaName) | Out-Null
        Start-Sleep -Seconds 2
    }

    # --- 4. Traer los 3 contenidos ---
    Write-Host "[6/6] Trayendo certificado, key y CA para armar el .ovpn..."
    $cert = Invoke-Remote (':put [/file get [/file find name="' + $crtFile + '"] contents]')
    $key  = Invoke-Remote (':put [/file get [/file find name="' + $keyFile + '"] contents]')
    $ca   = Invoke-Remote (':put [/file get [/file find name="' + $caFile + '"] contents]')

    if ([string]::IsNullOrWhiteSpace($cert) -or [string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($ca)) {
        throw "Algún contenido vino vacío.`ncert=[$cert]`nkey=[$key]`nca=[$ca]"
    }

    # --- 5. Armar el .ovpn final ---
    $header = @"
client
dev tun
windows-driver wintun
proto tcp
port 31194
remote vpn.iea.com.ar
nobind
persist-key
persist-tun
tls-client
remote-cert-tls server
cipher AES-256-CBC
tls-cipher TLS-RSA-WITH-AES-256-CBC-SHA
auth SHA1
route-nopull
route 10.0.0.0 255.240.0.0
route 172.20.0.0 255.255.0.0
<auth-user-pass>
$User
$pass
</auth-user-pass>
verb 6
dhcp-option DNS 10.0.1.3
dhcp-option DOMAIN iea.com.ar

"@

    $full = $header + "<ca>`n$ca`n</ca>`n`n<cert>`n$cert`n</cert>`n<key>`n$key`n</key>`n"

    $outFile = Join-Path (Get-Location) "$User.ovpn"
    Set-Content -Path $outFile -Value $full -NoNewline -Encoding ascii

Write-Host ""
Write-Host "Listo: $outFile"
Write-Host "Un solo archivo, autocontenido, listo para entregar al usuario."
Write-Host ""
Write-Host "-------- Credenciales --------"
Write-Host "Usuario:  $User"
Write-Host "Password: $pass"
Write-Host "-------------------------------"
