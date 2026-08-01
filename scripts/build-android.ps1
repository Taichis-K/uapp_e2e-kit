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
# **末尾の `\` を落とす**（run-e2e.ps1 / run-unity-tests.ps1 と同じ正規化）。
# タブ補完は `unity-nis\` の形を作り、`Resolve-Path` はそれを保つ。付いたまま引用すると
# 閉じ引用符が `\"` と解釈され、**後続の引数までパスに飲み込まれる**
# （`-executeMethod` 以降が Unity に届かず、原因の分かりにくいビルド失敗になる）。
# **ドライブ直下（`C:\`）だけは落とせない** — `C:` はドライブ相対を指す別物になるため。
# この 1 ケースは引用側（Format-CliArg）で吸収するので、パスの引用は必ずそこを通すこと
if ($projectPath -notmatch '^[A-Za-z]:\\$') { $projectPath = $projectPath.TrimEnd('\') }
$projectName = Split-Path $projectPath -Leaf

function Format-CliArg {
    <#
      .SYNOPSIS
      ネイティブプロセスへ渡す引数 1 個を引用する（末尾の `\` を正しく退避する）。

      .NOTES
      **閉じ引用符の直前の `\` は、引用符そのものをエスケープする**（Windows の引数解釈規則）。
      `"C:\"` は 1 引数として閉じず、後続の引数まで飲み込む。末尾の `\` だけを倍にすれば
      リテラルの `\` 1 個として渡り、**値そのものは変わらない**。
      パス（ドライブ直下を含む）を Start-Process へ渡すときは必ずここを通す。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    # `"` の直前の `\` は連続ぶんだけ倍にしてから `\"` で退避し、末尾の `\` も倍にする
    $escaped = [regex]::Replace($Value, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
    $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
    return '"' + $escaped + '"'
}

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
    "-projectPath", (Format-CliArg $projectPath),
    "-executeMethod", $ExecuteMethod,
    "-buildOutput", (Format-CliArg $Output),
    "-logFile", (Format-CliArg $logFile)
)
if ($Release) { $unityArgs += "-release" }

Write-Host "[$projectName] Unity $unityVersion でビルド開始（初回は IL2CPP のため 10 分以上かかることがあります）..."
$buildStarted = Get-Date
$process = Start-Process -FilePath $UnityPath -ArgumentList $unityArgs -Wait -PassThru -NoNewWindow

# エージェント開発ダッシュボードが導入されていればビルド結果を1行記録する（無ければ何もしない）
$emitHelper = Join-Path $PSScriptRoot "emit-status.ps1"
if (Test-Path -LiteralPath $emitHelper -PathType Leaf) {
    . $emitHelper
    $apkSize = if (Test-Path -LiteralPath $Output -PathType Leaf) { (Get-Item $Output).Length } else { $null }
    Send-DashEvent -Kind "evidence.build" -StartPath $root -Data @{
        target       = "Android"
        project      = $projectName
        exitCode     = $process.ExitCode
        durationSec  = [math]::Round(((Get-Date) - $buildStarted).TotalSeconds, 1)
        artifactPath = $Output
        sizeBytes    = $apkSize
        logPath      = $logFile
    }
}

if ($process.ExitCode -ne 0) {
    Write-Host "--- $logFile 末尾 ---"
    Get-Content $logFile -Tail 60
    throw "ビルド失敗 (exit=$($process.ExitCode))。ログ全体: $logFile"
}
Write-Host "[$projectName] ビルド成功: $Output"
