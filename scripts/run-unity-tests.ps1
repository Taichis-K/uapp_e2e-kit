# Unity の EditMode/PlayMode テスト（内側ループ）を実行し、結果を AI が読める要約で出力する。
# E2E（外側ループ）はビルドや実機が要るため、ロジックの検証はまずこちらで回す（docs/04-ai-loop.md）。
# 使い方: .\scripts\run-unity-tests.ps1 [-Project unity-nis] [-Mode EditMode|PlayMode] [-Filter <pattern>]
#
# Unity CLI（https://docs.unity.com/en-us/unity-cli）があればそれを使い、無ければ Unity 本体の
# batchmode -runTests へ自動フォールバックする（キットは Unity CLI を必須依存にしない）。
# どちらの経路でも NUnit XML を出力し、失敗テスト名・メッセージ・スタックの先頭を要約表示する。
param(
    [string]$Project = "unity-nis",   # このリポジトリ内のサンプル名（uapp_e2e開発用）
    [string]$ProjectPath,             # 任意の場所のUnityプロジェクト（実プロジェクト導入時はこちら）
    [ValidateSet("EditMode", "PlayMode")][string]$Mode = "EditMode",
    [string]$Filter,                  # テスト名の絞り込み（例: MyNamespace.MyTests）
    [string]$Output,                  # NUnit XML の出力先（既定: Builds\test-results-<project>-<mode>.xml）
    [int]$TimeoutSeconds = 1800,      # Unity プロセスを強制終了するまでの秒数（終了ハング対策）
    [string]$UnityPath,               # Unity 本体の明示指定（フォールバック経路用）
    # EditMode は既定で -nographics（グラフィックス初期化と USB スキャンを避ける。これが無いと
    # 2022.3 でライセンス初期化後にスキャンを繰り返したまま進まない事象を実測）。
    # 描画が要る PlayMode では既定 OFF。明示指定は -NoGraphics:$true / -NoGraphics:$false（bool のため値が必須）
    [bool]$NoGraphics = ($Mode -eq "EditMode")
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path "$PSScriptRoot\..").Path

# 対象プロジェクト解決: -ProjectPath 優先 → キット親がUnityプロジェクトならそれ → $root\$Project
if ($ProjectPath) {
    $projectDir = (Resolve-Path $ProjectPath).Path
}
elseif ((Test-Path (Join-Path $root "..\Assets")) -and (Test-Path (Join-Path $root "..\ProjectSettings"))) {
    $projectDir = (Resolve-Path (Join-Path $root "..")).Path
}
else {
    $projectDir = Join-Path $root $Project
}
if (-not (Test-Path $projectDir)) { throw "プロジェクトがありません: $projectDir" }
$projectName = Split-Path $projectDir -Leaf

$buildsDir = Join-Path $root "Builds"
New-Item -ItemType Directory -Force $buildsDir | Out-Null
if (-not $Output) { $Output = Join-Path $buildsDir "test-results-$projectName-$Mode.xml" }
if (Test-Path $Output) { Remove-Item $Output -Force }   # 前回結果を誤読しない

# Unity CLI の解決（PATH → 既定インストール先）。無ければ batchmode フォールバック
$unityCli = (Get-Command unity -ErrorAction SilentlyContinue).Source
if (-not $unityCli) {
    $candidate = Join-Path $env:LOCALAPPDATA "Unity\bin\unity.exe"
    if (Test-Path $candidate) { $unityCli = $candidate }
}

Write-Host "[$projectName] $Mode テストを実行中（Unity の起動を含むため数分かかります）..."

$logFile = Join-Path $buildsDir "test-$projectName-$Mode.log"

