# Atualizador automático Nextec

Mantém o monitoramento de todas as máquinas na versão publicada pela Nextec, sem ninguém entrar em cada uma. O instalador (Linux 2.4.0+, Windows 2.14.0+) instala o atualizador junto com o Alloy. Histórico de versões em [`../CHANGELOG.md`](../CHANGELOG.md).

## Como funciona

1. Todo dia, de madrugada (01h às 05h no horário de Brasília, com atraso aleatório por máquina; no Linux o fuso fica fixo no timer, no Windows vale o relógio do Windows), o atualizador baixa `manifesto.json` e `manifesto.json.sig` desta pasta, na branch `main`.
2. Confere a assinatura RSA 4096 com as chaves públicas gravadas **dentro do próprio atualizador**. Sem assinatura válida, nada é aplicado.
3. Recusa manifesto vencido, manifesto com sequência menor que a já aceita e manifesto com a mesma sequência e conteúdo diferente.
4. Respeita a pausa (`pausa.json`) e a onda da máquina.
5. Baixa cada arquivo pelo endereço fixado no commit e confere o SHA-256 do manifesto.
6. Guarda cópia do que está instalado e roda o instalador em modo de atualização, sem perguntas. As respostas ficam gravadas na máquina: `/etc/nextec/instalacao.conf` no Linux e o próprio `config.alloy` no Windows. As credenciais ficam onde já estão.
7. Confere a saúde do Alloy. Se ele não ficar saudável, volta tudo para a versão anterior sozinho, e aquela versão não é tentada de novo na máquina.
8. Grava métricas (`nextec_atualizador_*`) e eventos (`tipo="atualizador_evento"`) para o NOC.

O atualizador não aceita comando avulso: ele só aplica o que vier num manifesto assinado.

## Ondas

| Onda | Quem | Quando recebe |
| --- | --- | --- |
| 0 | Máquinas do cliente `nextec` | Na hora da publicação |
| 1 | Cerca de 10% das máquinas dos clientes (sorteio fixo por máquina) | 24h depois (ajustável) |
| 2 | Todas as demais | Só depois de `aprovar` |

Para fixar a onda de uma máquina, use `onda = 0`, `1` ou `2` em `/etc/nextec/atualizador.conf` (Linux) ou `C:\ProgramData\Nextec\atualizador.conf` (Windows). Para tirar uma máquina das atualizações, use `habilitado = nao` no mesmo arquivo.

## Segurança

| Ameaça | Proteção |
| --- | --- |
| Interceptar o download | HTTPS com certificado validado; redirecionamento para fora do HTTPS é recusado |
| Invadir o GitHub ou o servidor e trocar arquivos | Assinatura com chave privada que só existe no computador de quem publica; SHA-256 de cada arquivo dentro do manifesto assinado |
| Reenviar uma versão antiga e vulnerável | Sequência crescente; a máquina recusa número menor e recusa a mesma sequência com conteúdo diferente |
| Segurar as atualizações para sempre (congelamento) | Manifesto vence em até 30 dias e o NOC alerta 15 dias antes |
| Usar o publicador para assinar algo forjado | O publicador só assina se o manifesto local for igual ao da `main` e com assinatura válida |
| Usuário comum trocar o script que roda como root/SYSTEM | Linux: arquivos do root. Windows: pastas com ACL só de SYSTEM e Administradores (usuário comum só lê na pasta da Coleta), links e ACEs estranhas são removidos |
| Atualização ruim derrubar a frota | Ondas, volta automática e pausa |

A pausa não é assinada de propósito: ela só consegue impedir atualização, nunca instalar nada.

## Primeira configuração (uma vez)

Requisitos no seu computador: Python 3.8+, git e openssl (no Windows, o Git for Windows já traz o openssl), com este repositório clonado.

```bash
python3 Alloy/atualizador/publicar-versao.py gerar-chave --pasta "D:\Chaves Nextec"
git add Alloy/atualizador && git commit -m "Chave pública do atualizador" && git push
```

- A senha da chave é pedida pelo openssl. Guarde a chave privada (`nextec-atualizador-privada.pem`) e a senha no cofre (Bitwarden), em itens separados. Nunca coloque a chave em servidor, no GitHub ou em pasta sincronizada sem criptografia.
- A chave pública vai para dentro dos dois atualizadores. As máquinas instaladas **depois** desse commit já confiam nela; as instaladas antes precisam rodar o instalador uma vez.

