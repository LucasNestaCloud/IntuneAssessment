# Intune Advanced Assessment & Reporting Tool

> **EXECUTE SEMPRE POR `Run-IntuneAssessment.cmd`** (duplo clique ou `.\Run-IntuneAssessment.cmd`).
> Rodar `.\Invoke-IntuneAssessment.ps1` direto em um ZIP recém-baixado será bloqueado pelo
> Windows ("is not digitally signed") por causa do Mark of the Web — o `.cmd` resolve isso
> automaticamente, e após a primeira execução o `.ps1` direto também passa a funcionar.

Ferramenta PowerShell de assessment completo do Microsoft Intune via Microsoft Graph.
Coleta 13 módulos de dados do tenant, calcula um **Health Score (0–100)**, gera
**recomendações automáticas** priorizadas por severidade e produz um **relatório HTML
interativo** (executivo + técnico), além de exportar todos os dados brutos em CSV e JSON.

## Estrutura do projeto

```
IntuneAssessment/
├── Run-IntuneAssessment.cmd           # Lançador universal (resolve execution policy/MotW)
├── Invoke-IntuneAssessment.ps1        # Script principal (orquestrador)
├── Modules/
│   ├── IntuneAssessment.Core.psm1       # Autenticação, logging, retry, paginação
│   ├── IntuneAssessment.Collectors.psm1 # Módulos 1–13 de coleta
│   ├── IntuneAssessment.Analysis.psm1   # Health Score + recomendações
│   ├── IntuneAssessment.Report.psm1     # Exportação CSV/JSON + geração do HTML
│   └── ReportTemplate.html              # Template do relatório (Bootstrap/Chart.js/DataTables)
├── Docs/
│   ├── INSTALL.md                     # Guia de instalação
│   ├── EXECUTION.md                   # Guia de execução
│   ├── PERMISSIONS.md                 # Permissões Microsoft Graph necessárias
│   └── TROUBLESHOOTING.md             # Guia de solução de problemas
├── Sample/
│   └── IntuneAssessment_Report_Sample.html  # Exemplo de saída com dados fictícios
└── Output/                            # Criada em runtime: <timestamp>/relatório + RawData + log
```

## Módulos do assessment

| # | Módulo | O que coleta/analisa |
|---|--------|----------------------|
| 1 | Visão Geral | Tenant, domínios, totais de dispositivos/usuários/grupos/apps/políticas |
| 2 | Dispositivos | Inventário completo + classificação Windows 10/11/Server, Apple, Android, Linux |
| 3 | Compliance | Conformes, não conformes, carência, sem avaliação, erro; motivos de falha; dispositivos críticos; ranking por plataforma e usuário |
| 4 | Políticas de Conformidade | Inventário, assignments, sem atribuição, duplicadas, obsoletas |
| 5 | Configuration Profiles | Templates clássicos, Settings Catalog e ADMX; redundâncias e perfis órfãos |
| 6 | Aplicativos | Inventário por tipo (Win32, Store, M365, iOS, Android, macOS, Web), status de instalação, ranking de falhas |
| 7 | Grupos | Grupos usados pelo Intune, tipo, membros, objetos atribuídos |
| 8 | Enrollment | Restrições, perfis Autopilot, Apple ADE, Android Enterprise |
| 9 | Windows Autopilot | Dispositivos, Group Tag, perfil, status; sem perfil e órfãos |
| 10 | Tokens e Conectores | APNs, ADE, VPP, Managed Google Play, NDES, MTD — com semáforo de expiração |
| 11 | Segurança | Endpoint Security (AV, BitLocker, Firewall, ASR, EDR), baselines, lacunas |
| 12 | Scripts e Remediações | PowerShell, Shell e Proactive Remediations |
| 13 | Relacionamentos | Mapa Objeto → Grupo → Filtro de todo o ambiente |

## Início rápido

**Dê dois cliques em `Run-IntuneAssessment.cmd`** (ou execute-o no terminal).
O lançador remove automaticamente o bloqueio de "arquivo baixado da internet"
(Mark of the Web) e executa o assessment com `-ExecutionPolicy Bypass` somente
no processo — funciona em qualquer máquina, sem administrador e sem alterar a
política de execução do sistema.

```bat
Run-IntuneAssessment.cmd
Run-IntuneAssessment.cmd -AuthMethod DeviceCode
```

Alternativamente, direto pelo PowerShell:

```powershell
# Login interativo (browser) — modo padrão
.\Invoke-IntuneAssessment.ps1
```

Ao final, o relatório HTML abre automaticamente e os dados brutos ficam em
`Output\<timestamp>\RawData\` (Devices.csv, Apps.csv, Policies.csv, Tokens.csv, etc.).

Consulte `Docs/` para instalação, permissões, execução avançada e troubleshooting.

## Características técnicas

- **Somente leitura**: nenhuma operação de escrita é realizada no tenant.
- **Resiliente**: retry exponencial, tratamento de throttling (HTTP 429 com `Retry-After`),
  falhas parciais não interrompem o assessment (módulo gera WARN e segue).
- **Leve**: depende apenas de `Microsoft.Graph.Authentication` (REST puro via
  `Invoke-MgGraphRequest`), sem os ~40 submódulos do SDK completo.
- **Compatível**: PowerShell 5.1+ (recomendado PowerShell 7.x).
- **Relatório autocontido**: um único arquivo HTML com os dados embarcados em JSON;
  bibliotecas (Bootstrap, Chart.js, DataTables) carregadas via CDN.
