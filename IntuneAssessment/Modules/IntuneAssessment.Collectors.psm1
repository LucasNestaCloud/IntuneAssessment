<#
================================================================================
 IntuneAssessment.Collectors.psm1
--------------------------------------------------------------------------------
 Implementa os 13 módulos de coleta do assessment. Cada função:
   - Consulta o Microsoft Graph (v1.0 quando possível, beta quando necessário)
   - Normaliza os dados em PSCustomObjects "flat" (prontos para CSV/HTML)
   - Nunca lança exceção fatal: falhas parciais geram WARN e coleção vazia
================================================================================
#>

$GraphV1   = 'https://graph.microsoft.com/v1.0'
$GraphBeta = 'https://graph.microsoft.com/beta'

# Cache de grupos para resolução de assignments (id -> displayName)
$script:GroupCache = @{}

function Resolve-IAGroupName {
    <# Resolve o nome de um grupo a partir do ID, com cache para reduzir chamadas. #>
    param([string]$GroupId)
    if ([string]::IsNullOrWhiteSpace($GroupId)) { return '' }
    if ($script:GroupCache.ContainsKey($GroupId)) { return $script:GroupCache[$GroupId] }
    $g = Invoke-IAGraphRequest -Uri "$GraphV1/groups/$GroupId`?`$select=id,displayName" -SuppressNotFound
    $name = [string]$(if ($g -and $g.displayName) { $g.displayName } else { "(grupo removido: $GroupId)" })
    $script:GroupCache[$GroupId] = $name
    return $name
}

function ConvertTo-IAAssignmentSummary {
    <#
      Converte o array "assignments" do Graph em um resumo legível:
      grupos incluídos, excluídos, alvos especiais (All Users / All Devices) e filtros.

      NOTA (PS 5.1): parâmetro [object[]] e acumuladores List[string] tipados
      estabilizam os tipos vistos pelo binder dinâmico do Windows PowerShell,
      prevenindo o erro intermitente "Os tipos de argumento não correspondem"
      (ArgumentException) em funções compiladas após ~16 invocações.
    #>
    param([object[]]$Assignments = @())
    $included = New-Object 'System.Collections.Generic.List[string]'
    $excluded = New-Object 'System.Collections.Generic.List[string]'
    $filters  = New-Object 'System.Collections.Generic.List[string]'

    foreach ($a in @($Assignments)) {
        try {
            if ($null -eq $a) { continue }
            $t = $a.target
            if ($null -eq $t) { continue }
            $odata = [string]$t.'@odata.type'
            switch -Wildcard ($odata) {
                '*allLicensedUsersAssignmentTarget'   { $included.Add('Todos os usuários') }
                '*allDevicesAssignmentTarget'         { $included.Add('Todos os dispositivos') }
                '*exclusionGroupAssignmentTarget'     { $excluded.Add([string](Resolve-IAGroupName ([string]$t.groupId))) }
                '*groupAssignmentTarget'              { $included.Add([string](Resolve-IAGroupName ([string]$t.groupId))) }
            }
            if ($t.deviceAndAppManagementAssignmentFilterId) {
                $filters.Add("$($t.deviceAndAppManagementAssignmentFilterId) ($($t.deviceAndAppManagementAssignmentFilterType))")
            }
        }
        catch {
            Write-IALog "Assignment ignorado (formato inesperado): $($_.Exception.Message)" -Level WARN
        }
    }
    $incU = @($included | Select-Object -Unique)
    $excU = @($excluded | Select-Object -Unique)
    $fltU = @($filters  | Select-Object -Unique)
    [PSCustomObject]@{
        Included       = $incU -join '; '
        Excluded       = $excU -join '; '
        Filters        = $fltU -join '; '
        HasAssignment  = [bool]($incU.Count -gt 0 -or $excU.Count -gt 0)
        GroupsIncluded = $incU
        GroupsExcluded = $excU
    }
}

# ============================================================ MÓDULO 1: VISÃO GERAL
function Get-IAOverview {
    param($TenantInfo, $Devices, $Apps, $PolicyCount)
    Write-IALog "[Módulo 1] Consolidando visão geral do ambiente..." -Level INFO

    # Contagem via "$count=true" + @odata.count: o endpoint /$count puro devolve
    # text/plain, que o Invoke-MgGraphRequest -OutputType Json rejeita
    # ("Non-Json response ... '-OutputFilePath'"). $count=true devolve JSON.
    $countHeaders = @{ ConsistencyLevel = 'eventual' }
    $uResp = Invoke-IAGraphRequest -Uri "$GraphV1/users?`$select=id&`$count=true&`$top=1"  -Headers $countHeaders -SuppressNotFound
    $gResp = Invoke-IAGraphRequest -Uri "$GraphV1/groups?`$select=id&`$count=true&`$top=1" -Headers $countHeaders -SuppressNotFound
    $userCount  = if ($uResp) { $uResp.'@odata.count' } else { $null }
    $groupCount = if ($gResp) { $gResp.'@odata.count' } else { $null }
    # Fallback: se o tenant bloquear advanced queries, conta por paginação
    if (-not ($userCount -is [int] -or $userCount -is [long] -or "$userCount" -match '^\d+$')) {
        $userCount = (Get-IAGraphCollection -Uri "$GraphV1/users?`$select=id&`$top=999" -Activity "Contando usuários").Count
    }
    if (-not ($groupCount -is [int] -or $groupCount -is [long] -or "$groupCount" -match '^\d+$')) {
        $groupCount = (Get-IAGraphCollection -Uri "$GraphV1/groups?`$select=id&`$top=999" -Activity "Contando grupos").Count
    }

    [PSCustomObject]@{
        TenantName   = $TenantInfo.TenantName
        TenantId     = $TenantInfo.TenantId
        Domains      = $TenantInfo.Domains -join '; '
        TotalDevices = @($Devices).Count
        TotalUsers   = [int]$userCount
        TotalGroups  = [int]$groupCount
        TotalApps    = @($Apps).Count
        TotalPolicies= [int]$PolicyCount
        ExecutedAt   = $TenantInfo.ExecutedAt
    }
}

