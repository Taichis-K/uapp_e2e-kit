# 指定サンプルプロジェクトの APK インストール〜アプリ起動〜pytest 実行を一括で行う。
# プロジェクト固有設定（package/activity/tests/deviceRotation）は <Project>\e2e-config.json から読む。
# 使い方: .\scripts\run-e2e.ps1 [-Project unity-nis|unity-ngui-nis|unity-ngui-legacy] [-SkipInstall] [-PytestArgs "-k xxx"]
param(
    [string]$Project = "unity-nis",   # このリポジトリ内のサンプル名（uapp_e2e開発用）
    [string]$ProjectPath,             # 任意の場所のUnityプロジェクト（実プロジェクト導入時はこちら）
    [string]$Apk,
    [string]$DeviceSerial,   # 複数デバイス同時運用時に対象を指定（例: emulator-5554）
    [int]$HostPort = 0,      # adb forward のホスト側ポート（未指定: local.json の bridgePort → 13333）
    [switch]$SkipInstall,
    [string]$JourneyDir,     # ジャーニー記録の出力先（未指定: Builds\journey。docs/07-viewer.md）
    [switch]$NoJourney,      # ジャーニー記録を無効化する
    [string]$PytestArgs = ""
)

$ErrorActionPreference = "Stop"
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
    $isRepoSample = $true   # 開発リポジトリのサンプル（Builds を3プロジェクトで共有する）
}
$projectName = Split-Path $projectDir -Leaf

# ジャーニー記録（docs/07-viewer.md）の出力先を固定する:
#   導入先（キット配置）= <uapp_e2e>\Builds\journey ／ 開発リポジトリ = Builds\journey\<サンプル名>
# 記録は追記マージなので毎回同じ場所に蓄積され、viewer/report の場所が常にここに確定する。
# PytestArgs で --journey を明示した場合はそちらが優先される（pytest オプション > 環境変数）
if (-not $NoJourney) {
    if (-not $JourneyDir) {
        $JourneyDir = if ($isRepoSample) { Join-Path $root "Builds\journey\$Project" }
                      else { Join-Path $root "Builds\journey" }
    }
    # pytest は driver\ から実行するため、相対指定でも壊れないよう絶対パス化しておく
    if (-not [System.IO.Path]::IsPathRooted($JourneyDir)) {
        $JourneyDir = Join-Path (Get-Location).Path $JourneyDir
    }
    $JourneyDir = [System.IO.Path]::GetFullPath($JourneyDir)
} else {
    $JourneyDir = $null
}

# 設定解決: キット内（導入配置: <project>\uapp_e2e\e2e-config.json）→ プロジェクト直下（本リポジトリのサンプル配置）
$configPath = Join-Path $root "e2e-config.json"
if (-not (Test-Path $configPath)) {
    $configPath = Join-Path $projectDir "e2e-config.json"
}
if (-not (Test-Path $configPath)) { throw "e2e-config.json がありません（$root または $projectDir 直下）" }
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$package = $config.package
$activity = $config.activity
# デバイス内で待ち受けるポート（e2e-config.json の devicePort、未指定は 13333）。
# 同一デバイスに計装アプリが複数ある場合はアプリごとに別ポートを割り当てる
$devicePort = if ($config.devicePort) { [int]$config.devicePort } else { 13333 }

if (-not $Apk) { $Apk = Join-Path $root "Builds\$projectName.apk" }

# 対象デバイス指定（複数AVD同時運用対応）。未指定なら adb 既定（1台接続時のみ有効）
$adbTarget = @()
if ($DeviceSerial) { $adbTarget = @("-s", $DeviceSerial) }

# adbデーモン再起動直後は device offline で各コマンドが黙って失敗するため、
# 接続を待った上で全stepのexit codeを検証する
adb @adbTarget wait-for-device
if ($LASTEXITCODE -ne 0) { throw "デバイスが接続されていません (adb devices で確認)" }

if (-not $SkipInstall) {
    if (-not (Test-Path $Apk)) { throw "APK がありません: $Apk （先に build-android.ps1 -Project $projectName を実行）" }
    Write-Host "[$projectName] インストール中: $Apk"
    adb @adbTarget install -r -g $Apk | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "adb install 失敗 (exit=$LASTEXITCODE)" }
}

