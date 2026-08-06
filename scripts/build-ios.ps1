# iOS 向けビルド一括（Unity → Xcode プロジェクト → xcodebuild → .app）＋計装登録の検査。
# 使い方: ./scripts/build-ios.ps1 [-Project unity-nis] [-Arch arm64|x86_64] [-Release]
#         ./scripts/build-ios.ps1 -Project unity-nis -Target device -Team <チームID> -AppId <bundle id>
#         ./scripts/build-ios.ps1 -Project unity-nis -VerifyAppOnly   # 既存 .app の登録簿検査だけ
# **macOS 専用**（xcodebuild が必要。Windows で実行すると xcodebuild 未検出の明示エラーで止まる）。
#
# -Target device（実機）で増える前提: 署名（Apple Development 証明書）と、チーム配下で登録できる
# bundle id。**bundle id は Unity 側（-appId）で設定する** — xcodebuild へ
# PRODUCT_BUNDLE_IDENTIFIER を渡すと**全ターゲットに適用されて** UnityFramework まで同じ id になり、
# DuplicateIdentifier で install が拒否される（2026-08-05 に実測）。
param(
    [string]$Project = "unity-nis",   # このリポジトリ内のサンプル名
    [string]$ProjectPath,             # 任意の場所の Unity プロジェクト（実プロジェクト導入時）
    [string]$UnityPath,
    [string]$Output,                  # Xcode プロジェクトの出力先（既定 Builds/ios-<target>/<プロジェクト名>）
    [string]$ExecuteMethod,           # ビルドメソッドの明示指定（サンプル以外は必須）
    # ビルド対象。simulator=シミュレータ（署名不要）/ device=実機（署名必須）
    [ValidateSet("simulator", "device")][string]$Target = "simulator",
    # 実行アーキテクチャ（simulator のみ）。既定はこの Mac のネイティブ。
    # Unity の書き出しは Universal なので、どちらを選んでも再エクスポートは不要
    [ValidateSet("arm64", "x86_64")][string]$Arch,
    [string]$Team,                    # device: 署名チーム ID（未指定なら config/local.json の iosTeamId）
    [string]$AppId,                   # device: bundle id（未指定なら config/local.json の iosDeviceAppId → e2e-config の package）
    [switch]$Release,
    [switch]$VerifyAppOnly,
    [switch]$SkipBridgeCheck
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "uapp-platform.ps1")   # OS 差分の吸収

$root = (Resolve-Path (Join-UappPath $PSScriptRoot "..")).Path

# xcodebuild の解決が macOS 専用ガードを兼ねる（Windows には存在しないので、ここで明示的に止まる）
$xcodebuild = Get-UappCommandPath "xcodebuild"
if (-not $xcodebuild) {
    throw ("xcodebuild が見つかりません。このスクリプトは macOS 専用です" +
           "（macOS の場合は Xcode を導入し、xcode-select --install を実行してください）")
}

$isDevice = ($Target -eq "device")
if (-not $Arch) {
    # .NET の OSArchitecture は OS 分岐なしでホストのネイティブを返す
    $Arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq
                [System.Runtime.InteropServices.Architecture]::Arm64) { "arm64" } else { "x86_64" }
}
if ($isDevice) { $Arch = "arm64" }   # 実機は arm64 のみ（DerivedData の分離キーとしても使う）

# --------------------------------------------------------------- プロジェクト解決
$isSample = $false
if ($ProjectPath) {
    $projectPath = (Resolve-Path $ProjectPath).Path
}
elseif ((Test-Path (Join-UappPath $root "..\Assets")) -and (Test-Path (Join-UappPath $root "..\ProjectSettings"))) {
    # 導入先レイアウト: uapp_e2e\ の親が Unity プロジェクト（run-e2e.ps1 と同じ規則）。
    # これが無いと、導入先で -ProjectPath を省いた実行が $root\unity-nis（存在しない）を探して必ず落ちる
    $projectPath = (Resolve-Path (Join-UappPath $root "..")).Path
}
else {
    $projectPath = Join-UappPath $root $Project
    $isSample = $true
}
if (-not (Test-Path $projectPath)) { throw "プロジェクトがありません: $projectPath" }
$projectPath = Get-UappNormalizedDir $projectPath
$projectName = Split-Path $projectPath -Leaf

$buildsDir = Join-UappPath $root "Builds"
New-Item -ItemType Directory -Force $buildsDir | Out-Null
# プロジェクトごとに分ける（共有すると別プロジェクトの Xcode プロジェクトを上書きし合う）
if (-not $Output) { $Output = Join-UappPath $buildsDir $(if ($isDevice) { "ios-device" } else { "ios-sim" }) $projectName }
$configName = if ($Release) { "Release" } else { "Debug" }
$sdkSuffix = if ($isDevice) { "iphoneos" } else { "iphonesimulator" }
$derivedData = Join-UappPath $Output "DerivedData-$Arch"
$appDir = Join-UappPath $derivedData "Build/Products/$configName-$sdkSuffix"

