param(
    [string]$notas = "Nueva version de Iron Dominio"
)

$repo = "SecOpsJoseph/Iron_Dominio"

$contenido = Get-Content "pubspec.yaml" -Raw
if ($contenido -match 'version:\s*(\d+\.\d+\.\d+)\+(\d+)') {
    $nombre = $Matches[1]
    $build = [int]$Matches[2] + 1
    $nuevoVersion = "$nombre+$build"
    $contenido = $contenido -replace 'version:\s*\d+\.\d+\.\d+\+\d+', "version: $nuevoVersion"
    Set-Content "pubspec.yaml" $contenido -NoNewline
    Write-Host "Version nueva: $nuevoVersion"
} else {
    Write-Error "No encontre la version en pubspec.yaml"
    exit 1
}

& "C:\Dev\flutter\bin\flutter.bat" build apk --release
if ($LASTEXITCODE -ne 0) {
    Write-Error "Fallo la compilacion"
    exit 1
}

$apkOrigen = "build\app\outputs\flutter-apk\app-release.apk"
$apkDestino = "build\app\outputs\flutter-apk\Iron Dominio.apk"
if (Test-Path $apkOrigen) {
    Copy-Item $apkOrigen $apkDestino -Force
    Write-Host "APK listo: $apkDestino"
} else {
    Write-Error "No se encontro el APK compilado: $apkOrigen"
    exit 1
}

$tag = "v$nombre"
$tag = $tag -replace '\.0$', ''
if ($build -gt 0) {
    $tag = "v$nombre"
}

$fullTitle = "Iron Dominio $nombre+$build"

Write-Host "Creando release $tag"
& gh release create $tag "$apkDestino" --repo $repo --title $fullTitle --notes "$notas"

if ($LASTEXITCODE -ne 0) {
    Write-Error "Fallo la creacion de la release"
    exit 1
}

Write-Host "Release publicada correctamente."
