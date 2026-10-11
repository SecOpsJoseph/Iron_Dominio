@echo off
cd /d "%~dp0"

echo ================================================
echo Publicando Iron Dominio
echo ================================================

git add .
git commit -m "Release Iron Dominio"
git branch -M main
git remote add origin https://github.com/SecOpsJoseph/Iron_Dominio.git 2>nul
git push -u origin main

echo.
echo Abriendo GitHub para crear la release...
start https://github.com/SecOpsJoseph/Iron_Dominio/releases/new

echo.
echo Ahora crea la tag v1.0.0 y adjunta el APK:
echo   build\app\outputs\flutter-apk\Iron Dominio.apk
pause