function Get-BuiltAppPath {
    $apps = @(Get-ChildItem -LiteralPath $appDir -Filter "*.app" -Directory -ErrorAction SilentlyContinue)
    if ($apps.Count -eq 1) { return $apps[0].FullName }
    if ($apps.Count -eq 0) { return $null }
    throw ".app が複数あります（$appDir）。DerivedData を消して作り直してください"
}

function Assert-BridgeRegisteredInApp([string]$AppPath) {
    <#
      .SYNOPSIS
      .app の登録簿（Data/RuntimeInitializeOnLoads.json）で計装の起動登録を検査する。

      .NOTES
      Android の「ビルド成功なのに計装だけ落ちて全件接続エラー」（build-android.ps1 の
      Assert-BridgeRegisteredInApk）と同型の網。iOS は APK と違い .app が素のディレクトリなので
      unzip は不要。**-Release は逆向きに検査する**（計装が入っていたら本番分離違反として停止。
      レビュー指摘による負の検査）。
    #>
    $registry = Join-UappPath $AppPath "Data/RuntimeInitializeOnLoads.json"
    if (-not (Test-Path -LiteralPath $registry)) {
        throw ("登録簿がありません: $registry`n" +
               ".app が壊れているか、データを別配置にする非標準構成です（後者は -SkipBridgeCheck を明示）")
    }
    $entries = (Get-Content -LiteralPath $registry -Raw | ConvertFrom-Json).root
    $hit = @($entries | Where-Object {
        $_.assemblyName -eq "E2EBridge.Runtime" -and $_.className -eq "BridgeBootstrap" -and $_.methodName -eq "Init"
    })
    if ($Release) {
        if ($hit.Count -gt 0) {
            throw ("-Release なのに計装（BridgeBootstrap.Init）が .app に登録されています。" +
                   "本番分離違反です。UAPP_E2E_BRIDGE define が iOS ターゲットに残っていないか確認してください")
        }
        Write-Host "[$projectName] 負の検査 OK: Release に計装は入っていない"
        return
    }
    if ($hit.Count -eq 0) {
        throw ("計装の起動登録（E2EBridge.Runtime / BridgeBootstrap.Init）が .app の登録簿にありません。" +
               "ビルドは成功していても全テストが接続エラーになります。`n" +
               "  確認: ①Unity ビルドを -buildTarget iOS で起動したか" +
               " ②UAPP_E2E_BRIDGE define が iOS ターゲットに付いたか（BuildScript 経由なら自動）`n" +
               "  復旧: unity-nis/Library の Bee, ScriptAssemblies, BuildPlayerData, PlayerDataCache と Temp を消して再ビルド")
    }
    Write-Host "[$projectName] 計装の起動登録を確認（E2EBridge.Runtime / BridgeBootstrap.Init）"
}

if ($VerifyAppOnly) {
    if ($SkipBridgeCheck) { throw "-VerifyAppOnly と -SkipBridgeCheck は同時に指定できません" }
    $app = Get-BuiltAppPath
    if (-not $app) { throw "検査対象の .app がありません: $appDir（先に本走でビルドしてください）" }
    Assert-BridgeRegisteredInApp $app
    Write-Host "APP_PATH=$app"
    exit 0
}

# --------------------------------------------------------------- Unity 書き出し
if (-not $ExecuteMethod) {
    if ($isSample) {
        $ExecuteMethod = if ($isDevice) { "Sample.Editor.BuildScript.BuildIosDevice" }
                         else { "Sample.Editor.BuildScript.BuildIosSimulator" }
    }
    else {
        # 導入先向けの汎用エントリ（E2EBridge に同梱。kit 0.1.9 で追加）。
        # 自前のビルドパイプラインを使う場合は -ExecuteMethod で明示する
        $ExecuteMethod = if ($isDevice) { "E2EBridge.Editor.BuildEntry.BuildIosDevice" }
                         else { "E2EBridge.Editor.BuildEntry.BuildIosSimulator" }
    }
}

# Unity バージョンは ProjectVersion.txt（Unity 自身が維持する正）から読む
$versionFile = Join-UappPath $projectPath "ProjectSettings\ProjectVersion.txt"
if (-not (Test-Path $versionFile)) { throw "ProjectVersion.txt がありません: $versionFile" }
$versionRaw = Get-Content $versionFile -Raw
if ($versionRaw -notmatch "m_EditorVersion:\s*(\S+)") { throw "ProjectVersion.txt からバージョンを読めません: $versionFile" }
$unityVersion = $Matches[1]

