# エディタの Play を停止 → 再生し直す（Play をまたぐテストの部品。Unity CLI 必須）。
# 使い方: .\scripts\restart-editor-play.ps1 [-Project unity-nis] [-ProjectPath <Unityプロジェクト>]
#
# 用途: 「新規ユーザーからやり直す」等、メモリ上の状態を捨てたいテスト。
# 導入先実測では editor_stop → 数秒 → editor_play 再試行（停止から約 7 秒後に成功）で
# 1 プロセスの中で Play をまたげた。各プロジェクトが同じポーリングを書き直さなくて済むよう、
# その手順をここに置く。**ブリッジ復帰の待機はドライバ側の `wait_for_bridge(timeout)` を使う**
# （接続はテストコードの側にあるべきで、このスクリプトはエディタ操作だけを受け持つ）。
param(
    [string]$Project = "unity-nis",   # このリポジトリ内のサンプル名（uapp_e2e開発用）
    [string]$ProjectPath,             # 任意の場所のUnityプロジェクト（導入先ではこちら）
    [int]$PlayRetrySeconds = 60       # editor_play が成功するまでの再試行上限（停止直後は失敗する）
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "uapp-platform.ps1")   # OS 差分の吸収（Windows / macOS。mac は暫定・未検証）

$cliGlobalArgs = Get-UappUnityCliGlobalArgs -ProxyDisable:(Resolve-UappUnityCliProxyDisable)
$root = (Resolve-Path -LiteralPath (Join-UappPath $PSScriptRoot "..")).Path

# プロジェクト解決は他スクリプトと同じ規則: -ProjectPath 優先 → キット親がUnityプロジェクト → $root\$Project
if ($ProjectPath) {
    $projectDir = (Resolve-Path -LiteralPath $ProjectPath).Path
}
elseif ((Test-Path -LiteralPath (Join-UappPath $root "..\Assets")) -and (Test-Path -LiteralPath (Join-UappPath $root "..\ProjectSettings"))) {
    $projectDir = (Resolve-Path -LiteralPath (Join-UappPath $root "..")).Path
}
else {
    $projectDir = Join-UappPath $root $Project
}
if (-not (Test-Path -LiteralPath $projectDir)) { throw "プロジェクトがありません: $projectDir" }
$projectDir = Get-UappNormalizedDir $projectDir
$projectName = Split-Path $projectDir -Leaf

$unityCli = Get-UappUnityCli
if (-not $unityCli) {
    throw "Unity CLI が見つかりません（このスクリプトは Play の停止・再生に Unity CLI を使います）"
}

function Invoke-Cli {
    param([string[]]$CmdArgs)
    # CLI の出力（UTF-8）をコンソール符号化で復号しない（run-unity-tests.ps1 と同じ理由:
    # cp932 だとマルチバイトの後続バイトが `"` を飲み込み JSON が壊れる）
    $prevEnc = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $raw = & $unityCli @cliGlobalArgs cmd --project-path $projectDir @CmdArgs --format json --no-banner 2>&1 | Out-String
    } finally { [Console]::OutputEncoding = $prevEnc }
    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json } catch {}
    return $parsed
}

