@echo off
REM Assessment Nextec: clique com o botao direito neste arquivo e escolha "Executar como administrador".
REM Modo sem intervencao: valida o ambiente, coleta tudo e abre a pasta do relatorio. Sem administrador, o script avisa e encerra.
REM Se a conta atual nao tiver acesso as estacoes, pede um login e senha do dominio, uma unica vez.
REM Mantenha este .cmd na mesma pasta do Nextec-Assessment-v2.ps1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Nextec-Assessment-v2.ps1" -Automatico %*
