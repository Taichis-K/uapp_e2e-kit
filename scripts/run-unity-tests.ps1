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
    # 開いているエディタの中でテストを回す（Unity をもう1つ起動しない）。EditMode 専用。
    # 実測: EditMode 4件が batchmode 経路 約48秒 → エディタ内 約3秒。1行直すたびに回す内側ループ向け
    [switch]$Editor,
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

function Test-UnityProjectLocked {
    <#
      .SYNOPSIS
      エディタがこのプロジェクトを実際に開いているか（Temp\UnityLockfile を掴んでいるか）。

      .NOTES
      **ファイルの存在だけで判断しない**。エディタが異常終了するとロックファイルは残るため、
      存在で判定すると「既に開いています」と言い続けて永久に起動できなくなる（実際に踏んだ）。
      排他で開けたら誰も掴んでいない＝古い残骸。
    #>
    param([Parameter(Mandatory)][string]$ProjectDir)
    $lock = Join-Path $ProjectDir "Temp\UnityLockfile"
    if (-not (Test-Path -LiteralPath $lock)) { return $false }
    try {
        $stream = [System.IO.File]::Open($lock, "Open", "ReadWrite", "None")
        $stream.Close()
        return $false
    } catch {
        return $true
    }
}
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

# batchmode テストは Unity のプロジェクトロックと排他: エディタが同じプロジェクトを開いていると
# 起動できず、ログには「Exiting without the bug reporter」しか残らない（exit=6）。
# ここで先に検出しないと、AI は原因の分からない失敗を数分かけて再試行する
# （-Editor の E2E は逆に「開いている」必要がある。この 2 つが正反対なのが最も踏みやすい落とし穴）
$editorHoldsProject = $false
if ($unityCli -and -not $Editor) {
    $statusRaw = & $unityCli status --project-path $projectDir --format json --no-banner 2>&1 | Out-String
    $statusJson = $null
    try { $statusJson = $statusRaw | ConvertFrom-Json } catch {}
    if ($statusJson -and $statusJson.success -and $statusJson.data.count -ge 1) { $editorHoldsProject = $true }
}
if ($editorHoldsProject) {
    throw ("エディタがこのプロジェクトを開いているため batchmode テストを実行できません" +
           "（Unity のプロジェクトロック）: $projectDir。エディタを閉じてから再実行してください。" +
           "エディタを開いたまま回したい場合は -Editor を使う（EditMode のみ）")
}

$logFile = Join-Path $buildsDir "test-$projectName-$Mode.log"

# エージェント開発ダッシュボード連携（任意）。**監視が要るのは失敗経路ほど強い**ので、
# 結果が出なかった場合も「赤いエビデンス」を残してから throw する
$emitHelper = Join-Path $PSScriptRoot "emit-status.ps1"
try {
    if (Test-Path -LiteralPath $emitHelper -PathType Leaf) { . $emitHelper }
} catch {
    # 連携は補助機能。読み込みに失敗してもテスト実行は続ける
}
function Send-TestEvidence {
    param([hashtable]$Data)
    if (Get-Command Send-DashEvent -ErrorAction SilentlyContinue) {
        Send-DashEvent -Kind "evidence.test" -StartPath $root -Data $Data
    }
}

