<#
================================================================================
 IntuneAssessment.Report.psm1
--------------------------------------------------------------------------------
 - Export-IARawData : exporta dados brutos por módulo (CSV + JSON)
 - Export-IAReport  : injeta o JSON consolidado no template HTML
================================================================================
#>

function Export-IARawData {
    <#
      Exporta cada coleção em CSV e JSON dentro de OutputFolder\RawData.
      Nomes de arquivo seguem o padrão pedido: Devices.csv, Apps.csv, etc.
    #>
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)][string]$OutputFolder
    )
    $raw = Join-Path $OutputFolder 'RawData'
    New-Item -ItemType Directory -Path $raw -Force | Out-Null

    # Encoding: no PS 5.1, 'UTF8' já grava BOM; no PS 7+, 'utf8BOM' garante que o
    # Excel pt-BR abra os CSVs com acentuação correta.
    $enc = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }

    # Propriedades de coleção interna que não fazem sentido em CSV
    $exclude = 'GroupsIncluded','GroupsExcluded'

    $sets = [ordered]@{
        'Devices'            = $Data.Devices
        'Compliance'         = $Data.Compliance.FailureReasons
        'ComplianceCritical' = $Data.Compliance.CriticalDevices
        'Policies'           = $Data.CompliancePolicies.Items
        'Profiles'           = $Data.ConfigProfiles.Items
        'Apps'               = $Data.Applications.Items
        'Groups'             = $Data.Groups.Items
        'Enrollment'         = $Data.Enrollment.Restrictions
        'Autopilot'          = $Data.Autopilot.Items
        'Tokens'             = $Data.Tokens
        'Security'           = $Data.Security.Items
        'Scripts'            = $Data.Scripts.Items
        'Relationships'      = $Data.Relationships
        'Recommendations'    = $Data.Recommendations
    }

    foreach ($name in $sets.Keys) {
        $items = @($sets[$name])
        try {
            $flat = $items | Select-Object -Property * -ExcludeProperty $exclude
            $flat | Export-Csv -Path (Join-Path $raw "$name.csv") -NoTypeInformation -Encoding $enc
            $items | ConvertTo-Json -Depth 6 | Out-File (Join-Path $raw "$name.json") -Encoding $enc
            Write-IALog "Exportado: RawData/$name.csv / .json ($($items.Count) registros)" -Level INFO
        }
        catch {
            Write-IALog "Falha exportando $name : $($_.Exception.Message)" -Level WARN
        }
    }
    Write-IALog "Dados brutos exportados em $raw" -Level SUCCESS
}

