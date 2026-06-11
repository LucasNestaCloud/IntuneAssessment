#Requires -Version 5.1
<#
================================================================================
 IntuneAssessment.Core.psm1
--------------------------------------------------------------------------------
 Funções de infraestrutura compartilhadas por todos os módulos:
   - Logging estruturado (console + arquivo)
   - Autenticação Microsoft Graph (Interactive / DeviceCode / ClientSecret / Cert)
   - Wrapper de chamadas Graph com retry automático e tratamento de throttling
   - Paginação automática (@odata.nextLink)
   - Validação de escopos/permissões
================================================================================
#>

# ------------------------------------------------------------------ Variáveis
$script:LogFile = $null

# Escopos delegados mínimos exigidos pelo assessment (somente leitura)
$script:RequiredScopes = @(
    'DeviceManagementManagedDevices.Read.All'
    'DeviceManagementConfiguration.Read.All'
    # Peculiaridade documentada do Graph: os endpoints de scripts e remediações
    # (deviceManagementScripts / deviceShellScripts / deviceHealthScripts)
    # exigem o escopo ReadWrite ATÉ PARA LEITURA (GET) - Read.All retorna 403.
    # A ferramenta permanece 100% somente leitura: nenhuma operação de escrita
    # é executada; o escopo é necessário apenas para o Graph autorizar o GET.
    'DeviceManagementConfiguration.ReadWrite.All'
    'DeviceManagementApps.Read.All'
    'DeviceManagementServiceConfig.Read.All'
    'DeviceManagementRBAC.Read.All'
    'Group.Read.All'
    'User.Read.All'
    'Organization.Read.All'
    'Directory.Read.All'
)

