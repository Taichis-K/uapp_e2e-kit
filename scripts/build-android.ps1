# 指定サンプルプロジェクトの Android APK をビルドする。
# プロジェクト固有設定は <Project>\e2e-config.json、マシン固有設定は config\local.json から読む。
# 使い方: .\scripts\build-android.ps1 [-Project unity-nis|unity-ngui-nis|unity-ngui-legacy] [-Release]
#         .\scripts\build-android.ps1 -Project unity-nis -VerifyApkOnly   # 既存 APK の計装登録だけ検査
param(
    [string]$Project = "unity-nis",   # このリポジトリ内のサンプル名（uapp_e2e開発用）
    [string]$ProjectPath,             # 任意の場所のUnityプロジェクト（実プロジェクト導入時はこちら）
    [string]$UnityPath,
    [string]$Output,
    [string]$ExecuteMethod,           # ビルドメソッドの明示指定（自前パイプラインを使う場合）
    [switch]$Release,
    [switch]$VerifyApkOnly,           # ビルドせず、既存 APK のブリッジ登録検査だけ行う
    [switch]$SkipBridgeCheck          # ブリッジ登録検査を外す（データを APK 外へ置く非標準構成向け。
                                      # 外した場合は run-e2e の疎通テストで実接続を確認すること）
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "uapp-platform.ps1")   # OS 差分の吸収（Windows / macOS。mac は暫定・未検証）
$root = (Resolve-Path (Join-UappPath $PSScriptRoot "..")).Path

# 対象プロジェクト解決: -ProjectPath（絶対/相対パス）優先。
# 未指定時: キット親がUnityプロジェクトならそれ（実プロジェクト内 e2e/ 配置）、でなければ $root\$Project（本リポジトリ配置）
$isSample = $false
if ($ProjectPath) {
    $projectPath = (Resolve-Path $ProjectPath).Path
}
elseif ((Test-Path (Join-UappPath $root "..\Assets")) -and (Test-Path (Join-UappPath $root "..\ProjectSettings"))) {
    $projectPath = (Resolve-Path (Join-UappPath $root "..")).Path
}
else {
    $projectPath = Join-UappPath $root $Project
    $isSample = $true
}
if (-not (Test-Path $projectPath)) { throw "プロジェクトがありません: $projectPath" }
# **末尾の `\` を落とす**（run-e2e.ps1 / run-unity-tests.ps1 と同じ正規化）。
# タブ補完は `unity-nis\` の形を作り、`Resolve-Path` はそれを保つ。付いたまま引用すると
# 閉じ引用符が `\"` と解釈され、**後続の引数までパスに飲み込まれる**
# （`-executeMethod` 以降が Unity に届かず、原因の分かりにくいビルド失敗になる）。
# **ドライブ直下（`C:\`）だけは落とせない** — `C:` はドライブ相対を指す別物になるため。
# この 1 ケースは引用側（Format-CliArg）で吸収するので、パスの引用は必ずそこを通すこと
$projectPath = Get-UappNormalizedDir $projectPath
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