# run-e2e.ps1 -Editor と同じプロセス間ロックを取る（同じ名前のヘルパで組み立てる）。
# これが無いと、別ターミナルで進行中の E2E 実行の Play をこのスクリプトが途中で落とせてしまう。
# ただし **run-e2e -Editor 配下のテストから呼ばれた場合は親が同じ mutex を保持している**
# （pytest 実行中も保持し続ける）。それを「別プロセスの実行」と誤認して拒否すると
# Play またぎテストという本来用途が成立しないため、親は UAPP_E2E_EDITOR_LOCK に
# 保持中の mutex 名を渡し、**名前が一致するときだけ**同一実行単位として素通しする
$mutexName = Get-UappEditorPlayMutexName $projectDir
$editorMutex = $null
$mutexAcquired = $false
# 素通し条件は「名前一致」だけでは足りない（再レビュー指摘: 親が死んだ後に残った子が、
# 次の実行が取った排他を stale トークンで素通りできる。PID の生存確認も不成立 ―
# `.\scripts\run-e2e.ps1` はシェル内で動くので $PID は対話シェルを指し、実行が終わっても
# 生き続ける）。**親の実行だけが保持するリース mutex（実行ごとのランダム名）**で確かめる:
# 今も誰かが保持していれば親の実行は続いている。取得できてしまったら親はもう手放している
# （＝stale）ので、通常の排他取得へ落とす。これは同一マシン・同一ユーザーの協調ガードであり、
# 敵対プロセス対策ではない
$leaseHeld = $false
if ($env:UAPP_E2E_EDITOR_LOCK_SESSION) {
    $lease = New-Object System.Threading.Mutex($false, $env:UAPP_E2E_EDITOR_LOCK_SESSION)
    $leaseAcquired = $false
    try { $leaseAcquired = $lease.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $leaseAcquired = $true }
    if ($leaseAcquired) { $lease.ReleaseMutex() } else { $leaseHeld = $true }
    $lease.Dispose()
}
if ($env:UAPP_E2E_EDITOR_LOCK -eq $mutexName -and $leaseHeld) {
    Write-Host "[$projectName] 親の -Editor 実行（同一実行単位）の排他内で動作します"
}
else {
    $editorMutex = New-Object System.Threading.Mutex($false, $mutexName)
    try { $mutexAcquired = $editorMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $mutexAcquired = $true }
    if (-not $mutexAcquired) {
        throw ("このプロジェクトへの -Editor 実行が別プロセスで進行中です（run-e2e.ps1 -Editor など）。" +
               "その実行の Play を落とすことになるため中断しました。完了を待って再実行してください")
    }
}
try {

# 1. 停止 →「実際に止まった」ことを editor_status で確かめる。
#    editor_stop の成否だけでは足りない: stop が一時的に失敗しても、後段の editor_play は
#    「すでに Play 中」で success を返しうる（＝メモリ状態を捨てていないのに再起動成功と報告する）
Write-Host "[$projectName] Play を停止します..."
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$stopped = $false
while ($sw.Elapsed.TotalSeconds -lt $PlayRetrySeconds) {
    Invoke-Cli @("editor_stop") | Out-Null
    $status = Invoke-Cli @("editor_status")
    # ドメインリロード中は status 自体が応答しない（$null）。それは「まだ確認できない」であって
    # 「止まった」ではないので、確認できるまで待つ
    if ($status -and $status.success -and $status.data.result.playMode -eq "stopped") { $stopped = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $stopped) {
    throw ("editor_stop 後 $PlayRetrySeconds 秒待っても playMode=stopped を確認できません。" +
           "エディタの状態を確認してください（unity-editor-status.ps1 で状態を見る）")
}

# 2. 再生（停止直後はドメインリロード等で受け付けないため、成功するまで再試行する。
#    導入先実測: 停止から約 7 秒後に成功）。再試行枠は停止側と別に取る
#    （共有すると停止確認に時間を使った分だけ再生の再試行が痩せる）
Write-Host "[$projectName] Play を再開します（受付まで再試行）..."
$sw.Restart()
while ($true) {
    $result = Invoke-Cli @("editor_play")
    if ($result -and $result.success) { break }
    if ($sw.Elapsed.TotalSeconds -ge $PlayRetrySeconds) {
        throw ("editor_play が $PlayRetrySeconds 秒で成功しません。エディタの状態を確認してください" +
               "（unity-editor-status.ps1 で状態を見る）")
    }
    Start-Sleep -Seconds 2
}
# 文字列連結は行末 `+` では継続しない（このリポジトリで実際に表示が壊れた既知の罠）
Write-Host ("[$projectName] Play 再開（停止から $([int]$sw.Elapsed.TotalSeconds) 秒）。" +
            "ブリッジへの再接続はドライバの wait_for_bridge(timeout) を使ってください")
exit 0

} finally {
    if ($mutexAcquired) { $editorMutex.ReleaseMutex() }
    if ($editorMutex) { $editorMutex.Dispose() }
}
