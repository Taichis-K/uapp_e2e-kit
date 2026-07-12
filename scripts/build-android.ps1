# 指定サンプルプロジェクトの Android APK をビルドする。
# プロジェクト固有設定は <Project>\e2e-config.json、マシン固有設定は config\local.json から読む。
# 使い方: .\scripts\build-android.ps1 [-Project unity-nis|unity-ngui-nis|unity-ngui-legacy] [-Release]
param(
    [string]$Project = "unity-nis",   # このリポジトリ内のサンプル名（uapp_e2e開発用）
    [string]$ProjectPath,             # 任意の場所のUnityプロジェクト（実プロジェクト導入時はこちら）
    [string]$UnityPath,
    [string]$Output,
    [string]$ExecuteMethod,           # ビルドメソッドの明示指定（自前パイプラインを使う場合）
    [switch]$Release
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path "$PSScriptRoot\..").Path

# 対象プロジェクト解決: -ProjectPath（絶対/相対パス）優先。
# 未指定時: キット親がUnityプロジェクトならそれ（実プロジェクト内 e2e/ 配置）、でなければ $root\$Project（本リポジトリ配置）
$isSample = $false
if ($ProjectPath) {
    $projectPath = (Resolve-Path $ProjectPath).Path
}
elseif ((Test-Path (Join-Path $root "..\Assets")) -and (Test-Path (Join-Path $root "..\ProjectSettings"))) {
    $projectPath = (Resolve-Path (Join-Path $root "..")).Path
}
else {
    $projectPath = Join-Path $root $Project
    $isSample = $true
}
if (-not (Test-Path $projectPath)) { throw "プロジェクトがありません: $projectPath" }
$projectName = Split-Path $projectPath -Leaf

# Unity バージョンは ProjectVersion.txt（Unity自身が維持する正）から読む
$versionFile = Join-Path $projectPath "ProjectSettings\ProjectVersion.txt"
if (-not (Test-Path $versionFile)) { throw "ProjectVersion.txt がありません: $versionFile" }
$versionRaw = Get-Content $versionFile -Raw
if ($versionRaw -notmatch "m_EditorVersion:\s*(\S+)") { throw "ProjectVersion.txt からバージョンを読めません: $versionFile" }
$unityVersion = $Matches[1]

# エディタ解決: local.json の editorOverrides → editorRoots から unityVersion を探索
if (-not $UnityPath) {
    $localConfigPath = Join-Path $root "config\local.json"
    $local = if (Test-Path $localConfigPath) { Get-Content $localConfigPath -Raw | ConvertFrom-Json } else { $null }

    if ($local -and $local.editorOverrides.$Project) {
        $UnityPath = $local.editorOverrides.$Project
    }
    else {
        $editorRoots = if ($local -and $local.editorRoots) { $local.editorRoots } else {
            @("C:\Program Files\Unity\Hub\Editor", "D:\Unity\Hub\Editor")
        }
        foreach ($editorRoot in $editorRoots) {
            $candidate = Join-Path $editorRoot "$unityVersion\Editor\Unity.exe"
            if (Test-Path $candidate) { $UnityPath = $candidate; break }
        }
    }
    if (-not $UnityPath) {
        throw "Unity $unityVersion が見つかりません（config\local.json の editorRoots/editorOverrides を確認）"
    }
}
if (-not (Test-Path $UnityPath)) { throw "Unity が見つかりません: $UnityPath" }

$buildsDir = Join-Path $root "Builds"
if (-not $Output) { $Output = Join-Path $buildsDir "$projectName.apk" }
$logFile = Join-Path $buildsDir "build-$projectName.log"
New-Item -ItemType Directory -Force $buildsDir | Out-Null

# ビルドメソッド: サンプル（本リポジトリ配置）は Sample.Editor、
# 実プロジェクトはキット同梱の汎用エントリ（E2EBridge/Editor/BuildEntry.cs）
if (-not $ExecuteMethod) {
    $ExecuteMethod = if ($isSample) { "Sample.Editor.BuildScript.BuildAndroid" }
                     else { "E2EBridge.Editor.BuildEntry.BuildAndroid" }
}

$unityArgs = @(
    "-batchmode", "-quit",
    "-projectPath", "`"$projectPath`"",
    "-executeMethod", $ExecuteMethod,
    "-buildOutput", "`"$Output`"",
    "-logFile", "`"$logFile`""
)
if ($Release) { $unityArgs += "-release" }

Write-Host "[$projectName] Unity $unityVersion でビルド開始（初回は IL2CPP のため 10 分以上かかることがあります）..."
$process = Start-Process -FilePath $UnityPath -ArgumentList $unityArgs -Wait -PassThru -NoNewWindow

if ($process.ExitCode -ne 0) {
    Write-Host "--- $logFile 末尾 ---"
    Get-Content $logFile -Tail 60
    throw "ビルド失敗 (exit=$($process.ExitCode))。ログ全体: $logFile"
}
Write-Host "[$projectName] ビルド成功: $Output"