function Assert-BridgeRegisteredInApk {
    <#
      .SYNOPSIS
      計装入り APK の起動時メソッド登録簿（RuntimeInitializeOnLoads.json）に
      E2EBridge の自動起動（BridgeBootstrap.Init）が載っていることを検査する。

      .NOTES
      **「ビルド成功」だけでは計装が動くことを保証できない**。コンパイルエラーで失敗した
      ビルドの後に Library のビルドキャッシュが汚れていると、E2EBridge.Runtime.dll 自体は
      APK に入るのに登録簿から Init だけが漏れ、**アプリは正常描画・ブリッジだけ無言で不在**
      という偽の緑になる（テストは全件「接続できません」まで進まないと気づけない）。
      検知したら明示エラーで止め、復旧手順（ビルドキャッシュ削除）を案内する。

      **登録簿が見つからないときも fail-open にしない**。Split Application Binary でも
      先頭シーンぶんのプレイヤーデータ（assets/bin/Data/）は APK 側に残る仕様なので、
      データ群ごと無いのは破損の典型で、正当な分割構成の証拠にはならない。
      データを APK の外へ置く非標準構成を意図して使っている場合だけ、
      呼び出し側が -SkipBridgeCheck で明示的に検査を外す。
    #>
    param([Parameter(Mandatory)][string]$ApkPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ApkPath)
    try {
        # AAB は base/ 配下に入るため両方を見る（zip 内の区切りは常に `/`）
        $entry = $null
        $dataPrefix = $null
        foreach ($prefix in @("assets/bin/Data/", "base/assets/bin/Data/")) {
            if (@($zip.Entries | Where-Object { $_.FullName.StartsWith($prefix) }).Count -gt 0) {
                $dataPrefix = $prefix
                $entry = $zip.GetEntry($prefix + "RuntimeInitializeOnLoads.json")
                break
            }
        }
        if (-not $dataPrefix) {
            # Split Application Binary でも先頭シーンのデータは APK に残るため、全欠落は破損
            throw ("プレイヤーデータ（assets/bin/Data/）が $ApkPath 内に見つかりません。`n" +
                   "  Split Application Binary でも先頭シーンぶんのデータは APK 側に残るため、" +
                   "全欠落はビルド生成物の破損が典型です。`n" +
                   "  データを APK の外へ置く非標準構成を意図している場合のみ -SkipBridgeCheck で検査を外し、" +
                   "run-e2e の疎通テストで実接続を確認してください")
        }
        if (-not $entry) {
            # データはこの APK にあるのに登録簿だけ無い — 正常なビルドでは起きない
            throw ("APK にプレイヤーデータ（$dataPrefix）はあるのに RuntimeInitializeOnLoads.json が" +
                   "ありません: $ApkPath`n  ビルド生成物が壊れています。ビルドキャッシュを削除して再ビルドしてください")
        }
        $reader = New-Object System.IO.StreamReader($entry.Open())
        try { $json = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        # **アセンブリと名前空間まで照合する**。導入先プロジェクトに同名の BridgeBootstrap.Init が
        # あると、E2EBridge の登録が欠けていても素通りしてしまう（この検査の目的が消える）
        $hit = @($json.root | Where-Object {
            $_.assemblyName -eq "E2EBridge.Runtime" -and $_.nameSpace -eq "E2EBridge" -and
            $_.className -eq "BridgeBootstrap" -and $_.methodName -eq "Init"
        })
        if ($hit.Count -eq 0) {
            throw ("計装入りビルドなのに、起動時メソッド登録簿に E2EBridge.Runtime の BridgeBootstrap.Init がありません: $ApkPath`n" +
                   "  このままでは E2EBridge が起動せず、テストは全件接続エラーになります。`n" +
                   "  原因は「計装アセンブリがコンパイル対象から外れたまま player が作られた」こと。既知の経路は 2 つ:`n" +
                   "   (1) エディタのアクティブターゲットが Android でないまま起動した" +
                   "（`UAPP_E2E_BRIDGE` は Android 限定 define のため）。このスクリプトは `-buildTarget Android` を" +
                   "渡して防いでいるので、自前パイプライン（-ExecuteMethod）を使う場合は同じ引数を渡すこと。`n" +
                   "   (2) 直前に失敗したビルドの Library キャッシュ汚染。以下を削除して再ビルドしてください:`n" +
                   "    <プロジェクト>/Library/Bee, ScriptAssemblies, BuildPlayerData, PlayerDataCache と <プロジェクト>/Temp")
        }
        Write-Host "[$projectName] 計装の起動登録を確認（E2EBridge.Runtime / BridgeBootstrap.Init）"
    }
    finally {
        $zip.Dispose()
    }
}

# Unity バージョンは ProjectVersion.txt（Unity自身が維持する正）から読む
$versionFile = Join-UappPath $projectPath "ProjectSettings\ProjectVersion.txt"
if (-not (Test-Path $versionFile)) { throw "ProjectVersion.txt がありません: $versionFile" }
$versionRaw = Get-Content $versionFile -Raw
if ($versionRaw -notmatch "m_EditorVersion:\s*(\S+)") { throw "ProjectVersion.txt からバージョンを読めません: $versionFile" }
$unityVersion = $Matches[1]

# エディタ解決: local.json の editorOverrides → editorRoots から unityVersion を探索
# （-VerifyApkOnly は既存 APK の検査だけなので Unity 本体を要求しない）
if (-not $UnityPath -and -not $VerifyApkOnly) {
    $localConfigPath = Join-UappPath $root "config\local.json"
    $local = if (Test-Path $localConfigPath) { Get-Content $localConfigPath -Raw | ConvertFrom-Json } else { $null }

    if ($local -and $local.editorOverrides.$Project) {
        $UnityPath = $local.editorOverrides.$Project
    }
    else {
        # エディタ実体の並び（Windows は <root>\<版>\Editor\Unity.exe、
        # mac は <root>/<版>/Unity.app/Contents/MacOS/Unity）は uapp-platform.ps1 が吸収する
        $editorRoots = if ($local -and $local.editorRoots) { $local.editorRoots } else { Get-UappDefaultEditorRoots }
        $UnityPath = Resolve-UappEditor -Version $unityVersion -Roots $editorRoots
    }
    if (-not $UnityPath) {
        throw "Unity $unityVersion が見つかりません（config\local.json の editorRoots/editorOverrides を確認）"
    }
}
if (-not $VerifyApkOnly -and -not (Test-Path $UnityPath)) { throw "Unity が見つかりません: $UnityPath" }

$buildsDir = Join-UappPath $root "Builds"
if (-not $Output) { $Output = Join-UappPath $buildsDir "$projectName.apk" }
$logFile = Join-UappPath $buildsDir "build-$projectName.log"
New-Item -ItemType Directory -Force $buildsDir | Out-Null

if ($VerifyApkOnly) {
    if ($Release) { throw "-Release は計装なしビルドのため -VerifyApkOnly の対象外です" }
    if ($SkipBridgeCheck) { throw "-VerifyApkOnly と -SkipBridgeCheck は同時に指定できません（検査だけを頼んで検査を外す矛盾）" }
    if (-not (Test-Path -LiteralPath $Output -PathType Leaf)) { throw "検査対象の APK がありません: $Output" }
    $verifyStarted = Get-Date
    $verifyFailure = $null
    try { Assert-BridgeRegisteredInApk -ApkPath $Output }
    catch { $verifyFailure = $_ }
    # 検査だけの実行もダッシュボードへ記録する（verifyOnly=true で本走のビルドと区別）。
    # **verify-all のハング回収はこの経路の成功で BUILD_OK へ復帰する**ため、ここで記録しないと
    # 「回収時に killed された本走の失敗だけが evidence.build に残り、検査で成功へ戻った事実が
    # 残らない」食い違いになる
    $emitHelper = Join-UappPath $PSScriptRoot "emit-status.ps1"
    if (Test-Path -LiteralPath $emitHelper -PathType Leaf) {
        . $emitHelper
        Send-DashEvent -Kind "evidence.build" -StartPath $root -Data @{
            target       = "Android"
            project      = $projectName
            exitCode     = $(if ($verifyFailure) { 1 } else { 0 })
            durationSec  = [math]::Round(((Get-Date) - $verifyStarted).TotalSeconds, 1)
            artifactPath = $Output
            sizeBytes    = (Get-Item -LiteralPath $Output).Length
            verifyOnly   = $true
        }
    }
    if ($verifyFailure) { throw $verifyFailure }
    return
}

# ビルドメソッド: サンプル（本リポジトリ配置）は Sample.Editor、
# 実プロジェクトはキット同梱の汎用エントリ（E2EBridge/Editor/BuildEntry.cs）
if (-not $ExecuteMethod) {
    $ExecuteMethod = if ($isSample) { "Sample.Editor.BuildScript.BuildAndroid" }
                     else { "E2EBridge.Editor.BuildEntry.BuildAndroid" }
}

# **`-buildTarget Android` を必ず渡す**。これが無いと Unity は「最後に使った構成」で起動し、
# **プラットフォーム固有の条件付きコンパイルとロードされるアセンブリがその構成に従う**（Unity 公式マニュアル）。
# `UAPP_E2E_BRIDGE` は Android 限定の define なので、アクティブターゲットが Android でないまま
# 起動すると計装アセンブリがコンパイル対象から外れ、**ビルドは成功するのに APK の
# `RuntimeInitializeOnLoads.json` から `BridgeBootstrap.Init` だけが落ちる**（＝実行するまで
# 気づけない「偽の緑」。下の登録簿検査が捕まえる側の原因そのもの）。
# 2026-08-03 に A/B 実測: アクティブターゲット StandaloneOSX ＋ キャッシュ削除で再現し、
# この引数を足すと同条件で解消した。
$unityArgs = @(
    "-batchmode", "-quit",
    "-buildTarget", "Android",
    "-projectPath", (Format-CliArg $projectPath),
    "-executeMethod", $ExecuteMethod,
    "-buildOutput", (Format-CliArg $Output),
    "-logFile", (Format-CliArg $logFile)
)
if ($Release) { $unityArgs += "-release" }

Write-Host "[$projectName] Unity $unityVersion でビルド開始（初回は IL2CPP のため 10 分以上かかることがあります）..."
$buildStarted = Get-Date
$process = Start-Process -FilePath $UnityPath -ArgumentList $unityArgs -Wait -PassThru -NoNewWindow

# 計装入りビルドは、ブリッジの自動起動が登録簿に載ったことまで確認して初めて成功
#（-Release は計装なしなので対象外）。**ダッシュボードへの記録より先に検査する** —
# 後に回すと、検査で止めたのにダッシュボードには「成功」が残り、
# この検査が排除したい偽の緑を別経路で再生成してしまう
$bridgeCheckFailure = $null
if ($process.ExitCode -eq 0 -and -not $Release -and -not $SkipBridgeCheck) {
    try { Assert-BridgeRegisteredInApk -ApkPath $Output }
    catch { $bridgeCheckFailure = $_ }
}
elseif ($SkipBridgeCheck -and -not $Release) {
    Write-Host "[$projectName] ブリッジ登録検査をスキップ（-SkipBridgeCheck 指定。run-e2e の疎通テストで実接続を確認すること）"
}

# エージェント開発ダッシュボードが導入されていればビルド結果を1行記録する（無ければ何もしない）
$emitHelper = Join-UappPath $PSScriptRoot "emit-status.ps1"
if (Test-Path -LiteralPath $emitHelper -PathType Leaf) {
    . $emitHelper
    $apkSize = if (Test-Path -LiteralPath $Output -PathType Leaf) { (Get-Item $Output).Length } else { $null }
    # exitCode には登録簿検査の結果まで反映する（Unity が 0 でも検査で落ちれば失敗として記録）
    $reportedExit = if ($process.ExitCode -ne 0) { $process.ExitCode }
                    elseif ($bridgeCheckFailure) { 1 }
                    else { 0 }
    Send-DashEvent -Kind "evidence.build" -StartPath $root -Data @{
        target       = "Android"
        project      = $projectName
        exitCode     = $reportedExit
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
if ($bridgeCheckFailure) { throw $bridgeCheckFailure }
Write-Host "[$projectName] ビルド成功: $Output"
