#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Advanced Assessment & Reporting Tool
.DESCRIPTION
    Conecta ao Microsoft Graph, executa 13 módulos de coleta e análise do
    ambiente Microsoft Intune, calcula um Health Score, gera recomendações
    automáticas e produz:
      - Relatório HTML executivo/técnico interativo
      - Exportação completa dos dados brutos (CSV + JSON por módulo)
      - Log detalhado da execução
.PARAMETER AuthMethod
    Interactive (padrão) | DeviceCode | ClientSecret | Certificate
.PARAMETER TenantId
    ID ou domínio do tenant (obrigatório para ClientSecret/Certificate).
.PARAMETER ClientId
    Application (client) ID do App Registration (auth app-only).
.PARAMETER ClientSecret
    Segredo do App Registration (apenas para AuthMethod ClientSecret).
.PARAMETER CertificateThumbprint
    Thumbprint de certificado instalado localmente (AuthMethod Certificate).
.PARAMETER OutputPath
    Pasta de saída. Padrão: .\Output\<timestamp>
.PARAMETER SkipAppInstallStatus
    Pula a coleta de installSummary por aplicativo (acelera tenants com
    centenas de apps; o relatório omite os números de instalação).
.EXAMPLE
    .\Invoke-IntuneAssessment.ps1
    Execução interativa (browser) com todas as coletas.
.EXAMPLE
    .\Invoke-IntuneAssessment.ps1 -AuthMethod DeviceCode
.EXAMPLE
    .\Invoke-IntuneAssessment.ps1 -AuthMethod ClientSecret -TenantId contoso.com `
        -ClientId 11111111-2222-3333-4444-555555555555 -ClientSecret $env:IA_SECRET
.EXAMPLE
    .\Invoke-IntuneAssessment.ps1 -AuthMethod Certificate -TenantId contoso.com `
        -ClientId 1111... -CertificateThumbprint 'AB12CD34...'
.NOTES
    Requisitos : PowerShell 5.1+ (recomendado 7.x), Microsoft.Graph.Authentication
    Permissões : ver Docs\PERMISSIONS.md (somente leitura)
#>
[CmdletBinding()]
param(
    [ValidateSet('Interactive','DeviceCode','ClientSecret','Certificate')]
    [string]$AuthMethod = 'Interactive',
    [string]$TenantId,
    [string]$ClientId,
    [string]$ClientSecret,
    [string]$CertificateThumbprint,
    [string]$OutputPath,
    [switch]$SkipAppInstallStatus
)

$ErrorActionPreference = 'Stop'
$start = Get-Date

# ---------------------------------------------------------------- Setup
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

# Remove a marca "baixado da internet" (Mark of the Web) dos arquivos do projeto.
# Sem isso, políticas RemoteSigned/AllSigned bloqueiam os módulos .psm1 com
# "is not digitally signed". Operação local, sem privilégios de administrador.
try {
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        Unblock-File -ErrorAction SilentlyContinue
} catch { }

foreach ($m in 'IntuneAssessment.Core','IntuneAssessment.Collectors','IntuneAssessment.Analysis','IntuneAssessment.Report') {
    Import-Module (Join-Path (Join-Path $root 'Modules') "$m.psm1") -Force
}

