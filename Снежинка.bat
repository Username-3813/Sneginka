@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p='%~dp0Sneginka.ps1'; $t=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8); [IO.File]::WriteAllText($p,$t,(New-Object Text.UTF8Encoding $true))"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Sneginka.ps1"
exit
