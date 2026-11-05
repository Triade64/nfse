@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy RemoteSigned -File "%~dp0ConectorTriade.ps1" -RegisterProtocol
if errorlevel 1 (
  echo Nao foi possivel ativar a abertura pelo site. Extraia o ZIP inteiro e consulte LEIA-ME.txt.
  pause
)
endlocal
