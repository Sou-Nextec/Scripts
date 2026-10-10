@echo off
REM Assessment Nextec: de dois cliques neste arquivo.
REM Modo sem intervencao: reabre como administrador (confirme o UAC), valida o ambiente, coleta tudo e abre a pasta do relatorio.
REM Se a conta atual nao tiver acesso as estacoes, pede um login e senha do dominio, uma unica vez.
REM Mantenha este .cmd na mesma pasta do Nextec-Assessment-v2.ps1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Nextec-Assessment-v2.ps1" -Automatico %*
