# 指定サンプルプロジェクトの APK インストール〜アプリ起動〜pytest 実行を一括で行う。
# プロジェクト固有設定（package/activity/tests/deviceRotation）は <Project>\e2e-config.json から読む。
# 使い方: .\scripts\run-e2e.ps1 [-Project unity-nis|unity-ngui-nis|unity-ngui-legacy] [-SkipInstall] [-PytestArgs "-k xxx"]
#
# -Editor: エディタ直結モード（ビルド・デバイス・adb 不要）。Unity CLI（v1.0.0-beta.3+）と
#   com.unity.pipeline（Unity 6 以降）でエディタを外部制御し、シーンオープン→Game view解像度設定→
#   Play開始→pytest（UAPP_E2E_EDITOR=1）→Play終了 まで人手ゼロで実行する。
#   adb を直接使うテストは明示エラーになるため -PytestArgs "-k ..." で除外する。
#   Unity CLI が無い/Unity 6 未満の場合は従来の手動手順（エディタで Play → UAPP_E2E_EDITOR=1 で pytest）へ。
param(
    [string]$Project = "unity-nis",   # このリポジトリ内のサンプル名（uapp_e2e開発用）
    [string]$ProjectPath,             # 任意の場所のUnityプロジェクト（実プロジェクト導入時はこちら）
    [string]$Apk,
    [string]$DeviceSerial,   # 複数デバイス同時運用時に対象を指定（例: emulator-5554）
    [int]$HostPort = 0,      # adb forward のホスト側ポート（未指定: local.json の bridgePort → 13333）
    [switch]$SkipInstall,
    [string]$JourneyDir,     # ジャーニー記録の出力先（未指定: Builds\journey。docs/07-viewer.md）
    [switch]$NoJourney,      # ジャーニー記録を無効化する
    [switch]$Editor,             # エディタ直結モード（Unity CLI で Play 制御。ヘッダコメント参照）
    [string]$Scene,              # -Editor: 開くシーン（未指定: Build Settings の先頭シーン）
    [string]$EditorResolution,   # -Editor: Game view 解像度 "幅x高さ"（未指定: orientation から 1080x2340/2340x1080）
    # -Editor: エディタが pipeline コマンドに応答するまで待つ上限（秒）。コールドスタート直後は
    # アセットインポート/コンパイルで手が塞がっており、接続済み（unity status=ready）でも
    # 軽いコマンドがタイムアウトする。大規模プロジェクトの初回インポートは分単位になるので延ばせるようにする
    [int]$EditorReadyTimeoutSeconds = 600,
    # -Editor: `unity status`（最初の CLI 呼び出し）を打ち切るまでの秒数。CLI の認証セッションが
    # stale になると無言で 10 分以上ハングするため、必ず時間を区切って原因を示して止める
    [int]$UnityCliProbeSeconds = 60,
    # -Editor: Unity CLI の呼び出しに `--proxy-disable` を付ける（既定オフ）。
    # プロキシ配下では CLI が localhost 宛ての Pipeline 通信までプロキシへ流し、503 で
    # `unity status` が unreachable になる。NO_PROXY / UNITY_NOPROXY / config の bypass は
    # いずれも効かず、このフラグだけが効く（詳細は uapp-platform.ps1 の Get-UappUnityCliGlobalArgs）。
    # 環境変数 UAPP_E2E_UNITY_CLI_PROXY_DISABLE=1 でも同じ。**プロキシ経由が必要な認証・
    # ダウンロードも直結になる**ので、既定では付けない
    [switch]$UnityCliProxyDisable,
    # 導入先の自作テストの実行数が 0 なら失敗にする（既定オフ。導入先フィードバック起点＝
    # 「自作 0 件は緑だが無意味なので失敗と同じ扱いにしたい」。検証ループの門として使う）。
    # 判定はテスト内訳表示と同じ（kit-manifest.json 由来・skip は実行数に数えない）。
    # **判定できない環境では明示エラー**（manifest の無い開発リポジトリ・XML が書けない等。
    # fail-open にすると門のつもりが素通しになる）。
    # 環境変数 UAPP_E2E_REQUIRE_PROJECT_TESTS=1 でも有効化できる（ラッパーから渡しやすくする）
    [switch]$RequireProjectTests,
    [string]$PytestArgs = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "uapp-platform.ps1")   # OS 差分の吸収（Windows / macOS。mac は暫定・未検証）

# -RequireProjectTests は環境変数でも有効化できる（ラッパー・CI から渡しやすくする。
# スイッチ明示が常に優先＝環境変数で無効化はできない）
$requireProjectTests = [bool]$RequireProjectTests -or ($env:UAPP_E2E_REQUIRE_PROJECT_TESTS -eq "1")

function Get-DeviceFreeBytes {
    <#
      .SYNOPSIS
      デバイスの /data の空き容量（バイト）。取得できなければ 0。
    #>
    param([string[]]$AdbTarget = @())
    try {
        # df の 1K ブロック表示から Available 列を取る（-h だと単位付きで解析が面倒）
        $line = (& $script:adbExe @AdbTarget shell df /data 2>$null | Select-Object -Last 1)
        $columns = ($line -split '\s+') | Where-Object { $_ }
        # Filesystem 1K-blocks Used Available Use% Mounted → 4 列目が Available
        if ($columns.Count -ge 4 -and $columns[3] -match '^\d+$') { return [long]$columns[3] * 1024 }
    } catch { }
    return 0
}

