@echo off
:: ============================================================================
::  Run-IntuneAssessment.cmd
::  Lancador universal da ferramenta de assessment.
::
::  Por que ele existe:
::    Arquivos baixados da internet recebem a marca "Mark of the Web" e a
::    politica de execucao do PowerShell (RemoteSigned/AllSigned) bloqueia
::    scripts nao assinados com a mensagem "is not digitally signed".
::    Este .cmd (que NAO esta sujeito a execution policy):
::      1. Remove a marca de internet de todos os arquivos do projeto;
::      2. Executa o assessment com -ExecutionPolicy Bypass apenas neste
::         processo (sem alterar a configuracao da maquina, sem admin).
::
::  Uso:
::    Run-IntuneAssessment.cmd
::    Run-IntuneAssessment.cmd -AuthMethod DeviceCode
::    Run-IntuneAssessment.cmd -AuthMethod ClientSecret -TenantId contoso.com ...
::    (todos os parametros sao repassados ao Invoke-IntuneAssessment.ps1)
:: ============================================================================
setlocal
cd /d "%~dp0"

:: Prefere PowerShell 7 (pwsh) se instalado; senao usa o Windows PowerShell 5.1
set "PS=powershell"
where pwsh >nul 2>&1 && set "PS=pwsh"

echo.
echo  [1/2] Desbloqueando arquivos do projeto (Mark of the Web)...
%PS% -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0.' -Recurse -File | Unblock-File -ErrorAction SilentlyContinue"

echo        Desbloqueio concluido. A partir de agora, nesta maquina,
echo        ".\Invoke-IntuneAssessment.ps1" tambem funciona diretamente.
echo  [2/2] Iniciando o Intune Advanced Assessment...
echo.
%PS% -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-IntuneAssessment.ps1" %*

set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
    echo  A execucao terminou com codigo %RC%. Consulte o arquivo .log na pasta Output.
    pause
)
endlocal & exit /b %RC%
