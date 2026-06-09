# Guia de Troubleshooting

Sempre comece pelo arquivo `IntuneAssessment_<timestamp>.log` na pasta de saída —
todas as falhas (autenticação, permissão, throttling, endpoints) são registradas lá.

## Encoding / caracteres especiais (erro de parse ao executar)

| Sintoma | Causa | Solução |
|---------|-------|---------|
| `ParserError ... AmpersandNotAllowed`, texto corrompido tipo `â•‘` ou `MÃ³dulo` no console | Arquivo `.ps1`/`.psm1` salvo em **UTF-8 sem BOM**. O Windows PowerShell 5.1 lê arquivos sem BOM como ANSI e corrompe caracteres acentuados/Unicode, quebrando o parser. | Todos os arquivos do pacote já são distribuídos em **UTF-8 com BOM**. Se algum editor regravar sem BOM, rode `.\Tools\Test-Syntax.ps1` para detectar e corrigir conforme instruído, ou no VS Code: barra inferior → *UTF-8* → *Save with Encoding* → **UTF-8 with BOM**. |
| Acentos corrompidos só no console (script executa) | Code page do console | `[Console]::OutputEncoding = [Text.Encoding]::UTF8` ou use Windows Terminal/PowerShell 7. |

> Validação preventiva: execute `.\Tools\Test-Syntax.ps1` após qualquer edição —
> ele usa o parser oficial do PowerShell (AST) e confere o BOM de todos os arquivos.


## "is not digitally signed" / execution policy

| Sintoma | Causa | Solução |
|---------|-------|---------|
| `File ... is not digitally signed. You cannot run this script on the current system.` | O ZIP foi baixado da internet: o Windows marca cada arquivo extraído com o "Mark of the Web", e políticas `RemoteSigned`/`AllSigned` bloqueiam scripts baixados não assinados. Varia por máquina/política — por isso pode funcionar para um analista e bloquear para outro. | **Use o `Run-IntuneAssessment.cmd`** (recomendado para distribuição; após a primeira execução o desbloqueio é permanente e o `.ps1` direto também passa a funcionar): ele desbloqueia os arquivos e executa com `-ExecutionPolicy Bypass` apenas no processo, sem admin. Manualmente: `Get-ChildItem -Recurse \| Unblock-File` na pasta do projeto, ou `powershell -ExecutionPolicy Bypass -File .\Invoke-IntuneAssessment.ps1`. |
| SmartScreen: "O Windows protegeu o computador" ao abrir o `.cmd` | O `.cmd` baixado também carrega o Mark of the Web; o SmartScreen alerta sobre editor desconhecido (não bloqueia, só pede confirmação). | Clique em **Mais informações → Executar assim mesmo**. Ocorre apenas na primeira execução. |
| Mesmo com o `.cmd` o bloqueio persiste | A organização força a execution policy via **GPO** (`MachinePolicy`/`UserPolicy` em `Get-ExecutionPolicy -List`) — nesse caso `-ExecutionPolicy Bypass` é ignorado por design. | Assine os scripts com o certificado de code signing corporativo: `Get-ChildItem -Recurse -Include '*.ps1','*.psm1' \| Set-AuthenticodeSignature -Certificate (Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert)`, ou solicite exceção ao time de segurança. |

## Autenticação

| Sintoma | Causa provável | Solução |
|---------|----------------|---------|
| `AADSTS65001 ... consent` | Escopos delegados não consentidos | Um administrador deve aprovar o consentimento no primeiro login, ou conceder consent em nome da organização para o app *Microsoft Graph Command Line Tools*. |
| `AADSTS700016: Application not found` | `ClientId` incorreto ou app de outro tenant | Confirme o Application (client) ID e o `-TenantId`. |
| `AADSTS7000215: Invalid client secret` | Segredo expirado/incorreto (ou copiado o *Secret ID* em vez do *Value*) | Gere novo segredo e copie o campo **Value**. |
| `Certificate not found` | Thumbprint não existe no repositório do usuário/máquina que executa | `Get-ChildItem Cert:\CurrentUser\My` e confirme o thumbprint; em tarefa agendada como SYSTEM, o certificado deve estar em `Cert:\LocalMachine\My`. |
| Browser não abre no modo Interactive | Sessão remota/Server Core | Use `-AuthMethod DeviceCode`. |
| `Connect-MgGraph` não reconhecido | Módulo ausente e galeria bloqueada | Instale `Microsoft.Graph.Authentication` offline (ver INSTALL.md §2). |

## Sessão / tenant errado

