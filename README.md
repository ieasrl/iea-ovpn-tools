# Generador de perfiles OpenVPN - IEA

Script que automatiza todo el proceso de alta de un usuario VPN: crea el PPP secret (si no existe), genera y firma el certificado del cliente, y arma el archivo `.ovpn` final listo para entregar. Ya no hace falta tocar nada a mano en el MikroTik.

## Requisitos (una sola vez, por persona)

- Windows 10/11 con el cliente OpenSSH instalado (viene de fábrica). Para confirmar que lo tenés: `ssh` en PowerShell.
- Tener **usuario propio** en el MikroTik (no vale usar el de otro) con permisos para `certificate`/`ppp`/`file`. Si no tenés, pedirlo a tavila.
- Tu IP de origen tiene que estar habilitada en el servicio SSH del router (`/ip service print` → `ssh` → `address`). Si no estás en esa lista, no vas a poder conectar aunque tengas usuario. Avisar a tavila para que agregue tu IP (o tu rango de VPN si te conectás remoto).
- Acceso de red al router (`10.1.1.1`) por el puerto 22 (SSH). Si estás fuera de la red de IEA, conectate primero por VPN.

## Cómo correrlo

1. Cloná o descargá este repo, y parate en la carpeta con PowerShell:
   ```powershell
   cd ruta\al\repo\iea-ovpn-tools
   ```

2. Corré (reemplazando `usuario` por el nombre real del PPP secret que estás generando):
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\gen-ovpn-profile.ps1 -User usuario
   ```
   El `-ExecutionPolicy Bypass` hace falta porque Windows bloquea scripts sin firmar por default; no afecta nada más de tu PC.

   Te va a preguntar tu usuario del MikroTik al arrancar:
   ```
   Tu usuario de acceso al MikroTik:
   ```

3. Te va a pedir **tu** contraseña del MikroTik varias veces (una por cada paso que habla con el router). Es así porque el router tiene SSH restringido por IP y no se logró dejar la conexión "recordada" entre pasos. El script avisa qué está haciendo antes de cada prompt, ej:
   ```
   [3/6] Verificando si existe el certificado de 'usuario'...
   ```

4. Si el usuario es **nuevo** (no tiene PPP secret todavía), te va a mostrar la lista de PPP profiles disponibles y vas a tener que elegir uno por número (define el pool de IP / DNS que le corresponde):
   ```
   Profiles disponibles:
     [1] default
     [2] vpn-profile
     [3] vpn-profile-ing
     [4] vpn-profile-admin
     [7] vpn-profile-sistemas
     ...
   Elegí el número del profile a usar para 'usuario':
   ```
   Para gente de Sistemas/IT, usar `vpn-profile-sistemas`. Para otros sectores, elegir el profile que corresponda (`ing`, `admin`, etc.) — ante la duda, preguntar antes de elegir.

5. Al final te queda en la misma carpeta un archivo `usuario.ovpn` — un solo archivo, listo para entregarle al usuario. También te muestra en pantalla el usuario y la contraseña generada, para copiar y guardar donde corresponda (no queda visible en ningún otro lado):
   ```
   -------- Credenciales --------
   Usuario:  usuario
   Password: xxxxxxxxxxxxxxxx
   -------------------------------
   ```

## Qué hace el script (por si hay que revisar algo)

1. Busca si ya existe un PPP secret con ese nombre.
   - Si **no** existe: lo crea con una password random de 16 caracteres y el profile que elijas.
   - Si **ya** existe: reutiliza el que está, sin tocarlo.
2. Busca si ya existe un certificado con ese nombre.
   - Si **no** existe: lo genera, lo firma con la CA del router (`ca_iearl_router`) y lo exporta con passphrase = la password del PPP secret.
   - Si **ya** existe: no lo vuelve a generar (RouterOS no permite borrar certificados ya emitidos, solo revocarlos).
3. Exporta la CA pública del router una sola vez (se reutiliza para todos los usuarios siguientes, no hace falta repetirlo).
4. Arma el `.ovpn` final embebiendo la CA, el certificado, la key y las credenciales — mismo formato que los perfiles que ya veníamos usando (incluye las rutas fijas y el DNS interno ya configurados).

## Problemas comunes

| Error | Causa / solución |
|---|---|
| `No se puede cargar el archivo... no está firmado digitalmente` | Falta el `-ExecutionPolicy Bypass` al correrlo. |
| `Permission denied, please try again` | Contraseña mal tipeada en alguno de los prompts. Volver a correr. |
| `ssh: connect to host 10.1.1.1 port 22: Connection refused` / `Could not resolve hostname` | No estás en la red de IEA ni por VPN, o el SSH del router está caído. Confirmar conectividad primero. |
| El usuario se conecta pero no le asigna IP (queda en `0.0.0.0`) | El PPP secret quedó con un profile sin pool de direcciones asignado. Se arregla con `/ppp secret set [find name=usuario] profile=NOMBRE-CORRECTO`. |

## Contacto

Cualquier duda o si el script tira un error que no está en esta lista, consultar a Tomás Ávila (`tavila`) antes de tocar algo manualmente en el MikroTik.
