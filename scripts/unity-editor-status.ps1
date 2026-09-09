# 「**このプロジェクト**の Unity エディタが開いているか」を判定して表示する。
# 使い方: .\scripts\unity-editor-status.ps1 [-Project unity-nis] [-ProjectPath <Unityプロジェクト>] [-Json]
#
# ## `state` が取りうる値（**全列挙。ここが正**。値を増やしたら必ずここに足すこと）
#
# | state | 意味 | ラッパー側の扱い |
# |---|---|---|
# | closed              | 対象プロジェクトを掴んでいるものが無い | batchmode（テスト/ビルド）が使える |
# | open                | 開いていて使える | `-Editor` 系が使える（batchmode は排他で失敗） |
# | starting-or-blocked | 起動途中かモーダルダイアログ待ち | どちらも実行しない（画面を確認する） |
# | unknown             | プロセスを列挙できず判定できない（理由は `warnings`） | **closed として扱わない**。占有されている前提で待つ/原因を直す |
#
# **実行時に出た値だけを見て分岐を書かないこと**（3 値の頃にそう書かれたラッパーが、
# v0.1.8 の `unknown` 追加で「判定できなかった」を「閉じている」と読む状態になった。
# 導入先の実例あり）。`-Json` の分岐はこの表に対して網羅で書き、**未知の値は
# starting-or-blocked と同じ「実行しない」側へ落とす**のが安全。
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
    [switch]$Json,                    # 機械可読出力（AI やラッパーから使う）
    # Unity CLI の呼び出しに `--proxy-disable` を付ける（既定オフ）。プロキシ配下では CLI が
    # localhost 宛ての Pipeline 通信までプロキシへ流し 503 になり、Pipeline 接続が
    # 「なし」と誤判定される（詳細は uapp-platform.ps1 の Get-UappUnityCliGlobalArgs）。
    # 環境変数 UAPP_E2E_UNITY_CLI_PROXY_DISABLE=1 でも同じ
    [switch]$UnityCliProxyDisable,
    # **exec の疎通まで見るときの打ち切り**（issue #60）。メインスレッドが空いていれば
    # eval は即返るので短くてよい。0 を渡すとプローブ自体を打たない
    [int]$ExecProbeTimeoutSeconds = 15
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "uapp-platform.ps1")   # OS 差分の吸収（Windows / macOS。mac は暫定・未検証）

# CLI のグローバル引数は 1 か所で決めて全呼び出しへ渡す（check-portability.ps1 が検査する）
$cliGlobalArgs = Get-UappUnityCliGlobalArgs -ProxyDisable:(Resolve-UappUnityCliProxyDisable -Switch:$UnityCliProxyDisable)
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
# **末尾の `\` を落とす**（run-e2e.ps1 / run-unity-tests.ps1 と同じ正規化）。
# タブ補完は `unity-nis\` の形を作り、`Resolve-Path` はそれを保つ。付いたまま引用すると
# 閉じ引用符が `\"` と解釈され、**後続の引数までパスに飲み込まれる**。
# **ドライブ直下（`C:\`）だけは落とせない** — `C:` はドライブ相対を指す別物になるため。
# この 1 ケースは引用側（Format-CliArg）で吸収するので、パスの引用は必ずそこを通すこと
$projectDir = Get-UappNormalizedDir $projectDir
$projectName = Split-Path $projectDir -Leaf

