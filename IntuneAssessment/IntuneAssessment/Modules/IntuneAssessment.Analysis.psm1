<#
================================================================================
 IntuneAssessment.Analysis.psm1
--------------------------------------------------------------------------------
 - Health Score do ambiente (0-100, ponderado por 6 pilares)
 - Recomendações automáticas com severidade e impacto
================================================================================
#>

function Get-IAHealthScore {
    <#
      Score 0-100 calculado por pilar, com pesos:
        Compliance 30 | Tokens 15 | Segurança 20 | Aplicativos 15 | Políticas 10 | Enrollment 10
      Cada pilar gera nota 0-100; o score final é a média ponderada.
    #>
    param($Data)

    $pillars = @()

    # ---- 1. Compliance (peso 30) ----------------------------------------
    $c = $Data.Compliance.Summary
    $evaluated = $c.Compliant + $c.NonCompliant + $c.InGracePeriod + $c.Error
    $compScore = if ($evaluated -gt 0) { [math]::Round(($c.Compliant / $evaluated) * 100) } else { 50 }
    # Penalidade para dispositivos jamais avaliados (>20% do parque)
    $totalDev = @($Data.Devices).Count
    if ($totalDev -gt 0 -and ($c.NotEvaluated / $totalDev) -gt 0.2) { $compScore = [math]::Max(0, $compScore - 15) }
    $pillars += [PSCustomObject]@{ Pillar='Compliance'; Weight=30; Score=$compScore
        Detail="$($c.Compliant) de $evaluated dispositivos avaliados estão conformes; $($c.NotEvaluated) sem avaliação." }

    # ---- 2. Tokens e conectores (peso 15) --------------------------------
    $tokens = @($Data.Tokens)
    $tokenScore = 100
    foreach ($t in $tokens) {
        switch ($t.Color) {
            'red'    { $tokenScore -= 40 }
            'orange' { $tokenScore -= 20 }
            'yellow' { $tokenScore -= 10 }
        }
    }
    $tokenScore = [math]::Max(0, $tokenScore)
    $pillars += [PSCustomObject]@{ Pillar='Tokens e Conectores'; Weight=15; Score=$tokenScore
        Detail="$(@($tokens | Where-Object Color -eq 'red').Count) expirados, $(@($tokens | Where-Object Color -in 'orange','yellow').Count) próximos da expiração." }

    # ---- 3. Segurança (peso 20) -------------------------------------------
    $sec = $Data.Security
    $secScore = 100
    $secScore -= (@($sec.MissingCategories).Count * 15)                        # categorias essenciais ausentes
    if (@($sec.Items).Count -gt 0) {
        $secScore -= [math]::Round((@($sec.Unassigned).Count / @($sec.Items).Count) * 30)
    } else { $secScore = 30 }                                                  # nenhuma política de segurança
    $secScore = [math]::Max(0, $secScore)
    $pillars += [PSCustomObject]@{ Pillar='Segurança'; Weight=20; Score=$secScore
        Detail="$(@($sec.Items).Count) políticas; ausentes: $(if($sec.MissingCategories){$sec.MissingCategories -join ', '}else{'nenhuma'})." }

    # ---- 4. Aplicativos (peso 15) ------------------------------------------
    $apps = $Data.Applications
    $appScore = 100
    if (@($apps.Items).Count -gt 0) {
        $appScore -= [math]::Min(40, @($apps.HighFailure).Count * 8)           # apps com falha >= 30%
        $appScore -= [math]::Min(20, [math]::Round((@($apps.Unassigned).Count / @($apps.Items).Count) * 20))
    }
    $appScore = [math]::Max(0, $appScore)
    $pillars += [PSCustomObject]@{ Pillar='Aplicativos'; Weight=15; Score=$appScore
        Detail="$(@($apps.HighFailure).Count) apps com falha >=30%; $(@($apps.Unassigned).Count) sem atribuição." }

    # ---- 5. Políticas e perfis (peso 10) -----------------------------------
    $polTotal = @($Data.CompliancePolicies.Items).Count + @($Data.ConfigProfiles.Items).Count
    $polUnassigned = @($Data.CompliancePolicies.Unassigned).Count + @($Data.ConfigProfiles.Unassigned).Count
    $polDupes = @($Data.CompliancePolicies.Duplicates).Count + @($Data.ConfigProfiles.Duplicates).Count
    $polScore = 100
    if ($polTotal -gt 0) {
        $polScore -= [math]::Round(($polUnassigned / $polTotal) * 50)
        $polScore -= [math]::Min(20, $polDupes * 2)
    }
    $polScore = [math]::Max(0, $polScore)
    $pillars += [PSCustomObject]@{ Pillar='Políticas e Perfis'; Weight=10; Score=$polScore
        Detail="$polUnassigned de $polTotal objetos sem atribuição; $polDupes possíveis duplicidades." }

    # ---- 6. Enrollment (peso 10) -------------------------------------------
    $enr = $Data.Enrollment; $ap = $Data.Autopilot
    $enrScore = 100
    $enrScore -= [math]::Min(30, @($ap.NoProfile).Count * 3)                  # devices Autopilot sem perfil
    $enrScore -= [math]::Min(20, @($ap.Orphans).Count * 2)
    $apUnassigned = @($enr.AutopilotProfiles | Where-Object { -not $_.HasAssignment }).Count
    $enrScore -= ($apUnassigned * 10)
    $enrScore = [math]::Max(0, $enrScore)
    $pillars += [PSCustomObject]@{ Pillar='Enrollment'; Weight=10; Score=$enrScore
        Detail="$(@($ap.NoProfile).Count) dispositivos Autopilot sem perfil; $(@($ap.Orphans).Count) órfãos." }

    # ---- Score final ---------------------------------------------------------
    $final = [math]::Round((($pillars | ForEach-Object { $_.Score * $_.Weight } | Measure-Object -Sum).Sum) / 100)
    $rating = if ($final -ge 85) { 'Excelente' } elseif ($final -ge 70) { 'Bom' }
              elseif ($final -ge 50) { 'Atenção Necessária' } else { 'Crítico' }

    [PSCustomObject]@{
        Score = $final
        Rating = $rating
        Pillars = $pillars
        Justification = "Score ponderado: " + (($pillars | ForEach-Object { "$($_.Pillar)=$($_.Score) (peso $($_.Weight)%)" }) -join '; ')
    }
}

