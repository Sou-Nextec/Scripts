#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Prepara no servidor a pasta compartilhada que recebe a coleta local das estações do Assessment Nextec.

.DESCRIPTION
    Rodar uma vez, no controlador de domínio ou servidor de arquivos, como administrador.
    Cria a pasta, o compartilhamento oculto Assessment$ e as permissões:
      - Computadores do domínio: só gravar arquivos novos (não listam nem leem o que existe).
      - Admins. do domínio e SYSTEM: controle total.
    Cria também a pasta NETLOGON\Nextec com o coletor, que as estações leem para se atualizar.
    Não altera nada além disso. Pode ser executado de novo sem efeito colateral.

.PARAMETER Pasta
    Pasta local no servidor. Padrão: D:\Nextec\Assessment se existir o disco D:, senão C:\Nextec\Assessment.
#>
[CmdletBinding()]
param(
    [string]$Pasta
)

$ErrorActionPreference = 'Stop'

if (-not $Pasta) {
    $Pasta = if (Test-Path 'D:\') { 'D:\Nextec\Assessment' } else { 'C:\Nextec\Assessment' }
}
$estacoes = Join-Path $Pasta 'Estacoes'
New-Item -ItemType Directory -Path $estacoes -Force | Out-Null

# SIDs bem conhecidos do domínio: Computadores do domínio (515) e Admins. do domínio (512). Funciona em qualquer idioma.
Import-Module ActiveDirectory -ErrorAction Stop
$sidDominio = (Get-ADDomain).DomainSID.Value
$computadores = New-Object Security.Principal.SecurityIdentifier("$sidDominio-515")
$admins = New-Object Security.Principal.SecurityIdentifier("$sidDominio-512")
$system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')

# NTFS: herança desligada. Computadores gravam arquivos novos (CreateFiles + AppendData + atributos + Delete),
# sem ReadData nem ListDirectory: não enxergam o que as outras máquinas gravaram.
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$heranca = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
$nenhuma = [Security.AccessControl.PropagationFlags]::None
foreach ($sid in $admins, $system) {
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', $heranca, $nenhuma, 'Allow')))
}
$direitosMaquina = [Security.AccessControl.FileSystemRights]'CreateFiles, AppendData, WriteAttributes, WriteExtendedAttributes, ReadAttributes, Delete, Synchronize'
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($computadores, $direitosMaquina, $heranca, $nenhuma, 'Allow')))
# Travessia na pasta Assessment (acima de Estacoes): as máquinas só precisam atravessar até Estacoes.
$aclRaiz = New-Object Security.AccessControl.DirectorySecurity
$aclRaiz.SetAccessRuleProtection($true, $false)
foreach ($sid in $admins, $system) {
    $aclRaiz.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', $heranca, $nenhuma, 'Allow')))
}
$aclRaiz.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($computadores, 'Traverse, ReadAttributes, Synchronize', 'None', $nenhuma, 'Allow')))
Set-Acl -Path $Pasta -AclObject $aclRaiz
Set-Acl -Path $estacoes -AclObject $acl

# Compartilhamento oculto. O share libera o que o NTFS restringe.
$nomeShare = 'Assessment$'
if (Get-SmbShare -Name $nomeShare -ErrorAction SilentlyContinue) { Remove-SmbShare -Name $nomeShare -Force }
$contaComputadores = $computadores.Translate([Security.Principal.NTAccount]).Value
$contaAdmins = $admins.Translate([Security.Principal.NTAccount]).Value
New-SmbShare -Name $nomeShare -Path $Pasta -Description 'Assessment Nextec: coleta local das estacoes' `
    -FullAccess $contaAdmins -ChangeAccess $contaComputadores -FolderEnumerationMode AccessBased | Out-Null

# Cópia do coletor no NETLOGON (as estações já leem essa pasta). A estação se atualiza a cada inicialização.
$dominio = (Get-ADDomain).DNSRoot
$netlogon = Join-Path $env:SystemRoot "SYSVOL\sysvol\$dominio\scripts\Nextec"
New-Item -ItemType Directory -Path $netlogon -Force | Out-Null
$origem = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($arquivo in 'Nextec-Assessment-Estacao.ps1', 'Instalar-Assessment-Estacao.ps1') {
    $fonte = Join-Path $origem $arquivo
    if (Test-Path $fonte) { Copy-Item $fonte -Destination $netlogon -Force }
    else { Write-Warning "Não encontrei $arquivo ao lado deste script; copie manualmente para $netlogon" }
}

$unc = "\\$env:COMPUTERNAME.$dominio\Assessment`$\Estacoes"
Write-Host ''
Write-Host "Pasta local:        $estacoes"
Write-Host "Compartilhamento:   $unc"
Write-Host "Scripts (NETLOGON): \\$dominio\NETLOGON\Nextec"
Write-Host ''
Write-Host 'Na GPO (Configuração do Computador > Políticas > Configurações do Windows > Scripts > Inicialização > aba Scripts do PowerShell):'
Write-Host "  Nome do script: \\$dominio\NETLOGON\Nextec\Instalar-Assessment-Estacao.ps1"
Write-Host "  Parâmetros:     -Destino `"$unc`""
