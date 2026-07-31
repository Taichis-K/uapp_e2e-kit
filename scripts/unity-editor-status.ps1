# 「**このプロジェクト**の Unity エディタが開いているか」を判定して表示する。
# 使い方: .\scripts\unity-editor-status.ps1 [-Project unity-nis] [-ProjectPath <Unityプロジェクト>] [-Json]
#
# **`Get-Process Unity` では判定できない**。マシン上に Unity プロセスが居ることと、
# 対象プロジェクトが開かれていることは別物で、混同すると次の 2 つの事故が起きる:
#   - 別プロジェクトのエディタを「自分のだ」と思って強制終了する（他人の未保存作業を壊す）
#   - 自分のプロジェクトは閉じているのに「開いている」と誤判定して batchmode を諦める（逆も同様）
#
# **単一の根拠では判定できない**（2026-07-30 に Unity 6000.3.6f1 で実測）。3 つを合成する:
#   1. `-projectPath <対象>` を持つ Unity.exe プロセス … 起動直後から分かる唯一の信号。
#      ただし GUI 起動でこの引数が付かない経路があると取りこぼす
#   2. `Library\EditorInstance.json` の `process_id` が生存しているか … Unity 自身が書く。
#      **ロード完了後にしか書かれず、異常終了すると古い pid のまま残る**（生存確認が必須）
#   3. `Temp\UnityLockfile` を排他オープンできるか … 従来ここだけを見ていたが、
#      **開いていても排他オープンできてしまう状態を実測した**（起動途中・ダイアログ待ちのとき）。
#      ファイルの存在で見るのも誤り（異常終了の残骸が残り、永久に「開いている」と言い続ける）
#
# 実測で見つかった厄介な状態: **プロセスは対象プロジェクトで起動しているのに、
# モーダルダイアログ（例 "Recovering Scene Backups"）で止まっていて 2 も 3 も立たない**。
# この状態は batchmode も -Editor も失敗するので、「使えない・人の操作が必要」として区別して出す。
param(
    [string]$Project = "unity-nis",   # このリポジトリ内のサンプル名（uapp_e2e開発用）
    [string]$ProjectPath,             # 任意の場所のUnityプロジェクト（導入先ではこちら）
    [int]$CliTimeoutSeconds = 30,     # unity status の打ち切り（CLI は認証切れで無言ハングする）
    [switch]$Json                     # 機械可読出力（AI やラッパーから使う）
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path "$PSScriptRoot\..").Path

# プロジェクト解決は他スクリプトと同じ規則: -ProjectPath 優先 → キット親がUnityプロジェクト → $root\$Project
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

function Test-UnityProjectLocked {
    param([Parameter(Mandatory)][string]$Dir)
    $lock = Join-Path $Dir "Temp\UnityLockfile"
    if (-not (Test-Path -LiteralPath $lock)) { return $false }
    try {
        $stream = [System.IO.File]::Open($lock, "Open", "ReadWrite", "None")
        $stream.Close()
        return $false          # 排他で開けた＝誰も掴んでいない（異常終了後の残骸）
    } catch {
        return $true
    }
}

