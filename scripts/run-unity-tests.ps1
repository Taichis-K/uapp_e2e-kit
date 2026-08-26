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
    [bool]$NoGraphics = ($Mode -eq "EditMode"),
    # Unity CLI の呼び出しに `--proxy-disable` を付ける（既定オフ）。プロキシ配下では CLI が
    # localhost 宛ての Pipeline 通信までプロキシへ流し 503 になる。NO_PROXY / UNITY_NOPROXY /
    # config の bypass はいずれも効かず、このフラグだけが効く
    # （詳細は uapp-platform.ps1 の Get-UappUnityCliGlobalArgs）。
    # 環境変数 UAPP_E2E_UNITY_CLI_PROXY_DISABLE=1 でも同じ
    [switch]$UnityCliProxyDisable
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "uapp-platform.ps1")   # OS 差分の吸収（Windows / macOS。mac は暫定・未検証）

# **CLI のグローバル引数は 1 か所で決めて全呼び出しへ渡す**（一部の呼び出しにだけ付くと、
# 「status は通るのに pipeline install で落ちる」ような分かりにくい欠け方になる）。
# check-portability.ps1 が「$unityCli を @cliGlobalArgs 無しで呼んでいないか」を検査する
$cliGlobalArgs = Get-UappUnityCliGlobalArgs -ProxyDisable:(Resolve-UappUnityCliProxyDisable -Switch:$UnityCliProxyDisable)

function Test-UnityProjectLocked {
    <#
      .SYNOPSIS
      エディタがこのプロジェクトを掴んでいるか（真偽値）。**判定できないときは `$true`**（安全側）。

      .NOTES
      **実装は `Get-UappUnityProjectLockState`（uapp-platform.ps1）に 1 つだけ置く**（issue #51）。
      以前はこのファイルと `run-unity-tests.ps1` に**同じロジックが複製**されていた
      （説明文だけが分岐していて、ロジックは同一だった＝機械で確認済み）。
      **`$true` には「占有」と「判定不能」が混ざる**ので、
      **文面を書き分けたい呼び出し側は `Get-UappUnityProjectLockState` を直接使うこと**。
    #>
    param([Parameter(Mandatory)][string]$ProjectDir)
    return ((Get-UappUnityProjectLockState -ProjectDir $ProjectDir).State -ne "unlocked")
}
$root = (Resolve-Path -LiteralPath (Join-UappPath $PSScriptRoot "..")).Path

# 対象プロジェクト解決: -ProjectPath 優先 → キット親がUnityプロジェクトならそれ → $root\$Project
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
# **末尾の `\` を落とす**。タブ補完は `unity-nis\` の形を作り、`Resolve-Path` はそれを保つ。
# 付いたまま `"$projectDir"` と引用すると、閉じ引用符が `\"`（エスケープされた引用符）と
# 解釈され、**後続の引数までパスに飲み込まれる**（Windows の引数解釈規則。実測済み:
# `--project-path "…\unity-nis\" --format json --no-banner` が 1 引数になる）。
# ここで 1 度だけ正規化して、以降の全ての受け渡し（Start-Process 経由を含む）を安全にする。
# **ドライブ直下（`C:\`）だけは落とせない** — `C:` はドライブ相対を指す別物になるため。
# この 1 ケースは引用側（Format-CliArg）で吸収するので、パスの引用は必ずそこを通すこと
$projectDir = Get-UappNormalizedDir $projectDir
$projectName = Split-Path $projectDir -Leaf