# ===================================================== MÓDULO 2: DISPOSITIVOS
function Get-IAManagedDevices {
    Write-IALog "[Módulo 2] Coletando inventário completo de dispositivos..." -Level INFO

    # beta traz campos adicionais (ex.: hardwareInformation em alguns cenários)
    $raw = Get-IAGraphCollection -Uri "$GraphBeta/deviceManagement/managedDevices?`$top=1000" `
                                 -Activity "Coletando dispositivos gerenciados"

    $devices = foreach ($d in $raw) { try {
        # Classificação de plataforma (Windows 10/11, macOS, iOS, Android, Linux...)
        $os  = $d.operatingSystem
        $ver = $d.osVersion
        $platform = switch -Wildcard ($os) {
            'Windows*' {
                # Server APENAS por sinais explícitos (nome do SO ou SKU). O número
                # de build NÃO distingue: 26100 é Windows 11 24H2 E Server 2025.
                if ($os -like '*Server*' -or $d.skuFamily -like '*Server*' -or $d.deviceType -like '*server*') {
                    'Windows Server'
                }
                elseif ($ver -match '^10\.0\.(2[2-9]\d{3}|[3-9]\d{4})') { 'Windows 11' }  # build >= 22000
                elseif ($ver -match '^10\.0\.1\d{4}')                   { 'Windows 10' }  # builds 10240-19045
                else                                                     { 'Windows (outro)' }
            }
            'macOS' { 'macOS' }
            'iOS'   { if ($d.model -like '*iPad*') { 'iPad' } else { 'iPhone' } }
            'iPadOS'{ 'iPad' }
            'Android' {
                if ($d.deviceEnrollmentType -match 'androidEnterprise|AndroidEnterprise' -or
                    $d.managementAgent -match 'googleCloudDevicePolicyController') { 'Android Enterprise' } else { 'Android' }
            }
            'Linux*' { 'Linux' }
            default  { if ($os) { $os } else { 'Outros' } }
        }
        $family = switch ($platform) {
            { $_ -like 'Windows*' }            { 'Windows' }
            { $_ -in 'macOS','iPhone','iPad' } { 'Apple' }
            { $_ -like 'Android*' }            { 'Google' }
            'Linux'                            { 'Linux' }
            default                            { 'Outros' }
        }

        # 1073741824 = 1GB (bytes -> GB)
        $storageTotalGB = if ($d.totalStorageSpaceInBytes) { [math]::Round($d.totalStorageSpaceInBytes / 1073741824, 1) } else { $null }
        $storageFreeGB  = if ($d.freeStorageSpaceInBytes)  { [math]::Round($d.freeStorageSpaceInBytes / 1073741824, 1) }  else { $null }

        [PSCustomObject]@{
            DeviceName       = $d.deviceName
            DeviceId         = $d.id
            AzureAdDeviceId  = $d.azureADDeviceId
            SerialNumber     = $d.serialNumber
            Manufacturer     = $d.manufacturer
            Model            = $d.model
            OperatingSystem  = $os
            OSVersion        = $ver
            Platform         = $platform
            PlatformFamily   = $family
            Ownership        = $d.managedDeviceOwnerType      # company / personal
            EnrollmentType   = $d.deviceEnrollmentType
            JoinType         = $d.joinType
            ComplianceState  = $d.complianceState             # compliant / noncompliant / inGracePeriod / unknown / error / configManager
            ManagementState  = $d.managementState
            ManagementAgent  = $d.managementAgent
            LastCheckIn      = ConvertTo-IASafeDate $d.lastSyncDateTime
            EnrollmentDate   = ConvertTo-IASafeDate $d.enrolledDateTime
            PrimaryUser      = $d.userDisplayName
            UserEmail        = $d.emailAddress
            UserPrincipalName= $d.userPrincipalName
            DeviceCategory   = $d.deviceCategoryDisplayName
            StorageTotalGB   = $storageTotalGB
            StorageFreeGB    = $storageFreeGB
            IsEncrypted      = $d.isEncrypted
            DefenderState    = $d.windowsProtectionState.realTimeProtectionEnabled
            JailBroken       = $d.jailBroken
        }
        } catch { Write-IALog "Dispositivo ignorado (dados inesperados): $($_.Exception.Message)" -Level WARN }
    }
    Write-IALog "[Módulo 2] $(@($devices).Count) dispositivos coletados." -Level SUCCESS
    # A vírgula preserva o array (inclusive vazio) através do unroll do return;
    # sem ela, 0 dispositivos retornaria $null e quebraria os módulos seguintes.
    return ,@($devices)
}

# ====================================================== MÓDULO 3: COMPLIANCE
function Get-IAComplianceAssessment {
    # Sem [Mandatory]: tenant com 0 dispositivos gera assessment vazio, não erro.
    param([object[]]$Devices = @())
    Write-IALog "[Módulo 3] Executando compliance assessment..." -Level INFO

    $byState = $Devices | Group-Object ComplianceState
    $summary = [PSCustomObject]@{
        Compliant     = @($Devices | Where-Object ComplianceState -eq 'compliant').Count
        NonCompliant  = @($Devices | Where-Object ComplianceState -eq 'noncompliant').Count
        InGracePeriod = @($Devices | Where-Object ComplianceState -eq 'inGracePeriod').Count
        NotEvaluated  = @($Devices | Where-Object { $_.ComplianceState -in 'unknown',$null,'' }).Count
        Error         = @($Devices | Where-Object ComplianceState -eq 'error').Count
        ByState       = $byState | ForEach-Object { [PSCustomObject]@{ State = $_.Name; Count = $_.Count } }
    }

    # Motivos de não conformidade por configuração (relatório agregado - beta)
    $reasons = @()
    $settingStates = Get-IAGraphCollection `
        -Uri "$GraphBeta/deviceManagement/deviceCompliancePolicySettingStateSummaries" `
        -Activity "Coletando motivos de não conformidade" -SuppressNotFound
    foreach ($s in $settingStates) {
        if ($s.nonCompliantDeviceCount -gt 0 -or $s.errorDeviceCount -gt 0) {
            $reasons += [PSCustomObject]@{
                Setting            = ($s.settingName -replace '^.*\.', '')
                Platform           = $s.platformType
                NonCompliantCount  = $s.nonCompliantDeviceCount
                ErrorCount         = $s.errorDeviceCount
                ConflictCount      = $s.conflictDeviceCount
            }
        }
    }

    # Dispositivos críticos: não conformes + sem check-in há mais de 30 dias
    $cutoff = (Get-Date).AddDays(-30)
    $critical = $Devices | Where-Object {
        $_.ComplianceState -eq 'noncompliant' -and $_.LastCheckIn -and $_.LastCheckIn -lt $cutoff
    }

    # Ranking de não conformidade por plataforma e por usuário
    $byPlatform = $Devices | Where-Object ComplianceState -eq 'noncompliant' |
        Group-Object Platform | Sort-Object Count -Descending |
        ForEach-Object { [PSCustomObject]@{ Platform = $_.Name; Count = $_.Count } }
    $byUser = $Devices | Where-Object { $_.ComplianceState -eq 'noncompliant' -and $_.UserPrincipalName } |
        Group-Object UserPrincipalName | Sort-Object Count -Descending | Select-Object -First 20 |
        ForEach-Object { [PSCustomObject]@{ User = $_.Name; Count = $_.Count } }

    Write-IALog "[Módulo 3] Compliance: $($summary.Compliant) conformes / $($summary.NonCompliant) não conformes." -Level SUCCESS
    [PSCustomObject]@{
        Summary          = $summary
        FailureReasons   = $reasons | Sort-Object NonCompliantCount -Descending
        CriticalDevices  = @($critical)
        RankByPlatform   = @($byPlatform)
        RankByUser       = @($byUser)
    }
}

# ============================================ MÓDULO 4: POLÍTICAS DE CONFORMIDADE
function Get-IACompliancePolicies {
    Write-IALog "[Módulo 4] Coletando políticas de conformidade..." -Level INFO
    $raw = Get-IAGraphCollection `
        -Uri "$GraphBeta/deviceManagement/deviceCompliancePolicies?`$expand=assignments" `
        -Activity "Coletando compliance policies"

    $items = foreach ($p in $raw) { try {
        $asg = ConvertTo-IAAssignmentSummary @($p.assignments)
        [PSCustomObject]@{
            Name           = $p.displayName
            Id             = $p.id
            Platform       = ($p.'@odata.type' -replace '#microsoft.graph.|CompliancePolicy','')
            CreatedDate    = ConvertTo-IASafeDate $p.createdDateTime
            LastModified   = ConvertTo-IASafeDate $p.lastModifiedDateTime
            AssignedGroups = $asg.Included
            ExcludedGroups = $asg.Excluded
            Filters        = $asg.Filters
            HasAssignment  = $asg.HasAssignment
            GroupsIncluded = $asg.GroupsIncluded
        }
        } catch { Write-IALog "Política ignorado (dados inesperados): $($_.Exception.Message)" -Level WARN }
    }
    $items = @($items)

    # Análises: sem atribuição, duplicadas (mesmo nome base), obsoletas (>12 meses sem alteração)
    $unassigned = @($items | Where-Object { -not $_.HasAssignment })
    $dupes      = @($items | Group-Object { ($_.Name -replace '\s*[-_]?\s*(copy|cópia|copia|v?\d+)\s*$','').Trim().ToLower() } |
                    Where-Object Count -gt 1 | ForEach-Object { $_.Group })
    $stale      = @($items | Where-Object { $_.LastModified -and $_.LastModified -lt (Get-Date).AddMonths(-12) })

    Write-IALog "[Módulo 4] $($items.Count) políticas ($($unassigned.Count) sem atribuição)." -Level SUCCESS
    [PSCustomObject]@{ Items = $items; Unassigned = $unassigned; Duplicates = $dupes; Stale = $stale }
}

# ============================================ MÓDULO 5: CONFIGURATION PROFILES
function Get-IAConfigurationProfiles {
    Write-IALog "[Módulo 5] Coletando configuration profiles..." -Level INFO
    $all = New-Object System.Collections.Generic.List[object]

    # 5a. Perfis clássicos (templates)
    $classic = Get-IAGraphCollection `
        -Uri "$GraphBeta/deviceManagement/deviceConfigurations?`$expand=assignments" `
        -Activity "Coletando device configurations"
    foreach ($p in $classic) { try {
        $asg = ConvertTo-IAAssignmentSummary @($p.assignments)
        $all.Add([PSCustomObject]@{
            Name = $p.displayName; Id = $p.id
            Type = ($p.'@odata.type' -replace '#microsoft.graph.','')
            Source = 'Template (clássico)'
            Platform = ($p.'@odata.type' -replace '#microsoft.graph.|Configuration|GeneralDevice|CustomC.*','' )
            CreatedDate = ConvertTo-IASafeDate $p.createdDateTime
            LastModified = ConvertTo-IASafeDate $p.lastModifiedDateTime
            AssignedGroups = $asg.Included; ExcludedGroups = $asg.Excluded
            Filters = $asg.Filters; HasAssignment = $asg.HasAssignment
            GroupsIncluded = $asg.GroupsIncluded
        })
        } catch { Write-IALog "Perfil ignorado (dados inesperados): $($_.Exception.Message)" -Level WARN }
    }

    # 5b. Settings Catalog (configurationPolicies - apenas beta)
    $catalog = Get-IAGraphCollection `
        -Uri "$GraphBeta/deviceManagement/configurationPolicies?`$expand=assignments" `
        -Activity "Coletando settings catalog" -SuppressNotFound
    foreach ($p in $catalog) { try {
        $asg = ConvertTo-IAAssignmentSummary @($p.assignments)
        $all.Add([PSCustomObject]@{
            Name = $p.name; Id = $p.id
            Type = 'Settings Catalog'
            Source = 'Settings Catalog'
            Platform = $p.platforms
            CreatedDate = ConvertTo-IASafeDate $p.createdDateTime
            LastModified = ConvertTo-IASafeDate $p.lastModifiedDateTime
            AssignedGroups = $asg.Included; ExcludedGroups = $asg.Excluded
            Filters = $asg.Filters; HasAssignment = $asg.HasAssignment
            GroupsIncluded = $asg.GroupsIncluded
        })
        } catch { Write-IALog "Perfil ignorado (dados inesperados): $($_.Exception.Message)" -Level WARN }
    }

    # 5c. Administrative Templates (Group Policy / ADMX)
    $gpo = Get-IAGraphCollection `
        -Uri "$GraphBeta/deviceManagement/groupPolicyConfigurations?`$expand=assignments" `
        -Activity "Coletando administrative templates" -SuppressNotFound
    foreach ($p in $gpo) { try {
        $asg = ConvertTo-IAAssignmentSummary @($p.assignments)
        $all.Add([PSCustomObject]@{
            Name = $p.displayName; Id = $p.id
            Type = 'Administrative Template (ADMX)'
            Source = 'Group Policy'
            Platform = 'windows10'
            CreatedDate = ConvertTo-IASafeDate $p.createdDateTime
            LastModified = ConvertTo-IASafeDate $p.lastModifiedDateTime
            AssignedGroups = $asg.Included; ExcludedGroups = $asg.Excluded
            Filters = $asg.Filters; HasAssignment = $asg.HasAssignment
            GroupsIncluded = $asg.GroupsIncluded
        })
        } catch { Write-IALog "Perfil ignorado (dados inesperados): $($_.Exception.Message)" -Level WARN }
    }

    $items      = $all.ToArray()
    $unassigned = @($items | Where-Object { -not $_.HasAssignment })
    $dupes      = @($items | Group-Object { ($_.Name -replace '\s*[-_]?\s*(copy|cópia|copia|v?\d+)\s*$','').Trim().ToLower() } |
                    Where-Object Count -gt 1 | ForEach-Object { $_.Group })

    Write-IALog "[Módulo 5] $($items.Count) perfis ($($unassigned.Count) sem atribuição)." -Level SUCCESS
    [PSCustomObject]@{ Items = $items; Unassigned = $unassigned; Duplicates = $dupes }
}

# ===================================================== MÓDULO 6: APLICATIVOS
function Get-IAAppInstallSummaryReport {
    <#
      Status de instalação de TODOS os apps em uma única fonte: a API de relatórios
      do Intune (getAppsInstallSummaryReport) - a MESMA que o portal usa na tela
      "Status de instalação do app".

      Esse endpoint responde como OctetStream (anexo) e NÃO como JSON, então o
      -OutputType Json do SDK falha ("Please specify -OutputFilePath"). Aqui
      gravamos a resposta em arquivo temporário, descomprimimos se vier em gzip,
      e parseamos o JSON. Retorna mapas indexados por ApplicationId e por nome.
    #>
    param([string]$ReportUri = "$GraphBeta/deviceManagement/reports/getAppsInstallSummaryReport")
    $byId = @{}; $byName = @{}
    $skip = 0; $top = 50; $guard = 0
    try {
        while ($true) {
            $guard++; if ($guard -gt 200) { break }   # trava de segurança

            # --- baixa uma página do relatório para arquivo temporário ---
            # caminho temporário sem pré-criar o arquivo (alguns -OutputFilePath não sobrescrevem)
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ia_apprep_" + [guid]::NewGuid().ToString('N') + ".json")
            $text = $null
            try {
                $bodyJson = (@{ skip = $skip; top = $top } | ConvertTo-Json -Compress)
                $attempt = 0
                while ($true) {
                    $attempt++
                    try {
                        Invoke-MgGraphRequest -Method POST -Uri $ReportUri -Body $bodyJson `
                            -ContentType 'application/json' -OutputFilePath $tmp -ErrorAction Stop
                        break
                    }
                    catch {
                        $m = $_.Exception.Message
                        $st = if ($m -match '\b(4\d\d|5\d\d)\b') { [int]$Matches[1] } else { 0 }
                        if (($st -eq 429 -or $st -ge 500) -and $attempt -lt 4) {
                            Start-Sleep -Seconds ([math]::Pow(2, $attempt)); continue
                        }
                        throw
                    }
                }

                $bytes = [System.IO.File]::ReadAllBytes($tmp)
                if (-not $bytes -or $bytes.Length -eq 0) { break }
                # Descomprime se for gzip (magic bytes 1F 8B); senão lê como UTF-8
                if ($bytes.Length -ge 2 -and $bytes[0] -eq 0x1f -and $bytes[1] -eq 0x8b) {
                    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
                    $ms = New-Object System.IO.MemoryStream(, $bytes)
                    $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
                    $sr = New-Object System.IO.StreamReader($gz, [System.Text.Encoding]::UTF8)
                    $text = $sr.ReadToEnd(); $sr.Dispose(); $gz.Dispose(); $ms.Dispose()
                }
                else {
                    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
                }
            }
            finally {
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            }

            if ([string]::IsNullOrWhiteSpace($text)) { break }
            $resp = ConvertFrom-IAJson $text
            $schema = @($resp.Schema)
            $values = @($resp.Values)
            if ($schema.Count -eq 0 -or $values.Count -eq 0) { break }

            # índice das colunas por nome (tolerante a variações entre versões da API)
            $col = @{}
            for ($i = 0; $i -lt $schema.Count; $i++) {
                $name = if ($schema[$i].Column) { [string]$schema[$i].Column } else { [string]$schema[$i].column }
                if ($name) { $col[$name] = $i }
            }
            $get = {
                param($row, [string[]]$names)
                foreach ($n in $names) { if ($col.ContainsKey($n)) { $v = $row[$col[$n]]; if ($null -ne $v -and $v -ne '') { return [int]$v } } }
                return 0
            }
            $idCol   = @('ApplicationId', 'AppId') | Where-Object { $col.ContainsKey($_) } | Select-Object -First 1
            $nameCol = @('DisplayName', 'ApplicationName', 'Name') | Where-Object { $col.ContainsKey($_) } | Select-Object -First 1

            foreach ($row in $values) {
                $counts = [PSCustomObject]@{
                    Installed     = (& $get $row @('InstalledDeviceCount'))      + (& $get $row @('InstalledUserCount'))
                    Failed        = (& $get $row @('FailedDeviceCount'))         + (& $get $row @('FailedUserCount'))
                    Pending       = (& $get $row @('PendingInstallDeviceCount')) + (& $get $row @('PendingInstallUserCount'))
                    NotInstalled  = (& $get $row @('NotInstalledDeviceCount'))   + (& $get $row @('NotInstalledUserCount'))
                    NotApplicable = (& $get $row @('NotApplicableDeviceCount'))  + (& $get $row @('NotApplicableUserCount'))
                }
                if ($idCol)   { $id = [string]$row[$col[$idCol]];   if ($id)   { $byId[$id] = $counts } }
                if ($nameCol) { $nm = [string]$row[$col[$nameCol]]; if ($nm)   { $byName[$nm] = $counts } }
            }

            $total = [int]$resp.TotalRowCount
            $skip += $top
            if ($values.Count -lt $top -or ($total -gt 0 -and $skip -ge $total)) { break }
        }
        if ($byId.Count -or $byName.Count) {
            Write-IALog "Status de instalacao obtido via relatorio do Intune: $([math]::Max($byId.Count,$byName.Count)) apps." -Level INFO
        }
    }
    catch {
        Write-IALog "Relatorio getAppsInstallSummaryReport indisponivel ($($_.Exception.Message)). Usando installSummary por app como alternativa." -Level WARN
    }
    return [PSCustomObject]@{ ById = $byId; ByName = $byName }
}