# マシン上の Unity プロセスを列挙し、**それぞれがどのプロジェクトのものか**を推定する。
# 判定材料: コマンドラインの -projectPath（batchmode / Hub 起動で付く）→ 無ければウィンドウ
# タイトルの先頭（"<プロジェクト名> - <シーン> - <プラットフォーム> - Unity 6.x"）
function Get-UnityProcesses {
    $result = @()
    $procs = @(Get-Process Unity -ErrorAction SilentlyContinue)
    if (-not $procs) { return $result }
    $cim = @{}
    try {
        foreach ($p in Get-CimInstance Win32_Process -Filter "Name='Unity.exe'" -ErrorAction Stop) {
            $cim[[int]$p.ProcessId] = $p.CommandLine
        }
    } catch { }
    foreach ($p in $procs) {
        $cmd = $cim[[int]$p.Id]
        $path = $null
        if ($cmd -and $cmd -match '-projectPath\s+"?([^"]+?)"?(\s+-|\s*$)') { $path = $Matches[1].Trim() }
        $title = $p.MainWindowTitle
        $name = if ($path) { Split-Path $path -Leaf }
                elseif ($title -and $title -match '^(.+?)\s+-\s') { $Matches[1] }
                else { $null }
        $isTarget = $false
        if ($path) {
            try { $isTarget = ((Resolve-Path -LiteralPath $path).Path.TrimEnd('\') -ieq $projectDir.TrimEnd('\')) } catch { }
        } elseif ($name) {
            $isTarget = ($name -ieq $projectName)   # パスが取れないときは名前一致（弱い根拠）
        }
        $result += [pscustomobject]@{
            pid          = $p.Id
            project      = $name
            projectPath  = $path
            batchmode    = [bool]($cmd -and $cmd -match '(^|\s)-batchmode(\s|$)')
            hasWindow    = [bool]$title
            isTarget     = $isTarget
            evidence     = if ($path) { "commandLine" } elseif ($name) { "windowTitle" } else { "unknown" }
        }
    }
    return $result
}

# Unity CLI があれば pipeline の接続状況も見る（Play 中かどうかはここでしか分からない）。
# **時間制限つきで呼ぶ**: CLI は認証セッションが切れると無言で 10 分以上返らない
function Get-CliStatus {
    param([string]$Cli)
    if (-not $Cli) { return $null }
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $Cli -PassThru -NoNewWindow `
            -ArgumentList @("status", "--project-path", "`"$projectDir`"", "--format", "json", "--no-banner") `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if (-not $p.WaitForExit($CliTimeoutSeconds * 1000)) {
            try { $p.Kill() } catch { }
            return [pscustomobject]@{ available = $true; timedOut = $true; connected = $false; state = $null }
        }
        $raw = ((Get-Content $outFile -Raw -ErrorAction SilentlyContinue) +
                (Get-Content $errFile -Raw -ErrorAction SilentlyContinue))
        $json = $null
        try { $json = $raw | ConvertFrom-Json } catch { }
        $connected = [bool]($json -and $json.success -and $json.data.count -ge 1)
        return [pscustomobject]@{
            available = $true
            timedOut  = $false
            connected = $connected
            state     = if ($connected) { $json.data.instances[0].state } else { $null }
        }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

$cli = (Get-Command unity -ErrorAction SilentlyContinue).Source
if (-not $cli) {
    $candidate = Join-Path $env:LOCALAPPDATA "Unity\bin\unity.exe"
    if (Test-Path $candidate) { $cli = $candidate }
}

function Get-EditorInstance {
    param([Parameter(Mandatory)][string]$Dir)
    $file = Join-Path $Dir "Library\EditorInstance.json"
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try { $json = Get-Content $file -Raw | ConvertFrom-Json } catch { return $null }
    # $pid は PowerShell の読み取り専用変数（自プロセスの PID）なので使えない
    $editorPid = [int]($json.process_id)
    $proc = if ($editorPid) { Get-Process -Id $editorPid -ErrorAction SilentlyContinue } else { $null }
    [pscustomobject]@{
        pid     = $editorPid
        alive   = [bool]($proc -and $proc.ProcessName -eq "Unity")   # 古い pid の使い回しで誤検出しない
        version = $json.version
    }
}

$locked = Test-UnityProjectLocked -Dir $projectDir
$procs = Get-UnityProcesses
$instance = Get-EditorInstance -Dir $projectDir
$cliStatus = Get-CliStatus -Cli $cli

$targetProcs = @($procs | Where-Object { $_.isTarget -and -not $_.batchmode })
$instanceAlive = [bool]($instance -and $instance.alive)
$pipelineOk = [bool]($cliStatus -and $cliStatus.connected)
# **使える状態か**（-Editor 系が成立するか）と、**占有しているか**（batchmode が失敗するか）は別。
# 起動途中・ダイアログ待ちは「占有しているが使えない」＝どちらの経路もダメで人の操作が要る
$occupied = [bool]($targetProcs.Count -gt 0 -or $instanceAlive -or $locked)
$usable = [bool]($pipelineOk -or $instanceAlive)
$state = if (-not $occupied) { "closed" }
         elseif ($usable) { "open" }
         else { "starting-or-blocked" }

$report = [pscustomobject]@{
    project          = $projectName
    projectPath      = $projectDir
    state            = $state       # closed / open / starting-or-blocked
    occupied         = $occupied    # true なら batchmode（build / test）は排他ロックで失敗する
    usable           = $usable      # true なら -Editor 系（エディタ直結E2E・エディタ内テスト）が使える
    signals          = [pscustomobject]@{
        processWithProjectPath = $targetProcs.Count
        editorInstanceJson     = $instance
        lockfileHeld           = $locked
        pipelineConnected      = $pipelineOk
    }
    unityProcesses   = $procs.Count                              # マシン上の Unity プロセス総数
    othersOnly       = [bool](-not $occupied -and $procs.Count -gt 0)
    processes        = $procs
    pipeline         = $cliStatus
}

if ($Json) {
    $report | ConvertTo-Json -Depth 5
    exit 0
}

Write-Host "プロジェクト: $projectName（$projectDir）"
switch ($state) {
    "closed" { Write-Host "  このプロジェクトのエディタ: **開いていない**" }
    "open"   { Write-Host "  このプロジェクトのエディタ: **開いている**（使える状態）" }
    default  {
        Write-Host "  このプロジェクトのエディタ: **起動途中か、ダイアログ待ちで止まっている**"
        Write-Host "    → batchmode も -Editor も失敗する。エディタの画面を見て（ダイアログを閉じて）から再実行する"
        foreach ($p in $targetProcs) {
            if ($p.hasWindow) { Write-Host ("    ウィンドウタイトル: " + (Get-Process -Id $p.pid -ErrorAction SilentlyContinue).MainWindowTitle) }
        }
    }
}
Write-Host ("    根拠: -projectPath 一致プロセス={0} / EditorInstance.json={1} / ロックファイル保持={2} / Pipeline={3}" -f `
    $targetProcs.Count,
    $(if ($instance) { "pid=$($instance.pid) 生存=$($instance.alive)" } else { "なし" }),
    $locked, $pipelineOk)
if ($cliStatus) {
    if ($cliStatus.timedOut) {
        Write-Host "  Unity CLI: $CliTimeoutSeconds 秒で応答なし（認証切れの可能性。'unity doctor' / 'unity auth login'）"
    } elseif ($cliStatus.connected) {
        Write-Host "  Pipeline 接続: あり（state=$($cliStatus.state)）＝エディタ直結E2E / エディタ内テストが使える"
    } else {
        Write-Host "  Pipeline 接続: なし（-Editor 系を使うには com.unity.pipeline と接続が必要）"
    }
} else {
    Write-Host "  Unity CLI: 未検出（-Editor 系は使えない。batchmode 経路のみ）"
}
Write-Host "  マシン上の Unity プロセス: $($procs.Count) 個"
foreach ($p in $procs) {
    $mark = if ($p.isTarget) { "→ このプロジェクト" } else { "  （別プロジェクト）" }
    $who = if ($p.project) { $p.project } else { "不明" }
    $mode = if ($p.batchmode) { "batchmode" } elseif ($p.hasWindow) { "GUI" } else { "不明" }
    Write-Host ("    pid={0,-6} {1,-22} {2,-10} 根拠={3} {4}" -f $p.pid, $who, $mode, $p.evidence, $mark)
}
if ($report.othersOnly) {
    Write-Host "  ※ Unity プロセスは居るが、**このプロジェクトのものではない**"
    Write-Host "    （プロセスの有無で判断すると、他プロジェクトの作業中エディタを巻き込む）"
}
Write-Host ""
Write-Host "使い分け:"
Write-Host "  open                → run-e2e.ps1 -Editor / run-unity-tests.ps1 -Editor（batchmode は排他ロックで失敗する）"
Write-Host "  closed              → run-unity-tests.ps1（batchmode）/ build-android.ps1"
Write-Host "  starting-or-blocked → どちらも実行しない（エディタの画面を確認する）"
exit 0
