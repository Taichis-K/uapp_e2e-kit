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

# --- エディタ直結モード（-Editor。ここで完結して adb フローには進まない） ---
if ($Editor) {
    # Unity CLI の解決: PATH → 既定インストール先。無ければ手動手順を案内して失敗
    $unityCli = (Get-Command unity -ErrorAction SilentlyContinue).Source
    if (-not $unityCli) {
        $candidate = Join-Path $env:LOCALAPPDATA "Unity\bin\unity.exe"
        if (Test-Path $candidate) { $unityCli = $candidate }
    }
    if (-not $unityCli) {
        throw ("-Editor には Unity CLI が必要です（https://docs.unity.com/en-us/unity-cli）。" +
               "CLI を使わない場合の手動手順: エディタで対象シーンを開いて Play →" +
               " `$env:UAPP_E2E_EDITOR='1' で pytest を実行")
    }

    # com.unity.pipeline は Unity 6 以降のみ
    $projVer = (Get-Content (Join-Path $projectDir "ProjectSettings\ProjectVersion.txt") -TotalCount 1) -replace "m_EditorVersion:\s*", ""
    if ([int]($projVer -split "\.")[0] -lt 6000) {
        throw ("-Editor は Unity 6 以降のみ対応（com.unity.pipeline の要件。このプロジェクト: $projVer）。" +
               "手動手順: エディタで Play → `$env:UAPP_E2E_EDITOR='1' で pytest")
    }

    function Invoke-UnityCli {
        param([string[]]$CliArgs, [switch]$AllowFail)
        # cmd 系は常に対象プロジェクトへスコープする（複数エディタ起動時に別プロジェクトを操作・停止しない）
        if ($CliArgs[0] -eq "cmd") {
            $CliArgs = @("cmd", "--project-path", $projectDir) + $CliArgs[1..($CliArgs.Count - 1)]
        }
        $raw = & $unityCli @CliArgs --format json --no-banner 2>&1 | Out-String
        $parsed = $null
        try { $parsed = $raw | ConvertFrom-Json } catch {}
        if (-not $AllowFail -and (-not $parsed -or -not $parsed.success)) {
            throw "unity $($CliArgs -join ' ') が失敗: $raw"
        }
        $parsed
    }

    # 同一プロジェクトへの -Editor 同時実行を防ぐプロセス間ロック（TOCTOU対策:
    # 2プロセスが同時に playMode=stopped を見て両方進むと、片方の editor_stop が他方の Play を落とす）
    $mutexName = "uapp_e2e-editor-" + (($projectDir.ToLowerInvariant() -replace "[^a-z0-9]", "-"))
    $editorMutex = New-Object System.Threading.Mutex($false, $mutexName)
    $mutexAcquired = $false
    try { $mutexAcquired = $editorMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $mutexAcquired = $true }
    if (-not $mutexAcquired) {
        throw "このプロジェクトへの -Editor 実行が別プロセスで進行中です。完了を待って再実行"
    }
    try {

    # エディタが Pipeline 接続済みかを確認。未接続なら pipeline install → エディタ起動 → 接続待ち
    $status = Invoke-UnityCli @("status", "--project-path", $projectDir) -AllowFail
    if (-not $status -or -not $status.success -or $status.data.count -lt 1) {
        Write-Host "[$projectName] エディタ未接続。Pipeline パッケージを確認してエディタを起動します..."
        # 注意: 未導入の場合 Packages\manifest.json に com.unity.pipeline が追加される（VCS差分になる）
        $null = Invoke-UnityCli @("pipeline", "install", "--project-path", $projectDir)
        Start-Process -FilePath $unityCli -ArgumentList @("open", $projectDir) | Out-Null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            Start-Sleep -Seconds 5
            $status = Invoke-UnityCli @("status", "--project-path", $projectDir) -AllowFail
            if ($status -and $status.success -and $status.data.count -ge 1 -and
                $status.data.instances[0].state -eq "ready") { break }
            if ($sw.Elapsed.TotalSeconds -gt 600) { throw "エディタの Pipeline 接続待ちがタイムアウト（600秒）。Editor.log を確認" }
        }
        Write-Host "[$projectName] エディタ接続完了（$([int]$sw.Elapsed.TotalSeconds)秒）"
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
    if (-not $Scene) {
        $r = Invoke-UnityCli @("cmd", "eval",
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
    if (-not $EditorResolution) {
        $EditorResolution = if ($config.orientation -eq "landscape") { "2340x1080" } else { "1080x2340" }
    }
    $wh = $EditorResolution -split "x"
    # C#文字列リテラルの二重引用符はコマンドライン経由で壊れやすいため eval_file（一時ファイル）で渡す
    $evalTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("uapp_e2e-eval-" + [System.IO.Path]::GetRandomFileName() + ".cs")
    try {
        [System.IO.File]::WriteAllText($evalTmp,
            "UnityEditor.PlayModeWindow.SetCustomRenderingResolution($($wh[0]), $($wh[1]), `"uapp_e2e E2E`");`nreturn `"ok`";`n")
        $null = Invoke-UnityCli @("cmd", "eval_file", "--file", $evalTmp)
    } finally {
        Remove-Item $evalTmp -ErrorAction SilentlyContinue
    }
    Write-Host "[$projectName] Game view 解像度: $EditorResolution / Play 開始..."

    $null = Invoke-UnityCli @("cmd", "editor_play")
    if ($JourneyDir) { Write-Host "[$projectName] ジャーニー記録: $JourneyDir（エディタ直結はスクリーンショットなし）" }

    $env:UAPP_E2E_EDITOR = "1"
    if ($JourneyDir) { $env:UAPP_E2E_JOURNEY_DIR = $JourneyDir }
    Push-Location (Join-Path $root "driver")
    try {
        if ($PytestArgs) {
            python -m pytest $config.tests @($PytestArgs -split " ") -v
        } else {
            python -m pytest $config.tests -v
        }
        $exit = $LASTEXITCODE
        if ($JourneyDir -and (Test-Path (Join-Path $JourneyDir "journey.json"))) {
            python -m e2e_driver.journey $JourneyDir
            if ($LASTEXITCODE -eq 0) { Write-Host "ジャーニーレポート: $(Join-Path $JourneyDir 'report.html')" }
        }
    } finally {
        Pop-Location
        Remove-Item Env:\UAPP_E2E_EDITOR -ErrorAction SilentlyContinue
        Remove-Item Env:\UAPP_E2E_JOURNEY_DIR -ErrorAction SilentlyContinue
        # Play は必ず終了させる（次のタスクのために排他資源を解放）
        $null = Invoke-UnityCli @("cmd", "editor_stop") -AllowFail
    }

    } finally {
        # 途中の throw でもプロセス間ロックを確実に解放する（Play/シーン操作前の失敗を含む）
        $editorMutex.ReleaseMutex()
        $editorMutex.Dispose()
    }

    if ($exit -ne 0) {
        Write-Host "失敗解析: エディタの Console と Editor.log（%LOCALAPPDATA%\Unity\Editor\Editor.log）を確認"
        exit $exit
    }
    Write-Host "[$projectName] E2E テスト成功（エディタ直結）。"
    exit 0
}

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



