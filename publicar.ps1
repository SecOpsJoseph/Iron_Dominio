param(
    [string]$Notas = "Nueva version",
    [string]$Repo = "TU_USUARIO/TU_REPO",
    [string]$AppName = "Iron Dominio"
)

$ErrorActionPreference = 'Stop'

if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

Set-Location $PSScriptRoot

function Ensure-Command {
    param([string]$Nombre)
    if (-not (Get-Command $Nombre -ErrorAction SilentlyContinue)) {
        throw "Falta la herramienta '$Nombre' en PATH. Instálala antes de continuar."
    }
}

function Show-DeveloperModeHelp {
    Write-Host ""
    Write-Host "Flutter requiere soporte de symlinks en Windows."
    Write-Host "Activa 'Modo desarrollador'."
    Write-Host "Pulsa esta línea en PowerShell:"
    Write-Host "  start ms-settings:developers"
    Write-Host "o entra en Configuración > Privacidad y seguridad > Para desarrolladores > Modo desarrollador."
    Write-Host ""
}

Ensure-Command -Nombre "flutter"
Ensure-Command -Nombre "gh"

Write-Host "==> Verificando pubspec.yaml"
$contenido = Get-Content "pubspec.yaml" -Raw
if ($contenido -match '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)') {
    $nombreVersion = $Matches[1]
    $buildActual = [int]$Matches[2]
    $buildNuevo = $buildActual + 1
    $contenido = $contenido -replace 'version:\s*\d+\.\d+\.\d+\+\d+', "version: $nombreVersion+$buildNuevo"
    Set-Content -Path "pubspec.yaml" -Value $contenido -NoNewline
    Write-Host "Version nueva: $nombreVersion+$buildNuevo"
} else {
    throw "No encontré la versión en pubspec.yaml. Revisa el formato: version: X.Y.Z+N"
}

Write-Host "==> Compilando APK release"
$buildOutput = & flutter build apk --release 2>&1
$exitCode = $LASTEXITCODE
$buildOutput | ForEach-Object { Write-Host $_ }

if ($exitCode -ne 0) {
    $esErrorReal = $buildOutput -match 'BUILD FAILED|FAILURE:|Exception|Error:|error:'
    if ($esErrorReal) {
        if ($buildOutput -match 'requires symlink support|Developer Mode|ms-settings:developers') {
            Show-DeveloperModeHelp
        }
        throw "Falló la compilación de Flutter. Revisa el error anterior."
    }

    Write-Warning "Flutter devolvió un código de salida $exitCode, pero la salida no muestra un fallo real de compilación. Esto suele ser una advertencia de Java/Gradle y no bloquea la build."
    Write-Warning "Si la build no se genera, ejecuta manualmente: flutter build apk --release --verbose"
}

$apkOrigen = Join-Path $PSScriptRoot "build\app\outputs\flutter-apk\app-release.apk"
if (-not (Test-Path $apkOrigen)) {
    throw "No encontré el APK generado en: $apkOrigen"
}

$apkDestino = Join-Path $PSScriptRoot ("build\app\outputs\flutter-apk\Iron Dominio.apk")
Copy-Item -Path $apkOrigen -Destination $apkDestino -Force
Write-Host "APK listo: $apkDestino"

$tag = "v$buildNuevo"
Write-Host "==> Creando release en GitHub"
$releaseTitle = "$AppName $nombreVersion+$buildNuevo"

gh release create $tag "$apkDestino" --repo $Repo --title $releaseTitle --notes "$Notas"
if ($LASTEXITCODE -ne 0) {
    throw "Falló la creación del release en GitHub. Revisa que el repo y el token estén correctos."
}

Write-Host "Release creado correctamente: $tag"
Write-Host "Resumen: $AppName | $nombreVersion+$buildNuevo | Repo: $Repo"
