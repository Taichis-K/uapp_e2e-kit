# 対象プロジェクトの Unity エディタを閉じる（Unity CLI 必須）。
# 使い方: .\scripts\close-editor.ps1 [-Project unity-nis] [-ProjectPath <Unityプロジェクト>]
#
# 用途: 「注入 → 起動 → 実行 → **閉じる** → 撤去」を 1 サイクルで回す運用（issue #35-B）。
# 閉じないと、次のサイクルの事前チェックが「他人が開いている」と誤判定する。
#
# **Exit は応答前にプロセスが落ちるので、CLI 側はほぼ必ずエラーを返す**
# （導入先実測: `Invalid response format from Pipeline server`）。それは異常ではないので、
# ここでは CLI の戻り値を成否の根拠にせず、**unity-editor-status.ps1 と同じ判定で
# 「本当に閉じたか」を確かめる**（送っただけで成功と報告しない）。
#
# Unity CLI の `unity projects close` はリリースノートに載っているが 1.0.0-beta.5 の実体には
# 無い（導入先が `unknown command 'close'` を実測）。CLI 側に頼れないのでキットで持つ。
param(
    [string]$Project = "unity-nis",   # このリポジトリ内のサンプル名（uapp_e2e開発用）
    [string]$ProjectPath,             # 任意の場所のUnityプロジェクト（導入先ではこちら）
    [int]$TimeoutSeconds = 120,       # closed を確認するまでの上限
    [switch]$Force,                   # 未保存シーンがあっても閉じる（既定は中断する）
    # Unity CLI の呼び出しに `--proxy-disable` を付ける（既定オフ。他スクリプトと同じ）。
    # **状態判定の子プロセスへも引き継ぐ** ― 渡さないと本体と判定で別の条件になる
    [switch]$UnityCliProxyDisable
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "uapp-platform.ps1")   # OS 差分の吸収（Windows / macOS）

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
$projectDir = Get-UappNormalizedDir $projectDir
$projectName = Split-Path $projectDir -Leaf

$statusScript = Join-UappPath $PSScriptRoot "unity-editor-status.ps1"
if (-not (Test-Path -LiteralPath $statusScript)) { throw "unity-editor-status.ps1 が見つかりません: $statusScript" }

function Get-EditorState {
    # **状態判定は unity-editor-status.ps1 に一本化する**（ここで独自に
    # プロセスやロックファイルを見ると、同じことを別の根拠で数える経路が増える）
    $pwshExe = (Get-Process -Id $PID).Path
    # **CLI のグローバル引数を引き継ぐ**。渡さないと、本体と状態判定で別の条件になる
    #（プロキシ配下で CLI が落ちる環境だと、片方だけ「繋がらない」になりうる。未実測）
    $extra = @()
    if (Resolve-UappUnityCliProxyDisable -Switch:$UnityCliProxyDisable) { $extra += "-UnityCliProxyDisable" }
    $json = & $pwshExe -NoProfile -File $statusScript -ProjectPath $projectDir -Json @extra 2>$null | Out-String
    try { return ($json | ConvertFrom-Json) } catch { return $null }
}

$status = Get-EditorState
$state = if ($status) { $status.state } else { $null }
if ($state -eq "closed") {
    Write-Host "[$projectName] エディタは既に閉じています"
    exit 0
}