# --- 経路A: 開いているエディタの中で回す（-Editor）------------------------------
# Unity をもう1つ起動しないので桁違いに速い（実測 EditMode 4件で 約3秒 / batchmode 約48秒）。
# **PlayMode は使えない**（com.unity.pipeline 0.4.0-exp.1 では Summary.Total=0 のまま返る）ので、
# PlayMode は batchmode 経路に任せる
if ($Editor) {
    if ($Mode -ne "EditMode") {
        throw ("-Editor は EditMode のみ対応です（com.unity.pipeline がエディタ内 PlayMode 実行を" +
               "まだ返さないため）。PlayMode は -Editor を外して batchmode で実行してください")
    }
    if (-not $unityCli) {
        throw ("-Editor には Unity CLI が必要です: https://docs.unity.com/en-us/unity-cli 。" +
               "-Editor を外せば Unity 本体の batchmode で同じテストを実行できます")
    }

    function Invoke-Pipeline {
        param([string[]]$CmdArgs, [switch]$AllowFail)
        $raw = & $unityCli cmd --project-path $projectDir @CmdArgs --format json --no-banner 2>&1 | Out-String
        $parsed = $null
        try { $parsed = $raw | ConvertFrom-Json } catch {}
        if (-not $AllowFail -and (-not $parsed -or -not $parsed.success)) {
            throw "unity cmd $($CmdArgs -join ' ') が失敗: $raw"
        }
        $parsed
    }

    # エディタ未接続なら起動して待つ（run-e2e.ps1 -Editor と同じ運用）
    # ドメインリロード中などは status が一瞬応答しないことがある。1 回の失敗で
    # 「未接続」と決めない（決めると下でエディタを起動しにいく）
    $statusJson = $null
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Seconds 2 }
        $status = & $unityCli status --project-path $projectDir --format json --no-banner 2>&1 | Out-String
        try { $statusJson = $status | ConvertFrom-Json } catch { $statusJson = $null }
        if ($statusJson -and $statusJson.success -and $statusJson.data.count -ge 1) { break }
    }
    if (-not $statusJson -or -not $statusJson.success -or $statusJson.data.count -lt 1) {
        # **既に開いているプロジェクトを二重に開かない**。Unity は開いている間 Temp\UnityLockfile を作る。
        # status が一時的に応答しないだけで `unity open` すると、利用者の画面に
        # 「プロジェクトは既に開かれています」ダイアログが出て操作を奪う（実際に出した）
        # エディタが動いている（ロックファイルがある）なら、応答しない理由の大半は
        # **コンパイル/ドメインリロード中**。数秒であきらめず、腰を据えて待つ
        # （C# を直した直後に -Editor を叩くのは日常なので、ここで落ちると使い物にならない）
        if (Test-UnityProjectLocked -ProjectDir $projectDir) {
            Write-Host "[$projectName] エディタは起動中だが Pipeline が応答しない（コンパイル中の可能性）。最大 300 秒待ちます..."
            $wait = [System.Diagnostics.Stopwatch]::StartNew()
            while ($wait.Elapsed.TotalSeconds -lt 300) {
                Start-Sleep -Seconds 3
                $status = & $unityCli status --project-path $projectDir --format json --no-banner 2>&1 | Out-String
                try { $statusJson = $status | ConvertFrom-Json } catch { $statusJson = $null }
                if ($statusJson -and $statusJson.success -and $statusJson.data.count -ge 1) { break }
            }
            Write-Host "[$projectName] 待機 $([int]$wait.Elapsed.TotalSeconds) 秒"
        }
    }
    if (-not $statusJson -or -not $statusJson.success -or $statusJson.data.count -lt 1) {
        if (Test-UnityProjectLocked -ProjectDir $projectDir) {
            # 何が返ってきたのかを必ず見せる（「接続していません」だけでは切り分けようがない）
            $lastStatus = ($status -replace "\s+", " ").Trim()
            if ($lastStatus.Length -gt 300) { $lastStatus = $lastStatus.Substring(0, 300) + " …" }
            throw ("エディタは既にこのプロジェクトを開いていますが、Pipeline に接続していません: $projectDir。" +
                   "二重起動はしません。エディタ側で com.unity.pipeline が入っているか（Package Manager）、" +
                   "接続が生きているか（unity status）を確認してください。" +
                   "エディタを閉じてよいなら -Editor を外して batchmode で実行できます。" +
                   "`n  status の応答: $lastStatus")
        }
        Write-Host "[$projectName] エディタ未接続。Pipeline パッケージを確認してエディタを起動します..."
        & $unityCli pipeline install --project-path $projectDir --format json --no-banner | Out-Null
        Start-Process -FilePath $unityCli -ArgumentList @("open", $projectDir) | Out-Null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            Start-Sleep -Seconds 5
            $status = & $unityCli status --project-path $projectDir --format json --no-banner 2>&1 | Out-String
            try { $statusJson = $status | ConvertFrom-Json } catch { $statusJson = $null }
            if ($statusJson -and $statusJson.success -and $statusJson.data.count -ge 1 -and
                $statusJson.data.instances[0].state -eq "ready") { break }
            if ($sw.Elapsed.TotalSeconds -gt 600) { throw "エディタの Pipeline 接続待ちがタイムアウト（600秒）。Editor.log を確認" }
        }
        Write-Host "[$projectName] エディタ接続完了（$([int]$sw.Elapsed.TotalSeconds)秒）"
    }

    # 直前の編集を反映させてから走らせる（未コンパイルのまま古いアセンブリで通ると偽の緑になる）。
    # recompile_status の result は**オブジェクトではなく JSON 文字列**で返るため正規化する
    # **ここで妥協すると「古いアセンブリで通った緑」を返す**ことになるので、
    # 応答不能・タイムアウトは黙って進まずに止める（-AllowFail を使わない）
    Write-Host "[$projectName] コンパイルを確認中..."
    Invoke-Pipeline @("recompile") | Out-Null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $compileDone = $false
    while ($sw.Elapsed.TotalSeconds -lt 300) {
        $probe = Invoke-Pipeline @("recompile_status")
        $state = $probe.data.result
        # recompile_status の result は**オブジェクトではなく JSON 文字列**で返る
        if ($state -is [string]) {
            try { $state = $state | ConvertFrom-Json }
            catch { throw "recompile_status の応答を解釈できません: $($probe.data.result)" }
        }
        $phase = "$($state.status)$($state.state)"
        if (-not $phase) { throw "recompile_status が状態を返しません（Unity CLI / pipeline の版を確認）" }
        if ($phase -notmatch "compil|reload|pending|running") { $compileDone = $true; break }
        Start-Sleep -Milliseconds 700
    }
    if (-not $compileDone) {
        throw ("コンパイルが 300 秒で終わりません（最後の状態: $phase）。" +
               "エディタの Console でコンパイルエラーを確認してください。" +
               "この状態で走らせると古いアセンブリのまま緑になりうるので中断します")
    }

    Write-Host "[$projectName] $Mode テストを実行中（開いているエディタ内）..."
    $cmdArgs = @("run_tests", "--mode", "editor", "--timeout", $TimeoutSeconds)
    if ($Filter) { $cmdArgs += @("--filter", $Filter) }
    $response = Invoke-Pipeline $cmdArgs
    $result = $response.data.result
    $summary = $result.Summary

    Write-Host ""
    Write-Host "=== $Mode テスト結果（エディタ内 run_tests） ==="
    Write-Host ("  合計 $($summary.Total) / 成功 $($summary.Passed) / 失敗 $($summary.Failed) / " +
                "スキップ $($summary.Skipped) / $([math]::Round([double]$result.Duration, 1))秒")
    foreach ($case in @($result.Results | Where-Object { $_.Status -ne "Passed" -and $_.Status -ne "Skipped" })) {
        Write-Host ""
        Write-Host "  [$($case.Status)] $($case.FullName)"
        if ($case.Message) { Write-Host "    $($case.Message.Trim())" }
        if ($case.StackTrace) {
            ($case.StackTrace -split "`n" | Select-Object -First 3) | ForEach-Object { Write-Host "    $($_.Trim())" }
        }
    }
    Write-Host ""

    $total = [int]$summary.Total
    $failedCount = [int]$summary.Failed
    if ($total -eq 0) {
        Write-Warning "テストが 0 件でした（$Mode）。テストアセンブリと -Filter を確認"
    }
    # **0 件は成功ではない**（フィルタ誤り・アセンブリ未検出）
    $ok = ($failedCount -eq 0 -and $total -gt 0)
    Send-TestEvidence @{
        suite = "unity-$($Mode.ToLower())"; project = $projectName; via = "editor"
        total = $total; passed = [int]$summary.Passed; failed = $failedCount
        skipped = [int]$summary.Skipped; durationSec = [double]$result.Duration
        ok = $ok; exitCode = $(if ($ok) { 0 } else { 1 })
    }
    if (-not $ok) { exit 1 }
    exit 0
}