function Export-IAReport {
    <#
      Gera o relatório HTML final.
      Estratégia: o template (ReportTemplate.html) contém o placeholder
      __REPORT_DATA__ que recebe um JSON único com todos os dados - a
      renderização (gráficos, tabelas, score) acontece no navegador.
    #>
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)][string]$OutputFolder,
        [string]$TemplatePath = (Join-Path $PSScriptRoot 'ReportTemplate.html')
    )

    if (-not (Test-Path $TemplatePath)) { throw "Template HTML não encontrado: $TemplatePath" }
    Write-IALog "Gerando relatório HTML..." -Level INFO

    # ---- Monta o payload consumido pelo JavaScript do template -------------
    # Contagens pré-calculadas evitam custo no navegador e arrays gigantes duplicados.
    # Projeção enxuta SÓ para o HTML (reduz o peso do arquivo): apenas os campos
    # exibidos no relatório. Os dados completos permanecem no RawData (Devices.csv/.json).
    # Lista de colunas como array (em vez de "Select-Object a,b,c") para clareza.
    $devCols = 'DeviceName','Platform','PlatformFamily','Model','OSVersion','UserPrincipalName','ComplianceState','IsEncrypted','LastCheckIn','SerialNumber'
    $devicesLite  = @($Data.Devices | Select-Object $devCols)
    $criticalLite = @($Data.Compliance.CriticalDevices | Select-Object $devCols)

    $payload = [ordered]@{
        Overview = $Data.Overview
        HealthScore = $Data.HealthScore
        Recommendations = @($Data.Recommendations)
        Devices = $devicesLite
        Compliance = [ordered]@{
            Summary         = $Data.Compliance.Summary
            FailureReasons  = @($Data.Compliance.FailureReasons)
            CriticalDevices = $criticalLite
            RankByPlatform  = @($Data.Compliance.RankByPlatform)
            RankByUser      = @($Data.Compliance.RankByUser)
        }
        CompliancePolicies = [ordered]@{
            Items = @($Data.CompliancePolicies.Items | Select-Object * -ExcludeProperty GroupsIncluded)
            UnassignedCount = @($Data.CompliancePolicies.Unassigned).Count
            DuplicateCount  = @($Data.CompliancePolicies.Duplicates).Count
            StaleCount      = @($Data.CompliancePolicies.Stale).Count
        }
        ConfigProfiles = [ordered]@{
            Items = @($Data.ConfigProfiles.Items | Select-Object * -ExcludeProperty GroupsIncluded)
            UnassignedCount = @($Data.ConfigProfiles.Unassigned).Count
            DuplicateCount  = @($Data.ConfigProfiles.Duplicates).Count
        }
        Applications = [ordered]@{
            Items = @($Data.Applications.Items | Select-Object * -ExcludeProperty GroupsIncluded)
            FailureRanking   = @($Data.Applications.FailureRanking | Select-Object * -ExcludeProperty GroupsIncluded)
            UnassignedCount  = @($Data.Applications.Unassigned).Count
            HighFailureCount = @($Data.Applications.HighFailure).Count
            StatusUnavailableCount = [int]$Data.Applications.StatusUnavailableCount
        }
        Groups = @($Data.Groups.Items)
        Enrollment = [ordered]@{
            Restrictions    = @($Data.Enrollment.Restrictions)
            AndroidProfiles = @($Data.Enrollment.AndroidProfiles)
        }
        Autopilot = [ordered]@{
            Items = @($Data.Autopilot.Items)
            NoProfileCount = @($Data.Autopilot.NoProfile).Count
            OrphanCount    = @($Data.Autopilot.Orphans).Count
        }
        Tokens = @($Data.Tokens)
        Security = [ordered]@{
            Items = @($Data.Security.Items)
            Categories = @($Data.Security.Categories)
            UnassignedCount   = @($Data.Security.Unassigned).Count
            MissingCategories = @($Data.Security.MissingCategories)
        }
        Scripts = @($Data.Scripts.Items | Select-Object * -ExcludeProperty GroupsIncluded)
        Relationships = @($Data.Relationships)
    }

    # ConvertTo-Json: datas em ISO 8601 para o JavaScript (new Date()) entender
    $json = $payload | ConvertTo-Json -Depth 10 -Compress
    # PowerShell 5.1 serializa DateTime como "\/Date(...)\/" em alguns cenários - normaliza:
    $json = [regex]::Replace($json, '"\\/Date\((\d+)\)\\/"', {
        param($m)
        '"' + ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$m.Groups[1].Value).ToString('yyyy-MM-ddTHH:mm:ssZ')) + '"'
    })
    # Evita fechamento prematuro da tag <script> caso algum nome contenha "</script>"
    $json = $json -replace '</script', '<\/script'

    $template = Get-Content -Path $TemplatePath -Raw -Encoding UTF8
    $html = $template.Replace('__REPORT_DATA__', $json)

    $reportPath = Join-Path $OutputFolder ("IntuneAssessment_Report_{0}.html" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $enc = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
    $html | Out-File -FilePath $reportPath -Encoding $enc

    Write-IALog "Relatório HTML gerado: $reportPath" -Level SUCCESS
    return $reportPath
}

Export-ModuleMember -Function @('Export-IARawData', 'Export-IAReport')