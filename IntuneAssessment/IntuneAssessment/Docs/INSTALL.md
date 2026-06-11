# Guia de Instalação

## 1. Pré-requisitos

| Requisito | Detalhe |
|-----------|---------|
| PowerShell | 5.1 (Windows) ou 7.x (recomendado, multiplataforma) |
| Módulo | `Microsoft.Graph.Authentication` (instalado automaticamente se ausente) |
| Rede | Acesso HTTPS a `graph.microsoft.com` e `login.microsoftonline.com` |
| Conta | Conta com permissões de leitura do Intune (ver `PERMISSIONS.md`) |

> A ferramenta usa exclusivamente `Invoke-MgGraphRequest` (REST). Não é necessário
> instalar o SDK completo `Microsoft.Graph` (~40 submódulos).

## 2. Instalação do módulo de autenticação (opcional — o script instala sozinho)

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
```

Em ambientes sem acesso à PowerShell Gallery, baixe o pacote em uma máquina com
internet e copie para `$env:USERPROFILE\Documents\PowerShell\Modules`:

```powershell
Save-Module Microsoft.Graph.Authentication -Path C:\Temp\Modules
```

## 3. Política de execução

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
# ou, para uma única sessão:
powershell.exe -ExecutionPolicy Bypass -File .\Invoke-IntuneAssessment.ps1
```

Preferencialmente execute via `Run-IntuneAssessment.cmd`, que dispensa este passo.
Se optar por rodar o `.ps1` diretamente e o ZIP foi baixado da internet, desbloqueie os arquivos:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

## 4. Estrutura de pastas

Extraia o projeto mantendo a estrutura — o script principal localiza os módulos
em `.\Modules\` relativo a ele próprio:

```
C:\Tools\IntuneAssessment\
├── Invoke-IntuneAssessment.ps1
└── Modules\
    ├── IntuneAssessment.Core.psm1
    ├── IntuneAssessment.Collectors.psm1
    ├── IntuneAssessment.Analysis.psm1
    ├── IntuneAssessment.Report.psm1
    └── ReportTemplate.html
```

## 5. (Opcional) App Registration para execução não interativa

Necessário apenas para os métodos `ClientSecret` ou `Certificate` (automação/agendamento):

1. **Entra ID → App registrations → New registration** (ex.: `Intune-Assessment-Reader`).
2. **API permissions → Microsoft Graph → Application permissions**: adicione as
   permissões listadas em `PERMISSIONS.md` e conceda **admin consent**.
3. Credencial:
   - **Client Secret**: *Certificates & secrets → New client secret* (anote o valor), **ou**
   - **Certificado**: faça upload do `.cer` público; o certificado com chave privada deve
     estar no repositório local da máquina de execução (`Cert:\CurrentUser\My`).

Exemplo de certificado autoassinado para testes:

```powershell
$cert = New-SelfSignedCertificate -Subject 'CN=IntuneAssessment' `
    -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy NonExportable `
    -KeySpec Signature -KeyLength 2048 -NotAfter (Get-Date).AddYears(2)
Export-Certificate -Cert $cert -FilePath C:\Temp\IntuneAssessment.cer   # upload no App Registration
$cert.Thumbprint                                                        # usar em -CertificateThumbprint
```

## 6. Validação da instalação

```powershell
cd C:\Tools\IntuneAssessment
.\Invoke-IntuneAssessment.ps1 -AuthMethod Interactive
```

Se o banner aparecer e o login do Microsoft Graph for solicitado, a instalação está correta.