function Format-InstallFailure {
    <#
      .SYNOPSIS
      adb install の失敗を「何が起きて、どう直すか」に翻訳する。

      .NOTES
      生の Failure[...] だけだと、呼び出し元（verify-all 等）の要約では「テスト失敗」に見え、
      コードの回帰を疑って時間を溶かす（2026-07-29 に実際に踏んだ）。
    #>
    param([string]$Output, [int]$ExitCode, [string]$Apk, [string]$Package, [long]$FreeBytes = 0)

    $apkMb = [math]::Round((Get-Item $Apk).Length / 1MB)
    $freeMb = if ($FreeBytes -gt 0) { [math]::Round($FreeBytes / 1MB) } else { $null }
    $hint = switch -Regex ($Output) {
        # 文言は Android の版で違う（INSTALL_FAILED_INSUFFICIENT_STORAGE のこともあれば、
        # "Requested internal only, but not enough space" の IOException のこともある。両方実測）
        "INSUFFICIENT_STORAGE|not enough space|No space left" {
            "デバイスの空き容量が足りません" + $(if ($freeMb) { "（空き ${freeMb} MB / APK ${apkMb} MB）" }) +
            "。不要なアプリを削除するか（adb uninstall <package>）、AVD のディスクサイズを拡張してください。" +
            "計装アプリを複数のプロジェクト分入れていると起きやすい"
            break
        }
        "UPDATE_INCOMPATIBLE|INCONSISTENT_CERTIFICATES" {
            "同じ package が別の署名で既に入っています（$Package）。" +
            "adb uninstall $Package してから再実行してください"
            break
        }
        "VERSION_DOWNGRADE" {
            "デバイス側の方が新しい版です（$Package）。adb uninstall $Package してから再実行してください"
            break
        }
        "INSTALL_FAILED_NO_MATCHING_ABIS" {
            "APK の ABI がデバイスと合いません（エミュレーターは x86_64、実機は arm64 が普通）。" +
            "ビルド設定のターゲットアーキテクチャを確認してください"
            break
        }
        default { "adb の出力をそのまま確認してください" }
    }
    return "adb install 失敗 (exit=$ExitCode): $hint`n--- adb の出力 ---`n$Output"
}

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
    <#
      .SYNOPSIS
      エディタがこのプロジェクトを掴んでいるか（二重に開かないためのガード）。

      .NOTES
      **単一の根拠では判定できない**（2026-07-30 に Unity 6000.3.6f1 で実測。
      内訳の表示は `scripts\unity-editor-status.ps1`）:

      1. `-projectPath <対象>` を持つ GUI の Unity.exe プロセス … 起動直後から分かる唯一の信号
      2. `Library\EditorInstance.json` の `process_id` の生存 … **ロード完了後**にしか現れず、
         異常終了で古い pid が残る（生存確認が必須）
      3. `Temp\UnityLockfile` の排他オープン … **開いているのに排他オープンできてしまう状態がある**
         （起動途中・モーダルダイアログ待ち）。存在で判定するのも誤り（残骸で永久に開いている扱い）
    #>
    param([Parameter(Mandatory)][string]$ProjectDir)

    try {
        $target = Get-UappNormalizedDir (Resolve-Path -LiteralPath $ProjectDir).Path
        foreach ($p in (Get-UappUnityProcess)) {   # プロセス列挙の OS 差は uapp-platform.ps1 が吸収する
            $cmd = $p.CommandLine
            # **コマンドラインが取れていない Unity プロセスは「無関係」と断定できない**。
            # 安全側（掴んでいる扱い）に倒す（Windows で CIM が権限等で失敗したときに効く）
            if (-not $p.CommandLineAvailable) {
                Write-Warning "Unity プロセスのコマンドラインが取得できないため、占有されている前提で扱います"
                return $true
            }
            if (-not $cmd) { continue }
            if ($cmd -match '-projectPath\s+"?([^"]+?)"?(\s+-|\s*$)') {
                $path = $Matches[1].Trim()
                try { $path = Get-UappNormalizedDir (Resolve-Path -LiteralPath $path).Path } catch { }
                # **batchmode でも対象パスが一致すれば占有**（別ターミナルの batchmode は
                # 実際にロックを握る。この判定は自分が Unity を起動する前に行うので、
                # 自分自身を誤検出することはない）
                if ($path -ieq $target) { return $true }
                continue
            }
            # **ウィンドウタイトルは実行可否に使わない（が、黙って素通りもしない）**。
            # これは**トレードオフで、どちらに倒しても壊れる**（外部レビューで両方向を指摘された）:
            #   止める  … 別の場所にある同名プロジェクトを開いているだけで**実行不能**（回避策が無い）
            #   止めない… `-projectPath` 無し＋EditorInstance.json 生成前の起動途中を見落とす
            # 代償の小さい後者を選び、**警告だけ出して続行**する。この非対称は意図的（docs/04-ai-loop.md）
            if ($p.MainWindowTitle -and $p.MainWindowTitle -match '^(.+?)\s+-\s' -and
                $Matches[1] -ieq (Split-Path $target -Leaf)) {
                Write-Warning ("同名のプロジェクトを開いている Unity があります（タイトル: $($p.MainWindowTitle)）。" +
                               "**対象と同じものなら閉じてから再実行**してください" +
                               "（-projectPath を持たない起動のため、同一かどうか確定できません）")
            }
        }
    } catch [System.InvalidOperationException] {
        # **列挙できない＝「掴んでいない」と断定できない**。安全側（掴んでいる扱い）に倒す。
        # ここで false を返すと、起動途中のエディタを見落として二重に開きにいく
        Write-Warning ("Unity プロセスを列挙できませんでした（$($_.Exception.Message)）。" +
                       "占有されている前提で扱います")
        return $true
    } catch { }

    $instanceFile = Join-UappPath $ProjectDir "Library\EditorInstance.json"
    if (Test-Path -LiteralPath $instanceFile) {
        try {
            $editorPid = [int]((Get-Content $instanceFile -Raw | ConvertFrom-Json).process_id)
            $proc = if ($editorPid) { Get-Process -Id $editorPid -ErrorAction SilentlyContinue } else { $null }
            if ($proc -and $proc.ProcessName -eq "Unity") { return $true }
        } catch { }
    }

    $lock = Join-UappPath $ProjectDir "Temp\UnityLockfile"
    if (-not (Test-Path -LiteralPath $lock)) { return $false }
    try {
        $stream = [System.IO.File]::Open($lock, "Open", "ReadWrite", "None")
        $stream.Close()
        return $false
    } catch {
        return $true
    }
}
$root = (Resolve-Path (Join-UappPath $PSScriptRoot "..")).Path

# Python の実体を先に決める（pytest / ジャーニー生成 / スクショで使う）。
# **mac は `python` が無く `python3` だけ、という構成が普通**なので裸で呼ばない
$script:pythonExe = Get-UappPython
if (-not $script:pythonExe) {
    throw "python が見つかりません（python / python3 のどちらも PATH にありません）"
}

# 対象プロジェクト解決: -ProjectPath 優先 → キット親がUnityプロジェクトならそれ → $root\$Project
if ($ProjectPath) {
    $projectDir = (Resolve-Path $ProjectPath).Path
}
elseif ((Test-Path (Join-UappPath $root "..\Assets")) -and (Test-Path (Join-UappPath $root "..\ProjectSettings"))) {
    $projectDir = (Resolve-Path (Join-UappPath $root "..")).Path
}
else {
    $projectDir = Join-UappPath $root $Project
    $isRepoSample = $true   # 開発リポジトリのサンプル（Builds を3プロジェクトで共有する）
}
# **末尾の `\` を落とす**。タブ補完は `unity-nis\` の形を作り、`Resolve-Path` はそれを保つ。
# 付いたまま `"$projectDir"` と引用すると閉じ引用符が `\"` と解釈され、**後続の引数まで
# パスに飲み込まれる**（Windows の引数解釈規則。`Start-Process -ArgumentList` 経由の
# `unity status` / `unity open` が引数エラーで即失敗する）。
# **ドライブ直下（`C:\`）だけは落とせない** — `C:` はドライブ相対を指す別物になるため。
# この 1 ケースは引用側（Format-CliArg）で吸収するので、パスの引用は必ずそこを通すこと
$projectDir = Get-UappNormalizedDir $projectDir
$projectName = Split-Path $projectDir -Leaf

# ジャーニー記録（docs/07-viewer.md）の出力先を固定する:
#   導入先（キット配置）= <uapp_e2e>\Builds\journey ／ 開発リポジトリ = Builds\journey\<サンプル名>
# 記録は追記マージなので毎回同じ場所に蓄積され、viewer/report の場所が常にここに確定する。
# PytestArgs で --journey を明示した場合はそちらが優先される（pytest オプション > 環境変数）
if (-not $NoJourney) {
    if (-not $JourneyDir) {
        $JourneyDir = if ($isRepoSample) { Join-UappPath $root "Builds\journey\$Project" }
                      else { Join-UappPath $root "Builds\journey" }
    }
    # pytest は driver\ から実行するため、相対指定でも壊れないよう絶対パス化しておく
    if (-not [System.IO.Path]::IsPathRooted($JourneyDir)) {
        $JourneyDir = Join-UappPath (Get-Location).Path $JourneyDir
    }
    $JourneyDir = [System.IO.Path]::GetFullPath($JourneyDir)
} else {
    $JourneyDir = $null
}

# --- エージェント開発ダッシュボード連携（任意・別リポジトリ） ---
# **導入されていない環境では申告を変えない**: ダッシュボードのイベントは書かない。
# JUnit XML は従来ダッシュボード連携時だけ出力していたが、テスト内訳の表示
# （導入先の自作 / キット同梱。issue #30）にも使うため常に出力する
$emitHelper = Join-UappPath $PSScriptRoot "emit-status.ps1"
$dashEnabled = $false
# 連携の準備で失敗しても E2E 本体を巻き込まない（ErrorActionPreference="Stop" 下で throw させない）
try {
    if (Test-Path -LiteralPath $emitHelper -PathType Leaf) {
        . $emitHelper
        $dashEnabled = [bool](Get-DashStatusDir -StartPath $root)
    }
} catch {
    $dashEnabled = $false
}
$junitPath = $null

function Enable-JunitOutput {
    <# pytest に渡す --junitxml を組み立てる（件数の記録と内訳表示に使う）。
       出力先は**ターゲットごとに分ける**（同一プロジェクトの並行実行が互いの XML を壊さないため）。
       準備に失敗したら諦めて空配列を返す（テスト実行を止めない。ダッシュボード連携は
       件数なしの exitCode 記録に落ちる＝Send-E2eEvidence の既存フォールバック）。 #>
    param([Parameter(Mandatory)][string]$Tag)

    try {
        $safeTag = ($Tag -replace '[^A-Za-z0-9._-]', '_')
        $script:junitPath = Join-UappPath $root "Builds\e2e-results-$projectName-$safeTag.xml"
        New-Item -ItemType Directory -Force (Split-Path $script:junitPath -Parent) | Out-Null
        Remove-Item $script:junitPath -ErrorAction SilentlyContinue   # 前回結果を誤読しない
        return @("--junitxml=$script:junitPath")
    } catch {
        $script:junitPath = $null
        return @()
    }
}