function Get-IAApplications {
    param([switch]$SkipInstallStatus)   # acelera tenants com centenas de apps
    Write-IALog "[Módulo 6] Coletando inventário de aplicativos..." -Level INFO
    $raw = Get-IAGraphCollection -Uri "$GraphBeta/deviceAppManagement/mobileApps?`$expand=assignments&`$top=999" `
                                 -Activity "Coletando aplicativos"
    if (-not $raw -or @($raw).Count -eq 0) {
        Write-IALog "Graph retornou 0 aplicativos em deviceAppManagement/mobileApps. Se o tenant possui apps, verifique a permissão DeviceManagementApps.Read.All e a role Intune da conta." -Level WARN
    }

    # Fonte primária do status de instalação: relatório do Intune (1 chamada p/ todos).
    $installReport = if ($SkipInstallStatus) { [PSCustomObject]@{ ById = @{}; ByName = @{} } } else { Get-IAAppInstallSummaryReport }

    $typeMap = @{
        'win32LobApp'='Win32'; 'winGetApp'='Microsoft Store (novo)'; 'microsoftStoreForBusinessApp'='Microsoft Store (legado)'
        'officeSuiteApp'='Microsoft 365 Apps'; 'windowsMicrosoftEdgeApp'='Microsoft Edge'
        'androidManagedStoreApp'='Android (Managed Play)'; 'androidStoreApp'='Android'; 'androidLobApp'='Android LOB'
        'iosStoreApp'='iOS'; 'iosVppApp'='iOS VPP'; 'iosLobApp'='iOS LOB'
        'macOSLobApp'='macOS LOB'; 'macOSMicrosoftEdgeApp'='macOS Edge'; 'macOSOfficeSuiteApp'='macOS Office'
        'macOsVppApp'='macOS VPP'; 'macOSPkgApp'='macOS PKG'; 'macOSDmgApp'='macOS DMG'
        'webApp'='Web App'; 'windowsWebApp'='Web App'; 'managedIOSStoreApp'='iOS (MAM)'; 'managedAndroidStoreApp'='Android (MAM)'
    }

    $total = @($raw).Count; $i = 0
    $items = foreach ($a in $raw) { try {
        $i++
        Write-Progress -Activity "Processando aplicativos" -Status "$i de $total - $($a.displayName)" `
                       -PercentComplete (($i/$total)*100)
        $odType = $a.'@odata.type' -replace '#microsoft.graph.',''
        $cat    = if ($typeMap.ContainsKey($odType)) { $typeMap[$odType] } else { $odType }
        $asg    = ConvertTo-IAAssignmentSummary @($a.assignments)

        # Status de instalação: primeiro o relatório do Intune (fonte do portal);
        # se o app não estiver no relatório, tenta installSummary (beta -> v1.0);
        # se nada retornar, marca INDISPONÍVEL (não zero), para nunca exibir um
        # app com erro como "sem erro".
        $rep  = $installReport.ById[$a.id]
        if (-not $rep -and $a.displayName) { $rep = $installReport.ByName[[string]$a.displayName] }
        $inst = $null
        if (-not $rep -and -not $SkipInstallStatus) {
            $inst = Invoke-IAGraphRequest -Uri "$GraphBeta/deviceAppManagement/mobileApps/$($a.id)/installSummary" -SuppressNotFound
            if (-not $inst) { $inst = Invoke-IAGraphRequest -Uri "$GraphV1/deviceAppManagement/mobileApps/$($a.id)/installSummary" -SuppressNotFound }
        }
        $statusOK = [bool]$rep -or [bool]$inst
        if ($rep) {
            $ok = [int]$rep.Installed; $fail = [int]$rep.Failed; $pending = [int]$rep.Pending; $na = [int]$rep.NotApplicable
            $denom = $ok + $fail
            $failPct = if ($denom -gt 0) { [math]::Round(($fail / $denom) * 100, 1) } else { $null }
        }
        elseif ($inst) {
            $ok      = [int]($inst.installedDeviceCount)      + [int]($inst.installedUserCount)
            $fail    = [int]($inst.failedDeviceCount)         + [int]($inst.failedUserCount)
            $pending = [int]($inst.pendingInstallDeviceCount) + [int]($inst.pendingInstallUserCount)
            $na      = [int]($inst.notApplicableDeviceCount)  + [int]($inst.notApplicableUserCount)
            $denom   = $ok + $fail
            $failPct = if ($denom -gt 0) { [math]::Round(($fail / $denom) * 100, 1) } else { $null }
        }
        else {
            $ok = $null; $fail = $null; $pending = $null; $na = $null; $failPct = $null
            if (-not $SkipInstallStatus) { Write-IALog "Status de instalacao indisponivel para o app '$($a.displayName)'." -Level WARN }
        }

        [PSCustomObject]@{
            Name = $a.displayName; Id = $a.id
            Publisher = $a.publisher
            Type = $cat
            Platform = $(switch -Wildcard ($cat) {
                'Win32' {'Windows'}; 'Microsoft*' {'Windows'}; '*Edge*' {'Multi'}
                'Android*' {'Android'}; 'iOS*' {'iOS'}; 'macOS*' {'macOS'}; 'Web App' {'Web'}; default {'Outro'}
            })
            CreatedDate = ConvertTo-IASafeDate $a.createdDateTime
            InstallSuccess = $ok; InstallFailed = $fail; InstallPending = $pending; NotApplicable = $na
            FailurePct = $failPct; StatusAvailable = $statusOK
            AssignedGroups = $asg.Included; ExcludedGroups = $asg.Excluded; Filters = $asg.Filters
            HasAssignment = $asg.HasAssignment
            GroupsIncluded = $asg.GroupsIncluded
        }
        } catch { Write-IALog "Aplicativo ignorado (dados inesperados): $($_.Exception.Message)" -Level WARN }
    }
    Write-Progress -Activity "Processando aplicativos" -Completed

    $items = @($items)
    $unassigned  = @($items | Where-Object { -not $_.HasAssignment })
    $statusNA    = @($items | Where-Object { -not $_.StatusAvailable })
    $failRanking = @($items | Where-Object { $_.InstallFailed -gt 0 } |
                     Sort-Object InstallFailed -Descending | Select-Object -First 15)
    $highFailure = @($items | Where-Object { $_.FailurePct -ge 30 })

    $naMsg = if ($statusNA.Count) { ", $($statusNA.Count) com status indisponível" } else { '' }
    Write-IALog "[Módulo 6] $($items.Count) aplicativos ($($unassigned.Count) sem atribuição, $($highFailure.Count) com falha >=30%$naMsg)." -Level SUCCESS
    [PSCustomObject]@{ Items = $items; Unassigned = $unassigned; FailureRanking = $failRanking; HighFailure = $highFailure; StatusUnavailableCount = $statusNA.Count }
}

