@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy RemoteSigned -File "%~dp0ConectorTriade.ps1"
if errorlevel 1 (
  echo Nao foi possivel abrir o conector. Extraia o ZIP inteiro antes de executar.
  echo Se o Windows bloqueou o arquivo, consulte LEIA-ME.txt ou o suporte de TI.
  pause
)
endlocal