if (-not $OutputPath) {
    $OutputPath = Join-Path (Join-Path $root 'Output') (Get-Date -Format 'yyyyMMdd_HHmmss')
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
Initialize-IALog -OutputFolder $OutputPath

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '  |      INTUNE ADVANCED ASSESSMENT + REPORTING TOOL         |' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host ''

# --------------------------------------------------------- 0. Conexão
Test-IAPrerequisites
$tenantInfo = Connect-IAGraph -AuthMethod $AuthMethod -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret -CertificateThumbprint $CertificateThumbprint

# --------------------------------------------------------- Execução dos módulos
# A ordem importa: dispositivos e apps alimentam módulos posteriores.
# Cada módulo roda isolado: uma falha gera ERROR no log e a execução continua
# com estrutura vazia equivalente, preservando o relatório dos demais módulos.
$Data = [ordered]@{}
$steps = 12; $i = 0
function Step([string]$msg){ $script:i++; Write-Progress -Id 1 -Activity 'Intune Assessment' -Status "[$script:i/$steps] $msg" -PercentComplete (($script:i/$steps)*100) }

function Invoke-IAStep {
    <# Executa um módulo com isolamento de falha. #>
    param([string]$Name, [scriptblock]$Action, $Fallback)
    try {
        # Captura a saída em variável: se o módulo falhar no meio, a saída
        # parcial é descartada (em vez de vazar para o resultado).
        $out = & $Action
        # Saída nula (ex.: coleção vazia "unrollada" pelo PowerShell) recebe o
        # fallback - evita nulos em cascata e registros fantasma na exportação.
        if ($null -eq $out) { $out = $Fallback }
        # A vírgula preserva arrays (inclusive vazios) através do return;
        # "return @()" sem ela retornaria $null e geraria registros fantasma.
        return ,$out
    }
    catch {
        Write-IALog "FALHA no $Name : $($_.Exception.Message). Prosseguindo com dados vazios para este módulo." -Level ERROR
        Write-IALog ("Posição exata: " + ($_.InvocationInfo.PositionMessage -replace "`r?`n", ' | ')) -Level ERROR
        Write-IALog ("Stack: " + ($_.ScriptStackTrace -replace "`r?`n", ' <- ')) -Level ERROR
        return ,$Fallback
    }
}

# Estruturas vazias com o mesmo formato dos coletores (fallbacks)
$fbCompliance = [PSCustomObject]@{
    Summary = [PSCustomObject]@{ Compliant=0; NonCompliant=0; InGracePeriod=0; NotEvaluated=0; Error=0; ByState=@() }
    FailureReasons=@(); CriticalDevices=@(); RankByPlatform=@(); RankByUser=@()
}
$fbItems4   = [PSCustomObject]@{ Items=@(); Unassigned=@(); Duplicates=@(); Stale=@() }
$fbItems3   = [PSCustomObject]@{ Items=@(); Unassigned=@(); Duplicates=@() }
$fbApps     = [PSCustomObject]@{ Items=@(); Unassigned=@(); FailureRanking=@(); HighFailure=@() }
$fbScripts  = [PSCustomObject]@{ Items=@(); Unassigned=@() }
$fbGroups   = [PSCustomObject]@{ Items=@(); Relationships=@{} }
$fbEnroll   = [PSCustomObject]@{ Restrictions=@(); AutopilotProfiles=@(); AppleADE=@(); AndroidProfiles=@() }
$fbAutopilot= [PSCustomObject]@{ Items=@(); NoProfile=@(); Orphans=@() }
$fbSecurity = [PSCustomObject]@{ Items=@(); Unassigned=@(); Categories=@(); MissingCategories=@() }

try {
    Step 'Módulo 2 - Inventário de dispositivos'
    $Data.Devices = Invoke-IAStep 'Módulo 2 (Dispositivos)' { @(Get-IAManagedDevices) } @()

    Step 'Módulo 3 - Compliance assessment'
    $Data.Compliance = Invoke-IAStep 'Módulo 3 (Compliance)' { Get-IAComplianceAssessment -Devices $Data.Devices } $fbCompliance

    Step 'Módulo 4 - Políticas de conformidade'
    $Data.CompliancePolicies = Invoke-IAStep 'Módulo 4 (Políticas de Conformidade)' { Get-IACompliancePolicies } $fbItems4

    Step 'Módulo 5 - Configuration profiles'
    $Data.ConfigProfiles = Invoke-IAStep 'Módulo 5 (Configuration Profiles)' { Get-IAConfigurationProfiles } $fbItems3

    Step 'Módulo 6 - Aplicativos'
    if ($SkipAppInstallStatus) { Write-IALog 'SkipAppInstallStatus ativo: installSummary não será coletado.' -Level WARN }
    $Data.Applications = Invoke-IAStep 'Módulo 6 (Aplicativos)' { Get-IAApplications -SkipInstallStatus:$SkipAppInstallStatus } $fbApps

    Step 'Módulo 12 - Scripts e remediações'
    $Data.Scripts = Invoke-IAStep 'Módulo 12 (Scripts)' { Get-IAScriptsAndRemediations } $fbScripts

    Step 'Módulo 7 - Grupos'
    $Data.Groups = Invoke-IAStep 'Módulo 7 (Grupos)' { Get-IAGroups -CompliancePolicies $Data.CompliancePolicies `
        -ConfigProfiles $Data.ConfigProfiles -Applications $Data.Applications -Scripts $Data.Scripts } $fbGroups

    Step 'Módulo 8 - Enrollment'
    $Data.Enrollment = Invoke-IAStep 'Módulo 8 (Enrollment)' { Get-IAEnrollment } $fbEnroll

    Step 'Módulo 9 - Windows Autopilot'
    $Data.Autopilot = Invoke-IAStep 'Módulo 9 (Autopilot)' { Get-IAAutopilotDevices -AutopilotProfiles $Data.Enrollment.AutopilotProfiles `
        -ManagedDevices $Data.Devices } $fbAutopilot

    Step 'Módulo 10 - Tokens e conectores'
    $Data.Tokens = Invoke-IAStep 'Módulo 10 (Tokens)' { @(Get-IATokensAndConnectors) } @()

    Step 'Módulo 11 - Segurança'
    $Data.Security = Invoke-IAStep 'Módulo 11 (Segurança)' { Get-IASecurityPolicies } $fbSecurity

    Step 'Módulo 13 - Relacionamentos'
    $Data.Relationships = Invoke-IAStep 'Módulo 13 (Relacionamentos)' { @(Get-IARelationshipMap -CompliancePolicies $Data.CompliancePolicies `
        -ConfigProfiles $Data.ConfigProfiles -Applications $Data.Applications `
        -Scripts $Data.Scripts -SecurityPolicies $Data.Security) } @()
}
finally { Write-Progress -Id 1 -Activity 'Intune Assessment' -Completed }

# --------------------------------------------------------- Módulo 1 (consolida totais)
$policyCount = @($Data.CompliancePolicies.Items).Count + @($Data.ConfigProfiles.Items).Count + @($Data.Security.Items).Count
$Data.Overview = Invoke-IAStep 'Módulo 1 (Visão Geral)' {
    Get-IAOverview -TenantInfo $tenantInfo -Devices $Data.Devices -Apps $Data.Applications.Items -PolicyCount $policyCount
} ([PSCustomObject]@{
    TenantName=$tenantInfo.TenantName; TenantId=$tenantInfo.TenantId; Domains=($tenantInfo.Domains -join '; ')
    TotalDevices=@($Data.Devices).Count; TotalUsers=0; TotalGroups=0
    TotalApps=@($Data.Applications.Items).Count; TotalPolicies=[int]$policyCount; ExecutedAt=$tenantInfo.ExecutedAt
})

# --------------------------------------------------------- Análise
Write-IALog 'Calculando Health Score e recomendações...' -Level INFO
$Data.HealthScore = Invoke-IAStep 'Health Score' { Get-IAHealthScore -Data $Data } `
    ([PSCustomObject]@{ Score=0; Rating='Indisponível'; Pillars=@(); Justification='Falha no cálculo do score (ver log).' })
$Data.Recommendations = Invoke-IAStep 'Recomendações' { @(Get-IARecommendations -Data $Data) } @()
Write-IALog ("Health Score: {0}/100 ({1}) | {2} recomendações geradas." -f `
    $Data.HealthScore.Score, $Data.HealthScore.Rating, @($Data.Recommendations).Count) -Level SUCCESS