# --- 経路B: batchmode（Unity をもう1つ起動する）---------------------------------
Write-Host "[$projectName] $Mode テストを実行中（Unity の起動を含むため数分かかります）..."

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
# （ダッシュボード連携のヘルパーは経路A/B 共通なので上で読み込んでいる）
if (-not (Test-Path $Output)) {
    Send-TestEvidence @{
        suite = "unity-$($Mode.ToLower())"; project = $projectName
        ok = $false; exitCode = $exit; error = "結果XMLが出力されなかった（$via）"
        reportPath = $Output; logPath = $logFile
    }
    # exit=6 は Unity のプロジェクトロック。事前検出をすり抜けた場合（pipeline 未導入の
    # エディタが開いている等、`unity status` に出ないケース）でも、ここで意味を言う
    $hint = if ($exit -eq 6) {
        "エディタがこのプロジェクトを開いている可能性が高い（exit=6 は Unity のプロジェクトロック）。エディタを閉じて再実行"
    } else { "Unity のログを確認" }
    throw "テスト結果が出力されませんでした（$via / exit=$exit）: $Output。$hint"
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

# 結果を1行記録する（ダッシュボード未導入なら何もしない）。
# **テスト0件は成功ではない**（フィルタ誤り・アセンブリ未検出）ので ok=false で記録する
Send-TestEvidence @{
    suite       = "unity-$($Mode.ToLower())"
    project     = $projectName
    ok          = ($exit -eq 0 -and [int]$run.failed -eq 0 -and [int]$run.total -gt 0)
    passed      = [int]$run.passed
    failed      = [int]$run.failed
    skipped     = [int]$run.skipped
    total       = [int]$run.total
    exitCode    = $exit
    durationSec = [math]::Round([double]$run.duration, 1)
    reportPath  = $Output
    logPath     = $logFile
}
if ($exit -ne 0 -or [int]$run.failed -gt 0) { exit 1 }
Write-Host "[$projectName] $Mode テスト成功。"
exit 0