# ========================================================== MÓDULO 7: GRUPOS
function Get-IAGroups {
    param($CompliancePolicies, $ConfigProfiles, $Applications, $Scripts)
    Write-IALog "[Módulo 7] Mapeando grupos utilizados pelo Intune..." -Level INFO

    # Universo: todos os grupos referenciados em assignments (já em cache) + lookup de detalhes
    # Inclui grupos atribuídos, grupos de EXCLUSÃO e os alvos virtuais do Intune
    # ("Todos os usuários"/"Todos os dispositivos"), para o mapa refletir o
    # ambiente real mesmo quando tudo é atribuído a alvos virtuais.
    $virtualTargets = @('Todos os usuários','Todos os dispositivos')
    $usedGroupNames = @{}
    foreach ($coll in @($CompliancePolicies.Items, $ConfigProfiles.Items, $Applications.Items, $Scripts.Items)) {
        foreach ($obj in @($coll)) {
            $refs = @()
            $refs += @($obj.GroupsIncluded) | ForEach-Object { if ($_) { [PSCustomObject]@{ Name = [string]$_; Mode = 'Inclusão' } } }
            $refs += @($obj.PSObject.Properties['GroupsExcluded'].Value) | ForEach-Object { if ($_) { [PSCustomObject]@{ Name = [string]$_; Mode = 'Exclusão' } } }
            foreach ($r in $refs) {
                $g = $r.Name
                if (-not $usedGroupNames.ContainsKey($g)) { $usedGroupNames[$g] = New-Object System.Collections.Generic.List[object] }
                $usedGroupNames[$g].Add([PSCustomObject]@{
                    ObjectName = "$($obj.Name)$(if ($r.Mode -eq 'Exclusão') { ' (exclusão)' })"
                    ObjectType = $obj.PSObject.Properties['Type'].Value
                })
            }
        }
    }

    $total = @($usedGroupNames.Keys).Count
    $idx = 0
    $items = foreach ($name in $usedGroupNames.Keys) {
        $idx++
        if ($idx % 50 -eq 0) { Write-IALog "[Módulo 7] Resolvendo grupos: $idx/$total..." -Level INFO }
        # Alvos virtuais do Intune não são grupos do Entra: linha própria, sem lookup
        if ($name -in $virtualTargets) {
            [PSCustomObject]@{
                GroupName = $name; GroupId = $null
                GroupType = 'Alvo virtual do Intune'; IsDynamic = $false; MemberCount = $null
                AssignedObjects = $usedGroupNames[$name].Count
                Objects = ($usedGroupNames[$name] | ForEach-Object { $_.ObjectName }) -join '; '
                Description = $(if ($name -eq 'Todos os dispositivos') { 'Alvo virtual do Intune: todos os dispositivos gerenciados pelo tenant.' } else { 'Alvo virtual do Intune: todos os usuários licenciados do tenant.' })
                CreatedDate = $null; Mail = $null; MembershipRule = $null
            }
            continue
        }
        try {
            # Detalhes do grupo pelo displayName (1 chamada). Escapa o filtro OData
            # inteiro: nomes com & # + % quebrariam a query string.
            $flt = [uri]::EscapeDataString("displayName eq '$($name -replace "'","''")'")
            $g = (Invoke-IAGraphRequest -Uri "$GraphV1/groups?`$filter=$flt&`$select=id,displayName,description,createdDateTime,mail,groupTypes,membershipRule,securityEnabled,mailEnabled" -SuppressNotFound).value | Select-Object -First 1
            $kind =
                if (-not $g)                              { 'Desconhecido' }
                elseif ($g.groupTypes -contains 'Unified'){ 'Microsoft 365' }
                elseif ($g.membershipRule)                { 'Dinâmico (Security)' }
                elseif ($g.securityEnabled)               { 'Security (Assigned)' }
                else                                      { 'Outro' }
            # Contagem de membros: APENAS a via leve $count (1 chamada). Sem enumerar
            # membros - enumerar centenas de grupos travava a execução em tenants grandes.
            # Se o $count não vier, MemberCount fica nulo (desconhecido).
            $members = $null
            if ($g) {
                $mResp = Invoke-IAGraphRequest -Uri "$GraphV1/groups/$($g.id)/members?`$select=id&`$count=true&`$top=1" `
                    -Headers @{ ConsistencyLevel = 'eventual' } -SuppressNotFound
                if ($mResp -and $null -ne $mResp.'@odata.count') { $members = [int]$mResp.'@odata.count' }
            }
            [PSCustomObject]@{
                GroupName     = $name
                GroupId       = $g.id
                GroupType     = $kind
                IsDynamic     = [bool]$g.membershipRule
                MemberCount   = $members
                AssignedObjects = $usedGroupNames[$name].Count
                Objects       = ($usedGroupNames[$name] | ForEach-Object { $_.ObjectName }) -join '; '
                Description   = $g.description
                CreatedDate   = ConvertTo-IASafeDate $g.createdDateTime
                Mail          = $g.mail
                MembershipRule = $g.membershipRule
            }
        }
        catch {
            Write-IALog "Grupo '$name' não pôde ser detalhado: $($_.Exception.Message)" -Level WARN
            [PSCustomObject]@{
                GroupName = $name; GroupId = $null; GroupType = 'Desconhecido'; IsDynamic = $false; MemberCount = $null
                AssignedObjects = $usedGroupNames[$name].Count
                Objects = ($usedGroupNames[$name] | ForEach-Object { $_.ObjectName }) -join '; '
                Description = $null; CreatedDate = $null; Mail = $null; MembershipRule = $null
            }
        }
    }
    $items = @($items | Sort-Object AssignedObjects -Descending)
    Write-IALog "[Módulo 7] $($items.Count) grupos mapeados." -Level SUCCESS
    [PSCustomObject]@{ Items = $items; Relationships = $usedGroupNames }
}

# ====================================================== MÓDULO 8: ENROLLMENT
function Get-IAEnrollment {
    Write-IALog "[Módulo 8] Coletando configurações de enrollment..." -Level INFO

    $configs = Get-IAGraphCollection `
        -Uri "$GraphBeta/deviceManagement/deviceEnrollmentConfigurations?`$expand=assignments" `
        -Activity "Coletando enrollment configurations" -SuppressNotFound
    $restrictions = foreach ($c in $configs) {
        $asg = ConvertTo-IAAssignmentSummary @($c.assignments)
        [PSCustomObject]@{
            Name = $c.displayName; Id = $c.id
            Type = ($c.'@odata.type' -replace '#microsoft.graph.deviceEnrollment|Configuration','')
            Priority = $c.priority
            LastModified = ConvertTo-IASafeDate $c.lastModifiedDateTime
            AssignedGroups = $asg.Included
            HasAssignment = ($asg.HasAssignment -or $c.priority -eq 0)  # priority 0 = default, aplica a todos
        }
    }

    $autopilotProfiles = Get-IAGraphCollection `
        -Uri "$GraphBeta/deviceManagement/windowsAutopilotDeploymentProfiles?`$expand=assignments" `
        -Activity "Coletando perfis Autopilot" -SuppressNotFound
    $apProfiles = foreach ($p in $autopilotProfiles) {
        $asg = ConvertTo-IAAssignmentSummary @($p.assignments)
        [PSCustomObject]@{
            Name = $p.displayName; Id = $p.id
            JoinType = $(if ($p.'@odata.type' -like '*HybridJoined*' -or $null -ne $p.hybridAzureADJoinSkipConnectivityCheck) { 'Hybrid Join' } else { 'Entra Join' })
            DeviceNameTemplate = $p.deviceNameTemplate
            LastModified = ConvertTo-IASafeDate $p.lastModifiedDateTime
            AssignedGroups = $asg.Included
            HasAssignment = $asg.HasAssignment
        }
    }

    $appleDep = Get-IAGraphCollection -Uri "$GraphBeta/deviceManagement/depOnboardingSettings" `
        -Activity "Verificando Apple ADE" -SuppressNotFound
    $androidProfiles = Get-IAGraphCollection -Uri "$GraphBeta/deviceManagement/androidDeviceOwnerEnrollmentProfiles" `
        -Activity "Coletando perfis Android Enterprise" -SuppressNotFound

    Write-IALog "[Módulo 8] $(@($restrictions).Count) configs / $(@($apProfiles).Count) perfis Autopilot." -Level SUCCESS
    [PSCustomObject]@{
        Restrictions      = @($restrictions)
        AutopilotProfiles = @($apProfiles)
        AppleADE          = @($appleDep)
        AndroidProfiles   = @($androidProfiles | ForEach-Object {
            [PSCustomObject]@{ Name = $_.displayName; EnrollmentMode = $_.enrollmentMode; EnrolledCount = $_.enrolledDeviceCount; TokenExpiry = ConvertTo-IASafeDate $_.tokenExpirationDateTime }
        })
    }
}

# ============================================= MÓDULO 9: WINDOWS AUTOPILOT
function Get-IAAutopilotDevices {
    param($AutopilotProfiles, $ManagedDevices)
    Write-IALog "[Módulo 9] Coletando dispositivos Windows Autopilot..." -Level INFO

    $raw = Get-IAGraphCollection `
        -Uri "$GraphBeta/deviceManagement/windowsAutopilotDeviceIdentities?`$top=1000" `
        -Activity "Coletando dispositivos Autopilot" -SuppressNotFound

    $managedSerials = @{}
    foreach ($d in @($ManagedDevices)) { if ($d.SerialNumber) { $managedSerials[$d.SerialNumber] = $true } }

    $items = foreach ($d in $raw) {
        [PSCustomObject]@{
            DisplayName      = $d.displayName
            SerialNumber     = $d.serialNumber
            Manufacturer     = $d.manufacturer
            Model            = $d.model
            GroupTag         = $d.groupTag
            AssignedProfile  = $d.deploymentProfileDisplayName
            ProfileStatus    = $d.deploymentProfileAssignmentStatus   # assigned* / notAssigned / pending / failed
            AssignedUser     = $d.userPrincipalName
            EnrollmentState  = $d.enrollmentState
            LastContact      = ConvertTo-IASafeDate $d.lastContactedDateTime
            IsManaged        = [bool]($d.serialNumber -and $managedSerials[[string]$d.serialNumber])
        }
    }
    $items = @($items)
    $noProfile = @($items | Where-Object { $_.ProfileStatus -notlike 'assigned*' })
    # Órfãos: registrados no Autopilot mas nunca enrolados / sem registro no Intune
    $orphans   = @($items | Where-Object { $_.EnrollmentState -ne 'enrolled' -and -not $_.IsManaged })

    Write-IALog "[Módulo 9] $($items.Count) dispositivos Autopilot ($($noProfile.Count) sem perfil, $($orphans.Count) órfãos)." -Level SUCCESS
    [PSCustomObject]@{ Items = $items; NoProfile = $noProfile; Orphans = $orphans }
}

# ====================================== MÓDULO 10: TOKENS E CONECTORES
function Get-IATokensAndConnectors {
    Write-IALog "[Módulo 10] Verificando tokens, certificados e conectores..." -Level INFO
    $items = New-Object System.Collections.Generic.List[object]

    function Add-Token {
        param($Name, $Category, $Expiry, $StatusOverride)
        $st = Get-IATokenStatus $Expiry
        $items.Add([PSCustomObject]@{
            Name = $Name; Category = $Category
            ExpirationDate = ConvertTo-IASafeDate $Expiry
            DaysRemaining  = $st.DaysRemaining
            Status = $(if ($StatusOverride) { $StatusOverride } else { $st.Status })
            Color  = $st.Color
        })
    }

    # Apple Push Notification Certificate (APNs / MDM Push)
    $apns = Invoke-IAGraphRequest -Uri "$GraphBeta/deviceManagement/applePushNotificationCertificate" -SuppressNotFound
    if ($apns) { Add-Token -Name "Apple MDM Push Certificate ($($apns.appleIdentifier))" -Category 'Apple' -Expiry $apns.expirationDateTime }

    # Apple Business Manager / ADE (DEP tokens)
    $dep = Get-IAGraphCollection -Uri "$GraphBeta/deviceManagement/depOnboardingSettings" -SuppressNotFound
    foreach ($t in $dep) { Add-Token -Name "Apple ADE Token: $($t.tokenName)" -Category 'Apple Business Manager' -Expiry $t.tokenExpirationDateTime }

    # Apple VPP Tokens
    $vpp = Get-IAGraphCollection -Uri "$GraphBeta/deviceAppManagement/vppTokens" -SuppressNotFound
    foreach ($t in $vpp) {
        $name = if ($t.displayName) { $t.displayName } else { $t.appleId }
        Add-Token -Name "VPP Token: $name" -Category 'Apple VPP' -Expiry $t.expirationDateTime `
                  -StatusOverride $(if ($t.state -ne 'valid') { "Estado: $($t.state)" })
    }

    # Managed Google Play / Android Enterprise
    $play = Invoke-IAGraphRequest -Uri "$GraphBeta/deviceManagement/androidManagedStoreAccountEnterpriseSettings" -SuppressNotFound
    if ($play -and $play.bindStatus) {
        $items.Add([PSCustomObject]@{
            Name = "Managed Google Play ($($play.ownerUserPrincipalName))"
            Category = 'Android Enterprise'
            ExpirationDate = $null; DaysRemaining = $null
            Status = $(if ($play.bindStatus -eq 'bound') { 'Vinculado' } else { $play.bindStatus })
            Color  = $(if ($play.bindStatus -eq 'bound') { 'green' } else { 'red' })
        })
    }

    # NDES / Certificate Connectors
    $certConn = Get-IAGraphCollection -Uri "$GraphBeta/deviceManagement/ndesConnectors" -SuppressNotFound
    foreach ($c in $certConn) {
        $items.Add([PSCustomObject]@{
            Name = "Certificate Connector: $($c.displayName)"; Category = 'Conector'
            ExpirationDate = $null; DaysRemaining = $null
            Status = $c.state; Color = $(if ($c.state -eq 'active') { 'green' } else { 'red' })
        })
    }

    # Mobile Threat Defense (inclui Defender for Endpoint)
    $mtd = Get-IAGraphCollection -Uri "$GraphBeta/deviceManagement/mobileThreatDefenseConnectors" -SuppressNotFound
    foreach ($c in $mtd) {
        $items.Add([PSCustomObject]@{
            Name = "MTD Connector: $($c.id)"; Category = 'Segurança'
            ExpirationDate = $null; DaysRemaining = $null
            Status = $c.partnerState; Color = $(if ($c.partnerState -in 'available','enabled') { 'green' } else { 'yellow' })
        })
    }

    Write-IALog "[Módulo 10] $($items.Count) tokens/conectores avaliados." -Level SUCCESS
    # ToArray(): conversão tipada, imune ao bug do binder do PS 5.1 com @(List)
    return ,$items.ToArray()
}

# ======================================================= MÓDULO 11: SEGURANÇA
function Get-IASecurityPolicies {
    Write-IALog "[Módulo 11] Coletando políticas de Endpoint Security..." -Level INFO
    $all = New-Object System.Collections.Generic.List[object]

    # Intents = Endpoint Security (AV, Firewall, Disk Encryption, ASR, EDR...) - legado/beta
    $intents = Get-IAGraphCollection -Uri "$GraphBeta/deviceManagement/intents" `
        -Activity "Coletando endpoint security policies" -SuppressNotFound
    foreach ($i in $intents) {
        $asgRaw = Get-IAGraphCollection -Uri "$GraphBeta/deviceManagement/intents/$($i.id)/assignments" -SuppressNotFound
        $asg = ConvertTo-IAAssignmentSummary @($asgRaw)
        $all.Add([PSCustomObject]@{
            Name = $i.displayName; Id = $i.id
            Category = 'Endpoint Security (Intent)'
            TemplateId = $i.templateId
            LastModified = ConvertTo-IASafeDate $i.lastModifiedDateTime
            AssignedGroups = $asg.Included; HasAssignment = $asg.HasAssignment
        })
    }

    # Security Baselines aparecem como templates/intents; novas políticas ES vivem em configurationPolicies
    $esPolicies = Get-IAGraphCollection `
        -Uri "$GraphBeta/deviceManagement/configurationPolicies?`$filter=templateReference/templateFamily ne 'none'&`$expand=assignments" `
        -Activity "Coletando políticas ES (settings catalog)" -SuppressNotFound
    foreach ($p in $esPolicies) {
        $fam = $p.templateReference.templateFamily
        if ($fam -like 'endpointSecurity*' -or $fam -like 'baseline*') {
            $asg = ConvertTo-IAAssignmentSummary @($p.assignments)
            $all.Add([PSCustomObject]@{
                Name = $p.name; Id = $p.id
                Category = $(switch -Wildcard ($fam) {
                    '*Antivirus*'        {'Antivirus'}
                    '*DiskEncryption*'   {'Disk Encryption'}
                    '*Firewall*'         {'Firewall'}
                    '*AttackSurface*'    {'Attack Surface Reduction'}
                    '*EndpointDetection*'{'EDR'}
                    'baseline*'          {'Security Baseline'}
                    default              {"Endpoint Security ($fam)"}
                })
                TemplateId = $p.templateReference.templateId
                LastModified = ConvertTo-IASafeDate $p.lastModifiedDateTime
                AssignedGroups = $asg.Included; HasAssignment = $asg.HasAssignment
            })
        }
    }

    $items = $all.ToArray()
    $unassigned = @($items | Where-Object { -not $_.HasAssignment })
    $categories = @($items | Group-Object Category | ForEach-Object { [PSCustomObject]@{ Category = $_.Name; Count = $_.Count } })

    # Categorias essenciais ausentes
    $present = $items.Category
    $missing = @('Antivirus','Disk Encryption','Firewall','Attack Surface Reduction') |
        Where-Object { $present -notcontains $_ }

    Write-IALog "[Módulo 11] $($items.Count) políticas de segurança ($($unassigned.Count) sem atribuição)." -Level SUCCESS
    [PSCustomObject]@{ Items = $items; Unassigned = $unassigned; Categories = $categories; MissingCategories = @($missing) }
}

# ============================================ MÓDULO 12: SCRIPTS E REMEDIAÇÕES
function Get-IAScriptsAndRemediations {
    Write-IALog "[Módulo 12] Coletando scripts e remediações..." -Level INFO
    $all = New-Object System.Collections.Generic.List[object]

    foreach ($def in @(
        @{ Uri = "$GraphBeta/deviceManagement/deviceManagementScripts?`$expand=assignments"; Type = 'PowerShell Script';      Platform = 'Windows' }
        @{ Uri = "$GraphBeta/deviceManagement/deviceShellScripts?`$expand=assignments";      Type = 'Shell Script';           Platform = 'macOS'   }
        @{ Uri = "$GraphBeta/deviceManagement/deviceHealthScripts?`$expand=assignments";     Type = 'Proactive Remediation';  Platform = 'Windows' }
    )) {
        $raw = Get-IAGraphCollection -Uri $def.Uri -Activity "Coletando $($def.Type)s" -SuppressNotFound
        foreach ($s in $raw) {
            $asg = ConvertTo-IAAssignmentSummary @($s.assignments)
            $all.Add([PSCustomObject]@{
                Name = $s.displayName; Id = $s.id
                Type = $def.Type; Platform = $def.Platform
                CreatedDate = ConvertTo-IASafeDate $s.createdDateTime
                LastModified = ConvertTo-IASafeDate $s.lastModifiedDateTime
                RunAsAccount = $s.runAsAccount
                AssignedGroups = $asg.Included; HasAssignment = $asg.HasAssignment
                GroupsIncluded = $asg.GroupsIncluded
            })
        }
    }
    $items = $all.ToArray()
    Write-IALog "[Módulo 12] $($items.Count) scripts/remediações coletados." -Level SUCCESS
    [PSCustomObject]@{ Items = $items; Unassigned = @($items | Where-Object { -not $_.HasAssignment }) }
}

# ============================================== MÓDULO 13: RELACIONAMENTOS
function Get-IARelationshipMap {
    param($CompliancePolicies, $ConfigProfiles, $Applications, $Scripts, $SecurityPolicies)
    Write-IALog "[Módulo 13] Construindo mapa de relacionamentos..." -Level INFO

    $map = New-Object System.Collections.Generic.List[object]
    $sources = @(
        @{ Coll = $CompliancePolicies.Items; Kind = 'Política de Conformidade' }
        @{ Coll = $ConfigProfiles.Items;     Kind = 'Configuration Profile'    }
        @{ Coll = $Applications.Items;       Kind = 'Aplicativo'               }
        @{ Coll = $Scripts.Items;            Kind = 'Script/Remediação'        }
        @{ Coll = $SecurityPolicies.Items;   Kind = 'Endpoint Security'        }
    )
    foreach ($src in $sources) {
        foreach ($obj in @($src.Coll)) {
            $groups = if ($obj.PSObject.Properties['GroupsIncluded']) { $obj.GroupsIncluded } else { @($obj.AssignedGroups -split ';\s*' | Where-Object { $_ }) }
            foreach ($g in @($groups)) {
                if ($g) {
                    $map.Add([PSCustomObject]@{
                        ObjectType = $src.Kind
                        ObjectName = $obj.Name
                        TargetGroup = $g
                        Filters = $obj.PSObject.Properties['Filters'].Value
                    })
                }
            }
        }
    }
    Write-IALog "[Módulo 13] $($map.Count) relacionamentos mapeados." -Level SUCCESS
    return ,$map.ToArray()
}

Export-ModuleMember -Function @('Get-IAOverview', 'Get-IAManagedDevices', 'Get-IAComplianceAssessment', 'Get-IACompliancePolicies', 'Get-IAConfigurationProfiles', 'Get-IAApplications', 'Get-IAGroups', 'Get-IAEnrollment', 'Get-IAAutopilotDevices', 'Get-IATokensAndConnectors', 'Get-IASecurityPolicies', 'Get-IAScriptsAndRemediations', 'Get-IARelationshipMap', 'Resolve-IAGroupName', 'ConvertTo-IAAssignmentSummary')