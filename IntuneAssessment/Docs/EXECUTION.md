# Guia de Execução

## Parâmetros do script

| Parâmetro | Tipo | Descrição |
|-----------|------|-----------|
| `-AuthMethod` | `Interactive` \| `DeviceCode` \| `ClientSecret` \| `Certificate` | Método de autenticação. Padrão: `Interactive`. |
| `-TenantId` | string | ID (GUID) ou domínio do tenant. Obrigatório para app-only. |
| `-ClientId` | string | Application (client) ID do App Registration. |
| `-ClientSecret` | string | Segredo do app (use variável de ambiente, não literal). |
| `-CertificateThumbprint` | string | Thumbprint do certificado em `Cert:\CurrentUser\My` ou `Cert:\LocalMachine\My`. |
| `-OutputPath` | string | Pasta de saída. Padrão: `.\Output\<timestamp>`. |
| `-SkipAppInstallStatus` | switch | Pula a coleta de installSummary por app (acelera tenants com centenas de aplicativos). |

## Cenários

### 0. Lançador universal (recomendado ao distribuir para vários analistas)

```bat
Run-IntuneAssessment.cmd
Run-IntuneAssessment.cmd -AuthMethod DeviceCode
```

O `.cmd` não está sujeito à execution policy do PowerShell: ele desbloqueia os
arquivos (Mark of the Web) e executa o script com `-ExecutionPolicy Bypass`
restrito ao processo. Todos os parâmetros são repassados ao `.ps1`.

### Sessão sempre nova + confirmação de tenant

A cada execução, qualquer sessão Graph anterior é **encerrada automaticamente**
(o SDK guarda cache de contexto em disco e, sem isso, a execução herdaria a
conta/tenant do último login). Nos fluxos interativos, após autenticar, a
ferramenta exibe tenant e conta e **pede confirmação (S/N)** antes de coletar
qualquer dado — se o SSO do navegador escolher a conta errada, basta responder
N, executar de novo e selecionar a conta correta no login.

### 1. Interativo (recomendado para assessment pontual)

```powershell
.\Invoke-IntuneAssessment.ps1
```

### 2. Device Code (servidores sem browser / sessões remotas)

```powershell
.\Invoke-IntuneAssessment.ps1 -AuthMethod DeviceCode
```

O script exibirá um código; acesse `https://microsoft.com/devicelogin` de qualquer
dispositivo e informe o código.

### 3. App Registration + Client Secret (automação)

```powershell
$env:IA_SECRET = '<segredo>'   # ou recupere de um cofre (Azure Key Vault, SecretManagement)
.\Invoke-IntuneAssessment.ps1 -AuthMethod ClientSecret `
    -TenantId 'contoso.onmicrosoft.com' `
    -ClientId  '11111111-2222-3333-4444-555555555555' `
    -ClientSecret $env:IA_SECRET
```

### 4. App Registration + Certificado (automação com maior segurança)

```powershell
.\Invoke-IntuneAssessment.ps1 -AuthMethod Certificate `
    -TenantId 'contoso.onmicrosoft.com' `
    -ClientId  '11111111-2222-3333-4444-555555555555' `
    -CertificateThumbprint 'AB12CD34EF56...'
```

### 5. Tenant grande (acelerar a coleta)

```powershell
.\Invoke-IntuneAssessment.ps1 -SkipAppInstallStatus
```

### 6. Agendamento (Task Scheduler)

```powershell
$action  = New-ScheduledTaskAction -Execute 'pwsh.exe' `
  -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Tools\IntuneAssessment\Invoke-IntuneAssessment.ps1" -AuthMethod Certificate -TenantId contoso.com -ClientId <id> -CertificateThumbprint <thumb> -OutputPath "D:\Reports\Intune"'
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 06:00
Register-ScheduledTask -TaskName 'Intune Assessment Semanal' -Action $action -Trigger $trigger -User 'SYSTEM'
```

## Saída gerada

```
Output\20260604_093000\
├── IntuneAssessment_Report_20260604_093000.html   # Relatório interativo
├── IntuneAssessment_20260604_093000.log           # Log detalhado da execução
└── RawData\
    ├── Devices.csv / Devices.json
    ├── Compliance.csv / ComplianceCritical.csv
    ├── Policies.csv / Profiles.csv
    ├── Apps.csv / Groups.csv
    ├── Enrollment.csv / Autopilot.csv
    ├── Tokens.csv / Security.csv / Scripts.csv
    ├── Relationships.csv
    └── Recommendations.csv (+ .json de cada um)
```

## Usando o relatório

- **Navegação lateral**: salta direto para cada módulo; o item ativo acompanha o scroll.
- **Busca global** (canto superior direito): filtra todas as tabelas e oculta seções
  sem correspondência.
- **Tabelas**: ordenação por coluna, filtro local e exportação CSV/Excel/Copiar por tabela.
- **Health Score**: anel com nota 0–100, classificação e barras por pilar com justificativa.
- **Recomendações**: cartões priorizados (Crítico → Baixo) com achado, impacto e ação.

O HTML é autocontido (dados embarcados); pode ser enviado por e-mail ou anexado em
apresentações. As bibliotecas visuais são carregadas via CDN — para visualização
100% offline, mantenha uma cópia local das libs e ajuste os `<script src>` do template.

## Tempo estimado de execução

| Porte do tenant | Dispositivos | Tempo aproximado |
|-----------------|--------------|------------------|
| Pequeno | < 500 | 2–5 min |
| Médio | 500–5.000 | 5–15 min |
| Grande | > 5.000 | 15–45 min (use `-SkipAppInstallStatus` se necessário) |

O maior custo é o `installSummary` por aplicativo (1 chamada por app) e a resolução
de nomes de grupos (mitigada por cache interno).