function Show-TestBreakdown {
    <# 「N passed」の内訳を「導入先の自作 / キット同梱」で表示する（issue #30・
       導入先フィードバック §27: 同梱テストが増え、合計だけでは導入先のゲームについて
       何も言わない数字になっていた。v0.1.9 時点で自作の割合 18%）。
       **数え方は変えず見せ方だけ**を分ける。同梱の判定は kit-manifest.json
       （installer が書く所有記録）の driver\tests\ 配下エントリを正とする
       ＝配布テスト一覧の新たなハードコードを作らない（installer と自動で追随）。
       manifest が無い開発リポジトリ・XML が無い実行では何も出さない（内訳は補助表示。
       失敗しても本流の結果に影響させない）。
       **戻り値**: 判定できたら内訳（OwnRun / KitRun / OwnSkipped / KitSkipped）、
       判定できなければ $null（-RequireProjectTests の門はこの区別を fail-closed に使う）。 #>
    if (-not $script:junitPath -or -not (Test-Path $script:junitPath)) { return $null }
    $manifestPath = Join-UappPath $root "kit-manifest.json"
    if (-not (Test-Path $manifestPath)) { return $null }
    try {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        # 例: "driver\tests\test_client_unit.py" → "test_client_unit"（区切りは両 OS を許容）
        $kitModules = @($manifest.PSObject.Properties.Name |
            ForEach-Object { $_ -replace '\\', '/' } |
            Where-Object { $_ -match '(^|/)driver/tests/[^/]+\.py$' } |
            ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) })
        if (-not $kitModules.Count) { return $null }
        $own = 0; $kit = 0; $ownFailed = 0; $kitFailed = 0; $ownSkipped = 0; $kitSkipped = 0
        $xml = [xml](Get-Content $script:junitPath -Raw)
        foreach ($case in $xml.SelectNodes("//testcase")) {
            # classname は "tests.test_client_unit" のようなドット区切りモジュールパス
            # （pytest 既定の xunit2。クラス入りなら末尾にクラス名が足される）
            $isKit = $false
            foreach ($part in (("" + $case.classname) -split '\.')) {
                if ($kitModules -contains $part) { $isKit = $true; break }
            }
            $failed = [bool]($case.SelectSingleNode("failure") -or $case.SelectSingleNode("error"))
            # **skip は「実行した」に数えない**（レビュー指摘: 自作が全件 skip でも
            # 「自作 N 件」と出て注意行も出ず、「同梱だけで緑」がすり抜ける）
            $skipped = (-not $failed) -and [bool]$case.SelectSingleNode("skipped")
            if ($isKit) {
                if ($skipped) { $kitSkipped++ } else { $kit++; if ($failed) { $kitFailed++ } }
            } else {
                if ($skipped) { $ownSkipped++ } else { $own++; if ($failed) { $ownFailed++ } }
            }
        }
        if (($own + $kit + $ownSkipped + $kitSkipped) -eq 0) {
            # XML と manifest はあるのに testcase が 0 件＝「実行 0 と判定できた」なので
            # 表示は出さないが、門には数えられた事実を返す（判定不能とは区別する）
            return [pscustomobject]@{ OwnRun = 0; KitRun = 0; OwnSkipped = 0; KitSkipped = 0 }
        }
        $line = "[$projectName] テスト内訳: 導入先の自作 $own 件 / キット同梱 $kit 件"
        if (($ownFailed + $kitFailed) -gt 0) {
            $line += "（失敗: 自作 $ownFailed / 同梱 $kitFailed）"
        }
        if (($ownSkipped + $kitSkipped) -gt 0) {
            $line += "（skip: 自作 $ownSkipped / 同梱 $kitSkipped）"
        }
        Write-Host $line
        if ($own -eq 0) {
            # 数字の水増しで最も危険な形（フィードバック §27 の核心）: 同梱だけで
            # 緑に見えるが、導入先のゲームは 1 件も検証されていない（全件 skip も同じ）
            Write-Host ("[$projectName] 注意: 導入先の自作テストが 1 件も実行されていません" +
                        "（この緑はキットの自己検証だけで、ゲームの導線は検証していません）")
        }
        return [pscustomobject]@{ OwnRun = $own; KitRun = $kit
                                  OwnSkipped = $ownSkipped; KitSkipped = $kitSkipped }
    } catch {
        # 内訳は補助表示。読めない XML・壊れた manifest で本流を止めない
        return $null
    }
}

function Get-ProjectTestsGateFailure {
    <# -RequireProjectTests の門（issue #31・導入先フィードバック §28: 「自作 0 件は
       緑だが無意味なので失敗と同じ扱いにしたい」）。失敗理由の文字列を返す（通過なら $null）。
       **判定できない環境では fail-closed**（門のつもりが素通しになるのを防ぐ）。 #>
    param($Breakdown)
    if (-not $script:requireProjectTests) { return $null }
    if ($null -eq $Breakdown) {
        return ("-RequireProjectTests が指定されていますが、自作テストの実行数を判定できません" +
                "（kit-manifest.json と JUnit XML の両方が要ります。導入先レイアウトで使ってください）")
    }
    if ($Breakdown.OwnRun -eq 0) {
        return ("導入先の自作テストが 1 件も実行されていないため失敗にします（-RequireProjectTests）。" +
                "テスト指定（tests / -PytestArgs の -k・--ignore・--deselect）を確認してください")
    }
    return $null
}

function Send-E2eEvidence {
    param([int]$ExitCode, [string]$Mode, [string]$FailureDir)

    if (-not $script:dashEnabled) { return }
    $junitPath = $script:junitPath

    $data = @{ suite = "e2e"; project = $projectName; mode = $Mode; exitCode = $ExitCode }
    if ($junitPath -and (Test-Path $junitPath)) {
        try {
            $suite = ([xml](Get-Content $junitPath -Raw)).SelectSingleNode("//testsuite")
            if ($suite) {
                $failed = [int]$suite.failures + [int]$suite.errors
                $data.failed = $failed
                $data.skipped = [int]$suite.skipped
                $data.passed = [int]$suite.tests - $failed - [int]$suite.skipped
                $data.durationSec = [math]::Round([double]$suite.time, 1)
            }
        } catch {
            # 件数が取れなくても exitCode だけで記録する
        }
    }
    if ($JourneyDir -and (Test-Path (Join-UappPath $JourneyDir "report.html"))) {
        $data.journeyReport = Join-UappPath $JourneyDir "report.html"
    }
    if ($FailureDir -and (Test-Path $FailureDir)) { $data.failureDir = $FailureDir }
    Send-DashEvent -Kind "evidence.e2e" -StartPath $root -Data $data
}

# 設定解決: キット内（導入配置: <project>\uapp_e2e\e2e-config.json）→ プロジェクト直下（本リポジトリのサンプル配置）
$configPath = Join-UappPath $root "e2e-config.json"
if (-not (Test-Path $configPath)) {
    $configPath = Join-UappPath $projectDir "e2e-config.json"
}
if (-not (Test-Path $configPath)) { throw "e2e-config.json がありません（$root または $projectDir 直下）" }
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$package = $config.package
$activity = $config.activity
# デバイス内で待ち受けるポート（e2e-config.json の devicePort、未指定は 13333）。
# 同一デバイスに計装アプリが複数ある場合はアプリごとに別ポートを割り当てる
$devicePort = if ($config.devicePort) { [int]$config.devicePort } else { 13333 }