# ------------------------------------------------------------------- Logging
function Initialize-IALog {
    <# Cria o arquivo de log da execução dentro da pasta de saída. #>
    param([Parameter(Mandatory)][string]$OutputFolder)
    $script:LogFile = Join-Path $OutputFolder ("IntuneAssessment_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Write-IALog -Message "Log inicializado em $script:LogFile" -Level INFO
}

function Write-IALog {
    <#
      Logging estruturado.
      Níveis: INFO, WARN, ERROR, SUCCESS, DEBUG
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG')][string]$Level = 'INFO'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = "[$stamp][$Level] $Message"

    switch ($Level) {
        'INFO'    { Write-Host $line -ForegroundColor Gray }
        'WARN'    { Write-Host $line -ForegroundColor Yellow }
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        'DEBUG'   { Write-Verbose $line }
    }
    if ($script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    }
}

# -------------------------------------------------------------- Pré-requisitos
function Test-IAPrerequisites {
    <#
      Garante que o módulo Microsoft.Graph.Authentication esteja disponível.
      A ferramenta usa exclusivamente Invoke-MgGraphRequest (REST) para evitar
      a instalação dos ~40 submódulos do SDK completo do Graph.
    #>
    Write-IALog "Validando pré-requisitos..." -Level INFO

    if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
        Write-IALog "Módulo Microsoft.Graph.Authentication não encontrado. Instalando (CurrentUser)..." -Level WARN
        try {
            # PS 5.1 usa TLS 1.0 por padrão e falha contra a PowerShell Gallery; força TLS 1.2
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        }
        catch {
            throw "Falha ao instalar Microsoft.Graph.Authentication: $($_.Exception.Message). Instale manualmente: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
        }
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Write-IALog "Pré-requisitos OK." -Level SUCCESS
}

# ------------------------------------------------------------------ Conexão
function Connect-IAGraph {
    <#
      Conecta ao Microsoft Graph com o método de autenticação escolhido.

      Métodos:
        Interactive  -> browser interativo (padrão)
        DeviceCode   -> código de dispositivo (servidores sem browser)
        ClientSecret -> App Registration + segredo (requer permissões de Aplicação)
        Certificate  -> App Registration + certificado (thumbprint local)
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Interactive','DeviceCode','ClientSecret','Certificate')]
        [string]$AuthMethod = 'Interactive',
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$CertificateThumbprint
    )

    Write-IALog "Conectando ao Microsoft Graph via $AuthMethod..." -Level INFO

    # NUNCA reutilizar sessão anterior: o SDK mantém um cache de contexto em disco
    # e, sem isso, uma execução nova herdaria silenciosamente a conta/tenant do
    # último login (risco de coletar dados do ambiente errado). Encerramos
    # qualquer contexto existente para forçar uma autenticação nova e explícita.
    try {
        $prev = Get-MgContext -ErrorAction SilentlyContinue
        if ($prev) {
            Write-IALog ("Sessão Graph anterior detectada (conta: {0} | tenant: {1}). Encerrando para forçar novo login." -f $prev.Account, $prev.TenantId) -Level WARN
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        }
    } catch { }

    try {
        switch ($AuthMethod) {
            'Interactive' {
                $p = @{ Scopes = $script:RequiredScopes; NoWelcome = $true }
                if ($TenantId) { $p.TenantId = $TenantId }
                Connect-MgGraph @p -ErrorAction Stop
            }
            'DeviceCode' {
                $p = @{ Scopes = $script:RequiredScopes; UseDeviceCode = $true; NoWelcome = $true }
                if ($TenantId) { $p.TenantId = $TenantId }
                Connect-MgGraph @p -ErrorAction Stop
            }
            'ClientSecret' {
                if (-not ($TenantId -and $ClientId -and $ClientSecret)) {
                    throw "ClientSecret requer -TenantId, -ClientId e -ClientSecret."
                }
                $sec  = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
                $cred = [System.Management.Automation.PSCredential]::new($ClientId, $sec)
                Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $cred -NoWelcome -ErrorAction Stop
            }
            'Certificate' {
                if (-not ($TenantId -and $ClientId -and $CertificateThumbprint)) {
                    throw "Certificate requer -TenantId, -ClientId e -CertificateThumbprint."
                }
                Connect-MgGraph -TenantId $TenantId -ClientId $ClientId `
                    -CertificateThumbprint $CertificateThumbprint -NoWelcome -ErrorAction Stop
            }
        }
    }
    catch {
        Write-IALog "Falha de autenticação: $($_.Exception.Message)" -Level ERROR
        throw
    }

    # ---- Validação de contexto e escopos -------------------------------
    $ctx = Get-MgContext
    if (-not $ctx) { throw "Conexão não estabelecida (contexto nulo)." }

    if ($ctx.AuthType -eq 'Delegated') {
        $missing = $script:RequiredScopes | Where-Object { $ctx.Scopes -notcontains $_ }
        if ($missing) {
            Write-IALog "Escopos ausentes (alguns módulos podem falhar): $($missing -join ', ')" -Level WARN
        }
    }
    else {
        Write-IALog "Autenticação App-Only detectada. Garanta as permissões de APLICAÇÃO equivalentes com admin consent." -Level INFO
    }

    # ---- Informações do tenant ------------------------------------------
    $org = (Invoke-IAGraphRequest -Uri 'https://graph.microsoft.com/v1.0/organization').value | Select-Object -First 1
    $defaultDomain = ($org.verifiedDomains | Where-Object { $_.isDefault }).name

    $tenantInfo = [PSCustomObject]@{
        TenantName    = $org.displayName
        TenantId      = $ctx.TenantId
        DefaultDomain = $defaultDomain
        Domains       = @($org.verifiedDomains.name)
        Account       = $ctx.Account
        AuthType      = $ctx.AuthType
        Scopes        = $ctx.Scopes
        ExecutedAt    = Get-Date
    }

    Write-IALog ("Conectado: {0} ({1}) | Domínio: {2} | Conta: {3}" -f `
        $tenantInfo.TenantName, $tenantInfo.TenantId, $tenantInfo.DefaultDomain, $ctx.Account) -Level SUCCESS

    # Confirmação explícita nos fluxos interativos: o SSO do browser pode logar
    # automaticamente na conta anterior. O analista valida tenant/conta antes
    # de qualquer coleta - garantia contra avaliar o ambiente errado.
    if ($AuthMethod -in 'Interactive','DeviceCode') {
        Write-Host ''
        Write-Host ("  Tenant : {0} ({1})" -f $tenantInfo.TenantName, $tenantInfo.DefaultDomain) -ForegroundColor Cyan
        Write-Host ("  Conta  : {0}" -f $ctx.Account) -ForegroundColor Cyan
        $resp = Read-Host '  Executar o assessment NESTE tenant com esta conta? (S/N)'
        if ($resp -notmatch '^[sSyY]') {
            Write-IALog 'Tenant não confirmado pelo analista. Sessão encerrada - execute novamente e autentique com a conta correta.' -Level WARN
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            exit 10
        }
    }

    return $tenantInfo
}

# ----------------------------------------------------- Wrapper Graph + Retry
function Initialize-IAJsonConverter {
    <#
      Compila (em memória, uma única vez) um conversor C# que desserializa JSON
      diretamente para PSObject/arrays - nunca Dictionary<string,object>.

      Por quê: no Windows PowerShell 5.1, dicionários genéricos retornados por
      desserializadores (SDK Graph ou JavaScriptSerializer) disparam dois bugs:
        1. ".Contains(chave)" resolve para a sobrecarga Contains(KeyValuePair)
           -> "Não é possível localizar uma sobrecarga para Contains";
        2. O binder dinâmico falha intermitentemente com
           "Os tipos de argumento não correspondem" (ArgumentException).
      Convertendo tudo para PSCustomObject, o acesso por ponto ($x.prop) fica
      uniforme e estável em PS 5.1 e PS 7. Sem limite de 2 MB (MaxJsonLength).
    #>
    if ($script:IAJsonReady) { return }
    $code = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Management.Automation;
using System.Web.Script.Serialization;

public static class IAJson
{
    private static JavaScriptSerializer _s;
    private static JavaScriptSerializer S
    {
        get
        {
            if (_s == null)
            {
                _s = new JavaScriptSerializer();
                _s.MaxJsonLength  = int.MaxValue;
                _s.RecursionLimit = 1000;
            }
            return _s;
        }
    }

    public static object Parse(string json)
    {
        if (string.IsNullOrWhiteSpace(json)) { return null; }
        return ToPS(S.DeserializeObject(json));
    }

    private static object ToPS(object o)
    {
        IDictionary<string, object> d = o as IDictionary<string, object>;
        if (d != null)
        {
            PSObject ps = new PSObject();
            foreach (KeyValuePair<string, object> kv in d)
            {
                ps.Properties.Add(new PSNoteProperty(kv.Key, ToPS(kv.Value)));
            }
            return ps;
        }
        IList l = o as IList;
        if (l != null)
        {
            object[] arr = new object[l.Count];
            for (int i = 0; i < l.Count; i++) { arr[i] = ToPS(l[i]); }
            return arr;
        }
        return o;
    }
}
'@
    try {
        if (-not ('IAJson' -as [type])) {
            $sma = [System.Management.Automation.PSObject].Assembly.Location
            Add-Type -TypeDefinition $code -ReferencedAssemblies @('System.Web.Extensions', $sma) -ErrorAction Stop
        }
        $script:IAJsonReady = $true
    }
    catch {
        Write-IALog "Conversor JSON nativo indisponível ($($_.Exception.Message)); usando ConvertFrom-Json padrão." -Level WARN
        $script:IAJsonReady = 'fallback'
    }
}

function ConvertFrom-IAJson {
    <#
      Desserializa JSON do Graph SEM depender da conversão interna do SDK
      (Invoke-MgGraphRequest -OutputType PSObject), que falha com
      "ArgumentException: Os tipos de argumento não correspondem" em payloads
      de deviceConfigurations (bug conhecido do msgraph-sdk-powershell).

      Saída SEMPRE em PSCustomObject/arrays, em todas as versões do PowerShell:
        PS 7+ : ConvertFrom-Json -Depth 100 (já produz PSCustomObject)
        PS 5.1: conversor C# IAJson (sem limite de 2 MB, sem dicionários genéricos)
    #>
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        try   { return ($Json | ConvertFrom-Json -Depth 100) }
        catch { return ($Json | ConvertFrom-Json -AsHashtable -Depth 100) }  # chaves duplicadas raras
    }
    Initialize-IAJsonConverter
    if ($script:IAJsonReady -eq 'fallback') { return ($Json | ConvertFrom-Json) }
    return [IAJson]::Parse($Json)
}

function Invoke-IAGraphRequest {
    <#
      Wrapper de Invoke-MgGraphRequest com:
        - Retry exponencial (padrão: 5 tentativas)
        - Respeito ao header Retry-After em HTTP 429 (throttling)
        - Tratamento explícito de 401/403 (permissão) e 404 (recurso inexistente)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers,        # ex.: @{ ConsistencyLevel = 'eventual' } para endpoints $count
        [object]$Body,              # corpo para POST (ex.: API de relatórios do Intune)
        [int]$MaxRetries = 5,
        [switch]$SuppressNotFound   # alguns endpoints retornam 404 quando o recurso não está configurado
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            # OutputType Json: recebemos a resposta bruta e desserializamos com
            # ConvertFrom-IAJson, contornando o bug de conversão do SDK (ver acima).
            $p = @{ Method = $Method; Uri = $Uri; OutputType = 'Json'; ErrorAction = 'Stop' }
            if ($Headers) { $p.Headers = $Headers }
            if ($null -ne $Body) {
                $p.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 8 -Compress }
                $p.ContentType = 'application/json'
            }
            $raw = Invoke-MgGraphRequest @p
            if ($raw -is [string]) { return (ConvertFrom-IAJson $raw) }
            return $raw   # alguns retornos (204/sem corpo) podem não ser string
        }
        catch {
            $msg    = $_.Exception.Message
            $status = $null
            # Extração robusta do status HTTP (propriedade tipada ou fallback por regex na mensagem)
            if ($_.Exception.PSObject.Properties['ResponseStatusCode'] -and $_.Exception.ResponseStatusCode) {
                $status = [int]$_.Exception.ResponseStatusCode
            }
            elseif ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response.StatusCode) {
                $status = [int]$_.Exception.Response.StatusCode
            }
            elseif ($msg -match '\b(4\d\d|5\d\d)\b') { $status = [int]$Matches[1] }

            # SDK rejeitou o corpo por não ser JSON (ex.: endpoints text/plain como /$count):
            # erro permanente do formato da resposta - repetir não muda o resultado.
            if ($msg -match 'Non-Json response') {
                Write-IALog "Resposta não-JSON em $Uri (endpoint incompatível com -OutputType Json): $msg" -Level WARN
                return $null
            }

            # 404: recurso/feature não configurado no tenant - opcionalmente silencioso
            if ($status -eq 404 -and $SuppressNotFound) {
                Write-IALog "Recurso não encontrado (404): $Uri" -Level DEBUG
                return $null
            }
            # 401/403: sem permissão - não adianta repetir
            if ($status -in 401, 403) {
                Write-IALog "Acesso negado ($status) em $Uri - verifique o escopo Graph consentido E a role RBAC do Intune da conta (escopo concedido não basta sem role equivalente)." -Level WARN
                return $null
            }
            # Demais 4xx (400, 404 sem supressão, 410...): erro permanente - não repetir
            # Exceções transitórias: 408 (timeout) e 429 (throttling)
            if ($status -ge 400 -and $status -lt 500 -and $status -notin 408, 429) {
                # Com -SuppressNotFound o chamador já espera ausência de dados
                # (ex.: installSummary não suportado por apps built-in -> 400):
                # registra só no nível DEBUG para não poluir o console.
                $lvl = if ($SuppressNotFound) { 'DEBUG' } else { 'WARN' }
                Write-IALog "Requisição rejeitada ($status) em $Uri : $msg" -Level $lvl
                return $null
            }
            # 408 / 429 / 5xx / status desconhecido (falha de rede): aguarda e tenta novamente
            if ($attempt -lt $MaxRetries) {
                $wait = [math]::Pow(2, $attempt)   # backoff exponencial: 2,4,8,16s
                if ($status -eq 429) {
                    Write-IALog "Throttling (429). Aguardando ${wait}s (tentativa $attempt/$MaxRetries)..." -Level WARN
                } else {
                    Write-IALog "Erro transitório ($(if($status){$status}else{'rede'})): aguardando ${wait}s (tentativa $attempt/$MaxRetries)..." -Level WARN
                }
                Start-Sleep -Seconds $wait
                continue
            }
            Write-IALog "Falha definitiva em $Uri : $msg" -Level ERROR
            return $null
        }
    }
}