# **pipeline が見えないならここで落とす**（2026-09-08・mac が実測）。
# このスクリプトの終了手段は `eval "EditorApplication.Exit(0)"` ＝ **pipeline 経由**なので、
# インスタンスが見つからない構成では**原理的に閉じられない**。
# ここで止めないと、`-Force`（＝未保存チェックを飛ばす、という意味しか持たない）を付けた場合に
# **3 秒で落ちていたものが 120 秒の空ポーリングに化け**、しかも失敗文言が
# 「保存ダイアログや再インポートで止まっている可能性」＝**Exit が一度も届いていないのに
# エディタの画面を探しに行かせる**（issue #38 と同じ「断定が探索の方向を固定する」型）。
# **`-Force` は勧めない** ― この状況では効かないため
# **`timedOut` は別扱いにする**（mac の観測）。`Get-CliStatus` はタイムアウト時にも
# `instanceCount = 0` を返すので、**CLI が無言ハングしただけ**で「pipeline が未導入」と
# 断定してしまう（この機は unity auth status が 25 秒返らないことがある）。
# 半分は当たっている（どちらも閉じられない）が、**直し方が違う**ので文面を分ける
if ($status -and $status.pipeline -and $status.pipeline.timedOut -eq $true) {
    throw ("Unity CLI が時間内に応答しませんでした（認証セッションが切れている可能性があります）。" +
           "エディタが健全かどうかもここでは判定できていません。" +
           "unity auth status を確認するか、エディタの画面で手動で閉じてください")
}
if ($status -and $status.signals -and $status.signals.pipelineConnected -eq $false `
    -and $null -ne $status.signals.pipelineInstanceCount -and $status.signals.pipelineInstanceCount -eq 0) {
    throw ("このプロジェクトの Unity インスタンスが Unity CLI から見えません" +
           "（com.unity.pipeline が未導入か、CLI がこのエディタを認識していない）。" +
           "close-editor はエディタの終了に pipeline を使うので、**この構成では閉じられません**。" +
           "エディタの画面で手動で閉じてください。**-Force を付けても閉じません**" +
           "（-Force は『未保存シーンがあっても閉じる』という意味で、終了手段は変わりません）")
}

$unityCli = Get-UappUnityCli
if (-not $unityCli) {
    throw ("Unity CLI が見つかりません（このスクリプトはエディタの終了に Unity CLI を使います）。" +
           "手動で閉じてください")
}

function Invoke-Cli {
    <#
      .SYNOPSIS
      Unity CLI の cmd を**時間を区切って**叩き、@{ Json; Raw; TimedOut } を返す。

      .NOTES
      **`& $unityCli` の直呼びにしない**。Unity CLI は認証セッションが stale になると
      無言で 10 分以上ハングする（導入先で実測済み・unity-editor-status.ps1 も同じ理由で
      時間を区切っている）。直呼びだと「エディタを閉じるだけ」のスクリプトが無期限に
      止まり、利用者からは何も起きていないように見える。
      出力は UTF-8 として読む（cp932 で復号するとマルチバイトの後続バイトが `"` を
      飲み込み JSON が壊れる）。
    #>
    param([string[]]$CmdArgs, [int]$TimeoutSeconds = 60)
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $tail = @("cmd", "--project-path", (Format-CliArg $projectDir)) +
                ($CmdArgs | ForEach-Object { Format-CliArg $_ }) +
                @("--format", "json", "--no-banner")
        # **グローバル引数は同じ呼び出しの中で渡す**（check-portability が
        # 「一部の呼び出しにだけ付く」退行を検査している。run-e2e.ps1 と同じ書き方に揃える）
        $proc = Start-Process -FilePath $unityCli -PassThru -NoNewWindow -ArgumentList (@($cliGlobalArgs) + $tail) `
                              -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.HasExited -and $sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Milliseconds 300
        }
        if (-not $proc.HasExited) {
            try { $proc.Kill() } catch {}
            $proc.WaitForExit(10000) | Out-Null
            return @{ Json = $null; Raw = ""; TimedOut = $true }
        }
        $raw = ((Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) +
                (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue))
        $parsed = $null
        try { $parsed = $raw | ConvertFrom-Json } catch {}
        return @{ Json = $parsed; Raw = $raw; TimedOut = $false }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Format-CliArg([string]$Value) {
    # Start-Process -ArgumentList は配列を空白で結合するだけなので、空白入りのパスは
    # 自分で引用する（引用しないと引数が割れる。既存スクリプトと同じ扱い）
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

# **未保存シーンを黙って捨てない**。Exit(0) は保存ダイアログを出さずに落とすため、
# 作業者の未保存変更が消える（run-e2e.ps1 -Editor の dirty シーン保護と同じ考え方）。
# **判定できないときは中断する（fail-closed）**。「確認できなかった」を「変更なし」として
# 進めると、破壊的な操作を根拠なしに実行することになる ― 失うのは他人の作業で、
# 取り返しがつかない。閉じられないだけなら -Force で明示的に選べる
if (-not $Force) {
    # **全 open scene を見る**。アクティブなシーンだけを見ると、additive で開いた
    # 非アクティブなシーンの未保存変更を取りこぼして黙って捨てる（外部レビュー指摘）。
    # 既存の run-e2e.ps1 の dirty 検査と同じ根拠（list_open_scenes）に揃える
    $scenes = Invoke-Cli @("list_open_scenes") -TimeoutSeconds 30
    if ($scenes.TimedOut -or -not $scenes.Json -or -not $scenes.Json.success) {
        $why = if ($scenes.TimedOut) { "応答がありません（30 秒）" }
               else { "応答を解釈できません: " + ("$($scenes.Raw)".Trim() -replace '\s+', ' ') }
        throw ("未保存の変更があるかを確認できないため中断します（$why）。" +
               "Exit は保存ダイアログを出さずに閉じるので、確認できないまま閉じません。" +
               "エディタの状態を確認するか、捨ててよいと分かっているなら -Force を付けてください")
    }
    $openScenes = @($scenes.Json.data.result.scenes)
    if ($openScenes.Count -eq 0) {
        throw ("開いているシーンを 1 つも取得できませんでした（応答の形が想定と違う）。" +
               "未保存の変更を判定できないため中断します（捨ててよいなら -Force）")
    }
    # **isDirty が欠けている要素は「判定不能」として扱う**（$null は偽なので、
    # そのままだと未保存を見落とす）
    $unknown = @($openScenes | Where-Object {
        -not ($_.PSObject.Properties.Name -contains "isDirty") -or $null -eq $_.isDirty })
    if ($unknown.Count -gt 0) {
        throw ("シーンの未保存状態を判定できない要素があります（$($unknown.Count) 件）。" +
               "確認できないまま閉じません（捨ててよいなら -Force）")
    }
    $dirty = @($openScenes | Where-Object { $_.isDirty } | ForEach-Object { $_.path })
    if ($dirty.Count -gt 0) {
        throw ("未保存のシーン変更があります: $($dirty -join ', ')。" +
               "保存してから実行するか、捨ててよいなら -Force を付けてください" +
               "（Exit は保存ダイアログを出さずに閉じます）")
    }
}

# Play 中なら先に止める（Play のまま Exit すると、実行中の状態がそのまま落ちる。
# 停止できなくても閉じる方針は変えない＝あくまで行儀の問題）
$playStatus = Invoke-Cli @("editor_status") -TimeoutSeconds 60
if ($playStatus.Json -and $playStatus.Json.success -and $playStatus.Json.data.result.playMode -ne "stopped") {
    Write-Host "[$projectName] Play 中なので先に停止します..."
    Invoke-Cli @("editor_stop") | Out-Null
    Start-Sleep -Seconds 2
}

Write-Host "[$projectName] エディタへ終了を送ります..."
# **戻り値は見ない**: Exit は応答前にプロセスが落ちるので、成功でもエラー形になる
# **短い期限で打ち切る**: Exit は応答を返さずにプロセスが落ちるのが正常なので、
# ここで長く待つ意味はない（待つべきは「本当に閉じたか」＝下の状態ポーリング）
Invoke-Cli @("eval", "--code", "UnityEditor.EditorApplication.Exit(0); return 0;") -TimeoutSeconds 20 | Out-Null

$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    if ((Get-EditorState).state -eq "closed") {
        Write-Host "[$projectName] エディタを閉じました（$([int]$sw.Elapsed.TotalSeconds) 秒）"
        exit 0
    }
    Start-Sleep -Seconds 2
}

throw ("終了を送ってから $TimeoutSeconds 秒たってもエディタが閉じません。" +
       "保存ダイアログや再インポートで止まっている可能性があります" +
       "（unity-editor-status.ps1 で状態を確認してください）")