# --- エディタ直結モード（-Editor。ここで完結して adb フローには進まない） ---
if ($Editor) {
    # Unity CLI の解決: PATH → 既定インストール先（OS 差は uapp-platform.ps1）。
    # 無ければ手動手順を案内して失敗
    $unityCli = Get-UappUnityCli
    if (-not $unityCli) {
        throw ("-Editor には Unity CLI が必要です（https://docs.unity.com/en-us/unity-cli）。" +
               "CLI を使わない場合の手動手順: エディタで対象シーンを開いて Play →" +
               " `$env:UAPP_E2E_EDITOR='1' で pytest を実行")
    }
    # **CLI のグローバル引数は 1 か所で決めて全呼び出しへ渡す**（一部の呼び出しにだけ付くと、
    # 「status は通るのに pipeline install で落ちる」ような分かりにくい欠け方になる）。
    # check-portability.ps1 が「$unityCli を @cliGlobalArgs 無しで呼んでいないか」を検査する
    $cliProxyDisable = Resolve-UappUnityCliProxyDisable -Switch:$UnityCliProxyDisable
    $cliGlobalArgs = Get-UappUnityCliGlobalArgs -ProxyDisable:$cliProxyDisable
    # 子プロセスへの伝達は pytest 直前で行う（**確実に後始末できる位置でだけ環境変数を触る**。
    # ここで立てると、pytest 到達前の例外で呼び出し元のシェルに残る）
    if ($cliGlobalArgs.Count -gt 0) {
        Write-Host "[$projectName] Unity CLI へ渡すグローバル引数: $($cliGlobalArgs -join ' ')"
    }

    # com.unity.pipeline は Unity 6 以降のみ
    $projVer = (Get-Content (Join-UappPath $projectDir "ProjectSettings\ProjectVersion.txt") -TotalCount 1) -replace "m_EditorVersion:\s*", ""
    if ([int]($projVer -split "\.")[0] -lt 6000) {
        throw ("-Editor は Unity 6 以降のみ対応（com.unity.pipeline の要件。このプロジェクト: $projVer）。" +
               "手動手順: エディタで Play → `$env:UAPP_E2E_EDITOR='1' で pytest")
    }

    function Invoke-UnityCliStatus {
        <#
          .SYNOPSIS
          `unity status` を時間制限つきで叩き、@{ TimedOut; Json; Raw } を返す。

          .NOTES
          Unity CLI は認証セッションが stale になると**無言で 10 分以上ハングする**（導入先で実測）。
          `& $unityCli` で直に呼ぶと打ち切れず、利用者からは「何も起きない」ようにしか見えないので、
          **エディタの状態を見る呼び出しだけは必ず時間を区切る**（ここが一番最初の CLI 呼び出し）。
          パスは明示的に引用する（`-ArgumentList` の配列は空白結合されるため、空白入りのパスが割れる）。
        #>
        param([int]$TimeoutSeconds = 60, [string]$WaitMessage)
        $outFile = [System.IO.Path]::GetTempFileName()
        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            $process = Start-Process -FilePath $unityCli -PassThru -NoNewWindow `
                -ArgumentList (@($cliGlobalArgs) + @("status", "--project-path", (Format-CliArg $projectDir), "--format", "json", "--no-banner")) `
                -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $announced = $false
            while (-not $process.HasExited -and $sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
                if ($WaitMessage -and $sw.Elapsed.TotalSeconds -ge 5 -and -not $announced) {
                    Write-Host $WaitMessage
                    $announced = $true
                }
                Start-Sleep -Milliseconds 500
            }
            if (-not $process.HasExited) {
                try { $process.Kill() } catch {}
                $process.WaitForExit(10000) | Out-Null
                return @{ TimedOut = $true; Json = $null; Raw = "" }
            }
            $raw = ((Get-Content $outFile -Raw -ErrorAction SilentlyContinue) +
                    (Get-Content $errFile -Raw -ErrorAction SilentlyContinue))
            $json = $null
            try { $json = $raw | ConvertFrom-Json } catch { $json = $null }
            return @{ TimedOut = $false; Json = $json; Raw = $raw }
        } finally {
            Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
        }
    }

    function Test-CliConnected {
        # `unity status` が「このプロジェクトを開いたエディタが居る」と言っているか
        param($Status)
        [bool]($Status -and $Status.Json -and $Status.Json.success -and $Status.Json.data.count -ge 1)
    }

    function Invoke-UnityCli {
        <#
          .SYNOPSIS
          pipeline コマンドを叩く。**タイムアウトは待って再試行する**（`-AllowFail` を除く）。

          .NOTES
          タイムアウトは「失敗」ではなく「エディタがまだ手空きでない」。コールドスタート直後は
          アセットインポートとコンパイルで塞がっており、**軽い eval は通るのに editor_status
          （EditorApplication の状態を集める）はまだ返らない**状態が実在する（導入先で実測）。
          そのため疎通プローブ 1 か所だけを再試行しても、その直後の呼び出しが同じ理由で落ちた。
          再試行はコマンド共通の関心事なので、**呼び出し側ではなくここに置く**
          （open_scene / editor_play / list_open_scenes も同じ危険を持つ）。

          `--timeout` を伸ばす対処は採らない。伸ばすと「本当に固まっている」と区別できなくなる。
          **タイムアウト以外の失敗は再試行せず即座に上げる**（版差・実エラーの切り分けを保つ）。
          `-AllowFail` の呼び出しは再試行しない — 失敗を織り込んで呼び手が分岐するためのもので、
          待つかどうかも呼び手が決める。

          **再試行してよいのは「二度実行しても害が無い」コマンドだけ**。
          クライアント側のタイムアウトは「実行されなかった」ことを保証しない（サーバーは
          メインスレッド待ちのまま残り、手が空いた時点で実行する）ため、再試行は重複実行に
          なりうる。下の一覧は com.unity.pipeline の実装で確認したもの
          （editor_play / editor_stop は現在の状態を見て何もしない・status 系は読み取りのみ・
          このスクリプトが渡す eval / eval_file は「有効シーンを読む」「Game view 解像度を
          設定する」だけ）。**一覧に無いコマンドは待たずに落とす**。
          たとえば editor_pause はトグルなので二度実行すると状態が反転する。
          **open_scene もあえて外す**: 1 回目が実行されたあとに（sceneOpened のコールバック等で）
          シーンが dirty になっていると、2 回目の OpenSceneMode.Single が
          その未保存変更を捨てる — 事前の dirty 検査は再試行の前には効かない。
          なお editor_status が同じ待機を通るので、そこを抜けた時点でエディタは手空きであり、
          外したことで v0.1.5 以前より悪くなる経路は無い。
        #>
        param([string[]]$CliArgs, [switch]$AllowFail)
        $retrySafe = @("pipeline", "editor_status", "list_open_scenes", "editor_play", "editor_stop",
                       "eval", "eval_file", "screenshot")
        # cmd 系は常に対象プロジェクトへスコープする（複数エディタ起動時に別プロジェクトを操作・停止しない）
        if ($CliArgs[0] -eq "cmd") {
            $cmdName = $CliArgs[1]
            $CliArgs = @("cmd", "--project-path", $projectDir) + $CliArgs[1..($CliArgs.Count - 1)]
        } else {
            $cmdName = $CliArgs[0]
        }
        $label = ($CliArgs | Where-Object { $_ -notmatch "^-" -and $_ -ne $projectDir }) -join " "
        $wait = [System.Diagnostics.Stopwatch]::StartNew()
        $notified = $false
        while ($true) {
            # **CLI の出力（UTF-8）をコンソール符号化で復号しない**（run-unity-tests.ps1 の
            # Invoke-Pipeline と同じ理由: cp932 だとマルチバイトの後続バイトが `"` を飲み込み
            # JSON が壊れる。dump の日本語 UI 名・日本語テスト名で発症する）
            $prevEnc = [Console]::OutputEncoding
            try {
                [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
                $raw = & $unityCli @cliGlobalArgs @CliArgs --format json --no-banner 2>&1 | Out-String
            } finally { [Console]::OutputEncoding = $prevEnc }
            $parsed = $null
            try { $parsed = $raw | ConvertFrom-Json } catch {}
            if ($parsed -and $parsed.success) {
                if ($notified) {
                    Write-Host "[$projectName] $label が応答（待機 $([int]$wait.Elapsed.TotalSeconds) 秒）"
                }
                return $parsed
            }
            $detail = if ($parsed.errors) { ($parsed.errors | ForEach-Object { $_.message }) -join " / " } else { $raw }
            # **タイムアウト判定は構造化されたエラーだけで行う**。生出力には `--timeout` の
            # 用法説明などが混ざるので、版差で出たヘルプを「待てば直る」と誤読すると
            # すぐ落ちるべき失敗を延々と待つことになる
            $isTimeout = $parsed -and $parsed.errors -and $detail -match "timed out|timeout"
            if ($AllowFail -or -not $isTimeout -or $retrySafe -notcontains $cmdName) { break }
            if ($wait.Elapsed.TotalSeconds -ge $EditorReadyTimeoutSeconds) {
                throw ("エディタが $([int]$wait.Elapsed.TotalSeconds) 秒たっても '$label' に応答しません: $detail。" +
                       "エディタ側でインポート/コンパイルが終わらない、または Console でエラーが出ていないか確認する" +
                       "（待ち時間は -EditorReadyTimeoutSeconds で延ばせる）")
            }
            if (-not $notified) {
                Write-Host ("[$projectName] エディタは接続済みだが '$label' に応答しない" +
                            "（インポート/コンパイル中の可能性）。最大 $EditorReadyTimeoutSeconds 秒待ちます...")
                $notified = $true
            }
            Start-Sleep -Seconds 3
        }
        if (-not $AllowFail -and (-not $parsed -or -not $parsed.success)) {
            throw "unity $($CliArgs -join ' ') が失敗: $raw"
        }
        $parsed
    }

    # 同一プロジェクトへの -Editor 同時実行を防ぐプロセス間ロック（TOCTOU対策:
    # 2プロセスが同時に playMode=stopped を見て両方進むと、片方の editor_stop が他方の Play を落とす）
    # **名前はホスト全体スコープへ変換する**。素の名前だと Unix では
    # `/tmp/.dotnet/shm/session<ID>/` に隔離され、**別ターミナルからの同時実行を素通しする**
    # （＝このガードが黙って無効になる。mac で実測）。変換は Get-UappHostMutexName に集約。
    # 名前の組み立ては restart-editor-play.ps1 と共有する（片方だけ別名だと排他が素通りする）
    $mutexName = Get-UappEditorPlayMutexName $projectDir
    $editorMutex = New-Object System.Threading.Mutex($false, $mutexName)
    $mutexAcquired = $false
    try { $mutexAcquired = $editorMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $mutexAcquired = $true }
    if (-not $mutexAcquired) {
        throw "このプロジェクトへの -Editor 実行が別プロセスで進行中です。完了を待って再実行"
    }
    # 子（pytest→restart-editor-play.ps1）への「同一実行単位」の証明は、**この実行だけが
    # 保持するリース mutex**で行う（実行ごとのランダム名・保持は下の finally まで）。
    # PID 方式は不成立だった（4 周目レビュー指摘: `.\scripts\run-e2e.ps1` はシェル内で動くため
    # $PID は対話シェルの PID。実行が終わってもシェルは生き続け、stale トークンが素通りする）
    $sessionMutexName = Get-UappHostMutexName ("uapp_e2e-editor-session-" + [guid]::NewGuid().ToString("n"))
    $sessionMutex = New-Object System.Threading.Mutex($true, $sessionMutexName)
    try {

    # エディタが Pipeline 接続済みかを確認。未接続なら pipeline install → エディタ起動 → 接続待ち
    # ドメインリロード直後などは status が一瞬応答しない。1 回の失敗で「未接続」と決めない
    # （決めるとエディタを起動しにいく／下のロックファイル判定で無用に止まる）
    $status = $null
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Seconds 3 }
        $status = Invoke-UnityCliStatus -TimeoutSeconds $UnityCliProbeSeconds `
            -WaitMessage "[$projectName] Unity CLI の応答を待っています（unity status）..."
        if (Test-CliConnected -Status $status) { break }
        if ($status.TimedOut) {
            # CLI 自体が壊れている（認証セッション stale 等）。-Editor は CLI 経由でしか
            # 成立しないので、黙って待ち続けずに原因と代替手段を示して止める
            throw ("Unity CLI が $UnityCliProbeSeconds 秒応答しません（unity status）。" +
                   "'unity doctor' で状態を確認し、認証セッションが切れているなら 'unity auth login' で復帰させてください。" +
                   "CLI を使わない手順: エディタで対象シーンを開いて Play → `$env:UAPP_E2E_EDITOR='1' で pytest" +
                   "（待ち時間は -UnityCliProbeSeconds で延ばせる）")
        }
    }
    # エディタが動いている（ロックファイルがある）のに応答しない理由の大半は
    # **コンパイル/ドメインリロード中**。C# を直した直後に叩くのは日常なので、腰を据えて待つ
    if (-not (Test-CliConnected -Status $status) -and (Test-UnityProjectLocked -ProjectDir $projectDir)) {
        Write-Host "[$projectName] エディタは起動中だが Pipeline が応答しない（コンパイル中の可能性）。最大 300 秒待ちます..."
        $wait = [System.Diagnostics.Stopwatch]::StartNew()
        while ($wait.Elapsed.TotalSeconds -lt 300) {
            Start-Sleep -Seconds 3
            $status = Invoke-UnityCliStatus -TimeoutSeconds $UnityCliProbeSeconds
            if (Test-CliConnected -Status $status) { break }
        }
        Write-Host "[$projectName] 待機 $([int]$wait.Elapsed.TotalSeconds) 秒"
    }
    if (-not (Test-CliConnected -Status $status)) {
        # **既に開いているプロジェクトを二重に開かない**。Unity は開いている間 Temp\UnityLockfile を作る。
        # status が一時的に応答しないだけで `unity open` すると、利用者の画面に
        # 「プロジェクトは既に開かれています」ダイアログが出て操作を奪う
        if (Test-UnityProjectLocked -ProjectDir $projectDir) {
            throw ("エディタは既にこのプロジェクトを開いていますが、Pipeline に接続していません: $projectDir。" +
                   "二重起動はしません。エディタ側で com.unity.pipeline が入っているか（Package Manager）、" +
                   "接続が生きているか（unity status）を確認してください")
        }
        Write-Host "[$projectName] エディタ未接続。Pipeline パッケージを確認してエディタを起動します..."
        # 注意: 未導入の場合 Packages\manifest.json に com.unity.pipeline が追加される（VCS差分になる）
        $null = Invoke-UnityCli @("pipeline", "install", "--project-path", $projectDir)
        # **パスは引用する**（-ArgumentList の配列は空白結合されるため、空白入りのパスが割れる）
        Start-Process -FilePath $unityCli -ArgumentList (@($cliGlobalArgs) + @("open", (Format-CliArg $projectDir))) | Out-Null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            Start-Sleep -Seconds 5
            $status = Invoke-UnityCliStatus -TimeoutSeconds $UnityCliProbeSeconds
            if ((Test-CliConnected -Status $status) -and $status.Json.data.instances[0].state -eq "ready") { break }
            if ($sw.Elapsed.TotalSeconds -gt 600) { throw "エディタの Pipeline 接続待ちがタイムアウト（600秒）。Editor.log を確認" }
        }
        Write-Host "[$projectName] エディタ接続完了（$([int]$sw.Elapsed.TotalSeconds)秒）"
    }

    # 版差の早期検出: Unity CLI と com.unity.pipeline の組み合わせが変わると、後続の失敗が
    # 「400 Bad Request: Parameter Validation Failed」のような読み解きにくい形で出る
    # （実例: pipeline 0.4 で eval の code が必須の名前付き引数になり、位置引数の呼び出しが全滅した）。
    # 一番単純な eval を叩いて、ここで切り分けを終わらせる。
    #
    # **これは版差の検出であって「準備完了」の判定ではない**。
    # プローブが 1 回で通っても、エディタが手空きとは限らない（軽い eval は通るのに
    # editor_status はまだ返らない状態が実在する）。準備完了の待機は Invoke-UnityCli が
    # コマンドごとに行うので、ここで待つ必要はない — タイムアウトは版差でなく手空きでないだけなので
    # 素通しし、後続の呼び出し（同関数が待って再試行する）に判断を委ねる
    $probe = Invoke-UnityCli @("cmd", "eval", "--code", 'return "ok";') -AllowFail
    $probeTimedOut = $probe -and -not $probe.success -and
                     ((($probe.errors | ForEach-Object { $_.message }) -join " / ") -match "timed out|timeout")
    if (-not $probeTimedOut -and (-not $probe -or -not $probe.success -or $probe.data.result.result -ne "ok")) {
        $detail = if ($probe.errors) { ($probe.errors | ForEach-Object { $_.message }) -join " / " } else { "応答なし" }
        throw ("Unity CLI / com.unity.pipeline のバージョンが想定と異なります（eval の疎通に失敗: $detail）。" +
               "'unity --version' と <プロジェクト>\Packages\manifest.json の com.unity.pipeline を確認する。" +
               "検証済みの組み合わせ: unity-cli 1.0.0-beta.3 / com.unity.pipeline 0.4.0-exp.1")
    }

    # 排他ガード: stopped 以外（playing / paused）は他タスク/他セッションが使用中とみなしてフェイルファスト
    # （paused も既存 Play セッション。ここを通すと finally の editor_stop で他者の Play を強制終了してしまう）
    $es = Invoke-UnityCli @("cmd", "editor_status")
    $playMode = $es.data.result.playMode
    if ($playMode -ne "stopped") {
        throw ("エディタは既に Play セッション中です（playMode=$playMode。他タスク/他セッションが使用中の可能性）。" +
               "意図的に奪う場合は 'unity cmd editor_stop' 後に再実行")
    }

    # シーン: 未指定なら Build Settings の先頭有効シーン
    # eval の C# コードは **--code で渡す**。com.unity.pipeline の CodeEvalCommand は
    # code を必須の名前付き引数として宣言しており（[CliArg("code", Required = true)]）、
    # 位置引数で渡すと 400 Parameter Validation Failed になる（0.4.0-exp.1 で実測）
    if (-not $Scene) {
        $r = Invoke-UnityCli @("cmd", "eval", "--code",
            'foreach (var s in UnityEditor.EditorBuildSettings.scenes) { if (s.enabled) return s.path; } return "";')
        $Scene = $r.data.result.result
    }
    if ($Scene) {
        # open_scene は現在の全シーンを閉じる（OpenSceneMode.Single）ため、未保存変更を黙って捨てない:
        # 対象シーンが既にアクティブなら開き直さない。別シーンを開く必要があり dirty があれば中断する
        $openScenes = (Invoke-UnityCli @("cmd", "list_open_scenes")).data.result.scenes
        $activeScene = $openScenes | Where-Object { $_.isActive } | Select-Object -First 1
        if ($activeScene -and $activeScene.path -eq $Scene) {
            Write-Host "[$projectName] シーン: $Scene（既に開いている）"
        } else {
            $dirty = @($openScenes | Where-Object { $_.isDirty } | ForEach-Object { $_.path })
            if ($dirty.Count -gt 0) {
                throw ("未保存のシーン変更があるため中断: $($dirty -join ', ')。" +
                       "エディタで保存または破棄してから再実行（open_scene は現在のシーンを閉じるため）")
            }
            $null = Invoke-UnityCli @("cmd", "open_scene", "--path", $Scene)
            Write-Host "[$projectName] シーン: $Scene"
        }
    }

    # Game view 解像度: 実機と同等のアンカー配置にする（不一致だと UI が画面外に落ちて NOTHING_HIT になる）
    # 解像度の優先順位: -EditorResolution 引数 > e2e-config.json の editorResolution > orientation 由来。
    # **UI の設計解像度が orientation 既定と違うプロジェクトは editorResolution を設定する**
    # （導入先実測: 900x1600 設計のところへ既定 1080x2340 で流すと、座標決め打ちのテストだけが
    # 静かに壊れる — 大半の要素は取れてしまうので気づきにくい。毎回 -EditorResolution を
    # 付ける運用は忘れるため、git 管理の設定に置けるようにする）
    if (-not $EditorResolution -and $config.editorResolution) {
        $EditorResolution = "$($config.editorResolution)"
    }
    if (-not $EditorResolution) {
        $EditorResolution = if ($config.orientation -eq "landscape") { "2340x1080" } else { "1080x2340" }
    }
    # **数値であることを検証してから C# へ埋める**。ここは文字列連結でコードを組み立てているので、
    # 検証せずに通すと値の中身がそのままコードになる（`-EditorResolution '1080x2340);…//'` で
    # 任意の文を差し込めてしまい、「eval に渡すのは固定コードだから再試行しても安全」という
    # Invoke-UnityCli の前提も崩れる）。打ち間違いをその場で弾ける利点もある
    if ($EditorResolution -notmatch '^\s*(\d+)\s*[xX]\s*(\d+)\s*$') {
        throw "-EditorResolution は '幅x高さ'（例: 1080x2340）で指定してください: '$EditorResolution'"
    }
    $wh = @([int]$Matches[1], [int]$Matches[2])
    if ($wh[0] -le 0 -or $wh[1] -le 0) { throw "-EditorResolution の幅・高さは 1 以上: '$EditorResolution'" }
    # C#文字列リテラルの二重引用符はコマンドライン経由で壊れやすいため eval_file（一時ファイル）で渡す。
    # 置き場所は TEMP でなく Builds\ 配下（gitignore 済み）: サンドボックス環境では TEMP が
    # 8.3 短縮パス（C:\Users\XXXXXX~1.YYY\...）で渡り、その形のパスは Move-Item / Remove-Item が
    # -ErrorAction SilentlyContinue でも抑止されない失敗になる（導入先で実測）
    $evalTmpDir = Join-UappPath $root "Builds\tmp"
    New-Item -ItemType Directory -Force $evalTmpDir | Out-Null
    $evalTmp = Join-UappPath $evalTmpDir ("uapp_e2e-eval-" + [System.IO.Path]::GetRandomFileName() + ".cs")
    try {
        [System.IO.File]::WriteAllText($evalTmp,
            "UnityEditor.PlayModeWindow.SetCustomRenderingResolution($($wh[0]), $($wh[1]), `"uapp_e2e E2E`");`nreturn `"ok`";`n")
        $null = Invoke-UnityCli @("cmd", "eval_file", "--file", $evalTmp)
    } finally {
        Remove-Item $evalTmp -ErrorAction SilentlyContinue
    }
    Write-Host "[$projectName] Game view 解像度: $EditorResolution / Play 開始..."

    $null = Invoke-UnityCli @("cmd", "editor_play")
    if ($JourneyDir) { Write-Host "[$projectName] ジャーニー記録: $JourneyDir（Game view を Unity CLI で撮影）" }

    # **子プロセス（pytest → Python ドライバ）も同じ Unity CLI を叩く**（ジャーニー/失敗時の
    # スクリーンショットは `unity eval` で撮る）。ここで伝えないと**画像だけが静かに欠落する**。
    # 元の値は下の finally で必ず戻す（戻さないと、同じシェルで次にスイッチ無しで実行した
    # スクリプトにも --proxy-disable が付き、プロキシ経由が要る認証・ダウンロードが壊れる）
    $savedCliProxyEnv = $env:UAPP_E2E_UNITY_CLI_PROXY_DISABLE
    # **接続先ポートを明示的に渡す**。ドライバの `resolve_port` は pytest の CWD（driver\）から
    # 上位へ e2e-config.json を探すが、**この開発リポジトリは設定をプロジェクト直下
    # （unity-nis\e2e-config.json 等）に置く配置**なので driver\ からは見つからず、
    # 既定 13333 に落ちる。導入先レイアウト（uapp_e2e\e2e-config.json）では見つかるため
    # 差が出にくいが、**開発リポジトリでは editorBridgePort を変えても効かない**という
    # 分かりにくい形で現れる（issue #25 の A を入れたときに実測して発覚）
    # **呼び出し元が既に設定していれば尊重する**。ドライバの解決順は
    # 明示引数 > 環境変数 > e2e-config.json なので、ここで無条件に上書きすると
    # 「環境変数で別ポートを指したのに設定ファイルの値で接続しにいく」という
    # 契約違反になる（docs/02 のポート設計）。元の値は finally で必ず戻す
    $savedBridgePort = $env:UAPP_E2E_BRIDGE_PORT
    # **例外を投げうる処理は環境変数を触る前に済ませる**。設定と try の間で throw すると
    # 呼び出し元のシェルに残る（不正な editorBridgePort での [int] 変換、Push-Location の失敗。
    # 4 周目のレビュー指摘）
    $editorPortToPass = $null
    if (-not $savedBridgePort -and $config.editorBridgePort) {
        $editorPortToPass = [int]$config.editorBridgePort
    }
    Push-Location (Join-UappPath $root "driver")
    try {
        # **環境変数は try の中でだけ触る**（下の finally が必ず戻す）
        $env:UAPP_E2E_EDITOR = "1"
        # このプロセスが保持している editor-play mutex の名前を子（pytest→テストが呼ぶ
        # restart-editor-play.ps1）へ渡す。無いと、テスト中の Play 再起動が親の保持する
        # mutex に阻まれて必ず中断する（＝Play またぎテストという本来用途が成立しない）。
        # リース mutex の名前も渡す: 子は「名前一致＋リースがまだ保持されている」ときだけ
        # 素通しする（この実行が終われば finally でリースが手放されるので、残った子が
        # 次の実行の排他を stale トークンで素通りすることはない）
        $env:UAPP_E2E_EDITOR_LOCK = $mutexName
        $env:UAPP_E2E_EDITOR_LOCK_SESSION = $sessionMutexName
        if ($cliProxyDisable) { $env:UAPP_E2E_UNITY_CLI_PROXY_DISABLE = "1" }
        if ($editorPortToPass) { $env:UAPP_E2E_BRIDGE_PORT = $editorPortToPass }
        # ジャーニーのスクリーンショットは adb ではなく Unity CLI の screenshot で撮る
        # （エディタ直結で adb を使うと実機を検証してしまうため、経路自体を分けている）。
        # 複数エディタが起動していても宛先を誤らないよう、対象プロジェクトも渡す
        $env:UAPP_E2E_UNITY_CLI = $unityCli
        $env:UAPP_E2E_PROJECT_PATH = $projectDir
        if ($JourneyDir) { $env:UAPP_E2E_JOURNEY_DIR = $JourneyDir }
        # @(...) で必ず配列にする: 1要素の戻り値はスカラー文字列に化け、@splat が1文字ずつ展開される
        $junitArgs = @(Enable-JunitOutput -Tag "editor")
        if ($PytestArgs) {
            & $script:pythonExe -m pytest $config.tests @($PytestArgs -split " ") @junitArgs -v
        } else {
            & $script:pythonExe -m pytest $config.tests @junitArgs -v
        }
        $exit = $LASTEXITCODE
        # 失敗証跡: エディタ直結でも「AI が読める画像」を残す（Play を止める前に撮る）。
        # これが無いと -Editor の失敗時に「Console と Editor.log を見ろ」しか言えず、
        # AI から見える証跡がゼロになる
        if ($exit -ne 0) {
            $editorFailureDir = Join-UappPath $root "Builds\failure"
            New-Item -ItemType Directory -Force $editorFailureDir | Out-Null
            $shot = Join-UappPath $editorFailureDir "screen.png"
            & $script:pythonExe -c "from e2e_driver import editor_screenshot as es; import sys; sys.exit(0 if es.capture(sys.argv[1]) else 1)" $shot
            if ($LASTEXITCODE -eq 0) { Write-Host "失敗時のスクリーンショット: $shot" }
        }
        if ($JourneyDir -and (Test-Path (Join-UappPath $JourneyDir "journey.json"))) {
            & $script:pythonExe -m e2e_driver.journey $JourneyDir
            if ($LASTEXITCODE -eq 0) { Write-Host "ジャーニーレポート: $(Join-UappPath $JourneyDir 'report.html')" }
        }
    } finally {
        Pop-Location
        Remove-Item Env:\UAPP_E2E_EDITOR -ErrorAction SilentlyContinue
        Remove-Item Env:\UAPP_E2E_EDITOR_LOCK -ErrorAction SilentlyContinue
        Remove-Item Env:\UAPP_E2E_EDITOR_LOCK_SESSION -ErrorAction SilentlyContinue
        if ($savedCliProxyEnv) { $env:UAPP_E2E_UNITY_CLI_PROXY_DISABLE = $savedCliProxyEnv }
        else { Remove-Item Env:\UAPP_E2E_UNITY_CLI_PROXY_DISABLE -ErrorAction SilentlyContinue }
        Remove-Item Env:\UAPP_E2E_JOURNEY_DIR -ErrorAction SilentlyContinue
        # 設定した分は全部消す（消し漏れると、次に手で pytest を回したときに
        # 古いプロジェクトのエディタへスクリーンショットを撮りに行く）
        Remove-Item Env:\UAPP_E2E_UNITY_CLI -ErrorAction SilentlyContinue
        Remove-Item Env:\UAPP_E2E_PROJECT_PATH -ErrorAction SilentlyContinue
        # **消すのではなく元の値へ戻す**（呼び出し元が設定していた値を奪わない）
        if ($savedBridgePort) { $env:UAPP_E2E_BRIDGE_PORT = $savedBridgePort }
        else { Remove-Item Env:\UAPP_E2E_BRIDGE_PORT -ErrorAction SilentlyContinue }
        # Play は必ず終了させる（次のタスクのために排他資源を解放）
        $null = Invoke-UnityCli @("cmd", "editor_stop") -AllowFail
    }

    } finally {
        # 途中の throw でもプロセス間ロックを確実に解放する（Play/シーン操作前の失敗を含む）
        $sessionMutex.ReleaseMutex()
        $sessionMutex.Dispose()
        $editorMutex.ReleaseMutex()
        $editorMutex.Dispose()
    }

    $breakdown = Show-TestBreakdown
    $gateFailure = Get-ProjectTestsGateFailure $breakdown
    $finalExit = $exit
    if ($gateFailure -and $finalExit -eq 0) { $finalExit = 1 }
    Send-E2eEvidence -ExitCode $finalExit -Mode "editor"
    if ($exit -ne 0) {
        $shot = Join-UappPath $root "Builds\failure\screen.png"
        $editorLog = Get-UappEditorLogPath   # 置き場は OS で違う（分岐は uapp-platform.ps1 側）
        Write-Host ("失敗解析: " + $(if (Test-Path $shot) { "$shot（画像として読む） → " } else { "" }) +
                    "エディタの Console と Editor.log（$editorLog）を確認")
        exit $exit
    }
    if ($gateFailure) {
        # **最後に出す**（導入先フィードバック §28: 途中の注意行は pytest の warnings に埋もれる）
        Write-Host "[$projectName] $gateFailure"
        exit $finalExit
    }
    Write-Host "[$projectName] E2E テスト成功（エディタ直結）。"
    exit 0
}