function Get-IARecommendations {
    <#
      Gera recomendações automáticas a partir dos achados.
      Severidades: Crítico, Alto, Médio, Baixo
    #>
    param($Data)
    $recs = New-Object System.Collections.Generic.List[object]

    function Add-Rec ($Severity, $Area, $Finding, $Impact, $Recommendation) {
        $recs.Add([PSCustomObject]@{
            Severity = $Severity; Area = $Area; Finding = $Finding
            Impact = $Impact; Recommendation = $Recommendation
        })
    }

    # --- Compliance --------------------------------------------------------
    $nc = $Data.Compliance.Summary.NonCompliant
    if ($nc -gt 0) {
        Add-Rec 'Alto' 'Compliance' "Existem $nc dispositivos sem conformidade." `
            'Dispositivos não conformes podem ser bloqueados por Acesso Condicional ou representar risco de segurança.' `
            'Analisar os principais motivos de falha no Módulo 3, priorizando os dispositivos críticos (não conformes + sem check-in há 30 dias).'
    }
    $ne = $Data.Compliance.Summary.NotEvaluated
    if ($ne -gt 0 -and @($Data.Devices).Count -gt 0 -and ($ne / @($Data.Devices).Count) -gt 0.1) {
        Add-Rec 'Médio' 'Compliance' "$ne dispositivos sem avaliação de conformidade." `
            'Sem avaliação, não há garantia da postura de segurança desses dispositivos.' `
            'Garantir que todas as plataformas possuam ao menos uma política de conformidade atribuída e revisar dispositivos sem sincronização.'
    }
    $crit = @($Data.Compliance.CriticalDevices).Count
    if ($crit -gt 0) {
        Add-Rec 'Crítico' 'Compliance' "$crit dispositivos não conformes sem check-in há mais de 30 dias." `
            'Dispositivos abandonados podem conter dados corporativos sem proteção ativa.' `
            'Executar ações de retire/wipe ou re-enrollment para dispositivos inativos; avaliar regras de limpeza automática de dispositivos.'
    }

    # --- Tokens --------------------------------------------------------------
    foreach ($t in @($Data.Tokens)) {
        if ($t.Color -eq 'red' -and $t.ExpirationDate) {
            Add-Rec 'Crítico' 'Tokens' "$($t.Name) está EXPIRADO." `
                'Tokens expirados interrompem gerenciamento e distribuição de apps para a plataforma associada.' `
                'Renovar imediatamente o token/certificado no portal correspondente (Apple Business Manager / Intune).'
        }
        elseif ($t.Color -eq 'orange') {
            Add-Rec 'Alto' 'Tokens' "$($t.Name) expira em $($t.DaysRemaining) dias." `
                'A expiração causará perda de gerenciamento dos dispositivos/apps dependentes.' `
                'Agendar a renovação com o mesmo Apple ID/conta original antes do vencimento.'
        }
        elseif ($t.Color -eq 'yellow') {
            Add-Rec 'Médio' 'Tokens' "$($t.Name) expira em $($t.DaysRemaining) dias." `
                'Janela de renovação se aproximando.' `
                'Planejar renovação nos próximos ciclos de manutenção.'
        }
    }

    # --- Aplicativos ------------------------------------------------------------
    $hf = @($Data.Applications.HighFailure).Count
    if ($hf -gt 0) {
        Add-Rec 'Alto' 'Aplicativos' "$hf aplicativos apresentam falhas de instalação acima de 30%." `
            'Falhas recorrentes afetam produtividade e geram chamados de suporte.' `
            'Revisar logs de instalação (IME), requisitos, regras de detecção e dependências dos apps listados no ranking de falhas.'
    }
    $ua = @($Data.Applications.Unassigned).Count
    if ($ua -gt 0) {
        Add-Rec 'Baixo' 'Aplicativos' "$ua aplicativos sem nenhuma atribuição." `
            'Objetos órfãos dificultam a governança do ambiente.' `
            'Remover ou arquivar aplicativos que não são mais utilizados.'
    }

    # --- Políticas/Perfis ---------------------------------------------------------
    $pu = @($Data.CompliancePolicies.Unassigned).Count + @($Data.ConfigProfiles.Unassigned).Count
    if ($pu -gt 0) {
        Add-Rec 'Médio' 'Políticas' "Existem $pu políticas/perfis sem atribuição." `
            'Políticas não atribuídas não produzem efeito e poluem o ambiente.' `
            'Atribuir aos grupos corretos ou remover os objetos não utilizados.'
    }
    $dupes = @($Data.CompliancePolicies.Duplicates).Count + @($Data.ConfigProfiles.Duplicates).Count
    if ($dupes -gt 0) {
        Add-Rec 'Baixo' 'Políticas' "$dupes objetos com nomes potencialmente duplicados." `
            'Duplicidade pode gerar conflitos de configuração e resultados imprevisíveis.' `
            'Consolidar políticas duplicadas e padronizar nomenclatura (ex.: PRD-WIN-Compliance-Base).'
    }
    $stale = @($Data.CompliancePolicies.Stale).Count
    if ($stale -gt 0) {
        Add-Rec 'Baixo' 'Políticas' "$stale políticas sem alteração há mais de 12 meses." `
            'Políticas antigas podem não refletir os requisitos atuais de segurança.' `
            'Revisar e revalidar as políticas potencialmente obsoletas.'
    }

    # --- Segurança ------------------------------------------------------------------
    # (Não geramos recomendações prescritivas do tipo "categoria X ausente" - apenas
    #  achados derivados de dados reais do relatório. A ausência de categorias continua
    #  visível como informação no Módulo 11, sem virar recomendação.)
    $su = @($Data.Security.Unassigned).Count
    if ($su -gt 0) {
        Add-Rec 'Médio' 'Segurança' "$su políticas de segurança sem atribuição." `
            'Políticas de segurança não atribuídas não protegem nenhum dispositivo.' `
            'Atribuir as políticas aos grupos de dispositivos apropriados.'
    }

    # --- Enrollment / Autopilot -------------------------------------------------------
    $np = @($Data.Autopilot.NoProfile).Count
    if ($np -gt 0) {
        Add-Rec 'Médio' 'Autopilot' "$np dispositivos Autopilot sem perfil de implantação atribuído." `
            'Dispositivos sem perfil passarão por OOBE padrão, fora do fluxo corporativo.' `
            'Revisar atribuição dos Deployment Profiles (grupos dinâmicos por Group Tag são recomendados).'
    }
    $orph = @($Data.Autopilot.Orphans).Count
    if ($orph -gt 0) {
        Add-Rec 'Baixo' 'Autopilot' "$orph dispositivos Autopilot órfãos (registrados, nunca enrolados)." `
            'Registros órfãos podem indicar hardware substituído ou inventário desatualizado.' `
            'Limpar registros de hardware que não pertencem mais à organização.'
    }

    # --- Criptografia --------------------------------------------------------------------
    $unencrypted = @($Data.Devices | Where-Object { $_.PlatformFamily -eq 'Windows' -and $_.IsEncrypted -eq $false }).Count
    if ($unencrypted -gt 0) {
        Add-Rec 'Alto' 'Segurança' "$unencrypted dispositivos Windows sem criptografia de disco." `
            'Dados corporativos em repouso ficam expostos em caso de perda ou roubo.' `
            'Implantar política de BitLocker via Endpoint Security > Disk Encryption.'
    }

    if ($recs.Count -eq 0) {
        Add-Rec 'Baixo' 'Geral' 'Nenhum problema relevante identificado.' `
            'O ambiente apresenta boa postura de gerenciamento.' `
            'Manter revisões periódicas (trimestral) do assessment.'
    }

    $order = @{ 'Crítico'=0; 'Alto'=1; 'Médio'=2; 'Baixo'=3 }
    return @($recs | Sort-Object { $order[$_.Severity] })
}

Export-ModuleMember -Function @('Get-IAHealthScore', 'Get-IARecommendations')