# --------------------------------------------------------- Exportação
try { Export-IARawData -Data $Data -OutputFolder $OutputPath }
catch { Write-IALog "Falha na exportação de dados brutos: $($_.Exception.Message)" -Level ERROR }

$reportPath = '(não gerado)'
try { $reportPath = Export-IAReport -Data $Data -OutputFolder $OutputPath }
catch { Write-IALog "Falha na geração do relatório HTML: $($_.Exception.Message)" -Level ERROR }

# --------------------------------------------------------- Resumo final
$elapsed = (Get-Date) - $start
Write-Host ''
Write-Host '  -------------------- RESUMO DA EXECUÇÃO --------------------' -ForegroundColor Cyan
Write-Host ("   Tenant            : {0} ({1})" -f $tenantInfo.TenantName, $tenantInfo.DefaultDomain)
Write-Host ("   Dispositivos      : {0}" -f $Data.Overview.TotalDevices)
Write-Host ("   Aplicativos       : {0}" -f $Data.Overview.TotalApps)
Write-Host ("   Políticas/Perfis  : {0}" -f $Data.Overview.TotalPolicies)
Write-Host ("   Health Score      : {0}/100 ({1})" -f $Data.HealthScore.Score, $Data.HealthScore.Rating) -ForegroundColor Yellow
Write-Host ("   Recomendações     : {0}" -f @($Data.Recommendations).Count)
Write-Host ("   Tempo de execução : {0:mm\:ss}" -f $elapsed)
Write-Host ("   Saída             : {0}" -f $OutputPath)
Write-Host ("   Relatório HTML    : {0}" -f $reportPath) -ForegroundColor Green
Write-Host '  -------------------------------------------------------------'
Write-Host ''

# Abre o relatório automaticamente quando em sessão interativa Windows
if ($AuthMethod -in 'Interactive','DeviceCode' -and $env:OS -like '*Windows*' -and (Test-Path $reportPath)) {
    try { Start-Process $reportPath } catch {}
}

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Write-IALog 'Assessment concluído.' -Level SUCCESS