$localConfigPath = Join-UappPath $root "config\local.json"
$local = if (Test-Path $localConfigPath) { Get-Content $localConfigPath -Raw | ConvertFrom-Json } else { $null }

# 実機は署名が要る。チームと bundle id は「引数 > config/local.json > e2e-config.json の package」
# （**チーム ID は環境ごとの固有情報**なので追跡ファイルへ書かない＝local.json 側で持つ）
if ($isDevice) {
    if (-not $Team -and $local -and $local.iosTeamId) { $Team = $local.iosTeamId }
    if (-not $Team) {
        throw ("実機ビルドには署名チーム ID が要ります。-Team <ID> を渡すか、" +
               "config\local.json に iosTeamId を設定してください" +
               "（security find-identity -v -p codesigning の OU= がチーム ID）")
    }
    if (-not $AppId -and $local -and $local.iosDeviceAppId) { $AppId = $local.iosDeviceAppId }
    if (-not $AppId) {
        # 設定解決はキット内 → プロジェクト直下の順（run-e2e.ps1 と同じ規則。導入配置では
        # e2e-config.json はプロジェクト直下ではなく uapp_e2e\ 直下にある）
        $cfgPath = Join-UappPath $root "e2e-config.json"
        if (-not (Test-Path $cfgPath)) { $cfgPath = Join-UappPath $projectPath "e2e-config.json" }
        if (Test-Path $cfgPath) { $AppId = (Get-Content $cfgPath -Raw | ConvertFrom-Json).package }
    }
    if (-not $AppId) { throw "実機ビルドの bundle id を決められません（-AppId か e2e-config.json の package）" }
}

# エディタ解決: local.json の editorOverrides → editorRoots から探索（build-android.ps1 と同型）
if (-not $UnityPath) {
    if ($local -and $local.editorOverrides.$Project) {
        $UnityPath = $local.editorOverrides.$Project
    }
    else {
        $editorRoots = if ($local -and $local.editorRoots) { $local.editorRoots } else { Get-UappDefaultEditorRoots }
        $UnityPath = Resolve-UappEditor -Version $unityVersion -Roots $editorRoots
    }
    if (-not $UnityPath) {
        throw "Unity $unityVersion が見つかりません（config\local.json の editorRoots/editorOverrides を確認）"
    }
}
if (-not (Test-Path $UnityPath)) { throw "Unity が見つかりません: $UnityPath" }

