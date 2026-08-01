# Unity の EditMode/PlayMode テスト（内側ループ）を実行し、結果を AI が読める要約で出力する。
# E2E（外側ループ）はビルドや実機が要るため、ロジックの検証はまずこちらで回す（docs/04-ai-loop.md）。
# 使い方: .\scripts\run-unity-tests.ps1 [-Project unity-nis] [-Mode EditMode|PlayMode] [-Filter <pattern>]
#
# Unity CLI（https://docs.unity.com/en-us/unity-cli）があればそれを使い、無ければ Unity 本体の
# batchmode -runTests へ自動フォールバックする（キットは Unity CLI を必須依存にしない）。
# CLI が不調なとき（認証セッション stale 等）は -NoUnityCli で batchmode 経路に直接入れる。
# 指定しなくても、CLI が -UnityCliProbeSeconds 秒応答しなければ自動で batchmode へ切り替える。
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
    # Unity CLI を使わず、Unity 本体の batchmode 経路で実行する。
    # CLI 側だけが壊れている環境（認証セッションが stale 等）では CLI が無言でハングするため、
    # 「見つかったら必ず使う」だとフォールバック経路のコードがあるのに到達できない（issue #21）
    [switch]$NoUnityCli,
    # CLI の生存確認（unity status）を打ち切るまでの秒数。超えたら batchmode へ自動フォールバックする
    [int]$UnityCliProbeSeconds = 60,
    # EditMode は既定で -nographics（グラフィックス初期化と USB スキャンを避ける。これが無いと
    # 2022.3 でライセンス初期化後にスキャンを繰り返したまま進まない事象を実測）。
    # 描画が要る PlayMode では既定 OFF。明示指定は -NoGraphics:$true / -NoGraphics:$false（bool のため値が必須）
    [bool]$NoGraphics = ($Mode -eq "EditMode")
)

$ErrorActionPreference = "Stop"