# 縦横両対応アプリの初期向き指定（e2e-config.json の deviceRotation: 0=縦 1=横(左) 2=逆縦 3=横(右)）
if ($null -ne $config.deviceRotation) {
    adb @adbTarget shell settings put system accelerometer_rotation 0
    adb @adbTarget shell settings put system user_rotation $config.deviceRotation
    Write-Host "[$projectName] デバイス回転を固定: $($config.deviceRotation)"
}

# ホスト側ポート解決: -HostPort 引数 → config\local.json の bridgePort → 13333
# 複数ターゲット同時運用時はターゲットごとに別ポートを指定すること
if ($HostPort -eq 0) {
    $HostPort = 13333
    $localConfigPath = Join-Path $root "config\local.json"
    if (Test-Path $localConfigPath) {
        $local = Get-Content $localConfigPath -Raw | ConvertFrom-Json
        if ($local.bridgePort) { $HostPort = $local.bridgePort }
    }
}
adb @adbTarget forward "tcp:$HostPort" "tcp:$devicePort" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "adb forward 失敗 (exit=$LASTEXITCODE)。ポート $HostPort が他ターゲットと重複していないか確認" }
$env:UAPP_E2E_BRIDGE_PORT = $HostPort
adb @adbTarget logcat -c
# -S: 起動前に対象プロセスを確実にkill（前回実行の状態残留を防ぐ） / -W: 起動完了まで待つ
# -a MAIN -c LAUNCHER: ランチャー起動と同じ Intent にする（action 無しだと起動直後に
#   自ら閉じるカスタムActivityがある。実プロジェクト導入試験で実証）
# --ei uapp_e2e_port: ブリッジの待ち受けポートをアプリに伝える（BridgeHost が Intent extra から読む）
adb @adbTarget shell am start -S -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER --ei uapp_e2e_port $devicePort -n "$package/$activity" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "アプリ起動失敗 (exit=$LASTEXITCODE)" }
Write-Host "[$projectName] アプリ起動（$(if ($DeviceSerial) { $DeviceSerial } else { '既定デバイス' }) / port $HostPort）。テストを実行します..."
if ($JourneyDir) { Write-Host "[$projectName] ジャーニー記録: $JourneyDir" }

$env:UAPP_E2E_PACKAGE = $package
$env:UAPP_E2E_DEVICE_PORT = $devicePort
if ($DeviceSerial) { $env:UAPP_E2E_DEVICE_SERIAL = $DeviceSerial }
if ($JourneyDir) { $env:UAPP_E2E_JOURNEY_DIR = $JourneyDir }
Push-Location (Join-Path $root "driver")
try {
    if ($PytestArgs) {
        python -m pytest $config.tests @($PytestArgs -split " ") -v
    } else {
        python -m pytest $config.tests -v
    }
    $exit = $LASTEXITCODE
    # ジャーニーが記録されていれば自己完結レポートを更新する（失敗時も解析に使うため生成する）。
    # journey フィクスチャを使うテストが無かった実行では journey.json が無いのでスキップ
    if ($JourneyDir -and (Test-Path (Join-Path $JourneyDir "journey.json"))) {
        python -m e2e_driver.journey $JourneyDir
        if ($LASTEXITCODE -eq 0) {
            Write-Host "ジャーニーレポート: $(Join-Path $JourneyDir 'report.html')"
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

if ($exit -ne 0) {
    # 失敗時はAIが読める証跡を残す
    $evidence = Join-Path $root "Builds\failure"
    New-Item -ItemType Directory -Force $evidence | Out-Null
    adb @adbTarget exec-out screencap -p > (Join-Path $evidence "screen.png")
    adb @adbTarget logcat -d -s "Unity:*" > (Join-Path $evidence "unity-logcat.txt")
    adb @adbTarget logcat -d -b crash > (Join-Path $evidence "crash.txt")
    Write-Host "失敗時の証跡を保存: $evidence （screen.png / unity-logcat.txt / crash.txt）"
    exit $exit
}
Write-Host "[$projectName] E2E テスト成功。"