function Format-CliArg {
    <#
      .SYNOPSIS
      ネイティブプロセスへ渡す引数 1 個を引用する（末尾の `\` を正しく退避する）。

      .NOTES
      **閉じ引用符の直前の `\` は、引用符そのものをエスケープする**（Windows の引数解釈規則）。
      `"C:\"` は 1 引数として閉じず、後続の引数まで飲み込む（実測: `--project-path "C:\"
      --format json --no-banner` が 1 引数になる）。末尾の `\` だけを倍にすればリテラルの
      `\` 1 個として渡り、**値そのものは変わらない**。

      $projectDir は末尾の `\` を落として正規化してあるが、**ドライブ直下（`C:\`）だけは
      落とせない** — `C:` はドライブ相対（そのドライブのカレントディレクトリ）を指す別物になる。
      `C:\.` のような等価表現でも代用できない: **Unity CLI はプロジェクトパスを正規化せず
      文字列で突き合わせる**ので、実行中のエディタに一致しなくなる
      （実測: `unity status --project-path <プロジェクト>\.` が STATUS_NO_INSTANCES を返す）。
      値を保ったまま安全に渡せるのはこの引用だけなので、パスの引用は必ずここを通す。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    # `"` の直前の `\` は連続ぶんだけ倍にしてから `\"` で退避し、末尾の `\` も倍にする
    $escaped = [regex]::Replace($Value, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
    $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
    return '"' + $escaped + '"'
}

function Test-UnityProjectLocked {
    # **mac ではこの信号は当てにならない**（暫定対応・未検証）: Unix のファイルロックは
    # 助言的で、.NET の FileShare.None は他プロセスの排他を再現しない。つまり Unity が
    # 掴んでいても排他オープンに成功しうる＝常に「保持されていない」に倒れる。
    # 判定は残る 2 信号（-projectPath 一致プロセス / EditorInstance.json）で行う想定
    param([Parameter(Mandatory)][string]$Dir)
    $lock = Join-UappPath $Dir "Temp\UnityLockfile"
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
    # プロセス列挙とコマンドライン取得は OS で手段が違う（uapp-platform.ps1 に集約）。
    # **mac ではウィンドウタイトルが取れない**ので、タイトル由来の推定は効かない
    # （代わりに ps から全プロセスの引数が読めるため -projectPath 側で判定できる）
    foreach ($p in (Get-UappUnityProcess)) {
        $cmd = $p.CommandLine
        $path = $null
        if ($cmd -and $cmd -match '-projectPath\s+"?([^"]+?)"?(\s+-|\s*$)') { $path = $Matches[1].Trim() }
        $title = $p.MainWindowTitle
        $name = if ($path) { Split-Path $path -Leaf }
                elseif ($title -and $title -match '^(.+?)\s+-\s') { $Matches[1] }
                else { $null }
        $isTarget = $false
        if ($path) {
            try { $isTarget = ((Get-UappNormalizedDir (Resolve-Path -LiteralPath $path).Path) -ieq (Get-UappNormalizedDir $projectDir)) } catch { }
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
            # **引き継ぎ忘れると常に「取得失敗」になる**（欠落プロパティは $null で、
            # `-not $null` が真になるため。実際にこれで全件が unknown に倒れた）
            commandLineAvailable = [bool]$p.CommandLineAvailable
        }
    }
    return $result
}

# Unity CLI があれば pipeline の接続状況も見る（Play 中かどうかはここでしか分からない）。
# **時間制限つきで呼ぶ**: CLI は認証セッションが切れると無言で 10 分以上返らない
function Test-CliExec {
    <#
      **exec が実際に通るかを 1 回だけ確かめる**（issue #60）。

      `pipeline` が ready でも、**メインスレッドが止まっていればコマンドは返らない**。
      4 つ目の信号（無効化ウィンドウ）は**モーダルしか捕まえられず**、
      **モーダルが見当たらないのに exec だけ 30 秒タイムアウトを繰り返す**状態が
      導入先で実際に起きた（15 分・CPU 0%・画面にダイアログなし。
      Input System パッケージを外した直後のドメインリロードで発生）。

      **状態を変えない eval を打つ。** 返れば「使える」が**確定する**（推定ではなくなる）。
      **分類はしない** ― 返らなかったという**観測**だけを返す。
      理由（モーダル・長い処理・リロード中）はここでは区別できないし、
      **区別できないものを断定すると、読み手が別の方向を見なくなる**。
    #>
    param([string]$Cli, [string]$ProjectDir, [int]$TimeoutSeconds)
    if (-not $Cli -or $TimeoutSeconds -le 0) {
        return [pscustomobject]@{ attempted = $false; ok = $false; timedOut = $false; seconds = 0 }
    }
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        # **cmd は --project-path でスコープする**（複数エディタが起動していても対象を間違えない）。
        # code は名前付き引数が必須（位置引数だと 400 になる）
        $p = Start-Process -FilePath $Cli -PassThru -NoNewWindow `
            -ArgumentList (@($cliGlobalArgs) + @("cmd", "--project-path", (Format-CliArg $ProjectDir),
                                                 "eval", "--code", (Format-CliArg 'return "ok";'),
                                                 "--format", "json", "--no-banner")) `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            # **子孫ごと落とす。** `Kill()` は子へ再帰しないので、CLI が別プロセスを
            # 抱えていると**打ち切ったつもりで待たされる** ―
            # 偽 CLI で実測したら、6 秒で打ち切ったのに全体は 122 秒かかった
            # （残った子がリダイレクト先のハンドルを握り続けるため）
            try { Stop-UappProcessTree -ProcessId $p.Id } catch { try { $p.Kill() } catch { } }
            $sw.Stop()
            return [pscustomobject]@{ attempted = $true; ok = $false; timedOut = $true
                                      seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
        }
        $sw.Stop()
        $raw = ((Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) +
                (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue))
        $json = $null
        try { $json = $raw | ConvertFrom-Json } catch { }
        return [pscustomobject]@{ attempted = $true; ok = [bool]($json -and $json.success)
                                  timedOut = $false
                                  seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
    } catch {
        $sw.Stop()
        return [pscustomobject]@{ attempted = $true; ok = $false; timedOut = $false
                                  seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -ErrorAction SilentlyContinue
    }
}

function Get-CliStatus {
    param([string]$Cli)
    if (-not $Cli) { return $null }
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $Cli -PassThru -NoNewWindow `
            -ArgumentList (@($cliGlobalArgs) + @("status", "--project-path", (Format-CliArg $projectDir), "--format", "json", "--no-banner")) `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if (-not $p.WaitForExit($CliTimeoutSeconds * 1000)) {
            try { $p.Kill() } catch { }
            return [pscustomobject]@{ available = $true; timedOut = $true; connected = $false
                                      instanceCount = 0; state = $null }
        }
        $raw = ((Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) +
                (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue))
        $json = $null
        try { $json = $raw | ConvertFrom-Json } catch { }
        $connected = [bool]($json -and $json.success -and $json.data.count -ge 1)
        # **「0 件」と「見つかったが繋がらない」を潰さない**（2026-09-08 の退行の真因）。
        # CLI は別物として返している: 正常= success/count 1/state ready、
        # モーダル・占有= count 1 / state unreachable / STATUS_ALL_UNREACHABLE、
        # pipeline 未導入= count 0 / STATUS_NO_INSTANCES。
        # connected だけ見ると後者 2 つが同じになり、**pipeline を入れていない健全なエディタ**
        # （手動 Play ＋ UAPP_E2E_EDITOR=1 の運用。2022.3 でも動く）まで「使えない」に落ちる
        $instanceCount = 0
        if ($json -and $json.data -and $null -ne $json.data.count) { $instanceCount = [int]$json.data.count }
        return [pscustomobject]@{
            available     = $true
            timedOut      = $false
            connected     = $connected
            instanceCount = $instanceCount
            state         = if ($connected) { $json.data.instances[0].state } else { $null }
        }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

$cli = Get-UappUnityCli

function Get-EditorInstance {
    param([Parameter(Mandatory)][string]$Dir)
    $file = Join-UappPath $Dir "Library\EditorInstance.json"
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try { $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } catch { return $null }
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
# **警告は拾って持つ**（捨てない・混ぜない）。プロセス列挙が失敗すると helper が警告を出すが、
# それをそのまま流すと **`-Json` の出力に混ざって機械可読の契約が壊れる**（読み手の
# ConvertFrom-Json / json.loads が落ちる）。ここで分離し、JSON では `warnings` に入れる
$warnings = @()
# **列挙できなかったことを「0 件」と混同しない**（混同すると開いているエディタを
# closed と報告し、読んだ側が batchmode を起動して失敗する）
$procEnumFailed = $false
try {
    $procs = @(Get-UnityProcesses 3>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.WarningRecord]) { $warnings += $_.Message } else { $_ }
    })
} catch [System.InvalidOperationException] {
    $procEnumFailed = $true
    $procs = @()
    $warnings += $_.Exception.Message
}
# コマンドラインが取れていない（Windows で CIM が失敗した）場合も「判定できない」扱いにする。
# ウィンドウタイトルで当たりが付いたならそれは活きるので、当たらなかったときだけ安全側へ倒す
if (@($procs | Where-Object { -not $_.commandLineAvailable }).Count -gt 0) {
    $procEnumFailed = $true
    $warnings += "Unity プロセスのコマンドラインを取得できないため、どのプロジェクトのものか判定できません"
}
$instance = Get-EditorInstance -Dir $projectDir
$cliStatus = Get-CliStatus -Cli $cli

$targetProcs = @($procs | Where-Object { $_.isTarget -and -not $_.batchmode })
# **同じプロジェクトの batchmode も占有**（別ターミナルの batchmode は実際にロックを握る。
# 除外すると「非占有」と答えてしまい、読んだ側が batchmode を起動して exit=6 に落ちる）
$targetBatchProcs = @($procs | Where-Object { $_.isTarget -and $_.batchmode })
$instanceAlive = [bool]($instance -and $instance.alive)
$pipelineOk = [bool]($cliStatus -and $cliStatus.connected)
# **使える状態か**（-Editor 系が成立するか）と、**占有しているか**（batchmode が失敗するか）は別。
# 起動途中・ダイアログ待ちは「占有しているが使えない」＝どちらの経路もダメで人の操作が要る
$occupied = [bool]($targetProcs.Count -gt 0 -or $targetBatchProcs.Count -gt 0 -or $instanceAlive -or $locked)
# **CLI が「繋がらない」と答えたら、EditorInstance.json の生存では覆さない**（2026-09-08・mac の実測）。
# mac ではモーダル中に `unity status` が `unreachable` を返すのに、`-or $instanceAlive` の
# 右側が勝って `open`（使える）と答えていた ― Windows とは別経路で同じ「使えないのに使えると言う」。
#
# **CLI が無い場合は覆さない**（`available` が false）。測れていないだけなので、
# 手動 Play の運用まで「使えない」と言ってしまう。**測ったうえで否定されたときだけ落とす**。
# なお `-Editor` 系は com.unity.pipeline への接続が前提なので、
# 「CLI はあるが繋がらない」は素直に「使えない」でよい
# **このプロジェクトのインスタンスを見つけたうえで繋がらない**ときだけ落とす。
# - `instanceCount -eq 0`（STATUS_NO_INSTANCES）は「CLI がこのエディタについて何も言えていない」
#   ＝**測れていない**側。ここで落とすと com.unity.pipeline 未導入の健全なエディタを止める
#   （2026-09-08 に実際に落とした。mac が旧版との A/B で発見）
# - `timedOut` も落とさない。**CLI が無言ハングしただけ**で「ダイアログを閉じろ」と言うのは誤誘導
#   （この機は unity auth status が 25 秒返らないことがある。CLAUDE.local.md に記録）
$cliDeniesUsable = [bool]($cliStatus -and $cliStatus.available -and -not $cliStatus.timedOut `
                          -and $cliStatus.instanceCount -ge 1 -and -not $cliStatus.connected)
$usable = [bool](($pipelineOk -or $instanceAlive) -and -not $cliDeniesUsable)

# **4 つ目の信号: モーダルダイアログで止まっていないか**（2026-09-08 に追加）。
# 上の 3 信号だけだと **pipeline が ready を返すのに open と答えて外す**。
# 実測: Input System の「Do you want to enable the backends?」ダイアログが出ている間、
# `unity status` は ready・EditorInstance.json も生存・ロックも保持で **open と判定された**が、
# メインスレッドは止まっており、ブリッジは接続だけ成立して応答が返らなかった
# （呼び手側は 14 分無言でリトライし続けた）。
# **「pipeline が ready」は「コマンドを実行できる」の根拠にならない** ― issue #20 で
# 「`unity status=ready` と pipeline コマンドに応答できることは別」と分かっていたのに、
# その学びが判定側へ反映されていなかった。
$modal = $null
foreach ($p in $targetProcs) {
    $probe = Test-UappEditorModalBlocked -ProcessId $p.pid
    if ($probe.determinable -and $probe.disabledWindowExists) { $modal = $probe; break }
    # **「判定できて、無効化ウィンドウが無い」を優先して残す**。
    # 判定不能を先に掴んだまま上書きしないと、実際に見た結果があるのに「未確認」と表示してしまう
    if (-not $modal -or (-not $modal.determinable -and $probe.determinable)) { $modal = $probe }
}
# **判定できた場合だけ落とす**。判定できない環境（mac 等・ウィンドウ未生成）で塞ぐと、
# 正常なエディタまで使えないと言ってしまう。判定不能は下の表示で「見ていない」と明示する
if ($modal -and $modal.determinable -and $modal.disabledWindowExists) { $usable = $false }

# **5 つ目の信号: exec が実際に通るか**（issue #60）。
# 4 つ目（無効化ウィンドウ）は**モーダルしか捕まえられない**。導入先では
# **モーダルが見当たらないのに /api/exec だけ 30 秒タイムアウトを繰り返す**状態が起きた
# （15 分・CPU 0%）。上の 4 信号はどれも「使える」と答えてしまう。
#
# **CLI が接続できているときだけ打つ。** `instanceCount = 0`（pipeline 未導入）の
# 健全なエディタへ打つと必ず失敗し、**2026-09-08 に踏んだ退行を作り直すことになる**。
# ここは「ready と言っている相手が本当に応じるか」を確かめる場所であって、
# **pipeline を使わない構成を裁く場所ではない**
$execProbe = $null
# **エディタが実在するときだけ打つ**（`$occupied`）。居ないのに CLI を呼ぶのは
# ただの無駄で、偽 CLI の検証で「closed なのに exec を打っている」のが見えた
if ($occupied -and $usable -and $cliStatus -and $cliStatus.connected) {
    $execProbe = Test-CliExec -Cli $cli -ProjectDir $projectDir -TimeoutSeconds $ExecProbeTimeoutSeconds
    if ($execProbe.attempted -and -not $execProbe.ok) { $usable = $false }
}
# **プロセス列挙に失敗したら判定しない**。3 信号のうち最重要のものが欠けている状態で
# closed と言うと、読んだ側が batchmode を起動して排他ロックで失敗する（安全側へ倒す）
if ($procEnumFailed -and -not $usable) {
    $occupied = $true
    $usable = $false
}
$state = if ($procEnumFailed -and -not $usable) { "unknown" }
         elseif (-not $occupied) { "closed" }
         elseif ($usable) { "open" }
         else { "starting-or-blocked" }

$report = [pscustomobject]@{
    project          = $projectName
    projectPath      = $projectDir
    state            = $state       # closed / open / starting-or-blocked
    # **exec の観測**（issue #60）。分類はしない ― 打ったか / 返ったか / 何秒かかったか、だけ。
    # 返らなかった理由（モーダル・長い処理・ドメインリロード）はここでは区別できない
    execProbe        = $execProbe
    occupied         = $occupied    # true なら batchmode（build / test）は排他ロックで失敗する
    usable           = $usable      # true なら -Editor 系（エディタ直結E2E・エディタ内テスト）が使える
    signals          = [pscustomobject]@{
        processWithProjectPath = $targetProcs.Count
        editorInstanceJson     = $instance
        lockfileHeld           = $locked
        pipelineConnected      = $pipelineOk
        # **「0 件」と「見つかったが繋がらない」を呼び手も区別できるようにする**。
        # close-editor は「pipeline 経由でしか閉じられない」ので、0 件なら早期に落とす
        pipelineInstanceCount  = $(if ($cliStatus) { $cliStatus.instanceCount } else { $null })
        disabledWindowExists   = $(if ($modal -and $modal.determinable) { $modal.disabledWindowExists } else { $null })
        modalWindows           = $(if ($modal -and $modal.determinable) { $modal.windows } else { @() })
    }
    unityProcesses   = $procs.Count                              # マシン上の Unity プロセス総数
    othersOnly       = [bool](-not $occupied -and $procs.Count -gt 0)
    processes        = $procs
    pipeline         = $cliStatus
    # 空でなければ「信号のどれかが取得できていない」＝判定を鵜呑みにしない材料
    warnings         = $warnings
}

if ($Json) {
    $report | ConvertTo-Json -Depth 5
    exit 0
}

foreach ($w in $warnings) { Write-Warning $w }   # 人向け表示では警告をそのまま出す
Write-Host "プロジェクト: $projectName（$projectDir）"
switch ($state) {
    "closed" { Write-Host "  このプロジェクトのエディタ: **開いていない**" }
    "open"   { Write-Host "  このプロジェクトのエディタ: **開いている**（使える状態）" }
    "unknown" {
        Write-Host "  このプロジェクトのエディタ: **判定できない**（プロセスを列挙できなかった）"
        Write-Host "    → 開いていない証拠が無いので、占有されている前提で扱う。上の警告を見て原因を直すこと"
    }
    default  {
        Write-Host "  このプロジェクトのエディタ: **起動途中か、ダイアログ待ちで止まっている**"
        Write-Host "    → batchmode も -Editor も失敗する。エディタの画面を見て（ダイアログを閉じて）から再実行する"
        # **モーダルとは限らない**（2026-09-08 に mac が実測）。プログレスバー等でメインスレッドが
        # 占有されているだけでも同じ表示になり、そちらは**待てば明ける**。
        # いきなり「プロセス終了 → Temp 削除」を案内すると、**待てばよいものに最も高くつく手順**を
        # 踏ませる ―「断定は、間違っているときに探索の方向ごと固定する」の実例なので、
        # **先に測り直しを案内する**
        Write-Host "    **まず 20〜30 秒あけて、もう一度これを実行してください**"
        Write-Host "      長い import / コンパイル / 重い処理でメインスレッドが塞がっているだけなら、待つと open へ戻ります"
        Write-Host "      （その状態と、人の操作が要るモーダルは、この判定では区別できません）"
        Write-Host "    2 回目も同じなら、人の操作が要る可能性が高い。この状態になる例:"
        Write-Host "    - プロジェクトにコンパイルエラーがあると **Enter Safe Mode? のモーダル**が出て止まる"
        Write-Host "      （2026-08-26 に Windows / macOS の両方で実測。Editor.log はコンパイルエラーの直後で更新が止まり、"
        Write-Host "        EditorInstance.json は書かれず、ロックだけ握った状態になる。Recovering Scene Backups でも同じ状態）"
        Write-Host "      復旧（**2 回目も同じだったときだけ**）: 画面でダイアログを閉じる。"
        Write-Host "        閉じられなければプロセス終了 → <プロジェクト>\Temp 削除 → 再起動"
        foreach ($p in $targetProcs) {
            # **この分岐は実質 Windows 専用**。mac 側の列挙は MainWindowTitle を $null で埋めるので
            # hasWindow が常に false になり、ここへは来ない（mac セッションの指摘）。
            # 肝心の 3 行（Safe Mode の候補・機序・復旧）はループの外なので、mac でも出る
            if ($p.hasWindow) {
                $title = (Get-Process -Id $p.pid -ErrorAction SilentlyContinue).MainWindowTitle
                if ([string]::IsNullOrWhiteSpace($title)) {
                    # **タイトルが空でも「ダイアログが無い」ではない**。モーダルは別ウィンドウで、
                    # MainWindowTitle には出ない（Safe Mode の実測時も空だった）
                    Write-Host "    ウィンドウタイトル: （空。モーダルは別ウィンドウのことがあり、ここには出ない）"
                } else {
                    Write-Host ("    ウィンドウタイトル: " + $title)
                }
            }
        }
    }
}
Write-Host ("    根拠: -projectPath 一致プロセス={0} / EditorInstance.json={1} / ロックファイル保持={2} / Pipeline={3} / モーダル={4}" -f `
    $targetProcs.Count,
    $(if ($instance) { "pid=$($instance.pid) 生存=$($instance.alive)" } else { "なし" }),
    $locked, $(if ($cliDeniesUsable -and $instanceAlive) {
                   "$pipelineOk（**CLI が繋がらないので使えない側へ倒した** ― エディタは生きているが、コマンドを受けられない）"
               } else { $pipelineOk }),
    $(if (-not $modal) { "未確認" }
      elseif (-not $modal.determinable) { "判定不能（$($modal.reason)）" }
      elseif ($modal.disabledWindowExists) { "**無効化ウィンドウあり**（$($modal.reason)）" }
      else { "なし" }))
if ($modal -and $modal.determinable -and $modal.disabledWindowExists) {
    Write-Host "    **無効化されたウィンドウがあります**（pipeline が ready でもコマンドが実行されないことがあります）"
    Write-Host "      観測したのは「無効化された可視ウィンドウがある」ことだけで、原因は断定しません。"
    Write-Host "      最も多いのはモーダルダイアログですが、**長時間処理の UI ロックでも同じ状態になります**"
    Write-Host ("      見えているウィンドウ: " + ($modal.windows -join " / "))
    Write-Host "      この状態になる例: Input System の 'Do you want to enable the backends?'"
    Write-Host "        （com.unity.inputsystem を入れて activeInputHandler が 0 のプロジェクトを GUI で開くと出る。"
    Write-Host "          **Yes を押すと 2（Both）へ変わってエディタが再起動する**ので、0 のままにしたいなら No）"
    Write-Host "      ほかに Enter Safe Mode? / Recovering Scene Backups でも同じ状態になる（断定はしない）"
    Write-Host "      復旧: 画面でダイアログを閉じる。閉じられなければプロセス終了 → <プロジェクト>\Temp 削除 → 再起動"
}

# **exec の観測を出す**（issue #60）。分類はしない ― 打ったか / 返ったか / 何秒か、だけ
if ($execProbe -and $execProbe.attempted) {
    if ($execProbe.ok) {
        Write-Host "  exec 疎通: **通った**（$($execProbe.seconds) 秒）― コマンドを受け付ける状態です"
    } elseif ($execProbe.timedOut) {
        Write-Host "  exec 疎通: **$($execProbe.seconds) 秒返らない**（打ち切り）"
        Write-Host "    pipeline が ready でも**メインスレッドが空いていなければコマンドは返りません**。"
        Write-Host "    **理由は断定しません** ― モーダル・長時間処理・ドメインリロードのどれでも同じに見えます。"
        Write-Host "    まず時間をあけて測り直してください（リロード中なら数十秒で明けます）。"
        Write-Host "    明けないなら画面を確認する（上の無効化ウィンドウの行も見る）"
    } else {
        Write-Host "  exec 疎通: **失敗**（$($execProbe.seconds) 秒。応答が JSON にならないか success でない）"
    }
}
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
Write-Host "  unknown             → 判定できない（列挙に失敗）。占有されている前提で扱い、warnings の原因を直す"
exit 0
