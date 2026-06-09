# Permissões Microsoft Graph

A ferramenta é **100% somente leitura**: nenhuma operação de escrita é executada no tenant.
Única exceção de *consentimento* (não de comportamento): `DeviceManagementConfiguration.ReadWrite.All`,
que a Microsoft exige até para **ler** scripts e Proactive Remediations (o GET retorna 403 com `Read.All`).

## Escopos delegados (Interactive / DeviceCode)

| Escopo | Usado por |
|--------|-----------|
| `DeviceManagementManagedDevices.Read.All` | Módulos 2, 3 (dispositivos, compliance por dispositivo) |
| `DeviceManagementConfiguration.Read.All` | Módulos 4, 5, 8, 11 (políticas, perfis, enrollment, segurança) |
| `DeviceManagementConfiguration.ReadWrite.All` | Módulo 12 (scripts e Proactive Remediations). **Exigência da Microsoft**: esses endpoints retornam 403 com `Read.All`, mesmo para leitura (GET). A ferramenta não executa nenhuma escrita — o escopo serve apenas para o Graph autorizar a listagem. |
| `DeviceManagementApps.Read.All` | Módulo 6 e 10 (apps, installSummary, VPP tokens) |
| `DeviceManagementServiceConfig.Read.All` | Módulos 8, 9, 10 (Autopilot, APNs, ADE, conectores) |
| `DeviceManagementRBAC.Read.All` | Leitura de metadados administrativos |
| `Group.Read.All` | Módulo 7 e resolução de nomes em assignments |
| `User.Read.All` | Contagem de usuários e dados do usuário primário |
| `Organization.Read.All` | Nome do tenant e domínios verificados |
| `Directory.Read.All` | Contagens `$count` (requer ConsistencyLevel) |

No primeiro login, um administrador pode precisar conceder consentimento
(individual ou em nome da organização).

## Permissões de aplicação (ClientSecret / Certificate)

Adicione as permissões **Application** equivalentes no App Registration e conceda
**Grant admin consent**:

- `DeviceManagementManagedDevices.Read.All`
- `DeviceManagementConfiguration.Read.All`
- `DeviceManagementConfiguration.ReadWrite.All` (obrigatório para LER scripts/remediações — ver nota acima)
- `DeviceManagementApps.Read.All`
- `DeviceManagementServiceConfig.Read.All`
- `DeviceManagementRBAC.Read.All`
- `Group.Read.All`
- `User.Read.All`
- `Organization.Read.All`
- `Directory.Read.All`

## Roles do Entra ID suficientes para o modo delegado

Qualquer uma das opções abaixo atende:

- **Intune Administrator** (leitura completa do Intune)
- **Global Reader** + consentimento dos escopos delegados
- Conta padrão, desde que um Global Admin tenha consentido os escopos para o app
  `Microsoft Graph Command Line Tools`

## Comportamento com permissões parciais

Se algum escopo estiver ausente, o script **não falha**: registra um WARN no log,
o endpoint afetado retorna 401/403 e o módulo correspondente aparece vazio no
relatório. Verifique o `.log` na pasta de saída para identificar o escopo faltante.