function Get-IAGraphCollection {
    <#
      Recupera TODOS os itens de uma coleção Graph seguindo @odata.nextLink.
      Exibe progresso opcional para coleções grandes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Activity,
        [switch]$SuppressNotFound
    )

    $all  = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    $page = 0

    while ($next) {
        $page++
        if ($Activity) {
            Write-Progress -Activity $Activity -Status "Página $page - $($all.Count) itens coletados"
        }
        $resp = Invoke-IAGraphRequest -Uri $next -SuppressNotFound:$SuppressNotFound
        if (-not $resp) { break }

        # A resposta é PSCustomObject (caminho padrão) ou IDictionary (fallback PS7
        # com -AsHashtable). NUNCA usar .Contains() em dicionários: em
        # Dictionary<string,object> ele resolve para Contains(KeyValuePair) e
        # falha com "overload para Contains". O operador -contains é seguro.
        $hasValue = if ($resp -is [System.Collections.IDictionary]) { @($resp.Keys) -contains 'value' }
                    else { $null -ne $resp.PSObject.Properties['value'] }
        if ($hasValue) { foreach ($i in @($resp.value)) { if ($null -ne $i) { $all.Add($i) } } }
        else { $all.Add($resp) }

        $next = $resp.'@odata.nextLink'
    }
    if ($Activity) { Write-Progress -Activity $Activity -Completed }
    # ToArray() em vez de @(): conversão tipada, imune ao binder do PS 5.1.
    # A vírgula preserva o array (inclusive vazio) através do unroll do return.
    return ,$all.ToArray()
}