if (-not $Apk) { $Apk = Join-UappPath $root "Builds\$projectName.apk" }

# adb が PATH に無ければ SDK の platform-tools を PATH へ足す（子プロセスの pytest にも効く）。
# **mac は SDK を入れても platform-tools が PATH に入らないことが多い**
$adbPathAdded = Initialize-UappAndroidPath
if ($adbPathAdded) { Write-Host "adb を PATH に追加しました: $adbPathAdded" }
# **解決した実体を保持して、以降は `& $script:adbExe` で呼ぶ**。
# PATH に足すだけでは足りない（`adb` という関数やエイリアスが定義されていると、
# 存在判定は実行ファイルを見つけるのに、実際の呼び出しはそちらへ入って失敗する）。
# PATH への追加は**子プロセスの Python ドライバ用**として引き続き必要
$script:adbExe = Get-UappCommandPath "adb"
if (-not $script:adbExe) {
    throw ("adb が見つかりません。Android SDK Platform-Tools を導入して PATH に追加するか、" +
           "ANDROID_HOME / ANDROID_SDK_ROOT を設定してください")
}

# 対象デバイス指定（複数AVD同時運用対応）。未指定なら adb 既定（1台接続時のみ有効）
$adbTarget = @()
if ($DeviceSerial) { $adbTarget = @("-s", $DeviceSerial) }

