# Segurança Linux: kernel (CVE-2026-99999) e PHP (CVE-2026-109618, CVE-2026-109619, CVE-2026-115560)

Verifica se o servidor está corrigido, mostra o resultado em verde ou vermelho, oferece a correção quando a distribuição já publicou o pacote, agenda a atualização e o reinício e envia o relatório por e-mail.

## Execução

Como root:

```bash
curl -fsSL https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Seguranca-Linux/nextec-cve.sh -o ~/nextec-cve.sh && NEXTEC_BREVO_API_KEY='CHAVE' bash ~/nextec-cve.sh
```

Com usuário comum:

```bash
curl -fsSL https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Seguranca-Linux/nextec-cve.sh -o ~/nextec-cve.sh && sudo env NEXTEC_BREVO_API_KEY='CHAVE' bash ~/nextec-cve.sh
```

## Variáveis

| Variável | O que é | Para que serve |
|---|---|---|
| `NEXTEC_BREVO_API_KEY` | Chave de API da Brevo (`xkeysib-...`) | Envio do relatório pela API HTTPS (porta 443). Se não for informada, o script pede na tela quando o e-mail for solicitado. |
| `NEXTEC_SMTP_SENHA` | Chave SMTP da Brevo (`xsmtpsib-...`), opcional | Envio pelo SMTP (portas 587, 2525 e 465), tentado antes da API. |

As chaves não ficam no repositório. Quando há agendamento, elas são gravadas em `/etc/nextec/notificacao.env` (permissão 600) e removidas ao fim da rodada, junto com o script instalado.

## Outras opções

- `--teste-email destinatario`: envia um relatório de teste.
- `--cancelar`: cancela os agendamentos e remove os arquivos do servidor.
