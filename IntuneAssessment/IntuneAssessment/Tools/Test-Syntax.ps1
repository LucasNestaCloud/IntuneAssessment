# Test-Syntax.ps1
# ------------------------------------------------------------------------------
# Valida todos os arquivos .ps1/.psm1 do projeto usando o parser oficial do
# PowerShell (AST) e confere o encoding (UTF-8 com BOM, exigido pelo PS 5.1).
# Execute a partir da raiz do projeto:  .\Tools\Test-Syntax.ps1
# ------------------------------------------------------------------------------
[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))

$failed = $false
$files = Get-ChildItem -Path $ProjectRoot -Recurse -Include '*.ps1','*.psm1' |
         Where-Object { $_.FullName -notmatch '\\Output\\|/Output/' }

foreach ($f in $files) {
    # ---- 1. Encoding: UTF-8 com BOM ------------------------------------------
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if (-not $hasBom) {
        Write-Host "[ENCODING] $($f.Name): sem BOM UTF-8 - o Windows PowerShell 5.1 lerá como ANSI e corromperá acentos." -ForegroundColor Yellow
        Write-Host "           Corrija com: `$c = Get-Content '$($f.FullName)' -Raw; [IO.File]::WriteAllText('$($f.FullName)', `$c, (New-Object Text.UTF8Encoding `$true))" -ForegroundColor DarkGray
        $failed = $true
    }

    # ---- 2. Sintaxe: parser oficial (AST) -------------------------------------
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $failed = $true
        foreach ($e in $errors) {
            Write-Host ("[SINTAXE ] {0}:{1} {2}" -f $f.Name, $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
        }
    } else {
        Write-Host ("[OK      ] {0}" -f $f.Name) -ForegroundColor Green
    }
}

if ($failed) {
    Write-Host "`nValidação concluída com problemas. Corrija os itens acima antes de executar o assessment." -ForegroundColor Red
    exit 1
}
Write-Host "`nTodos os arquivos passaram na validação de sintaxe e encoding." -ForegroundColor Green