| Sintoma | Causa | Solução |
|---------|-------|---------|
| Conectou no tenant errado sem pedir login | Versões antigas reutilizavam o cache de contexto do SDK Graph. | Corrigido: toda execução encerra a sessão anterior e exige novo login; nos modos interativos há confirmação (S/N) do tenant/conta antes da coleta. |
| Login abre e entra sozinho na conta anterior | SSO do navegador (sessão do browser, não do SDK). | Responda **N** na confirmação, execute novamente e clique em "Usar outra conta" no login — ou use uma janela anônima/`-AuthMethod DeviceCode`. |

## Permissões / dados vazios

| Sintoma | Causa | Solução |
|---------|-------|---------|
| `403` apenas em `deviceManagementScripts`/`deviceShellScripts`/`deviceHealthScripts` (Módulo 12) | Exigência da Microsoft: esses endpoints requerem `DeviceManagementConfiguration.ReadWrite.All` mesmo para GET. | A ferramenta já solicita esse escopo; no primeiro login após a atualização, aceite o novo consentimento (admin consent se solicitado). Em app-only, adicione a permissão de Aplicação correspondente + admin consent. |
| Log com `Acesso negado (403)` em um endpoint | Escopo/permissão ausente | Compare o endpoint com a tabela de PERMISSIONS.md e adicione o escopo correspondente (delegado ou de aplicação + admin consent). |
| Módulo 1 com totais de usuários/grupos zerados | `$count` requer `Directory.Read.All` | O script faz fallback por paginação; se persistir, conceda `Directory.Read.All`. |
| Módulo 10 sem tokens Apple | Tenant sem APNs/ADE configurado | Comportamento esperado — endpoints retornam 404 e são suprimidos. |
| Apps sem números de instalação | `-SkipAppInstallStatus` usado, ou permissão `DeviceManagementApps.Read.All` ausente | Execute sem o switch / conceda a permissão. |
| `(grupo removido: <guid>)` em assignments | Grupo excluído do Entra ID após a atribuição | Achado legítimo: limpe a atribuição órfã no Intune. |

## Desempenho e throttling

| Sintoma | Causa | Solução |
|---------|-------|---------|
| Mensagens `Throttling (429)` recorrentes | Limites do Graph para o tenant | Normal — o script aguarda com backoff exponencial e continua. Em tenants muito grandes, execute fora do horário de pico. |
| Execução muito longa no Módulo 6 | 1 chamada `installSummary` por app | Use `-SkipAppInstallStatus`. |
| Execução longa no Módulo 7 | Lookup de detalhes por grupo | Esperado em ambientes com centenas de grupos atribuídos; o cache evita repetições. |

## Relatório HTML

| Sintoma | Causa | Solução |
|---------|-------|---------|
| Página em branco | Bloqueio de CDN (rede sem internet/proxy) | Abra em rede com acesso a `cdn.jsdelivr.net`, `cdn.datatables.net`, `code.jquery.com`, `cdnjs.cloudflare.com` e `fonts.googleapis.com`, ou hospede as libs localmente e ajuste o template. |
| Gráfico exibe "Sem dados para exibir" | Coleção vazia (permissão ou tenant sem o recurso) | Verifique o log do módulo correspondente. |
| Acentuação incorreta | Arquivo aberto com encoding errado por editor externo | O HTML é gravado em UTF-8; abra diretamente no navegador. |
| `Template HTML não encontrado` | `ReportTemplate.html` fora de `Modules\` | Restaure a estrutura de pastas original. |

## Exportação CSV/JSON

| Sintoma | Causa | Solução |
|---------|-------|---------|
| CSV com colunas `System.Object[]` | Editor/Excel interpretando arrays | Use o `.json` correspondente para estruturas aninhadas; os CSVs já excluem as coleções internas. |
| Excel exibindo acentos errados | Excel abrindo UTF-8 sem BOM (PS 5.1) | Importe via *Dados → De Texto/CSV → UTF-8*, ou execute com PowerShell 7. |

## Erros gerais

- **`File cannot be loaded because running scripts is disabled`** → ajuste a execution
  policy (INSTALL.md §3).
- **`Import-Module ... not found`** → execute o script a partir da raiz do projeto; os
  módulos são resolvidos relativos ao `.ps1`.
- **Execução interrompida no meio** → os CSV/JSON só são gravados ao final; reexecute.
  Falhas de um módulo individual não interrompem os demais (geram WARN).

## Suporte a diagnóstico

Para abrir um chamado interno, anexe:
1. O arquivo `.log` completo da execução;
2. A versão do PowerShell (`$PSVersionTable`);
3. O método de autenticação utilizado;
4. Saída de `Get-MgContext` (oculte dados sensíveis).