# adbデーモン再起動直後は device offline で各コマンドが黙って失敗するため、
# 接続を待った上で全stepのexit codeを検証する
& $script:adbExe @adbTarget wait-for-device
if ($LASTEXITCODE -ne 0) { throw "デバイスが接続されていません (adb devices で確認)" }

if (-not $SkipInstall) {
    if (-not (Test-Path $Apk)) { throw "APK がありません: $Apk （先に build-android.ps1 -Project $projectName を実行）" }
    $apkBytes = (Get-Item $Apk).Length
    Write-Host "[$projectName] インストール中: $Apk （$([math]::Round($apkBytes / 1MB)) MB）"

    # 入れてみて失敗するより先に空きを見る。計装アプリを複数並べると普通に足りなくなり、
    # そのときの adb のメッセージは「テストが失敗した」ようにしか見えない（実際に嵌まった）
    $freeBytes = Get-DeviceFreeBytes -AdbTarget $adbTarget
    if ($freeBytes -gt 0 -and $freeBytes -lt ($apkBytes * 2.5)) {
        Write-Warning ("デバイスの空き容量が少なくなっています（空き $([math]::Round($freeBytes / 1MB)) MB / " +
                       "APK $([math]::Round($apkBytes / 1MB)) MB）。インストールに失敗する可能性があります。" +
                       "不要なアプリを削除するか、AVD のディスクを拡張してください")
    }

    # install の出力は捨てない。失敗理由（ストレージ不足・署名不一致等）が全部ここに出る
    $installOutput = (& $script:adbExe @adbTarget install -r -g $Apk 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw (Format-InstallFailure -Output $installOutput -ExitCode $LASTEXITCODE -Apk $Apk `
                                     -Package $package -FreeBytes $freeBytes)
    }
}

# 縦横両対応アプリの初期向き指定（e2e-config.json の deviceRotation: 0=縦 1=横(左) 2=逆縦 3=横(右)）
if ($null -ne $config.deviceRotation) {
    & $script:adbExe @adbTarget shell settings put system accelerometer_rotation 0
    & $script:adbExe @adbTarget shell settings put system user_rotation $config.deviceRotation
    Write-Host "[$projectName] デバイス回転を固定: $($config.deviceRotation)"
}

# ホスト側ポート解決: -HostPort 引数 → config\local.json の bridgePort → 13333
# 複数ターゲット同時運用時はターゲットごとに別ポートを指定すること
if ($HostPort -eq 0) {
    $HostPort = 13333
    $localConfigPath = Join-UappPath $root "config\local.json"
    if (Test-Path $localConfigPath) {
        $local = Get-Content $localConfigPath -Raw | ConvertFrom-Json
        if ($local.bridgePort) { $HostPort = $local.bridgePort }
    }
}
# **ホスト側ポートが editorBridgePort と同じなら、この forward はエディタ直結の接続先を奪う**。
# ここは `$HostPort` が確定した後なので誤検知が無い（installer 側は local.json が
# 未作成のことがあり仮判定にしかならない）。**並行実行に限らない** — forward は実行後も
# 残るので、このあとエディタ直結を回すだけで踏む。ドライバ側の WrongBridgeTargetError が
# 最終的には止めるが、**踏む前にここで気づける**ようにしておく（issue #25）
$editorBridgePort = if ($config.editorBridgePort) { [int]$config.editorBridgePort } else { 0 }
if ($editorBridgePort -eq $HostPort) {
    Write-Warning ("ホスト側の forward ポートと e2e-config.json の editorBridgePort が同じ値です（$HostPort）。" +
                   "この forward は実行後も残り、次にエディタ直結（-Editor / UAPP_E2E_EDITOR=1）を回すと" +
                   "接続先を奪います。editorBridgePort をずらすか、-HostPort で別の番号を使ってください")
}
& $script:adbExe @adbTarget forward "tcp:$HostPort" "tcp:$devicePort" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "adb forward 失敗 (exit=$LASTEXITCODE)。ポート $HostPort が他ターゲットと重複していないか確認" }
& $script:adbExe @adbTarget logcat -c
# -S: 起動前に対象プロセスを確実にkill（前回実行の状態残留を防ぐ） / -W: 起動完了まで待つ
# -a MAIN -c LAUNCHER: ランチャー起動と同じ Intent にする（action 無しだと起動直後に
#   自ら閉じるカスタムActivityがある。実プロジェクト導入試験で実証）
# --ei uapp_e2e_port: ブリッジの待ち受けポートをアプリに伝える（BridgeHost が Intent extra から読む）
& $script:adbExe @adbTarget shell am start -S -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER --ei uapp_e2e_port $devicePort -n "$package/$activity" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "アプリ起動失敗 (exit=$LASTEXITCODE)" }
Write-Host "[$projectName] アプリ起動（$(if ($DeviceSerial) { $DeviceSerial } else { '既定デバイス' }) / port $HostPort）。テストを実行します..."
if ($JourneyDir) { Write-Host "[$projectName] ジャーニー記録: $JourneyDir" }

# pytest へ渡す環境変数は、この直後の try/finally で必ず消せる位置でだけ設定する
#（起動失敗で throw する箇所より前に置くと、呼び出し元のシェルに残る。残った
#  UAPP_E2E_BRIDGE_PORT は、次に手で pytest を回したときに疎通スモークを
#  「run-e2e 経由」と誤認させ、待受のいないポートへ接続しにいく）
$env:UAPP_E2E_BRIDGE_PORT = $HostPort
$env:UAPP_E2E_PACKAGE = $package
$env:UAPP_E2E_DEVICE_PORT = $devicePort
if ($DeviceSerial) { $env:UAPP_E2E_DEVICE_SERIAL = $DeviceSerial }
if ($JourneyDir) { $env:UAPP_E2E_JOURNEY_DIR = $JourneyDir }
Push-Location (Join-UappPath $root "driver")
try {
    # ターゲット（デバイス・ホスト側ポート）ごとに XML を分ける＝並行実行が互いを壊さない。
    # @(...) は必須（1要素の戻り値がスカラー化すると @splat が1文字ずつ展開される）
    $junitArgs = @(Enable-JunitOutput -Tag ("device-" + $(if ($DeviceSerial) { "$DeviceSerial-" } else { "" }) + $HostPort))
    if ($PytestArgs) {
        & $script:pythonExe -m pytest $config.tests @($PytestArgs -split " ") @junitArgs -v
    } else {
        & $script:pythonExe -m pytest $config.tests @junitArgs -v
    }
    $exit = $LASTEXITCODE
    # ジャーニーが記録されていれば自己完結レポートを更新する（失敗時も解析に使うため生成する）。
    # journey フィクスチャを使うテストが無かった実行では journey.json が無いのでスキップ
    if ($JourneyDir -and (Test-Path (Join-UappPath $JourneyDir "journey.json"))) {
        & $script:pythonExe -m e2e_driver.journey $JourneyDir
        if ($LASTEXITCODE -eq 0) {
            Write-Host "ジャーニーレポート: $(Join-UappPath $JourneyDir 'report.html')"
        } else {
            Write-Warning "ジャーニーレポート生成に失敗（テスト結果には影響しない）: $JourneyDir"
        }
    }
} finally {
    Pop-Location
    Remove-Item Env:\UAPP_E2E_PACKAGE -ErrorAction SilentlyContinue
    Remove-Item Env:\UAPP_E2E_BRIDGE_PORT -ErrorAction SilentlyContinue
    Remove-Item Env:\UAPP_E2E_DEVICE_PORT -ErrorAction SilentlyContinue
    Remove-Item Env:\UAPP_E2E_DEVICE_SERIAL -ErrorAction SilentlyContinue
    Remove-Item Env:\UAPP_E2E_JOURNEY_DIR -ErrorAction SilentlyContinue
}

$breakdown = Show-TestBreakdown
$gateFailure = Get-ProjectTestsGateFailure $breakdown
if ($exit -ne 0) {
    # 失敗時はAIが読める証跡を残す
    $evidence = Join-UappPath $root "Builds\failure"
    New-Item -ItemType Directory -Force $evidence | Out-Null
    # **PNG は `>` で保存しない**（版によってはテキスト変換されて壊れる）。
    # 標準出力をバイト列のままファイルへ落とす
    Save-UappNativeOutput -Exe $script:adbExe -Arguments (@($adbTarget) + @("exec-out", "screencap", "-p")) `
                          -OutFile (Join-UappPath $evidence "screen.png") | Out-Null
    & $script:adbExe @adbTarget logcat -d -s "Unity:*" > (Join-UappPath $evidence "unity-logcat.txt")
    & $script:adbExe @adbTarget logcat -d -b crash > (Join-UappPath $evidence "crash.txt")
    Write-Host "失敗時の証跡を保存: $evidence （screen.png / unity-logcat.txt / crash.txt）"
    Send-E2eEvidence -ExitCode $exit -Mode "device" -FailureDir $evidence
    exit $exit
}
if ($gateFailure) {
    Send-E2eEvidence -ExitCode 1 -Mode "device"
    # **最後に出す**（導入先フィードバック §28: 途中の注意行は pytest の warnings に埋もれる）
    Write-Host "[$projectName] $gateFailure"
    exit 1
}
Send-E2eEvidence -ExitCode $exit -Mode "device"
Write-Host "[$projectName] E2E テスト成功。"