$buildsDir = Join-UappPath $root "Builds"
New-Item -ItemType Directory -Force $buildsDir | Out-Null
if (-not $Output) { $Output = Join-UappPath $buildsDir "test-results-$projectName-$Mode.xml" }
if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Force }   # 前回結果を誤読しない

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
        $text = ((Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) +
                 (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue))
        return @{ TimedOut = $false; Output = $text; ExitCode = $process.ExitCode }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
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
        [string]$WaitMessage,
        [string[]]$GlobalArgs = @()
    )
    $probe = Invoke-WithTimeout -FilePath $Cli -TimeoutSeconds $TimeoutSeconds `
        -Arguments (@($GlobalArgs) + @("status", "--project-path", (Format-CliArg $ProjectDir), "--format", "json", "--no-banner")) `
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
    $unityCli = Get-UappUnityCli   # PATH → 既定インストール先（OS 差は uapp-platform.ps1）
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
    $cliStatus = Get-UnityCliStatus -Cli $unityCli -ProjectDir $projectDir -TimeoutSeconds $UnityCliProbeSeconds -GlobalArgs $cliGlobalArgs `
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
    # **CLI の「接続あり」は占有の根拠になるが、「接続なし」は閉じている証拠にならない**。
    # 起動途中・モーダル待ちでは「pipeline 未接続だが対象プロジェクトのプロセスは居る」が
    # 普通に起きるので、否定側は必ず 3 信号の合成判定（プロセス / EditorInstance / ロック）で確かめる
    if ($cliStatus -and $cliStatus.Json -and (Test-CliConnected -Status $cliStatus)) {
        $editorHoldsProject = $true
    } else {
        $editorHoldsProject = Test-UnityProjectLocked -ProjectDir $projectDir
    }
}
if ($editorHoldsProject) {
    # **「確認した」と「判定できなかった」を書き分ける**（issue #51）。
    # 止めるかどうかは変えない（`unknown` も安全側で止める）― 変わるのは文面だけ
    $lockState = (Get-UappUnityProjectLockState -ProjectDir $projectDir)
    $why = if ($lockState.State -eq "locked") {
        "エディタがこのプロジェクトを開いています（$($lockState.Reason)）"
    } else {
        "エディタが開いているかを判定できませんでした（$($lockState.Reason)）。安全側で止めます"
    }
    throw ("$why ため batchmode テストを実行できません: $projectDir。" +
           "エディタを閉じてから再実行してください。" +
           "エディタを開いたまま回したい場合は -Editor を使う（EditMode のみ）")
}

$logFile = Join-UappPath $buildsDir "test-$projectName-$Mode.log"

# エージェント開発ダッシュボード連携（任意）。**監視が要るのは失敗経路ほど強い**ので、
# 結果が出なかった場合も「赤いエビデンス」を残してから throw する
$emitHelper = Join-UappPath $PSScriptRoot "emit-status.ps1"
try {
    if (Test-Path -LiteralPath $emitHelper -PathType Leaf) { . $emitHelper }
} catch {
    # 連携は補助機能。読み込みに失敗してもテスト実行は続ける
}
function Get-UnityNoResultHint {
    <#
      .SYNOPSIS
      結果 XML が出なかったときの案内を、**観測したことだけ**で組み立てる（issue #50）。

      .NOTES
      **以前は `exit=6` を無条件に「エディタが開いている」と断定していた**。
      2026-08-26 に、**エディタが 1 つも無い状態**（`unity-editor-status.ps1` が
      「Unity プロセス 0 個」と回答）で、**真因はテストのコンパイルエラー**なのに
      この案内が出た。案内どおり「エディタを閉じる」を試しても直らない
      （閉じるエディタが無い）。

      **`exit=6 = プロジェクトロック` は batchmode 経由で学んだ対応**で、
      **Unity CLI 経路の 6 が同じ意味とは限らない**（このときの Unity 自身のログは
      `Application will terminate with return code 1` だった＝6 を返したのは CLI 側）。
      **経路をまたいで終了コードの意味を持ち込まない。**

      順序は「①ログに真因が残っていればそれを言う ②機械で確かめられることを確かめる
      ③どれとも決まらなければ候補を並べる」。**断定しないと、読み手は消去法を使える。**
    #>
    param(
        [string]$LogPath,
        [int]$ExitCode,
        [string]$Via,
        [string]$ProjectDir,
        # **このログが今回の走行のものだと言えるか**。消せなかった場合は $false で渡す。
        # $false のログから真因を名指しすると、前回の痕跡を今回の原因にしてしまう（レビュー指摘）
        [bool]$LogIsFresh = $true
    )

    # ① ログの真因。**照合するのは ASCII の定型文だけ**なので、ログの文字コードに左右されない
    $compileLines = @()
    if ($LogIsFresh -and $LogPath -and (Test-Path -LiteralPath $LogPath)) {
        try {
            $compileLines = @(Get-Content -LiteralPath $LogPath -ErrorAction Stop |
                              Where-Object { $_ -match "error CS\d+|Scripts have compiler errors" } |
                              Select-Object -Unique -First 5)
        } catch {
            # ログが読めないこと自体は本流を止めない（案内が 1 段弱くなるだけ）
        }
    }
    if ($compileLines.Count -gt 0) {
        $head = ($compileLines | Select-Object -First 3) -join "; "
        return ("**コンパイルエラーでテストが走っていません**（ログに $($compileLines.Count) 行）: $head" +
                " / 全文: $LogPath")
    }

    # ② 機械で確かめられること。**掴んでいないと分かったらそう言う**（読み手に探させない）
    $locked = $null
    $lockReason = ""
    if ($ProjectDir) {
        try {
            $st = Get-UappUnityProjectLockState -ProjectDir $ProjectDir
            $lockReason = $st.Reason
            # **unknown を `$true` に丸めない**（issue #51）。丸めると
            # 「確認した」と書いてしまい、これは #50 で実際にやった間違い
            $locked = switch ($st.State) { "locked" { $true } "unlocked" { $false } default { $null } }
        } catch { $locked = $null }
    }
    if ($locked -eq $true) {
        # **3 状態で受けているので、ここは「確認できた占有」だけ**（issue #51）
        return ("エディタがこのプロジェクトを開いています（$lockReason）: $ProjectDir。" +
                "エディタを閉じてから再実行してください")
    }

    # ③ 決まらないときは候補を並べる。**exit コードから原因を名指ししない**
    $observed = if ($locked -eq $false) {
        "エディタはこのプロジェクトを掴んでいません（プロセス / EditorInstance / ロックのどれにも掛からなかった）。"
    } else {
        "エディタの占有は判定できませんでした（$lockReason）。"
    }
    # **$Via は本文へ挿し込まない**。「Unity batchmode（-NoUnityCli） / タイムアウトで強制終了 …」の
    # ように長い説明が入ることがあり、文が読めなくなる（実測）。経路と終了コードは呼び出し側が既に出す
    return ($observed + "考えられるのは ①テストが 1 件も収集されなかった " +
            "②Unity の起動自体に失敗した ③実行側が結果を書き出す前に落ちた、など。" +
            "**まず Unity のログを読んでください**: $LogPath" +
            "（占有の確認は scripts\unity-editor-status.ps1 -ProjectPath $ProjectDir）")
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

          **ここでは自動再試行しない**（issue #38。一度入れて撤回した）。
          一過性の接続エラー（`Network error: ...` / `No Pipeline instance found`）は
          run-e2e.ps1 側では待って再試行するが、**このスクリプトで再試行が効く対象は
          `recompile` と `run_tests` の 2 つだけ**（他はすべて `-AllowFail` で、呼び出し元が
          自前でポーリングしている）。そして**どちらも二度実行してよいコマンドではない**:
          `run_tests` は**全テストの二重実行**になり、1 本目がまだエディタ側で走っている最中に
          2 本目を投げうるうえ、証跡に載るのは 2 回目の結果だけになる。
          **クライアント側のエラーは「サーバが要求を受理していない」ことを保証しない**
          （run-e2e.ps1 の `$retrySafe` と同じ理由。あちらの一覧にもこの 2 つは入っていない）。
          そのかわり**失敗の分類を添えて落とす** ― 一過性なら「そのまま再実行すると通ることがある」と
          分かるので、人・AI のどちらが読んでも次の一手を選べる。
        #>
        param([string[]]$CmdArgs, [switch]$AllowFail, [int]$TimeoutSeconds = 0)
        if ($TimeoutSeconds -gt 0) {
            # **空白を含む引数は明示的に引用する**（Start-Process -ArgumentList の配列は
            # 空白で結合されるため、引用しないと eval のコードやパスが複数引数に割れる）
            $quoted = @("cmd", "--project-path", (Format-CliArg $projectDir)) +
                      @($CmdArgs | ForEach-Object { if ("$_" -match "\s") { Format-CliArg "$_" } else { "$_" } }) +
                      @("--format", "json", "--no-banner")
            $raw = (Invoke-WithTimeout -FilePath $unityCli -Arguments (@($cliGlobalArgs) + $quoted) -TimeoutSeconds $TimeoutSeconds).Output
        } else {
            # **CLI の出力（UTF-8）をコンソール符号化で復号しない**。日本語 Windows の既定
            # （cp932）だと、日本語テスト名等のマルチバイトの**後続バイトが直後の `"` を
            # 飲み込んで JSON が壊れ、「全件成功なのに失敗扱い」**になる（unity-nis の
            # 日本語テスト名で実測。ASCII 名だけのプロジェクトでは発症しない）。
            # `&` 直取りの復号は [Console]::OutputEncoding に従うため、この間だけ UTF-8 にする
            $prevEnc = [Console]::OutputEncoding
            try {
                [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
                $raw = & $unityCli @cliGlobalArgs cmd --project-path $projectDir @CmdArgs --format json --no-banner 2>&1 | Out-String
            } finally { [Console]::OutputEncoding = $prevEnc }
        }
        $parsed = $null
        try { $parsed = $raw | ConvertFrom-Json } catch {}
        if (-not $AllowFail -and (-not $parsed -or -not $parsed.success)) {
            # **分類は添えるが、再試行はしない**（上の .NOTES 参照）。
            # 一過性だと分かれば「そのまま再実行すれば通る」と判断できる
            $cls = Get-UappUnityCliErrorClass -Parsed $parsed
            $hint = if ($cls.Class -eq "transient") {
                        "（一過性の可能性: $($cls.Reason)。エディタが生きていれば、そのまま再実行すると通ることがある）"
                    } else { "（$($cls.Reason)）" }
            throw "unity cmd $($CmdArgs -join ' ') が失敗${hint}: $raw"
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
        $st = Get-UnityCliStatus -Cli $unityCli -ProjectDir $projectDir -TimeoutSeconds $UnityCliProbeSeconds -GlobalArgs $cliGlobalArgs
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
                $st = Get-UnityCliStatus -Cli $unityCli -ProjectDir $projectDir -TimeoutSeconds $UnityCliProbeSeconds -GlobalArgs $cliGlobalArgs
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
        & $unityCli @cliGlobalArgs pipeline install --project-path $projectDir --format json --no-banner | Out-Null
        # **パスは引用する**（-ArgumentList の配列は空白結合されるため、空白入りのパスが割れる）
        Start-Process -FilePath $unityCli -ArgumentList (@($cliGlobalArgs) + @("open", (Format-CliArg $projectDir))) | Out-Null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            Start-Sleep -Seconds 5
            $st = Get-UnityCliStatus -Cli $unityCli -ProjectDir $projectDir -TimeoutSeconds $UnityCliProbeSeconds -GlobalArgs $cliGlobalArgs
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
    # **Play 中なら待つ前に止める**（導入先 §24・実測）: Unity は Play 中のスクリプトコンパイルを
    # 保留するため、このまま recompile を投げると 300 秒待った末に「Console でコンパイルエラーを
    # 確認しろ」という**存在しないエラーを探させる誤誘導**になる。バランス調整で人がゲームを
    # 遊んで放置しているのが常態の導入先があるので、**自動では停止しない**（進行中のプレイが消える）
    $esProbe = Invoke-Pipeline @("editor_status") -AllowFail -TimeoutSeconds 60
    $esResult = if ($esProbe) { $esProbe.data.result } else { $null }
    if ($esResult -is [string]) { try { $esResult = $esResult | ConvertFrom-Json } catch {} }
    $playMode = "$($esResult.playMode)"
    if ($playMode -in @("playing", "paused")) {
        throw ("エディタが Play 中です（playMode: $playMode）。Unity は Play 中のスクリプトコンパイルを" +
               "保留するため、このまま待ってもテストは始まりません。**Play を停止してから再実行**" +
               "してください（人が操作している可能性があるため、自動では停止しません）")
    }
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
                # **コールドスタート直後の一瞬の非応答を即死にしない**（導入先 §25・実測:
                # キットが自分で起動したエディタは接続直後まだインポート中で、recompile_status が
                # 数秒だけ応答を落とす。直後に叩くと 1 秒で返り、再実行すれば通っていた）。
                # 非応答は「何も分からない」であって、偽の緑の原因だった「up_to_date の誤読」とは
                # 別物なので、**猶予内のリトライは §16 のガードを弱めない**（状態が取れたときの
                # 判定と最後の砦は不変）。猶予を超えても応答が無ければ従来どおり止める
                if ($sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 700; continue }
                throw ("recompile_status が 30 秒応答しません（コンパイルは開始していない）。" +
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
        # 保険: 事前検査の後で人が Play を始めた場合もここへ来る。playMode を添えて
        # 「存在しないコンパイルエラーを探させる」誤誘導を避ける（導入先 §24）
        $lateEs = Invoke-Pipeline @("editor_status") -AllowFail -TimeoutSeconds 30
        $lateResult = if ($lateEs) { $lateEs.data.result } else { $null }
        if ($lateResult -is [string]) { try { $lateResult = $lateResult | ConvertFrom-Json } catch {} }
        $latePlay = "$($lateResult.playMode)"
        $playHint = if ($latePlay -in @("playing", "paused")) {
            "**エディタが Play 中です（playMode: $latePlay）。Unity は Play 中コンパイルを保留するので、" +
            "Play を停止してから再実行してください（コンパイルエラーではない可能性が高い）。**"
        } elseif ($latePlay) { "（playMode: $latePlay）" } else { "" }
        throw ("コンパイルが 300 秒で終わりません（最後の状態: $phase）。$playHint" +
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

# **前回の走行と混ざらないよう、ログを 1 回だけ消す**（issue #50）。
# 失敗時の案内はこのログから真因（コンパイルエラー）を読むので、**古い痕跡が残っていると
# 今回の失敗を古い証拠で名指ししうる** ―「断定を直したつもりで、別の断定を作る」形になる
# （`run-e2e.ps1` の `Save-CliRawEvidence` が「先頭で 1 回切り詰め、以後は追記」なのと同じ考え方）。
# 実測では Unity CLI / batchmode とも `-logFile` は上書きだが、**truncate するのは Unity 自身**なので
# 起動しなかった回・起動直後に死んだ回は前回のログが残る（＝案内が呼ばれるのはまさにその回）。
# **消すのはここ** ― `-Editor` 経路はこのログへ何も書かずに終わるので、
# **実行の先頭で消すと、内側ループを回すたびに直前の batchmode の証跡が消える**（レビュー指摘）
$logIsFresh = $true
if (Test-Path -LiteralPath $logFile) {
    try {
        Remove-Item -LiteralPath $logFile -Force
    } catch {
        # **消せなかったログは、真因の判定に使わない**（警告だけ出して使い続けると、
        # 前回のコンパイルエラーを今回の真因として名指ししうる＝直したはずの穴の再導入）
        $logIsFresh = $false
        Write-Warning ("前回のテストログを消せませんでした（$logFile）: $($_.Exception.Message)。" +
                       "このログは今回の走行のものと断定できないため、失敗時の案内では真因の判定に使いません")
    }
}
Write-Host "[$projectName] $Mode テストを実行中（Unity の起動を含むため数分かかります）..."

if ($unityCli) {
    $cliArgs = @("test", $projectDir, "--mode", $Mode, "--output", $Output,
                 "--timeout", $TimeoutSeconds, "--non-interactive", "--no-banner")
    if ($Filter) { $cliArgs += @("--filter", $Filter) }
    # -- 以降は Unity 本体へ転送される。ログは必ずプロジェクト側に確保する
    # （既定の Editor.log は複数 Unity 同時実行で競合し、後発の実行がログを1行も残せないことがある）
    $cliArgs += @("--", "-logFile", $logFile)
    if ($NoGraphics) { $cliArgs += "-nographics" }
    & $unityCli @cliGlobalArgs @cliArgs
    $exit = $LASTEXITCODE
    $via = "Unity CLI"
    Write-Host "ログ: $logFile"
} else {
    # フォールバック: Unity 本体を batchmode で起動する（CLI と同じ NUnit XML を出力させる）
    if (-not $UnityPath) {
        $versionFile = Join-UappPath $projectDir "ProjectSettings\ProjectVersion.txt"
        if (-not (Test-Path -LiteralPath $versionFile)) { throw "ProjectVersion.txt がありません: $versionFile" }
        if ((Get-Content -LiteralPath $versionFile -Raw) -notmatch "m_EditorVersion:\s*(\S+)") {
            throw "ProjectVersion.txt からバージョンを読めません: $versionFile"
        }
        $unityVersion = $Matches[1]
        $localConfigPath = Join-UappPath $root "config\local.json"
        $local = if (Test-Path -LiteralPath $localConfigPath) { Get-Content -LiteralPath $localConfigPath -Raw | ConvertFrom-Json } else { $null }
        # エディタ実体の並び（Windows は <root>\<版>\Editor\Unity.exe、
        # mac は <root>/<版>/Unity.app/Contents/MacOS/Unity）は uapp-platform.ps1 が吸収する
        $editorRoots = if ($local -and $local.editorRoots) { $local.editorRoots }
                       else { Get-UappDefaultEditorRoots }
        $UnityPath = Resolve-UappEditor -Version $unityVersion -Roots $editorRoots
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
if (-not (Test-Path -LiteralPath $Output)) {
    Send-TestEvidence @{
        suite = "unity-$($Mode.ToLower())"; project = $projectName
        ok = $false; exitCode = $exit; error = "結果XMLが出力されなかった（$via）"
        reportPath = $Output; logPath = $logFile
    }
    # **原因を断定せず、観測から組み立てる**（issue #50）。
    # 以前はここで `exit=6` を無条件に「エディタが開いている」と言っており、
    # **エディタが 0 個・真因はコンパイルエラー**の場合にも同じ案内を出していた
    $hint = Get-UnityNoResultHint -LogPath $logFile -ExitCode $exit -Via $via -ProjectDir $projectDir -LogIsFresh $logIsFresh
    throw "テスト結果が出力されませんでした（$via / exit=$exit）: $Output。$hint"
}
$xml = [xml](Get-Content -LiteralPath $Output -Raw)
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