function Test-UnityProjectLocked {
    <#
      .SYNOPSIS
      エディタがこのプロジェクトを掴んでいるか（＝batchmode が排他ロックで失敗するか）。

      .NOTES
      **単一の根拠では判定できない**（2026-07-30 に Unity 6000.3.6f1 で実測）。3 つを合成する:

      1. `-projectPath <対象>` を持つ GUI の Unity.exe プロセス … 起動直後から分かる唯一の信号
      2. `Library\EditorInstance.json` の `process_id` の生存 … Unity 自身が書くが**ロード完了後**
         にしか現れず、異常終了で古い pid が残る（生存確認が必須）
      3. `Temp\UnityLockfile` の排他オープン … 従来ここだけを見ていたが、**開いているのに
         排他オープンできてしまう状態を実測した**（起動途中・モーダルダイアログ待ち）。
         ファイルの存在で判定するのも誤り（残骸で永久に「開いています」と言い続ける）

      詳しい内訳を人が見たいときは `scripts\unity-editor-status.ps1`（プロジェクト単位の状態表示）。
    #>
    param([Parameter(Mandatory)][string]$ProjectDir)

    # 1. プロセスのコマンドラインで対象プロジェクトを掴んでいる GUI エディタを探す
    try {
        $target = (Resolve-Path -LiteralPath $ProjectDir).Path.TrimEnd('\')
        foreach ($p in Get-CimInstance Win32_Process -Filter "Name='Unity.exe'" -ErrorAction Stop) {
            $cmd = $p.CommandLine
            if (-not $cmd) { continue }
            if ($cmd -match '(^|\s)-batchmode(\s|$)') { continue }   # 自前で起動した batchmode は対象外
            if ($cmd -match '-projectPath\s+"?([^"]+?)"?(\s+-|\s*$)') {
                $path = $Matches[1].Trim()
                try { $path = (Resolve-Path -LiteralPath $path).Path.TrimEnd('\') } catch { }
                if ($path -ieq $target) { return $true }
            }
        }
    } catch { }

    # 2. Unity 自身が書く EditorInstance.json（pid の生存を必ず確かめる）
    $instanceFile = Join-Path $ProjectDir "Library\EditorInstance.json"
    if (Test-Path -LiteralPath $instanceFile) {
        try {
            $editorPid = [int]((Get-Content $instanceFile -Raw | ConvertFrom-Json).process_id)
            $proc = if ($editorPid) { Get-Process -Id $editorPid -ErrorAction SilentlyContinue } else { $null }
            if ($proc -and $proc.ProcessName -eq "Unity") { return $true }
        } catch { }
    }

    # 3. ロックファイルの排他オープン（掴まれていれば失敗する）
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
# **末尾の `\` を落とす**。タブ補完は `unity-nis\` の形を作り、`Resolve-Path` はそれを保つ。
# 付いたまま `"$projectDir"` と引用すると、閉じ引用符が `\"`（エスケープされた引用符）と
# 解釈され、**後続の引数までパスに飲み込まれる**（Windows の引数解釈規則。実測済み:
# `--project-path "…\unity-nis\" --format json --no-banner` が 1 引数になる）。
# ここで 1 度だけ正規化して、以降の全ての受け渡し（Start-Process 経由を含む）を安全にする。
# **ドライブ直下（`C:\`）だけは落とせない** — `C:` はドライブ相対を指す別物になるため。
# この 1 ケースは引用側（Format-CliArg）で吸収するので、パスの引用は必ずそこを通すこと
if ($projectDir -notmatch '^[A-Za-z]:\\$') { $projectDir = $projectDir.TrimEnd('\') }
$projectName = Split-Path $projectDir -Leaf

$buildsDir = Join-Path $root "Builds"
New-Item -ItemType Directory -Force $buildsDir | Out-Null
if (-not $Output) { $Output = Join-Path $buildsDir "test-results-$projectName-$Mode.xml" }
if (Test-Path $Output) { Remove-Item $Output -Force }   # 前回結果を誤読しない

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

function Invoke-WithTimeout {
    <#
      .SYNOPSIS
      外部コマンドを時間制限つきで実行し、@{ TimedOut; Output; ExitCode } を返す。

      .NOTES
      Unity CLI は認証セッションが stale になると**無言で数十分ハングする**（実測 10 分超）。
      `& $exe` で直に呼ぶと打ち切る手段が無く、利用者からは「何も起きない」ようにしか見えない。
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [string]$WaitMessage
    )
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -NoNewWindow `
                                 -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $announced = $false
        while (-not $process.HasExited -and $sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            # 無言で待たない（ハングと正常な待機を利用者が区別できるようにする）
            if ($WaitMessage -and $sw.Elapsed.TotalSeconds -ge 5) {
                if (-not $announced) { Write-Host $WaitMessage; $announced = $true }
                elseif ([int]$sw.Elapsed.TotalSeconds % 10 -eq 0) { Write-Host "  待機 $([int]$sw.Elapsed.TotalSeconds) 秒" }
            }
            Start-Sleep -Milliseconds 500
        }
        if (-not $process.HasExited) {
            try { $process.Kill() } catch {}
            $process.WaitForExit(10000) | Out-Null
            return @{ TimedOut = $true; Output = ""; ExitCode = $null }
        }
        $text = ((Get-Content $outFile -Raw -ErrorAction SilentlyContinue) +
                 (Get-Content $errFile -Raw -ErrorAction SilentlyContinue))
        return @{ TimedOut = $false; Output = $text; ExitCode = $process.ExitCode }
    } finally {
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-UnityCliStatus {
    <#
      .SYNOPSIS
      `unity status` を時間制限つきで叩き、@{ TimedOut; Json; Raw; ExitCode } を返す。

      .NOTES
      **パスは明示的に引用する**。`Start-Process -ArgumentList` の配列は内部で空白結合されるため、
      引用しないと空白を含むプロジェクトパスが複数引数に割れ、CLI が引数エラーで即座に返る
      （＝タイムアウトにはならないので不調に見えず、判定だけが静かに壊れる）。
    #>
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$ProjectDir,
        [int]$TimeoutSeconds = 60,
        [string]$WaitMessage
    )
    $probe = Invoke-WithTimeout -FilePath $Cli -TimeoutSeconds $TimeoutSeconds `
        -Arguments @("status", "--project-path", (Format-CliArg $ProjectDir), "--format", "json", "--no-banner") `
        -WaitMessage $WaitMessage
    $json = $null
    if (-not $probe.TimedOut) {
        try { $json = $probe.Output | ConvertFrom-Json } catch { $json = $null }
    }
    @{ TimedOut = $probe.TimedOut; Json = $json; Raw = $probe.Output; ExitCode = $probe.ExitCode }
}

function Test-CliConnected {
    # `unity status` の応答が「このプロジェクトを開いたエディタが居る」と言っているか
    param($Status)
    $json = $Status.Json
    [bool]($json -and $json.success -and $json.data.count -ge 1)
}

# Unity CLI の解決（PATH → 既定インストール先）。無ければ batchmode フォールバック。
# -NoUnityCli なら探しにも行かない（CLI 側だけが壊れている環境からの脱出口）
$unityCli = $null
$cliSkipReason = $null
if ($NoUnityCli) {
    $cliSkipReason = "-NoUnityCli"
} else {
    $unityCli = (Get-Command unity -ErrorAction SilentlyContinue).Source
    if (-not $unityCli) {
        $candidate = Join-Path $env:LOCALAPPDATA "Unity\bin\unity.exe"
        if (Test-Path $candidate) { $unityCli = $candidate }
    }
    if (-not $unityCli) { $cliSkipReason = "Unity CLI 未検出" }
}
if ($Editor -and -not $unityCli) {
    throw ("-Editor には Unity CLI が必要です（$cliSkipReason）。" +
           "-Editor を外せば Unity 本体の batchmode で同じ EditMode テストを実行できます")
}

# CLI の生存確認は **-Editor でも batchmode でも必要**（どちらも最初に `unity status` を叩く）。
# 認証セッションが stale だと CLI は無言で 10 分以上ハングするので、必ず時間制限をかける。
# batchmode 経路はここで CLI を諦めて Unity 本体へ落ちられるが、-Editor は CLI が無いと
# 成立しないので明示エラーで止める（黙って待ち続けるより原因が伝わる）
$cliStatus = $null
if ($unityCli) {
    $cliStatus = Get-UnityCliStatus -Cli $unityCli -ProjectDir $projectDir -TimeoutSeconds $UnityCliProbeSeconds `
        -WaitMessage "[$projectName] Unity CLI の応答を待っています（unity status）..."
    if ($cliStatus.TimedOut) {
        if ($Editor) {
            throw ("Unity CLI が $UnityCliProbeSeconds 秒応答しません（-Editor は CLI 経由でしか成立しないため、" +
                   "batchmode へ切り替えられません）。'unity doctor' で状態を確認し、" +
                   "認証セッションが切れているなら 'unity auth login' で復帰させてください。" +
                   "急ぐなら -Editor を外せば Unity 本体の batchmode で同じ EditMode テストを実行できます" +
                   "（待ち時間は -UnityCliProbeSeconds で延ばせる）")
        }
        Write-Warning ("Unity CLI が $UnityCliProbeSeconds 秒応答しないため、Unity 本体の batchmode に切り替えます。" +
                       "CLI 側の不調が疑われます（'unity status' / 'unity doctor' を確認。認証切れなら 'unity auth login'）。" +
                       "最初からこの経路に入るには -NoUnityCli を付けてください")
        $unityCli = $null
        $cliSkipReason = "Unity CLI が応答しない"
    } elseif (-not $cliStatus.Json) {
        # 応答はしたが JSON として読めない（引数エラー・異常終了・想定外の出力）。
        # **黙って「エディタは開いていない」扱いにしない**（ロックの事前検出が静かに抜ける）
        $raw = ($cliStatus.Raw -replace "\s+", " ").Trim()
        if ($raw.Length -gt 200) { $raw = $raw.Substring(0, 200) + " …" }
        Write-Warning ("unity status の応答を解釈できませんでした（exit=$($cliStatus.ExitCode)）: $raw。" +
                       "エディタの占有はロックファイルで判定します")
    }
}

# batchmode テストは Unity のプロジェクトロックと排他: エディタが同じプロジェクトを開いていると
# 起動できず、ログには「Exiting without the bug reporter」しか残らない（exit=6）。
# ここで先に検出しないと、AI は原因の分からない失敗を数分かけて再試行する
# （-Editor の E2E は逆に「開いている」必要がある。この 2 つが正反対なのが最も踏みやすい落とし穴）
$editorHoldsProject = $false
if (-not $Editor) {
    if ($cliStatus -and $cliStatus.Json) {
        $editorHoldsProject = Test-CliConnected -Status $cliStatus
    } else {
        # CLI が無い/読めない場合も、ロックファイルを掴めるかで同じ判定ができる（exit=6 を待たない）
        $editorHoldsProject = Test-UnityProjectLocked -ProjectDir $projectDir
    }
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
    # Unity CLI の有無は上（解決直後）で判定済み。ここへ来る時点で $unityCli は必ずある

    function Invoke-Pipeline {
        <#
          .NOTES
          `-TimeoutSeconds` を渡すと**呼び出し 1 回ごとに時間制限**を掛ける。
          Unity CLI は認証セッションが stale になると無言でハングする（Invoke-WithTimeout の注記）ので、
          ポーリングの中から時間制限なしで呼ぶと外側のストップウォッチが進まず、
          「上限で中断する」という約束が守られない（無期限に黙って止まる）。
          長時間かかるのが正常な run_tests は従来どおり制限なしで呼ぶ（CLI 側の --timeout で縛る）。
        #>
        param([string[]]$CmdArgs, [switch]$AllowFail, [int]$TimeoutSeconds = 0)
        if ($TimeoutSeconds -gt 0) {
            # **空白を含む引数は明示的に引用する**（Start-Process -ArgumentList の配列は
            # 空白で結合されるため、引用しないと eval のコードやパスが複数引数に割れる）
            $quoted = @("cmd", "--project-path", (Format-CliArg $projectDir)) +
                      @($CmdArgs | ForEach-Object { if ("$_" -match "\s") { Format-CliArg "$_" } else { "$_" } }) +
                      @("--format", "json", "--no-banner")
            $raw = (Invoke-WithTimeout -FilePath $unityCli -Arguments $quoted -TimeoutSeconds $TimeoutSeconds).Output
        } else {
            $raw = & $unityCli cmd --project-path $projectDir @CmdArgs --format json --no-banner 2>&1 | Out-String
        }
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
    # 1 回目は上で取ったプローブ結果を再利用する（同じコマンドを二度叩かない）。
    # 以降の再取得も**必ず時間制限つき**（CLI 側が壊れると無言でハングする）
    $st = $cliStatus
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        if (Test-CliConnected -Status $st) { break }
        Start-Sleep -Seconds 2
        $st = Get-UnityCliStatus -Cli $unityCli -ProjectDir $projectDir -TimeoutSeconds $UnityCliProbeSeconds
    }
    if (-not (Test-CliConnected -Status $st)) {
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
                $st = Get-UnityCliStatus -Cli $unityCli -ProjectDir $projectDir -TimeoutSeconds $UnityCliProbeSeconds
                if (Test-CliConnected -Status $st) { break }
            }
            Write-Host "[$projectName] 待機 $([int]$wait.Elapsed.TotalSeconds) 秒"
        }
    }
    if (-not (Test-CliConnected -Status $st)) {
        if (Test-UnityProjectLocked -ProjectDir $projectDir) {
            # 何が返ってきたのかを必ず見せる（「接続していません」だけでは切り分けようがない）
            $lastStatus = if ($st.TimedOut) { "（$UnityCliProbeSeconds 秒で応答なし）" }
                          else { ($st.Raw -replace "\s+", " ").Trim() }
            if ($lastStatus.Length -gt 300) { $lastStatus = $lastStatus.Substring(0, 300) + " …" }
            throw ("エディタは既にこのプロジェクトを開いていますが、Pipeline に接続していません: $projectDir。" +
                   "二重起動はしません。エディタ側で com.unity.pipeline が入っているか（Package Manager）、" +
                   "接続が生きているか（unity status）を確認してください。" +
                   "エディタを閉じてよいなら -Editor を外して batchmode で実行できます。" +
                   "`n  status の応答: $lastStatus")
        }
        Write-Host "[$projectName] エディタ未接続。Pipeline パッケージを確認してエディタを起動します..."
        & $unityCli pipeline install --project-path $projectDir --format json --no-banner | Out-Null
        # **パスは引用する**（-ArgumentList の配列は空白結合されるため、空白入りのパスが割れる）
        Start-Process -FilePath $unityCli -ArgumentList @("open", (Format-CliArg $projectDir)) | Out-Null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            Start-Sleep -Seconds 5
            $st = Get-UnityCliStatus -Cli $unityCli -ProjectDir $projectDir -TimeoutSeconds $UnityCliProbeSeconds
            if ((Test-CliConnected -Status $st) -and $st.Json.data.instances[0].state -eq "ready") { break }
            if ($sw.Elapsed.TotalSeconds -gt 600) { throw "エディタの Pipeline 接続待ちがタイムアウト（600秒）。Editor.log を確認" }
        }
        Write-Host "[$projectName] エディタ接続完了（$([int]$sw.Elapsed.TotalSeconds)秒）"
    }

    # 直前の編集を反映させてから走らせる（未コンパイルのまま古いアセンブリで通ると偽の緑になる）。
    # **ここで妥協すると「古いアセンブリで通った緑」を返す**ことになるので、
    # 応答不能・タイムアウトは黙って進まずに止める（-AllowFail を使わない）。
    #
    # **`recompile` は非同期で、直後の `recompile_status` は前回の結果を返しうる。**
    # とくに `up_to_date` は「まだ新しいコンパイルが始まっていない」ときにも返るため、
    # これを完了と解釈すると待機がまったく機能しない（導入先で実測: コンパイルエラーのあるコードで
    # 古いアセンブリのテストが「39/39 成功」になり、新規テスト 24 件が 1 件も含まれていなかった）。
    # **偽の緑は失敗より悪い** — 落ちれば直すが、緑が出たら次へ進んでしまう。
    #
    # そこで「始まったことを確かめてから終わりを待つ」。ただし本当に変更が無ければ
    # コンパイルは始まらないので、**開始待ちは短い猶予で打ち切る**（無変更なら待つ意味がない）。
    # そのうえで最後に必ず `EditorUtility.scriptCompilationFailed` を見る。これは
    # 「まだ走っていない」に影響されず、**現在のアセンブリが壊れているか**をそのまま返す
    Write-Host "[$projectName] コンパイルを確認中..."
    # **`recompile` 自身の戻り値を捨てない**（これが「走り出したか」の一次情報）。
    # com.unity.pipeline の RecompileCommand は AssetDatabase.Refresh() のあと
    # `EditorApplication.isCompiling` を見て `compiling`（走り出した）/
    # `up_to_date`（何も要らなかった）を返す。解釈できない応答（版差）は
    # 「不明」として扱い、下のポーリングと最後の砦に判断を委ねる
    $trigger = Invoke-Pipeline @("recompile") -TimeoutSeconds 120
    $triggerState = $trigger.data.result
    if ($triggerState -is [string]) { try { $triggerState = $triggerState | ConvertFrom-Json } catch {} }
    # 状態は idle | triggered | compiling | completed | up_to_date。
    # **`triggered` は「Refresh 中でまだ compilationStarted が来ていない」進行中の状態**であり、
    # これを完了側に落とすと待機がすり抜けて偽の緑に戻る（版差に備えて進行中側は広めに取る。
    # `completed` は "compil" にも "pending" にも一致しないので終了側のまま）
    $inProgress = "compil|reload|pending|running|triggered"
    # **走り出したあとの完了は、終端状態が返ったときだけ**とみなす。
    # `idle`（状態ファイルが消えた等）を完了と読むと、コンパイル中のまま先へ進んで偽の緑になる
    $terminal = "completed|up[_-]?to[_-]?date"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $compileDone = $false
    $sawCompiling = ("$($triggerState.status)" -match $inProgress)
    $phase = "$($triggerState.status)"
    $compileErrors = @()
    $compileFailed = $false
    while ($sw.Elapsed.TotalSeconds -lt 300) {
        # コンパイル成功後のドメインリロード中は HTTP サーバーごと落ちて応答が無い
        # （パッケージが「クライアントは接続エラーを許容すること」と明記している）。
        # **走り出したと分かっている間だけ**それを許容する（そうでなければ従来どおり即エラー）
        $probe = Invoke-Pipeline @("recompile_status") -AllowFail -TimeoutSeconds 60
        if (-not $probe -or -not $probe.success) {
            if (-not $sawCompiling) {
                throw ("recompile_status が応答しません（コンパイルは開始していない）。" +
                       "エディタと Pipeline の接続を確認してください")
            }
            Start-Sleep -Milliseconds 700
            continue
        }
        $state = $probe.data.result
        # recompile_status の result は**オブジェクトではなく JSON 文字列**で返る
        if ($state -is [string]) {
            try { $state = $state | ConvertFrom-Json }
            catch { throw "recompile_status の応答を解釈できません: $($probe.data.result)" }
        }
        $phase = "$($state.status)$($state.state)"
        if (-not $phase) { throw "recompile_status が状態を返しません（Unity CLI / pipeline の版を確認）" }
        # **失敗の事実はエラー配列と別に握る**（`failed=true` なのに errors が空でも止める。
        # 自分の recompile が状態ファイルを書き直したあとしか読まないので、前回の結果は混じらない）
        if ($state.failed) {
            $compileFailed = $true
            if (@($state.errors).Count -gt 0) { $compileErrors = @($state.errors) }
        }

        if ($phase -match $inProgress) {
            $sawCompiling = $true            # 走り出した。ここから先は「終わる」まで待つ
        }
        elseif ($sawCompiling) {
            # 走り出したあとは、終端状態を見るまで完了にしない
            if ($phase -match $terminal) { $compileDone = $true; break }
        }
        elseif ($sw.Elapsed.TotalSeconds -ge 5) {
            # 5 秒待っても走り出さない＝変更が無い（この経路は下の最後の砦で必ず裏を取る）
            $compileDone = $true
            break
        }
        Start-Sleep -Milliseconds 700
    }
    if (-not $compileDone) {
        throw ("コンパイルが 300 秒で終わりません（最後の状態: $phase）。" +
               "エディタの Console でコンパイルエラーを確認してください。" +
               "この状態で走らせると古いアセンブリのまま緑になりうるので中断します")
    }

    # **最後の砦**: 状態遷移をどう読み違えても、アセンブリが壊れていればここで止まる。
    # `recompile_status.failed` はコンパイルが実際に走った場合しか立たないので、これだけに頼れない。
    # **「いまコンパイル中でないこと」も同時に見る** — 状態ファイルを信じて抜けたあとに
    # コンパイルが始まっていると、scriptCompilationFailed は前の（壊れる前の）結果を返す。
    # 2=コンパイル中 / 1=壊れている / 0=通っている（**C# の文字列リテラルを使わない**:
    # 二重引用符はコマンドライン経由で壊れるため。数値なら --code で安全に渡せる）
    $probeCode = ("return UnityEditor.EditorApplication.isCompiling ? 2 : " +
                  "(UnityEditor.EditorUtility.scriptCompilationFailed ? 1 : 0);")
    # ドメインリロード中はサーバーごと落ちるので少し粘る。
    # **応答が無い・まだコンパイル中を「壊れていない」と読んではならない** — 確認できなければ止める
    $probeResult = $null
    $probeWait = [System.Diagnostics.Stopwatch]::StartNew()
    while ($probeWait.Elapsed.TotalSeconds -lt 120) {
        $failedProbe = Invoke-Pipeline @("eval", "--code", $probeCode) -AllowFail -TimeoutSeconds 60
        if ($failedProbe -and $failedProbe.success) {
            $probeResult = "$($failedProbe.data.result.result)"
            if ($probeResult -ne "2") { break }      # コンパイル中でなくなるまで待つ
        }
        Start-Sleep -Seconds 2
    }
    if ($probeResult -notmatch "^[01]$") {
        throw ("コンパイルが通ったかを確認できません（応答: '$probeResult'。" +
               "120 秒たってもコンパイル中のままか、eval が返らない）。" +
               "確認できないまま走らせると古いアセンブリで緑になりうるので中断します")
    }
    $compilationBroken = $probeResult -eq "1"
    if ($compilationBroken -or $compileFailed -or $compileErrors.Count -gt 0) {
        Write-Host ""
        Write-Host "=== コンパイルエラー ==="
        foreach ($e in ($compileErrors | Select-Object -First 20)) { Write-Host "  $e" }
        if ($compileErrors.Count -eq 0) { Write-Host "  （詳細はエディタの Console を確認）" }
        Write-Host ""
        throw ("スクリプトのコンパイルが通っていません。テストは実行しません" +
               "（このまま走らせると古いアセンブリで緑になり、壊れたコードを通してしまう）")
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
    $unityArgs = @("-batchmode", "-runTests", "-projectPath", (Format-CliArg $projectDir),
                   "-testPlatform", $Mode, "-testResults", (Format-CliArg $Output),
                   "-logFile", (Format-CliArg $logFile))
    # **フィルタも引用する**（パスと同じ理由。`-ArgumentList` の配列は空白で結合されるので、
    # 空白を含むフィルタは複数引数に割れて、意図と違うテストが走るか 0 件になる）
    if ($Filter) { $unityArgs += @("-testFilter", (Format-CliArg $Filter)) }
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
    $via = "Unity batchmode（$cliSkipReason）" + $(if ($killedByTimeout) { " / タイムアウトで強制終了 → 結果XMLで判定" })
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