# --------------------------------------------------------------- Utilitários
function ConvertTo-IASafeDate {
    <# Converte datas Graph (string/DateTime) em DateTime ou $null, sem lançar erro.
       Parâmetro tipado [object] para estabilidade do binder no PS 5.1. #>
    param([object]$Value)
    if (-not $Value) { return $null }
    try {
        $d = [datetime]$Value
        if ($d.Year -le 1971) { return $null }  # 1/1/0001 e datas "vazias" do Graph
        return $d
    } catch { return $null }
}

function Get-IATokenStatus {
    <#
      Classificação de validade usada pelo Módulo 10 (Tokens/Conectores):
        Verde   > 60 dias  | Amarelo <= 60 | Laranja <= 30 | Vermelho expirado
    #>
    param($ExpirationDate)
    $exp = ConvertTo-IASafeDate $ExpirationDate
    if (-not $exp) { return [PSCustomObject]@{ DaysRemaining = $null; Status = 'Desconhecido'; Color = 'gray' } }
    $days = [math]::Floor(($exp - (Get-Date)).TotalDays)
    $status, $color =
        if     ($days -lt 0)  { 'Expirado','red' }
        elseif ($days -le 30) { 'Crítico','orange' }
        elseif ($days -le 60) { 'Atenção','yellow' }
        else                  { 'OK','green' }
    return [PSCustomObject]@{ DaysRemaining = $days; Status = $status; Color = $color }
}

Export-ModuleMember -Function @('Initialize-IALog', 'Write-IALog', 'Test-IAPrerequisites', 'Connect-IAGraph', 'Invoke-IAGraphRequest', 'Get-IAGraphCollection', 'ConvertTo-IASafeDate', 'Get-IATokenStatus', 'ConvertFrom-IAJson')