if ($unityCli) {
    $cliArgs = @("test", $projectDir, "--mode", $Mode, "--output", $Output,
                 "--timeout", $TimeoutSeconds, "--non-interactive", "--no-banner")
    if ($Filter) { $cliArgs += @("--filter", $Filter) }
    # -- 以降は Unity 本体へ転送される。ログは必ずプロジェクト側に確保する
    # （既定の Editor.log は複数 Unity 同時実行で競合し、後発の実行がログを1行も残せないことがある）
    $cliArgs += @("--", "-logFile", $logFile)
    if ($NoGraphics) { $cliArgs += "-nographics" }
    & $unityCli @cliArgs
    $exit = $LASTEXITCODE
    $via = "Unity CLI"
    Write-Host "ログ: $logFile"
} else {
    # フォールバック: Unity 本体を batchmode で起動する（CLI と同じ NUnit XML を出力させる）
    if (-not $UnityPath) {
        $versionFile = Join-Path $projectDir "ProjectSettings\ProjectVersion.txt"
        if (-not (Test-Path $versionFile)) { throw "ProjectVersion.txt がありません: $versionFile" }
        if ((Get-Content $versionFile -Raw) -notmatch "m_EditorVersion:\s*(\S+)") {
            throw "ProjectVersion.txt からバージョンを読めません: $versionFile"
        }
        $unityVersion = $Matches[1]
        $localConfigPath = Join-Path $root "config\local.json"
        $local = if (Test-Path $localConfigPath) { Get-Content $localConfigPath -Raw | ConvertFrom-Json } else { $null }
        $editorRoots = if ($local -and $local.editorRoots) { $local.editorRoots }
                       else { @("C:\Program Files\Unity\Hub\Editor", "D:\Unity\Hub\Editor") }
        foreach ($editorRoot in $editorRoots) {
            $candidate = Join-Path $editorRoot "$unityVersion\Editor\Unity.exe"
            if (Test-Path $candidate) { $UnityPath = $candidate; break }
        }
        if (-not $UnityPath) {
            throw ("Unity $unityVersion が見つかりません（config\local.json の editorRoots/editorOverrides を確認）。" +
                   "Unity CLI を導入すればエディタ解決も自動になる: https://docs.unity.com/en-us/unity-cli")
        }
    }
    $unityArgs = @("-batchmode", "-runTests", "-projectPath", "`"$projectDir`"",
                   "-testPlatform", $Mode, "-testResults", "`"$Output`"", "-logFile", "`"$logFile`"")
    if ($Filter) { $unityArgs += @("-testFilter", $Filter) }
    if ($NoGraphics) { $unityArgs += "-nographics" }
    $process = Start-Process -FilePath $UnityPath -ArgumentList $unityArgs -PassThru -NoNewWindow
    # Unity は終了時にハングすることがあるため、タイムアウトで強制終了して結果XMLで判断する
    $killedByTimeout = $false
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Write-Warning "Unity が $TimeoutSeconds 秒で終了しなかったため強制終了します（結果XMLがあれば判定に使う）"
        $process.Kill()
        $process.WaitForExit(30000) | Out-Null
        $killedByTimeout = $true
    }
    # 強制終了した場合、終了コードは kill によるもので信用できない。結果XMLの失敗数だけで判定する
    $exit = if ($killedByTimeout) { 0 } else { $process.ExitCode }
    $via = "Unity batchmode（Unity CLI 未検出）" + $(if ($killedByTimeout) { " / タイムアウトで強制終了 → 結果XMLで判定" })
    Write-Host "ログ: $logFile"
}

# --- 結果の要約（NUnit XML）: AI が失敗原因に直行できるよう、失敗のみ抜き出す ---
if (-not (Test-Path $Output)) {
    throw "テスト結果が出力されませんでした（$via / exit=$exit）: $Output。Unity のログを確認"
}
$xml = [xml](Get-Content $Output -Raw)
$run = $xml.DocumentElement
Write-Host ""
Write-Host "=== $Mode テスト結果（$via） ==="
Write-Host "  合計 $($run.total) / 成功 $($run.passed) / 失敗 $($run.failed) / スキップ $($run.skipped) / $([math]::Round([double]$run.duration, 1))秒"

$failed = $xml.SelectNodes("//test-case[@result='Failed']")
foreach ($case in $failed) {
    Write-Host ""
    Write-Host "  [失敗] $($case.fullname)"
    $message = $case.SelectSingleNode("failure/message")
    if ($message) { Write-Host "    $($message.InnerText.Trim())" }
    $stack = $case.SelectSingleNode("failure/stack-trace")
    if ($stack) {
        # スタックは先頭数行だけ出す（該当ファイル:行が分かれば十分）
        ($stack.InnerText -split "`n" | Select-Object -First 3) | ForEach-Object { Write-Host "    $($_.Trim())" }
    }
}
Write-Host ""
Write-Host "詳細（NUnit XML）: $Output"

if ([int]$run.total -eq 0) {
    Write-Warning "テストが 0 件でした（$Mode）。テストアセンブリ（.asmdef に UnityEngine.TestRunner/nunit.framework 参照）と -Filter を確認"
}
if ($exit -ne 0 -or [int]$run.failed -gt 0) { exit 1 }
Write-Host "[$projectName] $Mode テスト成功。"
exit 0
