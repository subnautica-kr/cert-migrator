# ============================================================
#  인증서 이사 도우미  (웹 UI: Edge 앱모드 + 로컬 서버)
#  - NPKI / GPKI / EPKI 자동검색, 백업 만들기, 설치, 정리(휴지통), 메모
#  - 모든 탐색/정리/설치 기준은 rules.json (화면에서 수정 가능)
#  - 실행: 상위 폴더의 "인증서 이사 도우미.exe"
# ============================================================

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName Microsoft.VisualBasic   # 휴지통 이동

# GitHub HTTPS 협상용 (구형 PowerShell은 기본 TLS가 낮아 실패함)
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}

# ------------------------------------------------------------
#  경로/로그
# ------------------------------------------------------------
$script:AppVersion = '2.6'
$script:AppDir  = $PSScriptRoot
if ([string]::IsNullOrEmpty($script:AppDir)) { $script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:RootDir = Split-Path -Parent $script:AppDir

$script:LogDir = Join-Path $script:RootDir 'logs'
try {
    if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force -ErrorAction Stop | Out-Null }
    $probe = Join-Path $script:LogDir '.write_test'
    [System.IO.File]::WriteAllText($probe, 'x'); Remove-Item -LiteralPath $probe -Force
} catch {
    $script:LogDir = Join-Path $env:TEMP '인증서이사도우미_logs'
    try { if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null } } catch {}
}
$script:LogFile = Join-Path $script:LogDir ("log_{0}_{1}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $env:COMPUTERNAME)

function Write-Log($msg, $level = 'INFO') {
    try {
        $line = ("[{0}] [{1}] {2}`r`n" -f (Get-Date -Format 'HH:mm:ss.fff'), $level, $msg)
        [System.IO.File]::AppendAllText($script:LogFile, $line, [System.Text.Encoding]::UTF8)
    } catch {}
}
function Log-Exception($where, $err) {
    try {
        if ($err -is [System.Management.Automation.ErrorRecord]) {
            $detail = $err.Exception.Message
            if ($err.InvocationInfo) { $detail += "`r`n  위치: " + $err.InvocationInfo.PositionMessage.Trim() }
            if ($err.ScriptStackTrace) { $detail += "`r`n  스택: " + $err.ScriptStackTrace }
        } else { $detail = [string]$err }
        Write-Log ("<$where> " + $detail) 'ERROR'
    } catch {}
}

try {
    Write-Log ("===== 인증서 이사 도우미 v{0} 시작 =====" -f $script:AppVersion)
    Write-Log ("컴퓨터: {0} / 사용자: {1}" -f $env:COMPUTERNAME, $env:USERNAME)
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) { Write-Log ("OS: {0} (빌드 {1})" -f $os.Caption, $os.BuildNumber) }
    Write-Log ("PowerShell: {0} / 프로그램 위치: {1}" -f $PSVersionTable.PSVersion, $script:RootDir)
    $drv = @()
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        try { if ($d.IsReady) { $drv += ("{0}({1})" -f $d.Name.TrimEnd('\'), $d.DriveType) } } catch {}
    }
    Write-Log ("드라이브: " + ($drv -join ', '))
} catch {}

# ------------------------------------------------------------
#  규칙(rules.json) 로드
# ------------------------------------------------------------
$script:RulesPath = Join-Path $script:AppDir 'rules.json'

$script:DefaultRulesJson = @'
{
  "_안내": "이 파일이 인증서 탐색·정리·백업·설치의 기준입니다. 프로그램 화면의 '규칙 설정'에서 바로 수정할 수 있고, 저장하면 즉시 다시 검색합니다.",
  "규칙버전": "2.5",
  "검색위치": [
    "%USERPROFILE%\\AppData\\LocalLow",
    "%USERPROFILE%\\AppData\\Local",
    "%APPDATA%",
    "C:\\",
    "C:\\Program Files",
    "C:\\Program Files (x86)",
    "@모든드라이브"
  ],
  "_검색위치_도움말": "위 위치들 바로 아래에서 마커폴더(NPKI 등)를 찾습니다. %변수% 사용 가능. @모든드라이브 = 연결된 모든 드라이브(USB 포함) 최상위.",
  "마커폴더": ["NPKI", "GPKI", "EPKI"],
  "_마커폴더_도움말": "인증서 보관 폴더 이름. 대소문자 구분 없음. 새 종류 발견 시 여기에 추가.",
  "폴더형모델": {
    "_설명": "NPKI 방식: cn=이름... 폴더 하나가 인증서 1개. 탐지파일이 있는 폴더를 인증서로 판단하고, 그 폴더 안 파일을 통째로 다룸.",
    "탐지파일": "signCert.der",
    "구성파일": ["signCert.der", "signPri.key", "kmCert.der", "kmPri.key"]
  },
  "묶음형모델": {
    "_설명": "GPKI/EPKI 방식: 이름_sig.cer 등 접미사가 붙은 파일 묶음이 인증서 1개. 여러 사람 것이 한 폴더에 섞여 있으므로 묶음 단위로만 다룸.",
    "탐지접미사": "_sig.cer",
    "묶음접미사": ["_sig.cer", "_sig.key", "_env.cer", "_env.key"]
  },
  "설치위치": {
    "_설명": "받은 인증서를 넣을 위치. 마커폴더 이름별로 지정. 백업파일 안의 'NPKI/...' 경로가 이 위치 아래에 그대로 만들어짐.",
    "NPKI": "%USERPROFILE%\\AppData\\LocalLow",
    "GPKI": "C:\\",
    "EPKI": "C:\\"
  },
  "정리": {
    "_설명": "인증서파일패턴에 맞는 파일만 '인증서 관련'으로 인정. 나머지는 잡파일로 분류되어 정리(휴지통 이동) 대상이 됨. 지우지않는빈폴더는 비어 있어도 남겨두는 표준 폴더 이름.",
    "인증서파일패턴": ["*.der", "*.cer", "*.key", "*.pfx", "*.p12", "CaPubs*"],
    "지우지않는빈폴더": ["USER", "CA", "class1", "class2", "Certificate", "root", "RootCA", "Government of Korea", "polinfo"]
  },
  "백업파일": {
    "_설명": "백업파일(zip)은 마커폴더(NPKI/GPKI/EPKI)부터 원본 폴더구조·파일이름을 그대로 보존함. 구조를 바꾸지 않음.",
    "매니페스트파일": "manifest.txt",
    "백업파일이름": "인증서백업_{컴퓨터명}_{날짜}.zip"
  },
  "업데이트": {
    "_설명": "확인URL은 GitHub에 올린 version.json의 raw 주소. 비워두면 업데이트 확인을 하지 않음. 예: https://raw.githubusercontent.com/OWNER/REPO/main/version.json",
    "확인URL": ""
  }
}
'@

function Load-Rules {
    try {
        if (-not (Test-Path -LiteralPath $script:RulesPath)) {
            [System.IO.File]::WriteAllText($script:RulesPath, $script:DefaultRulesJson, (New-Object System.Text.UTF8Encoding $true))
            Write-Log "rules.json 없음 -> 기본값 생성"
        }
        $raw = [System.IO.File]::ReadAllText($script:RulesPath, [System.Text.Encoding]::UTF8)
        $script:Rules = $raw | ConvertFrom-Json
        Write-Log ("규칙 로드: 버전 {0} / 마커 {1}" -f $script:Rules.'규칙버전', (@($script:Rules.'마커폴더') -join ','))
        return $true
    } catch {
        Log-Exception "규칙로드" $_
        try { $script:Rules = $script:DefaultRulesJson | ConvertFrom-Json } catch {}
        return $false
    }
}
Load-Rules | Out-Null

# ------------------------------------------------------------
#  메모(memos.json) - 인증서 지문(thumbprint) 기준
# ------------------------------------------------------------
$script:MemoPath = Join-Path $script:AppDir 'memos.json'
$script:Memos = @{}

function Load-Memos {
    $script:Memos = @{}
    try {
        if (Test-Path -LiteralPath $script:MemoPath) {
            $obj = [System.IO.File]::ReadAllText($script:MemoPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $script:Memos[$p.Name] = [string]$p.Value }
        }
    } catch { Log-Exception "메모로드" $_ }
}
function Save-Memos {
    try {
        $o = New-Object PSObject
        foreach ($k in $script:Memos.Keys) { $o | Add-Member NoteProperty $k $script:Memos[$k] }
        [System.IO.File]::WriteAllText($script:MemoPath, ($o | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $true))
    } catch { Log-Exception "메모저장" $_ }
}
Load-Memos

# ------------------------------------------------------------
#  인증서 엔진
# ------------------------------------------------------------
$script:OidMap = @{
    '1.2.410.200005.1.1.1'   = '개인 범용'
    '1.2.410.200005.1.1.4'   = '개인 은행·보험용'
    '1.2.410.200005.1.1.5'   = '기업 범용'
    '1.2.410.200005.1.1.6'   = '기업 은행용'
    '1.2.410.200004.5.1.1.5' = '개인 범용'
    '1.2.410.200004.5.1.1.7' = '개인 은행·카드용'
    '1.2.410.200004.5.2.1.2' = '기업 범용'
}

function Get-DnValue($dn, $key) {
    if ([string]::IsNullOrEmpty($dn)) { return "" }
    $m = [regex]::Match($dn, "(?:^|,)\s*$key=([^,]+)", 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ""
}

function Get-CaInfo($caFolder, $type, $issuerO) {
    if ($type -ieq 'GPKI') { return @{ Name = '행정전자서명(GPKI)'; Sector = '공무원·행정기관 (정부24, 온나라 등)' } }
    if ($type -ieq 'EPKI') { return @{ Name = '교육기관(EPKI)'; Sector = '교육행정 (나이스, 에듀파인 등)' } }
    $f = ""
    if ($caFolder) { $f = $caFolder.ToLower() }
    switch -Wildcard ($f) {
        '*yessign*'   { return @{ Name = '금융결제원(yessign)';   Sector = '은행·카드·보험·공공' } }
        '*signgate*'  { return @{ Name = '한국정보인증';           Sector = '은행·공공·범용' } }
        '*signkorea*' { return @{ Name = '코스콤(SignKorea)';     Sector = '증권·금융투자' } }
        '*crosscert*' { return @{ Name = '한국전자인증';           Sector = '범용·기업' } }
        '*tradesign*' { return @{ Name = '무역정보통신';           Sector = '무역·기업' } }
        '*kica*'      { return @{ Name = '한국정보인증(KICA)';    Sector = '범용·공공' } }
        default {
            if ($issuerO)  { return @{ Name = $issuerO;  Sector = '' } }
            if ($caFolder) { return @{ Name = $caFolder; Sector = '' } }
            return @{ Name = '알 수 없음'; Sector = '' }
        }
    }
}

function Get-PolicyPurpose($cert) {
    try {
        foreach ($ext in $cert.Extensions) {
            if ($ext.Oid.Value -eq '2.5.29.32') {
                $txt = $ext.Format($true)
                foreach ($m in [regex]::Matches($txt, '1\.2\.410\.\d+(?:\.\d+)+')) {
                    if ($script:OidMap.ContainsKey($m.Value)) { return $script:OidMap[$m.Value] }
                }
            }
        }
    } catch {}
    return ""
}

function Get-SearchRoots {
    $markers = @($script:Rules.'마커폴더')
    $bases = New-Object System.Collections.Generic.List[string]
    foreach ($loc in @($script:Rules.'검색위치')) {
        if ($loc -eq '@모든드라이브') {
            foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
                try { if ($d.IsReady) { $bases.Add($d.RootDirectory.FullName.TrimEnd('\')) } } catch {}
            }
        } else {
            $bases.Add([Environment]::ExpandEnvironmentVariables($loc).TrimEnd('\'))
        }
    }
    $roots = New-Object System.Collections.Generic.List[string]
    $seenR = New-Object System.Collections.Generic.HashSet[string]
    foreach ($b in $bases) {
        if ([string]::IsNullOrWhiteSpace($b)) { continue }
        foreach ($m in $markers) {
            $p = Join-Path $b $m
            try {
                if ((Test-Path -LiteralPath $p) -and $seenR.Add($p.ToLower())) { $roots.Add($p) }
            } catch {}
        }
    }
    Write-Log ("검색 루트 {0}개: {1}" -f $roots.Count, ($roots -join ' | '))
    return $roots
}

function Get-MarkerSplit($dirPath) {
    $probe = $dirPath + '\'
    foreach ($m in @($script:Rules.'마커폴더')) {
        $idx = $probe.IndexOf('\' + $m + '\', [System.StringComparison]::OrdinalIgnoreCase)
        if ($idx -ge 0) {
            return [PSCustomObject]@{
                Type    = $m.ToUpper()
                BaseDir = $dirPath.Substring(0, $idx)
                RelDir  = $probe.Substring($idx + 1).TrimEnd('\')
            }
        }
    }
    return $null
}

$script:DumpedRoots = New-Object System.Collections.Generic.HashSet[string]

function Test-CertFilePattern($fileName) {
    foreach ($pat in @($script:Rules.'정리'.'인증서파일패턴')) {
        if ($fileName -like $pat) { return $true }
    }
    return $false
}

function Log-FolderStructure($root, $allFiles) {
    if (-not $script:DumpedRoots.Add($root.ToLower())) { return }
    try {
        $histo = @($allFiles | Group-Object { if ($_.Extension) { $_.Extension.ToLower() } else { '(확장자없음)' } } |
            Sort-Object Count -Descending | ForEach-Object { "{0} {1}개" -f $_.Name, $_.Count })
        Write-Log ("[구조] {0} : 파일 {1}개 ({2})" -f $root, @($allFiles).Count, ($histo -join ', '))
        $shown = 0
        foreach ($f in $allFiles) {
            if ($shown -ge 300) { Write-Log ("[구조]   ...이하 {0}개 생략" -f (@($allFiles).Count - $shown)); break }
            $junk = ''
            if (-not (Test-CertFilePattern $f.Name)) { $junk = ' [잡파일]' }
            Write-Log ("[구조]   {0}  {1}b  {2:yyyy-MM-dd}{3}" -f $f.FullName.Substring($root.Length), $f.Length, $f.LastWriteTime, $junk)
            $shown++
        }
    } catch { Write-Log ("[구조] 덤프 실패: $root - " + $_.Exception.Message) 'WARN' }
}

function New-CertRecord($type, $model, $certFile, $leaf, $baseDir, $relDir, $groupBase) {
    $segs = $relDir.Split('\')
    $caFolder = ""
    if ($segs.Length -ge 2) { $caFolder = $segs[1] }

    $name = ""; $issuerO = ""; $notAfter = $null; $notBefore = $null; $purpose = ""; $thumb = ""
    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certFile
        $name    = Get-DnValue $cert.Subject 'CN'
        $issuerO = Get-DnValue $cert.Issuer 'O'
        $notAfter  = $cert.NotAfter
        $notBefore = $cert.NotBefore
        $purpose = Get-PolicyPurpose $cert
        $thumb = $cert.Thumbprint
        $cert.Dispose()
    } catch {
        Write-Log ("인증서 파일 해석 실패: " + $certFile + " - " + $_.Exception.Message) 'WARN'
    }
    if ([string]::IsNullOrEmpty($name)) {
        if ($model -eq 'files') { $name = $groupBase } else { $name = Split-Path $leaf -Leaf }
    }
    if ([string]::IsNullOrEmpty($thumb)) { $thumb = 'NOPARSE|' + $name }

    if ([string]::IsNullOrEmpty($purpose) -and $model -eq 'files') {
        if ($relDir -match '(?i)\\class1(\\|$)')     { $purpose = '기관·서버용' }
        elseif ($relDir -match '(?i)\\class2(\\|$)') { $purpose = '개인용' }
    }

    $ca = Get-CaInfo $caFolder $type $issuerO

    $files = @()
    $leafFiles = @(Get-ChildItem -LiteralPath $leaf -File -ErrorAction SilentlyContinue)
    if ($model -eq 'files') {
        $leafFiles = @($leafFiles | Where-Object { $_.Name.StartsWith($groupBase + '_', [System.StringComparison]::OrdinalIgnoreCase) })
    } else {
        # 폴더형도 인증서 파일만 소유(잡파일 zip 등은 제외) - 백업에 잡파일 안 담기고, 정리 때 남의 것 안 건드림
        $leafFiles = @($leafFiles | Where-Object { Test-CertFilePattern $_.Name })
    }
    foreach ($f in $leafFiles) {
        $entry = $f.FullName.Substring($baseDir.Length + 1).Replace('/', '_').Replace('\', '/')
        $files += [PSCustomObject]@{ Full = $f.FullName; Entry = $entry }
    }

    Write-Log ("발견: [{0}/{1}] {2} / {3} / 파일{4}개 / {5}" -f $type, $model, $name, $ca.Name, @($files).Count, $leaf)

    return [PSCustomObject]@{
        Name      = $name;    Type      = $type;   Model     = $model
        GroupBase = $groupBase; Thumb   = $thumb
        CaName    = $ca.Name; Sector    = $ca.Sector; Purpose = $purpose
        NotAfter  = $notAfter; NotBefore = $notBefore
        Folder    = $leaf;    RelFolder = $relDir;  Files    = $files
        Status    = '';       # 정상/만료/중복 - Analyze 단계에서 채움
    }
}

function Scan-All {
    # 반환: @{ Certs = ...; Junk = ...; EmptyDirs = ...; CaCache = n }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log "전체 검색 시작"
    $certs = New-Object System.Collections.Generic.List[object]
    $junk  = New-Object System.Collections.Generic.List[object]
    $seen  = New-Object System.Collections.Generic.HashSet[string]
    $caCache = 0
    $detectFile = [string]$script:Rules.'폴더형모델'.'탐지파일'
    $detectSuffix = [string]$script:Rules.'묶음형모델'.'탐지접미사'
    $emptyCandidates = New-Object System.Collections.Generic.List[string]

    foreach ($root in (Get-SearchRoots)) {
        $allFiles = @()
        try { $allFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue) }
        catch { Write-Log ("검색 실패: $root - " + $_.Exception.Message) 'WARN' }

        Log-FolderStructure $root $allFiles

        $caCache += @($allFiles | Where-Object { $_.Name -match '(?i)^[0-9a-f]{16,}_[0-9a-f]*\.der$' }).Count

        # 폴더형 (NPKI)
        foreach ($der in @($allFiles | Where-Object { $_.Name -ieq $detectFile })) {
            $leaf = $der.Directory.FullName
            if (-not $seen.Add($leaf.ToLower())) { continue }
            $split = Get-MarkerSplit $leaf
            if ($split -eq $null) { Write-Log ("마커 밖 인증서(건너뜀): " + $der.FullName) 'WARN'; continue }
            $certs.Add((New-CertRecord $split.Type 'folder' $der.FullName $leaf $split.BaseDir $split.RelDir $null))
        }
        # 묶음형 (GPKI/EPKI)
        foreach ($sig in @($allFiles | Where-Object { $_.Name.ToLower().EndsWith($detectSuffix.ToLower()) })) {
            $groupBase = $sig.Name.Substring(0, $sig.Name.Length - $detectSuffix.Length)
            $gdir = $sig.Directory.FullName
            if (-not $seen.Add(($gdir + '|' + $groupBase).ToLower())) { continue }
            $split = Get-MarkerSplit $gdir
            if ($split -eq $null) { Write-Log ("마커 밖 묶음형(건너뜀): " + $sig.FullName) 'WARN'; continue }
            $certs.Add((New-CertRecord $split.Type 'files' $sig.FullName $gdir $split.BaseDir $split.RelDir $groupBase))
        }
        # 잡파일
        foreach ($f in $allFiles) {
            if (-not (Test-CertFilePattern $f.Name)) {
                $junk.Add([PSCustomObject]@{
                    Kind = 'junk'; Path = $f.FullName; Size = $f.Length
                    Display = $f.FullName; Detail = ("{0:N0} bytes / {1:yyyy-MM-dd}" -f $f.Length, $f.LastWriteTime)
                })
            }
        }
        # 빈 폴더 후보 (표준 뼈대 폴더는 비어 있어도 보호 - 인증서 프로그램이 기대하는 구조)
        $protectedNames = @($script:Rules.'정리'.'지우지않는빈폴더')
        if ($protectedNames.Count -eq 0 -or $protectedNames[0] -eq $null) {
            $protectedNames = @('USER', 'CA', 'class1', 'class2', 'Certificate', 'root', 'RootCA', 'Government of Korea', 'polinfo')
        }
        try {
            foreach ($d in @(Get-ChildItem -LiteralPath $root -Recurse -Directory -ErrorAction SilentlyContinue)) {
                $isProtected = $false
                foreach ($pn in $protectedNames) { if ($d.Name -ieq $pn) { $isProtected = $true; break } }
                if ($isProtected) { continue }
                $hasFile = $true
                try { $hasFile = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0 } catch {}
                if (-not $hasFile) { $emptyCandidates.Add($d.FullName) }
            }
        } catch {}
    }

    # 최상위 빈 폴더만
    $set = New-Object System.Collections.Generic.HashSet[string]
    foreach ($p in $emptyCandidates) { [void]$set.Add($p.ToLower()) }
    $emptyTop = @()
    foreach ($p in $emptyCandidates) {
        $parent = Split-Path $p -Parent
        if (-not $set.Contains($parent.ToLower())) { $emptyTop += $p }
    }

    # 만료/중복 판정 (PS5.1 파이프라인 Group/Sort에서 간헐 오류가 있어 수동 구현)
    try {
        $stdLocalLow = (Join-Path $env:USERPROFILE 'AppData\LocalLow').ToLower()
        $byKey = @{}
        foreach ($c in $certs) {
            $k = ('{0}|{1}|{2}' -f $c.Name, $c.Type, $c.CaName)
            if (-not $byKey.ContainsKey($k)) { $byKey[$k] = New-Object System.Collections.Generic.List[object] }
            $byKey[$k].Add($c)
        }
        foreach ($k in @($byKey.Keys)) {
            $list = $byKey[$k]
            # 정상으로 남길 대표 1개: 유효한 것 > 표준위치(NPKI=LocalLow, GPKI/EPKI=C:\) > 최신 발급 순
            $keeper = $null
            foreach ($c in $list) {
                if ($keeper -eq $null) { $keeper = $c; continue }
                $cExp = ($c.NotAfter -ne $null -and $c.NotAfter -lt (Get-Date))
                $kExp = ($keeper.NotAfter -ne $null -and $keeper.NotAfter -lt (Get-Date))
                $cStdBase = $stdLocalLow; if ($c.Type -ne 'NPKI') { $cStdBase = ('c:\' + $c.Type).ToLower() }
                $kStdBase = $stdLocalLow; if ($keeper.Type -ne 'NPKI') { $kStdBase = ('c:\' + $keeper.Type).ToLower() }
                $cStd = $c.Folder.ToLower().StartsWith($cStdBase)
                $kStd = $keeper.Folder.ToLower().StartsWith($kStdBase)
                $better = $false
                if ($kExp -and -not $cExp) { $better = $true }
                elseif ($kExp -eq $cExp) {
                    if ($cStd -and -not $kStd) { $better = $true }
                    elseif (($cStd -eq $kStd) -and ($c.NotBefore -ne $null) -and ($keeper.NotBefore -ne $null) -and ($c.NotBefore -gt $keeper.NotBefore)) { $better = $true }
                }
                if ($better) { $keeper = $c }
            }
            foreach ($c in $list) {
                $expired = ($c.NotAfter -ne $null -and $c.NotAfter -lt (Get-Date))
                if ($expired) { $c.Status = '만료' }
                elseif ([object]::ReferenceEquals($c, $keeper)) { $c.Status = '정상' }
                else { $c.Status = '중복' }
            }
        }
    } catch { Log-Exception "판정" $_ }

    $sw.Stop()
    Write-Log ("검색 완료: 인증서 {0}개 / 잡파일 {1}개 / 빈폴더 {2}개 / CA캐시 {3}개 제외 / {4}초" -f `
        $certs.Count, $junk.Count, @($emptyTop).Count, $caCache, [math]::Round($sw.Elapsed.TotalSeconds, 1))

    # 주의: List[object]를 @()로 감싸면 PS5.1 바인더 버그(ArgumentException)가 터짐 -> ToArray() 사용
    return @{ Certs = $certs.ToArray(); Junk = $junk.ToArray(); EmptyDirs = @($emptyTop); CaCache = $caCache }
}

# 휴지통으로 보내기
function Send-ToRecycleBin($path, $isDir) {
    if ($isDir) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($path,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    } else {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    }
}

#### UI-START ####
# ------------------------------------------------------------
#  로컬 HTTP 서버 + Edge 앱모드 UI
#  (화면은 ui\index.html / style.css / app.js — 여기는 API만)
# ------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms

$script:UiDir = Join-Path $script:AppDir 'ui'
$script:LastScan = $null
$script:LastClean = @()
$script:Running = $true
$script:UiOpened = $false
$script:LastPing = Get-Date

function Build-CleanItems($r) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($c in @($r.Certs | Where-Object { $_.Status -eq '만료' })) {
        $items.Add([PSCustomObject]@{ Kind='cert'; Label='만료 인증서'; Title=$c.Name; Detail=("만료 {0:yyyy-MM-dd} · {1}" -f $c.NotAfter, $c.Folder); Cert=$c; Path=$c.Folder; Recommend=$true })
    }
    foreach ($c in @($r.Certs | Where-Object { $_.Status -eq '중복' })) {
        $items.Add([PSCustomObject]@{ Kind='cert'; Label='중복 인증서'; Title=$c.Name; Detail=("다른 위치에 원본 있음 · {0}" -f $c.Folder); Cert=$c; Path=$c.Folder; Recommend=$true })
    }
    foreach ($j in @($r.Junk)) {
        $items.Add([PSCustomObject]@{ Kind='junk'; Label='잡파일'; Title=(Split-Path $j.Path -Leaf); Detail=($j.Detail + " · " + $j.Path); Cert=$null; Path=$j.Path; Recommend=$true })
    }
    foreach ($d in @($r.EmptyDirs)) {
        $items.Add([PSCustomObject]@{ Kind='emptydir'; Label='빈 폴더'; Title=(Split-Path $d -Leaf); Detail=$d; Cert=$null; Path=$d; Recommend=$true })
    }
    return $items.ToArray()
}

function Get-BackupList {
    $out = @()
    $bakDir = Join-Path $script:RootDir '백업'
    if (Test-Path -LiteralPath $bakDir) {
        foreach ($z in @(Get-ChildItem -LiteralPath $bakDir -Filter '*.zip' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
            $out += [PSCustomObject]@{ name = $z.Name; path = $z.FullName; date = $z.LastWriteTime.ToString('MM-dd HH:mm') }
        }
    }
    return $out
}

function Get-ScanPayload {
    $r = Scan-All
    $script:LastScan = $r
    $script:LastClean = Build-CleanItems $r
    $certs = @()
    $i = 0
    foreach ($c in @($r.Certs)) {
        $memo = ''
        if ($script:Memos.ContainsKey($c.Thumb)) { $memo = $script:Memos[$c.Thumb] }
        $exp = ''; $expDays = $null
        if ($c.NotAfter -ne $null) { $exp = $c.NotAfter.ToString('yyyy-MM-dd'); $expDays = [int]($c.NotAfter - (Get-Date)).TotalDays }
        $certs += [PSCustomObject]@{
            id = $i; name = $c.Name; type = $c.Type; ca = $c.CaName; sector = $c.Sector
            purpose = $c.Purpose; expire = $exp; expireDays = $expDays; status = $c.Status
            folder = $c.Folder; memo = $memo; thumb = $c.Thumb
        }
        $i++
    }
    $clean = @()
    $i = 0
    foreach ($it in @($script:LastClean)) {
        $clean += [PSCustomObject]@{ id = $i; kind = $it.Kind; label = $it.Label; title = $it.Title; detail = $it.Detail; recommend = $it.Recommend }
        $i++
    }
    return [PSCustomObject]@{ certs = $certs; clean = $clean; caCache = $r.CaCache; backups = @(Get-BackupList); computer = $env:COMPUTERNAME; version = $script:AppVersion }
}

function Invoke-Export($ids) {
    $sel = @()
    foreach ($id in @($ids)) {
        if ($id -ge 0 -and $id -lt @($script:LastScan.Certs).Count) { $sel += $script:LastScan.Certs[$id] }
    }
    if ($sel.Count -eq 0) { return [PSCustomObject]@{ ok = $false; error = '선택된 인증서가 없습니다.' } }

    $namePattern = [string]$script:Rules.'백업파일'.'백업파일이름'
    if ([string]::IsNullOrWhiteSpace($namePattern)) { $namePattern = '인증서백업_{컴퓨터명}_{날짜}.zip' }
    $fileName = $namePattern.Replace('{컴퓨터명}', $env:COMPUTERNAME).Replace('{날짜}', (Get-Date -Format 'yyyyMMdd'))
    $bakDir = Join-Path $script:RootDir '백업'
    if (-not (Test-Path -LiteralPath $bakDir)) { New-Item -ItemType Directory -Path $bakDir -Force | Out-Null }
    $zipPath = Join-Path $bakDir $fileName
    if (Test-Path -LiteralPath $zipPath) {
        $zipPath = Join-Path $bakDir ($fileName -replace '\.zip$', ('_' + (Get-Date -Format 'HHmmss') + '.zip'))
    }
    Write-Log ("백업 시작: {0}개 -> {1}" -f $sel.Count, $zipPath)
    $failFiles = 0
    try {
        $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        $manifest = New-Object System.Text.StringBuilder
        [void]$manifest.AppendLine("# 인증서 백업 (인증서 도우미 v" + $script:AppVersion + ")")
        [void]$manifest.AppendLine("만든날짜=" + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
        [void]$manifest.AppendLine("보낸컴퓨터=" + $env:COMPUTERNAME)
        $memoOut = @{}
        foreach ($c in $sel) {
            [void]$manifest.AppendLine(("{0} | {1} | {2}" -f $c.Name, $c.CaName, $c.Folder))
            if ($script:Memos.ContainsKey($c.Thumb) -and $script:Memos[$c.Thumb]) { $memoOut[$c.Thumb] = $script:Memos[$c.Thumb] }
            foreach ($f in $c.Files) {
                try { [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.Full, $f.Entry) | Out-Null }
                catch { $failFiles++; Write-Log ("백업 담기 실패(건너뜀): " + $f.Full + " - " + $_.Exception.Message) 'WARN' }
            }
            Write-Log ("백업에 담음: " + $c.Folder)
        }
        $mName = [string]$script:Rules.'백업파일'.'매니페스트파일'
        if ([string]::IsNullOrWhiteSpace($mName)) { $mName = 'manifest.txt' }
        $e1 = $zip.CreateEntry($mName)
        $sw1 = New-Object System.IO.StreamWriter($e1.Open(), [System.Text.Encoding]::UTF8)
        $sw1.Write($manifest.ToString()); $sw1.Dispose()
        if ($memoOut.Count -gt 0) {
            $mo = New-Object PSObject
            foreach ($k in $memoOut.Keys) { $mo | Add-Member NoteProperty $k $memoOut[$k] }
            $e2 = $zip.CreateEntry('인증서메모.json')
            $sw2 = New-Object System.IO.StreamWriter($e2.Open(), [System.Text.Encoding]::UTF8)
            $sw2.Write(($mo | ConvertTo-Json)); $sw2.Dispose()
        }
        $zip.Dispose()
        Write-Log ("백업 완료: {0} (파일오류 {1}건)" -f $zipPath, $failFiles)
        return [PSCustomObject]@{ ok = $true; name = (Split-Path $zipPath -Leaf); path = $zipPath; fail = $failFiles }
    } catch {
        Log-Exception "백업" $_
        return [PSCustomObject]@{ ok = $false; error = $_.Exception.Message }
    }
}

function Get-ZipMemos($zipPath) {
    $map = @{}
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $me = $zip.Entries | Where-Object { $_.FullName -ieq '인증서메모.json' } | Select-Object -First 1
            if ($me) {
                $sr = New-Object System.IO.StreamReader($me.Open(), [System.Text.Encoding]::UTF8)
                $obj = $sr.ReadToEnd() | ConvertFrom-Json; $sr.Dispose()
                foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
            }
        } finally { $zip.Dispose() }
    } catch {}
    return $map
}

function Get-ZipPreviewData($zipPath) {
    Write-Log ("백업 미리보기: " + $zipPath)
    $detectFile = [string]$script:Rules.'폴더형모델'.'탐지파일'
    $detectSuffix = [string]$script:Rules.'묶음형모델'.'탐지접미사'
    $zipMemos = Get-ZipMemos $zipPath
    $items = @()
    $tmpDir = Join-Path $env:TEMP ("certprev_" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $n = 0
            foreach ($e in $zip.Entries) {
                $isFolderCert = ($e.Name -ieq $detectFile)
                $isGroupCert = $e.Name.ToLower().EndsWith($detectSuffix.ToLower())
                if (-not ($isFolderCert -or $isGroupCert)) { continue }
                $n++
                $tmpFile = Join-Path $tmpDir ("c$n.bin")
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $tmpFile, $true)
                $name = ""; $exp = ""; $thumb = ""
                try {
                    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $tmpFile
                    $name = Get-DnValue $cert.Subject 'CN'
                    $exp = $cert.NotAfter.ToString('yyyy-MM-dd')
                    $thumb = $cert.Thumbprint
                    $cert.Dispose()
                } catch { Write-Log ("백업 안 인증서 해석 실패: " + $e.FullName) 'WARN' }
                if ([string]::IsNullOrEmpty($name)) {
                    if ($isGroupCert) { $name = $e.Name.Substring(0, $e.Name.Length - $detectSuffix.Length) }
                    else { $parts = $e.FullName.Split('/'); if ($parts.Length -ge 2) { $name = $parts[$parts.Length-2] } else { $name = $e.FullName } }
                }
                $memo = ''
                if ($thumb -and $zipMemos.ContainsKey($thumb)) { $memo = $zipMemos[$thumb] }
                $items += [PSCustomObject]@{ name = $name; type = ($e.FullName.Split('/'))[0].ToUpper(); expire = $exp; memo = $memo }
            }
        } finally { $zip.Dispose() }
    } catch {
        Log-Exception "미리보기" $_
        return [PSCustomObject]@{ ok = $false; error = $_.Exception.Message }
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Log ("미리보기: 인증서 {0}개" -f @($items).Count)
    return [PSCustomObject]@{ ok = $true; items = @($items) }
}

function Invoke-Install($zipPath, $overwrite) {
    Write-Log ("설치 시작: " + $zipPath + " / 덮어쓰기=" + $overwrite)
    $markers = @($script:Rules.'마커폴더' | ForEach-Object { $_.ToUpper() })
    $detectFile = [string]$script:Rules.'폴더형모델'.'탐지파일'
    $detectSuffix = [string]$script:Rules.'묶음형모델'.'탐지접미사'
    $installed = 0; $skipped = 0; $failed = 0
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            foreach ($e in $zip.Entries) {
                if ([string]::IsNullOrEmpty($e.Name)) { continue }
                $top = ($e.FullName.Split('/'))[0].ToUpper()
                if ($markers -notcontains $top) {
                    if ($e.FullName -notmatch '(?i)^(manifest\.txt|인증서메모\.json)$') { Write-Log ("규격 밖 항목(건너뜀): " + $e.FullName) 'WARN' }
                    continue
                }
                if ($e.FullName.Contains('..')) { Write-Log ("경로조작 의심(건너뜀): " + $e.FullName) 'WARN'; continue }
                try {
                    $targetBase = [Environment]::ExpandEnvironmentVariables([string]$script:Rules.'설치위치'.$top)
                    if ([string]::IsNullOrWhiteSpace($targetBase)) { $targetBase = Join-Path $env:USERPROFILE 'AppData\LocalLow' }
                    $target = Join-Path $targetBase ($e.FullName.Replace('/', '\'))
                    $targetDir = Split-Path $target -Parent
                    if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
                    if ((Test-Path -LiteralPath $target) -and (-not $overwrite)) { $skipped++; continue }
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
                    if (($e.Name -ieq $detectFile) -or $e.Name.ToLower().EndsWith($detectSuffix.ToLower())) {
                        $installed++
                        Write-Log ("설치됨: " + $e.FullName + " -> " + $target)
                    }
                } catch {
                    $failed++
                    Write-Log ("설치 실패(건너뜀): " + $e.FullName + " - " + $_.Exception.Message) 'WARN'
                }
            }
        } finally { $zip.Dispose() }
        $zipMemos = Get-ZipMemos $zipPath
        if ($zipMemos.Count -gt 0) {
            foreach ($k in $zipMemos.Keys) { $script:Memos[$k] = $zipMemos[$k] }
            Save-Memos
            Write-Log ("메모 {0}건 가져옴" -f $zipMemos.Count)
        }
        Write-Log ("설치 완료: 설치 {0} / 건너뜀 {1} / 실패 {2}" -f $installed, $skipped, $failed)
        return [PSCustomObject]@{ ok = $true; installed = $installed; skipped = $skipped; failed = $failed }
    } catch {
        Log-Exception "설치" $_
        return [PSCustomObject]@{ ok = $false; error = $_.Exception.Message }
    }
}

function Invoke-Clean($ids) {
    $done = 0; $fail = 0
    Write-Log ("정리 시작: {0}개 선택" -f @($ids).Count)
    foreach ($id in @($ids)) {
        if ($id -lt 0 -or $id -ge @($script:LastClean).Count) { continue }
        $it = $script:LastClean[$id]
        try {
            if ($it.Kind -eq 'junk') {
                if (Test-Path -LiteralPath $it.Path) {
                    Send-ToRecycleBin $it.Path $false
                    Write-Log ("휴지통: [잡파일] " + $it.Path)
                } else { Write-Log ("이미 처리됨(건너뜀): " + $it.Path) }
                $done++
            } elseif ($it.Kind -eq 'emptydir') {
                if (Test-Path -LiteralPath $it.Path) {
                    Send-ToRecycleBin $it.Path $true
                    Write-Log ("휴지통: [빈폴더] " + $it.Path)
                } else { Write-Log ("이미 처리됨(건너뜀): " + $it.Path) }
                $done++
            } elseif ($it.Kind -eq 'cert') {
                # 절대 폴더째 지우지 않는다! 이 인증서 소유의 파일만. (2026-07-22 정미아 PC 사고 재발방지)
                $mv = 0
                foreach ($gf in $it.Cert.Files) {
                    if (Test-Path -LiteralPath $gf.Full) { Send-ToRecycleBin $gf.Full $false; $mv++ }
                }
                if ($it.Cert.Model -eq 'folder') {
                    $left = @(Get-ChildItem -LiteralPath $it.Cert.Folder -Force -ErrorAction SilentlyContinue)
                    if ($left.Count -eq 0) { Send-ToRecycleBin $it.Cert.Folder $true }
                }
                $done++
                Write-Log ("휴지통: [" + $it.Label + "] 파일 " + $mv + "개 / " + $it.Path)
            }
        } catch {
            $fail++
            Write-Log ("정리 실패: " + $it.Path + " - " + $_.Exception.Message) 'WARN'
        }
    }
    Write-Log ("정리 완료: 성공 {0} / 실패 {1}" -f $done, $fail)
    return [PSCustomObject]@{ ok = $true; done = $done; fail = $fail }
}

# 자동 업데이트: GitHub 릴리스 zip을 받아 프로그램 폴더를 교체하고 재시작.
# rules.json/memos.json(사용자 데이터)은 보존. 다운로드는 rules.json에 설정된 주소에서만.
function Invoke-DoUpdate {
    try {
        $u = ''
        try { $u = [string]$script:Rules.'업데이트'.'확인URL' } catch {}
        if ([string]::IsNullOrWhiteSpace($u)) { return [PSCustomObject]@{ ok = $false; error = '업데이트 주소가 설정되지 않았습니다.' } }
        $r = Invoke-WebRequest -Uri $u -TimeoutSec 8 -UseBasicParsing
        $info = $r.Content | ConvertFrom-Json
        $dl = [string]$info.download
        if ([string]::IsNullOrWhiteSpace($dl) -or $dl -notmatch '(?i)\.zip($|\?)') {
            return [PSCustomObject]@{ ok = $false; error = '다운로드용 zip 주소가 없습니다.' }
        }
        Write-Log ("업데이트 다운로드 시작: " + $dl)
        $tmp = Join-Path $env:TEMP ('certmove_upd_' + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $zip = Join-Path $tmp 'update.zip'
        Invoke-WebRequest -Uri $dl -OutFile $zip -TimeoutSec 90 -UseBasicParsing
        $ex = Join-Path $tmp 'x'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $ex)

        # 페이로드 루트 찾기 (app\main.ps1 이 있는 폴더 - GitHub 소스zip은 REPO-vX\ 로 한 겹 감쌈)
        $payload = $null
        if (Test-Path -LiteralPath (Join-Path $ex 'app\main.ps1')) { $payload = $ex }
        else {
            foreach ($d in @(Get-ChildItem -LiteralPath $ex -Directory -ErrorAction SilentlyContinue)) {
                if (Test-Path -LiteralPath (Join-Path $d.FullName 'app\main.ps1')) { $payload = $d.FullName; break }
            }
        }
        if (-not $payload) { return [PSCustomObject]@{ ok = $false; error = '내려받은 파일에서 프로그램을 찾지 못했습니다.' } }

        # 사용자 데이터 보존: 새 패키지의 rules.json 은 덮어쓰지 않음
        $pr = Join-Path $payload 'app\rules.json'
        if (Test-Path -LiteralPath $pr) { Remove-Item -LiteralPath $pr -Force -ErrorAction SilentlyContinue }

        # 교체+재시작 담당 업데이터 스크립트 생성 (현재 프로세스 종료 후 실행)
        $updater = Join-Path $tmp 'apply.ps1'
        $exe = Join-Path $script:RootDir '인증서 이사 도우미.exe'
        $uc = @"
Start-Sleep -Seconds 2
`$src = '$payload'
`$dst = '$($script:RootDir)'
try { Copy-Item -Path (Join-Path `$src '*') -Destination `$dst -Recurse -Force -ErrorAction SilentlyContinue } catch {}
if (Test-Path -LiteralPath '$exe') { Start-Process -FilePath '$exe' }
Start-Sleep -Seconds 2
Remove-Item -LiteralPath '$tmp' -Recurse -Force -ErrorAction SilentlyContinue
"@
        [System.IO.File]::WriteAllText($updater, $uc, (New-Object System.Text.UTF8Encoding $true))
        Start-Process powershell.exe ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $updater + '"')
        Write-Log ("업데이터 실행됨 (payload: {0}) -> 앱 종료 예정" -f $payload)
        return [PSCustomObject]@{ ok = $true }
    } catch {
        Log-Exception "업데이트적용" $_
        return [PSCustomObject]@{ ok = $false; error = $_.Exception.Message }
    }
}

# ------------------------------------------------------------
#  HTTP 유틸 (TcpListener 기반 - 관리자권한/URL ACL 불필요)
# ------------------------------------------------------------
function Read-HttpRequest($stream) {
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 16384
    $headerEnd = -1
    $bytes = $null
    while ($headerEnd -lt 0) {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { return $null }
        $ms.Write($buf, 0, $n)
        $bytes = $ms.ToArray()
        for ($i = 3; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i-3] -eq 13 -and $bytes[$i-2] -eq 10 -and $bytes[$i-1] -eq 13 -and $bytes[$i] -eq 10) { $headerEnd = $i + 1; break }
        }
        if ($ms.Length -gt 5MB) { return $null }
    }
    $headerText = [System.Text.Encoding]::ASCII.GetString($bytes, 0, $headerEnd)
    $lines = $headerText -split "`r`n"
    $parts = $lines[0].Split(' ')
    if ($parts.Length -lt 2) { return $null }
    $contentLength = 0
    foreach ($l in $lines) {
        if ($l -match '^(?i)Content-Length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
    }
    $bodyBytes = New-Object System.IO.MemoryStream
    if ($bytes.Length -gt $headerEnd) { $bodyBytes.Write($bytes, $headerEnd, $bytes.Length - $headerEnd) }
    while ($bodyBytes.Length -lt $contentLength) {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $bodyBytes.Write($buf, 0, $n)
    }
    return @{
        Method = $parts[0].ToUpper()
        Path   = ($parts[1] -split '\?')[0]
        Body   = [System.Text.Encoding]::UTF8.GetString($bodyBytes.ToArray())
    }
}

function Send-HttpBytes($stream, $status, $contentType, [byte[]]$body) {
    $header = "HTTP/1.1 $status`r`nContent-Type: $contentType`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($header)
    $stream.Write($hb, 0, $hb.Length)
    if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
    $stream.Flush()
}
function Send-Json($stream, $obj) {
    $json = $obj | ConvertTo-Json -Depth 8 -Compress
    Send-HttpBytes $stream '200 OK' 'application/json; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes($json))
}
function Send-Text($stream, $text, $ct) {
    Send-HttpBytes $stream '200 OK' ($ct + '; charset=utf-8') ([System.Text.Encoding]::UTF8.GetBytes([string]$text))
}
function Send-File($stream, $filePath, $ct) {
    if (Test-Path -LiteralPath $filePath) {
        Send-HttpBytes $stream '200 OK' ($ct + '; charset=utf-8') ([System.IO.File]::ReadAllBytes($filePath))
    } else {
        Send-HttpBytes $stream '404 Not Found' 'text/plain' ([System.Text.Encoding]::UTF8.GetBytes('not found'))
    }
}

# CSS/JS를 index.html에 인라인해서 '한 번의 요청'으로 전달.
# (단일 스레드 서버라 요청이 여러 개면 정체 위험 → 정적요청을 1개로 줄이는 게 가장 안전)
function Build-IndexHtml {
    $html = [System.IO.File]::ReadAllText((Join-Path $script:UiDir 'index.html'), [System.Text.Encoding]::UTF8)
    try {
        $css = [System.IO.File]::ReadAllText((Join-Path $script:UiDir 'style.css'), [System.Text.Encoding]::UTF8)
        $js  = [System.IO.File]::ReadAllText((Join-Path $script:UiDir 'app.js'), [System.Text.Encoding]::UTF8)
        $html = $html.Replace('<link rel="stylesheet" href="/style.css">', "<style>`r`n$css`r`n</style>")
        $html = $html.Replace('<script src="/app.js"></script>', "<script>`r`n$js`r`n</script>")
    } catch { Log-Exception "HTML조립" $_ }
    return $html
}

# ------------------------------------------------------------
#  라우팅
# ------------------------------------------------------------
function Handle-Request($req, $stream) {
    $script:LastPing = Get-Date
    # 진단용 요청 로그 (ping 반복은 첫 1회만 - 로그 폭주 방지)
    if ($req.Path -eq '/api/ping') {
        if (-not $script:UiOpened) { Write-Log "화면 연결 확인됨 (첫 ping 수신)" }
    } elseif ($req.Path -notmatch '(?i)^(/api/logtail|/favicon\.ico|/\.well-known/)') {
        Write-Log ("요청 " + $req.Method + " " + $req.Path)
    }
    $body = $null
    if ($req.Body) { try { $body = $req.Body | ConvertFrom-Json } catch {} }

    switch -Regex ($req.Path) {
        '^/$'              { Send-Text $stream (Build-IndexHtml) 'text/html'; return }
        '^/style\.css$'    { Send-File $stream (Join-Path $script:UiDir 'style.css') 'text/css'; return }
        '^/app\.js$'       { Send-File $stream (Join-Path $script:UiDir 'app.js') 'application/javascript'; return }
        '^/favicon\.ico$'  { Send-File $stream (Join-Path $script:UiDir 'favicon.ico') 'image/x-icon'; return }
        '^/assets/maker-logo\.svg$' { Send-File $stream (Join-Path $script:UiDir 'assets\maker-logo.svg') 'image/svg+xml'; return }
        '^/api/about$'     {
            $changelog = ''
            $clPath = Join-Path $script:RootDir 'CHANGELOG.md'
            try { if (Test-Path -LiteralPath $clPath) { $changelog = [System.IO.File]::ReadAllText($clPath, [System.Text.Encoding]::UTF8) } } catch {}
            Send-Json $stream @{ version = $script:AppVersion; changelog = $changelog }
            return
        }
        '^/api/checkupdate$' {
            $u = ''
            try { $u = [string]$script:Rules.'업데이트'.'확인URL' } catch {}
            if ([string]::IsNullOrWhiteSpace($u)) { Send-Json $stream @{ ok = $false; reason = 'nourl' }; return }
            try {
                $r = Invoke-WebRequest -Uri $u -TimeoutSec 6 -UseBasicParsing
                $info = $r.Content | ConvertFrom-Json
                $latest = [string]$info.version
                $hasUpd = $false
                try { $hasUpd = ([version]$latest -gt [version]$script:AppVersion) } catch { $hasUpd = ($latest -ne $script:AppVersion -and $latest -ne '') }
                Write-Log ("업데이트 확인: 현재 {0} / 최신 {1} / 새버전={2}" -f $script:AppVersion, $latest, $hasUpd)
                Send-Json $stream @{ ok = $true; current = $script:AppVersion; latest = $latest; hasUpdate = $hasUpd; notes = [string]$info.notes; download = [string]$info.download }
            } catch {
                Write-Log ("업데이트 확인 실패(네트워크): " + $_.Exception.Message) 'WARN'
                Send-Json $stream @{ ok = $false; reason = 'network' }
            }
            return
        }
        '^/api/openurl$'   { try { Start-Process ([string]$body.url) } catch { Log-Exception 'openurl' $_ }; Send-Json $stream @{ ok = $true }; return }
        '^/api/doupdate$'  {
            $res = Invoke-DoUpdate
            Send-Json $stream $res
            if ($res.ok) { Start-Sleep -Milliseconds 300; $script:Running = $false }   # 응답 전송 후 종료 → 업데이터가 교체·재시작
            return
        }
        '^/api/ping$'      { $script:UiOpened = $true; Send-Json $stream @{ ok = $true }; return }
        '^/api/scan$'      {
            try { Send-Json $stream (Get-ScanPayload) }
            catch { Log-Exception "스캔" $_; Send-Json $stream @{ certs = @(); clean = @(); error = $_.Exception.Message } }
            return
        }
        '^/api/export$'    { Send-Json $stream (Invoke-Export $body.ids); return }
        '^/api/preview$'   { Send-Json $stream (Get-ZipPreviewData $body.path); return }
        '^/api/install$'   { Send-Json $stream (Invoke-Install $body.path $body.overwrite); return }
        '^/api/clean$'     { Send-Json $stream (Invoke-Clean $body.ids); return }
        '^/api/memo$'      {
            $thumb = [string]$body.thumb
            $text = [string]$body.text
            if ([string]::IsNullOrWhiteSpace($text)) { $script:Memos.Remove($thumb) | Out-Null }
            else { $script:Memos[$thumb] = $text }
            Save-Memos
            Write-Log ("메모 변경: [$thumb] -> " + $text)
            Send-Json $stream @{ ok = $true }
            return
        }
        '^/api/rules$'     {
            if ($req.Method -eq 'GET') {
                Send-Text $stream ([System.IO.File]::ReadAllText($script:RulesPath, [System.Text.Encoding]::UTF8)) 'text/plain'
            } else {
                try {
                    $null = $body.text | ConvertFrom-Json
                    [System.IO.File]::WriteAllText($script:RulesPath, [string]$body.text, (New-Object System.Text.UTF8Encoding $true))
                    Load-Rules | Out-Null
                    Write-Log "규칙 저장됨"
                    Send-Json $stream @{ ok = $true }
                } catch {
                    Send-Json $stream @{ ok = $false; error = $_.Exception.Message }
                }
            }
            return
        }
        '^/api/rulesreset$' {
            [System.IO.File]::WriteAllText($script:RulesPath, $script:DefaultRulesJson, (New-Object System.Text.UTF8Encoding $true))
            Load-Rules | Out-Null
            Write-Log "규칙 기본값 복원"
            Send-Json $stream @{ ok = $true }
            return
        }
        '^/api/logtail$'   {
            $txt = ''
            try { if (Test-Path -LiteralPath $script:LogFile) { $txt = (Get-Content -LiteralPath $script:LogFile -Encoding UTF8 -Tail 400) -join "`n" } } catch {}
            Send-Text $stream $txt 'text/plain'
            return
        }
        '^/api/openlogs$'  { try { Start-Process explorer.exe "`"$($script:LogDir)`"" } catch {}; Send-Json $stream @{ ok = $true }; return }
        '^/api/openbackups$' {
            $bakDir = Join-Path $script:RootDir '백업'
            if (-not (Test-Path -LiteralPath $bakDir)) { New-Item -ItemType Directory -Path $bakDir -Force | Out-Null }
            try { Start-Process explorer.exe "`"$bakDir`"" } catch {}
            Send-Json $stream @{ ok = $true }
            return
        }
        '^/api/pickzip$'   {
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Filter = "인증서 백업파일 (*.zip)|*.zip"
            $dlg.Title = "전달받은 백업파일 선택"
            $picked = $null
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $picked = $dlg.FileName }
            Send-Json $stream @{ path = $picked }
            return
        }
        '^/api/quit$'      { Send-Json $stream @{ ok = $true }; $script:Running = $false; return }
        default            { Send-HttpBytes $stream '404 Not Found' 'text/plain' ([System.Text.Encoding]::UTF8.GetBytes('not found')) }
    }
}

# ------------------------------------------------------------
#  서버 시작 + Edge 앱모드 실행
# ------------------------------------------------------------
$listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
$listener.Start(64)
$port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
$url = "http://127.0.0.1:$port/"
Write-Log ("로컬 UI 서버 시작: " + $url)

$edge = $null
foreach ($p in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")) {
    if ($p -and (Test-Path -LiteralPath $p)) { $edge = $p; break }
}
if ($edge) {
    Start-Process $edge ("--app=$url --window-size=1000,880")
    Write-Log "Edge 앱모드로 UI 실행"
} else {
    Start-Process $url
    Write-Log "기본 브라우저로 UI 실행 (Edge 못 찾음)" 'WARN'
}

try {
    while ($script:Running) {
        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 60
            # 브라우저가 닫히고(핑 끊김) 30초 지나면 종료
            if ($script:UiOpened -and ((Get-Date) - $script:LastPing).TotalSeconds -gt 30) {
                Write-Log "UI 연결 끊김 -> 종료"
                $script:Running = $false
            }
            continue
        }
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 5000
            $client.SendTimeout = 5000
            # ★핵심★ Edge/Chrome 앱모드는 미리 '빈 소켓'(speculative preconnect)을 여는데,
            # 서버가 단일 스레드라 여기서 막히면 실제 app.js 로딩이 굶어 무한로딩이 됨.
            # 실제 HTTP 요청은 연결 직후 곧바로 데이터를 보내므로, 0.5초 안에 데이터가
            # 없으면 빈 소켓으로 간주하고 즉시 버린다. (Poll: 데이터있음 또는 닫힘이면 true)
            $sock = $client.Client
            if ((-not $sock.Poll(500000, [System.Net.Sockets.SelectMode]::SelectRead)) -or ($client.Available -eq 0)) {
                $client.Close()
                continue
            }
            $stream = $client.GetStream()
            $req = Read-HttpRequest $stream
            if ($req -ne $null) {
                try { Handle-Request $req $stream }
                catch {
                    Log-Exception ("요청 " + $req.Path) $_
                    try { Send-Json $stream @{ ok = $false; error = $_.Exception.Message } } catch {}
                }
            }
        } catch {
            # 사전연결/타임아웃 등은 정상 상황 - 로그 안 남김
        } finally {
            try { $client.Close() } catch {}
        }
    }
} finally {
    try { $listener.Stop() } catch {}
    Write-Log "정상 종료"
}
