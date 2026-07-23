# ============================================================
#  런처 exe(인증서 이사 도우미.exe) 빌드 스크립트
#  - host.cs 를 컴파일해 상위 폴더에 exe 를 만든다.
#  - WebView2 SDK DLL(../app/lib/*)을 참조. 창 크기는 host.cs 의 ClientSize.
#  실행: 이 폴더에서  powershell -ExecutionPolicy Bypass -File build.ps1
# ============================================================
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$lib  = Join-Path $root 'app\lib'
$out  = Join-Path $root '인증서 이사 도우미.exe'
$csc  = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

$rsp = @"
/nologo
/target:winexe
/platform:x64
/win32icon:"$here\cert.ico"
/reference:"C:\Windows\Microsoft.NET\Framework64\v4.0.30319\System.Windows.Forms.dll"
/reference:"C:\Windows\Microsoft.NET\Framework64\v4.0.30319\System.Drawing.dll"
/reference:"$lib\Microsoft.Web.WebView2.Core.dll"
/reference:"$lib\Microsoft.Web.WebView2.WinForms.dll"
/out:"$out"
"$here\host.cs"
"@
$rspPath = Join-Path $here 'build.rsp'
[System.IO.File]::WriteAllText($rspPath, $rsp, (New-Object System.Text.UTF8Encoding $false))

# 실행 중이면 종료(덮어쓰기 위해)
Get-Process -Name '인증서 이사 도우미' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

& $csc "@$rspPath"
if (Test-Path -LiteralPath $out) { Write-Host ("빌드 성공: {0} ({1} bytes)" -f $out, (Get-Item -LiteralPath $out).Length) }
else { Write-Host "빌드 실패" }