## Publicar uma versão

1. Teste na branch e faça o merge na `main` (`git pull` depois do merge).
2. Publique o commit da `main`:

   ```bash
   python3 Alloy/atualizador/publicar-versao.py publicar --commit HEAD --alloy 1.20.1 --chave "D:\Chaves Nextec\nextec-atualizador-privada.pem"
   git add Alloy/atualizador && git commit -m "Publica versão" && git push
   ```

   `--alloy` é a versão do Grafana Alloy que vai para a frota (teste antes na onda 0). `--onda1-horas` muda o intervalo até a onda 1.
3. Acompanhe no painel **NOC › Atualizador da frota**.
4. Libere para todos:

   ```bash
   python3 Alloy/atualizador/publicar-versao.py aprovar --chave "..."
   git add Alloy/atualizador && git commit -m "Aprova versão" && git push
   ```

## Outros comandos

| Comando | Para quê |
| --- | --- |
| `pausar --motivo "texto"` | Suspende todas as atualizações (não precisa de chave) |
| `retomar` | Remove a pausa |
| `renovar --chave ...` | Renova o vencimento sem mudar a versão. Rodar quando o NOC avisar |
| `verificar` | Confere a assinatura e mostra versão, ondas e pausa |
| `adicionar-chave --publica arquivo.pem` | Troca de chave: adiciona a nova, publica uma versão assinada pela atual e, depois que a frota atualizar, passa a assinar com a nova |

Para voltar a frota para uma versão anterior, publique o commit antigo com `publicar --commit <sha>`. A sequência continua subindo, então as máquinas aceitam.

## Na máquina

| | Linux | Windows |
| --- | --- | --- |
| Atualizador | `/usr/local/lib/nextec/nextec-atualizador.py` | `C:\ProgramData\Nextec\atualizador\nextec-atualizador.ps1` |
| Agendamento | timer `nextec-atualizador.timer` | tarefa `NextecAtualizador` (SYSTEM) |
| Configuração | `/etc/nextec/atualizador.conf` | `C:\ProgramData\Nextec\atualizador.conf` |
| Estado e cópias | `/var/lib/nextec-atualizador/` | `C:\ProgramData\Nextec\atualizador\` |
| Log do instalador | `/var/log/nextec/atualizador-instalador.log` | `C:\ProgramData\Nextec\atualizador\instalador.log` |

```bash
python3 /usr/local/lib/nextec/nextec-atualizador.py verificar   # situação, sem alterar nada
systemctl start nextec-atualizador                                # roda agora
journalctl -u nextec-atualizador -n 50
```

```powershell
powershell -ExecutionPolicy Bypass -File C:\ProgramData\Nextec\atualizador\nextec-atualizador.ps1 -Acao verificar
Start-ScheduledTask -TaskName NextecAtualizador
```

## Resultados (métrica `nextec_atualizador_resultado`)

| Resultado | Significado |
| --- | --- |
| `ok` / `atualizado` | Aplicou agora / já estava na versão |
| `aguardando_onda`, `pausado`, `desligado` | Nada a fazer por enquanto |
| `falha_instalacao` | Falhou e voltou à versão anterior (alerta) |
| `falha_rollback` | Falhou e a volta automática não deixou o Alloy saudável (crítico) |
| `assinatura_invalida`, `hash_invalido`, `versao_antiga`, `manifesto_divergente`, `manifesto_invalido` | Manifesto ou arquivo recusado: tratar como possível ataque (crítico) |
| `manifesto_vencido` | Rodar `renovar` |
| `sem_chave`, `sem_estado` | Atualizador sem chave pública ou máquina sem respostas gravadas: rodar o instalador uma vez |
| `dotnet_antigo` | Windows com .NET Framework anterior ao 4.6 |
| `erro_rede`, `falha_download` | Sem acesso ao GitHub naquela noite; tenta de novo na próxima |

## Limites conhecidos

- A pausa automática quando uma onda falha ainda não existe: hoje a pausa é manual (`pausar`).
- Máquinas instaladas antes do instalador 2.4.0 (Linux) e 2.14.0 (Windows) precisam rodar o instalador uma vez para entrar no atualizador.
