@echo off
setlocal
REM Executa o diagnostico como Administrador (aparece o prompt do UAC).
REM Parametros extras sao repassados. Ex.: Executar-Diagnostico.bat -Dias 30 -Completo
REM O relatorio vai para C:\Temp\Diagnostico (padrao do script); use -OutputPath para mudar.
REM
REM O script e copiado para uma pasta local ANTES de elevar: a sessao elevada nao enxerga
REM unidades de rede mapeadas (letra de unidade), e o .bat pode estar numa delas.
set "DIAG_DST=%PUBLIC%\Diagnostico-Windows-run.ps1"
copy /y "%~dp0Diagnostico-Windows.ps1" "%DIAG_DST%" >nul
if errorlevel 1 (
    echo Nao foi possivel copiar o script para "%PUBLIC%".
    pause
    exit /b 1
)
set "DIAG_ARGS=%*"
powershell -NoProfile -Command "$q=[char]34; $a='-NoProfile -ExecutionPolicy Bypass -NoExit -File '+$q+$env:DIAG_DST+$q+' -ApagarScriptAoFinal '+$env:DIAG_ARGS; Start-Process powershell -Verb RunAs -ArgumentList $a"