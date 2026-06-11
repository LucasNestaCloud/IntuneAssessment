# Intune Advanced Assessment & Reporting Tool

> Avaliação completa e automatizada de um tenant do **Microsoft Intune** via Microsoft Graph, com exportação de dados brutos (CSV/JSON) e um **relatório HTML executivo** — leve, autocontido e que abre offline.

> [!IMPORTANT]
> **Execute sempre por `Run-IntuneAssessment.cmd`** (duplo clique ou `.\Run-IntuneAssessment.cmd`).
> Rodar `.\Invoke-IntuneAssessment.ps1` direto em um ZIP recém-baixado é bloqueado pelo Windows
> (mensagem *"is not digitally signed"*) por causa do *Mark of the Web*. O `.cmd` resolve isso
> automaticamente; após a primeira execução, o `.ps1` direto também passa a funcionar naquela máquina.

---

## Índice

- [O que a ferramenta faz](#o-que-a-ferramenta-faz)
- [O que ela entrega](#o-que-ela-entrega)
- [Os 13 módulos de coleta](#os-13-módulos-de-coleta)
- [Como o Health Score é calculado](#como-o-health-score-é-calculado)
- [O relatório HTML](#o-relatório-html)
- [Pré-requisitos](#pré-requisitos)
- [Permissões necessárias](#permissões-necessárias)
- [Como executar](#como-executar)
- [Estrutura de saída](#estrutura-de-saída)
- [Estrutura do projeto](#estrutura-do-projeto)
- [Solução de problemas](#solução-de-problemas)
- [Notas de segurança e privacidade](#notas-de-segurança-e-privacidade)

---

## O que a ferramenta faz

O script conecta-se ao Microsoft Graph, executa **13 módulos** de coleta e análise do ambiente Intune e produz uma fotografia completa do tenant: inventário, conformidade, políticas, aplicativos, grupos, enrollment, Autopilot, tokens/conectores, segurança, scripts e o mapa de relacionamentos entre objetos e grupos. Ao final, calcula um **Health Score (0–100)** ponderado e gera **recomendações priorizadas**.

É **100% somente leitura**: nenhuma alteração é feita no tenant em nenhuma etapa.

Principais características:

- **Resiliente** — cada módulo roda isolado; se um falha (permissão, dado inesperado, indisponibilidade da API), o erro é registrado com posição exata e os demais módulos continuam.
- **Autenticação flexível** — interativo, device code, client secret ou certificado.
- **Sessão sempre nova** — encerra qualquer sessão Graph anterior e, nos modos interativos, pede confirmação do tenant/conta antes de coletar, evitando avaliar o ambiente errado.
- **Relatório offline** — o HTML não depende de internet nem de bibliotecas externas para renderizar.

---

## O que ela entrega

A cada execução é criada uma pasta com carimbo de data/hora contendo:

1. **Relatório HTML executivo** — visão navegável de todos os módulos, com KPIs, gráficos, tabelas filtráveis e o Health Score.
2. **Dados brutos** (`RawData/`) — um par `.csv` + `.json` por módulo, para auditoria, BI ou pós-processamento.
3. **Log de execução** — registro completo (INFO/SUCCESS/WARN/ERROR) com timestamps.

---

## Os 13 módulos de coleta

| # | Módulo | O que entrega |
|---|--------|---------------|
| 1 | **Visão Geral** | Totais do tenant: dispositivos, usuários, grupos, aplicativos, políticas/perfis |
| 2 | **Dispositivos** | Inventário completo com classificação automática por plataforma (Windows 10/11/Server, iOS, Android, macOS, Linux), modelo, versão de SO, proprietário, criptografia, último check-in |
| 3 | **Compliance** | Estados de conformidade, principais motivos de falha, ranking por plataforma/usuário e dispositivos críticos (não conformes sem check-in há mais de 30 dias) |
| 4 | **Políticas de Conformidade** | Inventário, atribuições e higiene: sem atribuição, possíveis duplicadas e potencialmente obsoletas |
| 5 | **Configuration Profiles** | Templates clássicos, Settings Catalog e ADMX, com origem e atribuições |
| 6 | **Aplicativos** | Inventário por tipo, status de instalação (sucesso/falha/pendente) e ranking de falhas. Distingue *sem falhas* de *status indisponível* |
| 7 | **Grupos** | Cada grupo/alvo usado pelo Intune, com tipo, dinâmico/atribuído, membros, data de criação, regra de associação e objetos atribuídos. Inclui alvos virtuais (Todos os dispositivos/usuários) e grupos de exclusão |
| 8 | **Enrollment** | Restrições de registro, perfis e Android Enterprise |
| 9 | **Windows Autopilot** | Dispositivos registrados, status do perfil e inconsistências (sem perfil, órfãos) |
| 10 | **Tokens e Conectores** | Semáforo de expiração de tokens/certificados (Apple MDM Push, VPP, conectores) |
| 11 | **Segurança** | Endpoint Security, Security Baselines e lacunas (categorias essenciais ausentes) |
| 12 | **Scripts e Remediações** | PowerShell Scripts, Shell Scripts e Proactive Remediations |
| 13 | **Relacionamentos** | Mapa Objeto → Grupo/Alvo de todo o ambiente, com filtros aplicados |

---

## Como o Health Score é calculado

O score final é um valor de **0 a 100**, resultado da **média ponderada de 6 pilares**. Cada pilar começa em 100 e sofre deduções conforme os achados:

| Pilar | Peso | Como é avaliado |
|-------|:----:|-----------------|
| **Compliance** | 30% | Percentual de dispositivos conformes entre os avaliados. Penalidade extra se mais de 20% dos dispositivos estiverem sem avaliação |
| **Segurança** | 20% | −15 por categoria essencial ausente (ex.: Antivirus, Firewall, ASR); deduções por políticas sem atribuição; piso baixo se não houver nenhuma política de segurança |
| **Tokens e Conectores** | 15% | −40 por token expirado (vermelho), −20 por ≤ 30 dias (laranja), −10 por ≤ 60 dias (amarelo) |
| **Aplicativos** | 15% | −8 por app com falha ≥ 30% (até −40); dedução por apps sem atribuição |
| **Políticas e Perfis** | 10% | Dedução proporcional a políticas sem atribuição; −2 por possível duplicidade |
| **Enrollment** | 10% | −3 por dispositivo Autopilot sem perfil; −2 por órfão; dedução por restrições sem atribuição |

**Fórmula:** `Score = Σ (nota_do_pilar × peso) / 100`

**Classificação resultante:**

| Faixa | Rating |
|-------|--------|
| 85–100 | **Excelente** |
| 70–84 | **Bom** |
| 50–69 | **Atenção Necessária** |
| 0–49 | **Crítico** |

O relatório mostra o score como um anel animado, detalha a nota e o peso de cada pilar e lista as **recomendações** geradas (com severidade Crítico/Alto/Médio/Baixo, impacto e ação sugerida).

---

## O relatório HTML

- **Autocontido e offline** — sem dependências de CDN; tabelas e gráficos são renderizados em JavaScript puro e SVG nativo. Abre em qualquer máquina, inclusive sem internet ou atrás de proxy corporativo.
- **Leve** — tipicamente ~120 KB; o payload embutido traz apenas os campos exibidos (os dados completos ficam no `RawData`).
- **Navegável** — sidebar com as 13 seções, busca global, KPIs com animação, gráficos com os valores sempre visíveis (sem precisar passar o mouse) e tabelas com ordenação, filtro, paginação e exportação CSV.
- **Design** — visual corporativo clean ("Porcelain & Ink"), tipografia padronizada e responsivo.

> Há um exemplo com dados fictícios em `Sample/IntuneAssessment_Report_Sample.html` — abra para ver o resultado antes de rodar no seu tenant.

---

## Pré-requisitos

- **Windows** com **PowerShell 5.1+** (recomendado PowerShell 7.x).
- Módulo **`Microsoft.Graph.Authentication`** — se ausente, o script tenta instalá-lo automaticamente em escopo `CurrentUser` (forçando TLS 1.2 para a PowerShell Gallery). Instalação manual, se necessário:
  ```powershell
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
  ```
- Conexão com a internet **para a coleta** (acesso ao Microsoft Graph). A visualização do relatório, depois de gerado, não exige internet.
- Conta com as permissões descritas abaixo.

---

## Permissões necessárias

A ferramenta solicita os seguintes escopos delegados do Microsoft Graph:

| Escopo | Usado por |
|--------|-----------|
| `DeviceManagementManagedDevices.Read.All` | Dispositivos e compliance (Módulos 2, 3) |
| `DeviceManagementConfiguration.Read.All` | Políticas, perfis, enrollment, segurança (4, 5, 8, 11) |
| `DeviceManagementConfiguration.ReadWrite.All` | Scripts e Proactive Remediations (12) — **exigência da Microsoft**: esses endpoints retornam 403 com `Read.All`, mesmo para leitura. A ferramenta **não escreve nada**; o escopo só autoriza o GET |
| `DeviceManagementApps.Read.All` | Aplicativos e status de instalação (6) |
| `DeviceManagementServiceConfig.Read.All` | Autopilot, tokens e conectores (9, 10) |
| `DeviceManagementRBAC.Read.All` | Papéis e escopos RBAC do Intune |
| `Group.Read.All` | Grupos, membros e regras dinâmicas (7) |
| `User.Read.All` | Usuários e totais do tenant |
| `Organization.Read.All` | Dados do tenant (nome, domínios) |
| `Directory.Read.All` | Leitura geral do diretório (13) |

> [!NOTE]
> **Escopo consentido não basta sem a role RBAC equivalente no Intune.** A conta precisa de um papel com leitura de dispositivos, configurações, apps e scripts — tipicamente **Intune Administrator** (ou um papel customizado equivalente). No primeiro login após uma atualização que inclua novos escopos, aceite o consentimento solicitado (um Global Admin pode consentir em nome da organização).

Para execução não interativa (App Registration com client secret ou certificado), os mesmos nomes valem como permissões de **Aplicação**, todas exigindo **admin consent**. Detalhes em [`Docs/PERMISSIONS.md`](Docs/PERMISSIONS.md).

---

## Como executar

### 1. Interativo (recomendado para assessment pontual)

```powershell
.\Run-IntuneAssessment.cmd
```

O navegador abre para login; em seguida a ferramenta mostra o tenant/conta e **pede confirmação (S/N)** antes de coletar.

### 2. Device Code (máquina sem navegador / SSH)

```powershell
.\Run-IntuneAssessment.cmd -AuthMethod DeviceCode
```

### 3. Não interativo — Client Secret

```powershell
.\Invoke-IntuneAssessment.ps1 -AuthMethod ClientSecret -TenantId contoso.com `
    -ClientId <app-id> -ClientSecret <secret>
```

### 4. Não interativo — Certificado

```powershell
.\Invoke-IntuneAssessment.ps1 -AuthMethod Certificate -TenantId contoso.com `
    -ClientId <app-id> -CertificateThumbprint <thumbprint>
```

### Parâmetros

| Parâmetro | Descrição |
|-----------|-----------|
| `-AuthMethod` | `Interactive` (padrão), `DeviceCode`, `ClientSecret` ou `Certificate` |
| `-TenantId` | Tenant (domínio ou GUID) — obrigatório nos modos não interativos |
| `-ClientId` | App ID do App Registration (modos não interativos) |
| `-ClientSecret` | Segredo do app (apenas `ClientSecret`) |
| `-CertificateThumbprint` | Thumbprint do certificado local (apenas `Certificate`) |
| `-OutputPath` | Pasta de saída (padrão: subpasta `Output/` do projeto) |
| `-SkipAppInstallStatus` | Pula o status de instalação por app — acelera tenants com centenas de aplicativos |

---

## Estrutura de saída

```
Output/
└── 20260606_101500/
    ├── IntuneAssessment_Report_20260606_101632.html   ← relatório HTML
    ├── IntuneAssessment_20260606_101500.log            ← log de execução
    └── RawData/
        ├── Devices.csv / .json
        ├── Compliance.csv / .json
        ├── ComplianceCritical.csv / .json
        ├── Policies.csv / .json
        ├── Profiles.csv / .json
        ├── Apps.csv / .json
        ├── Groups.csv / .json
        ├── Enrollment.csv / .json
        ├── Autopilot.csv / .json
        ├── Tokens.csv / .json
        ├── Security.csv / .json
        ├── Scripts.csv / .json
        ├── Relationships.csv / .json
        └── Recommendations.csv / .json
```

Os CSVs são gravados em UTF-8 com BOM, para abrir corretamente (com acentuação) no Excel pt-BR.

---

## Estrutura do projeto

```
IntuneAssessment/
├── Run-IntuneAssessment.cmd          ← ponto de entrada (desbloqueia + executa)
├── Invoke-IntuneAssessment.ps1       ← orquestrador dos 13 módulos
├── COMO-EXECUTAR.txt                 ← guia rápido na raiz
├── README.md
├── Modules/
│   ├── IntuneAssessment.Core.psm1        ← autenticação, logging, retry, chamadas ao Graph
│   ├── IntuneAssessment.Collectors.psm1  ← os 13 módulos de coleta
│   ├── IntuneAssessment.Analysis.psm1    ← Health Score e recomendações
│   ├── IntuneAssessment.Report.psm1      ← exportação CSV/JSON e geração do HTML
│   └── ReportTemplate.html               ← template do relatório (sem dependências externas)
├── Docs/
│   ├── INSTALL.md
│   ├── EXECUTION.md
│   ├── PERMISSIONS.md
│   └── TROUBLESHOOTING.md
├── Sample/
│   └── IntuneAssessment_Report_Sample.html   ← exemplo com dados fictícios
├── Tools/
│   └── Test-Syntax.ps1               ← validador de sintaxe dos scripts
└── Output/                           ← criado em runtime
```

---

## Solução de problemas

| Sintoma | Causa provável | Solução |
|---------|----------------|---------|
| *"is not digitally signed"* ao rodar o `.ps1` | Mark of the Web em arquivo baixado | Use `Run-IntuneAssessment.cmd` |
| SmartScreen ao abrir o `.cmd` | Editor desconhecido | **Mais informações → Executar assim mesmo** (só na 1ª vez) |
| Conectou no tenant errado | Sessão anterior reutilizada | Já corrigido: a sessão é sempre nova e há confirmação S/N. Responda **N** e selecione a conta certa |
| `403` em scripts (Módulo 12) | Falta o escopo ReadWrite ou a role RBAC | Aceite o novo consentimento; garanta a role Intune da conta |
| Algum módulo retorna vazio | O tenant realmente não tem aquele tipo de objeto, ou falta permissão | Confira o log; verifique escopos e role RBAC |
| Execution policy forçada por GPO | Política corporativa sobrepõe o `-ExecutionPolicy Bypass` | Assinar os scripts com o certificado corporativo |

Guia completo em [`Docs/TROUBLESHOOTING.md`](Docs/TROUBLESHOOTING.md).

---

## Notas de segurança e privacidade

- **Somente leitura.** A ferramenta não cria, altera nem remove nada no tenant.
- Os arquivos de saída contêm dados do ambiente (nomes de dispositivos, usuários, seriais). **Trate a pasta `Output/` como informação sensível** e armazene/compartilhe com cuidado.
- Em execução não interativa, proteja o client secret/certificado conforme as práticas da sua organização.
- O relatório HTML não envia dados a lugar nenhum: todo o conteúdo é embutido localmente no arquivo.

---

<sub>Ferramenta de avaliação somente leitura para Microsoft Intune. Não é um produto oficial da Microsoft.</sub>