$logFile = Join-UappPath $buildsDir "build-ios-$projectName.log"
function Format-CliArg {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $escaped = [regex]::Replace($Value, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
    $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
    return '"' + $escaped + '"'
}

# **`-buildTarget iOS` を必ず渡す**（Android で実測した「アクティブターゲット依存で計装が
# コンパイル対象から外れ、ビルド成功なのに登録簿から落ちる」偽の緑と同型の予防）
$unityArgs = @(
    "-batchmode", "-quit",
    "-buildTarget", "iOS",
    "-projectPath", (Format-CliArg $projectPath),
    "-executeMethod", $ExecuteMethod,
    "-buildOutput", (Format-CliArg $Output),
    "-logFile", (Format-CliArg $logFile)
)
if ($Release) { $unityArgs += "-release" }
# **bundle id は Unity 側で設定する**（xcodebuild へ渡すと UnityFramework まで同じ id になり
# DuplicateIdentifier で install が拒否される。2026-08-05 に実測）
if ($isDevice) { $unityArgs += @("-appId", (Format-CliArg $AppId)) }

# **実機用の bundle id が追跡ファイルへ焼き付くのを防ぐ**（サンプルのみ）。
# BuildScript は finally で appId を復元するが、復元先は「ビルド開始時の値」なので、
# **一度混入すると以後それが正常値として保存され続ける**（2026-08-05 に実際に混入し、
# チーム都合の接頭辞が付いた bundle id が ProjectSettings.asset へ残った）。
# ここでビルド前後を比較し、変わっていたら元へ戻す
$settingsAsset = $null
$settingsBefore = $null
if ($isSample -and $isDevice) {
    $settingsAsset = Join-UappPath $projectPath "ProjectSettings\ProjectSettings.asset"
    if (Test-Path $settingsAsset) { $settingsBefore = Get-Content $settingsAsset -Raw }
}

Write-Host "[$projectName] Unity $unityVersion で iOS $Target 向け書き出しを開始..."
$buildStarted = Get-Date
$process = Start-Process -FilePath $UnityPath -ArgumentList $unityArgs -Wait -PassThru -NoNewWindow
if ($process.ExitCode -ne 0) {
    Write-Host "--- $logFile 末尾 ---"
    Get-Content $logFile -Tail 60
    throw "Unity の書き出しに失敗 (exit=$($process.ExitCode))。ログ全体: $logFile"
}

# 実機用 bundle id の焼き付きを戻す（上の説明を参照）。**行単位で厳密に比べる** —
# ビルドで正当に変わる項目（既定値の明示化等）まで巻き戻さないため、
# applicationIdentifier の iPhone 行だけを対象にする
if ($settingsBefore -and (Test-Path $settingsAsset)) {
    $after = Get-Content $settingsAsset -Raw
    $rx = '(?m)^(\s*applicationIdentifier:\s*\r?\n(?:\s+\w+:.*\r?\n)*?\s*iPhone:\s*)(.*)$'
    $mBefore = [regex]::Match($settingsBefore, $rx)
    $mAfter = [regex]::Match($after, $rx)
    if ($mBefore.Success -and $mAfter.Success -and
        $mBefore.Groups[2].Value.Trim() -ne $mAfter.Groups[2].Value.Trim()) {
        $restored = $after.Remove($mAfter.Groups[2].Index, $mAfter.Groups[2].Length).
                           Insert($mAfter.Groups[2].Index, $mBefore.Groups[2].Value)
        Set-Content -LiteralPath $settingsAsset -Value $restored -NoNewline
        Write-Warning ("実機用の bundle id が ProjectSettings.asset へ書き込まれたため元へ戻しました " +
                       "（'$($mAfter.Groups[2].Value.Trim())' → '$($mBefore.Groups[2].Value.Trim())'）。" +
                       "**署名チーム都合の bundle id を追跡ファイルへ残さない**ための処理です")
    }
}

# --------------------------------------------------------------- xcodebuild
$xcodeproj = Join-UappPath $Output "Unity-iPhone.xcodeproj"
if (-not (Test-Path $xcodeproj)) { throw "Xcode プロジェクトがありません: $xcodeproj" }

Write-Host "[$projectName] xcodebuild ($configName / $Arch / $sdkSuffix)..."
$xcodeLog = Join-UappPath $buildsDir "xcodebuild-ios-$projectName.log"
# Unity 側の Development/Release と xcodebuild の configuration を必ず揃える
# （Unity だけ -release にしても xcodebuild が Debug では IL2CPP が Debug のまま＝レビュー指摘）
# 実機は署名が要る（automatic signing にチームを渡し、プロビジョニングは自動生成させる）。
# **PRODUCT_BUNDLE_IDENTIFIER は渡さない** — 全ターゲットに適用されて UnityFramework と
# 衝突する（DuplicateIdentifier）。bundle id は Unity 側（-appId）で設定済み
$xcodeArgs = if ($isDevice) {
    @("-destination", "generic/platform=iOS", "-allowProvisioningUpdates",
      "DEVELOPMENT_TEAM=$Team", "CODE_SIGN_STYLE=Automatic")
} else {
    @("-destination", "generic/platform=iOS Simulator", "ARCHS=$Arch", "CODE_SIGNING_ALLOWED=NO")
}
& $xcodebuild -project $xcodeproj -scheme "Unity-iPhone" -configuration $configName `
    -derivedDataPath $derivedData @xcodeArgs build *> $xcodeLog
if ($LASTEXITCODE -ne 0) {
    Write-Host "--- $xcodeLog 末尾 ---"
    Get-Content $xcodeLog -Tail 40
    throw "xcodebuild に失敗 (exit=$LASTEXITCODE)。ログ全体: $xcodeLog"
}

$app = Get-BuiltAppPath
if (-not $app) { throw ".app が見つかりません: $appDir" }

# --------------------------------------------------------------- 検査 → 記録
$bridgeCheckFailure = $null
if (-not $SkipBridgeCheck) {
    try { Assert-BridgeRegisteredInApp $app }
    catch { $bridgeCheckFailure = $_ }
} else {
    Write-Host "[$projectName] ブリッジ登録検査をスキップ（-SkipBridgeCheck 指定）"
}

# エージェント開発ダッシュボードが導入されていれば記録（無ければ no-op）
$emitHelper = Join-UappPath $PSScriptRoot "emit-status.ps1"
if (Test-Path -LiteralPath $emitHelper -PathType Leaf) {
    . $emitHelper
    Send-DashEvent -Kind "evidence.build" -StartPath $root -Data @{
        target       = $(if ($isDevice) { "iOSDevice" } else { "iOSSimulator" })
        project      = $projectName
        exitCode     = $(if ($bridgeCheckFailure) { 1 } else { 0 })
        durationSec  = [math]::Round(((Get-Date) - $buildStarted).TotalSeconds, 1)
        artifactPath = $app
        arch         = $Arch
        logPath      = $logFile
    }
}

if ($bridgeCheckFailure) { throw $bridgeCheckFailure }
Write-Host "[$projectName] ビルド成功: $app"
Write-Host "APP_PATH=$app"
