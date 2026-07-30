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
    [string]$PytestArgs = ""
)

$ErrorActionPreference = "Stop"

function Get-DeviceFreeBytes {
    <#
      .SYNOPSIS
      デバイスの /data の空き容量（バイト）。取得できなければ 0。
    #>
    param([string[]]$AdbTarget = @())
    try {
        # df の 1K ブロック表示から Available 列を取る（-h だと単位付きで解析が面倒）
        $line = (adb @AdbTarget shell df /data 2>$null | Select-Object -Last 1)
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

function Test-UnityProjectLocked {
    <#
      .SYNOPSIS
      エディタがこのプロジェクトを実際に開いているか（Temp\UnityLockfile を掴んでいるか）。

      .NOTES
      **ファイルの存在だけで判断しない**。エディタが異常終了するとロックファイルは残るため、
      存在で判定すると「既に開いています」と言い続けて永久に起動できなくなる（実際に踏んだ）。
      排他で開けたら誰も掴んでいない＝古い残骸。
    #>
    param([Parameter(Mandatory)][string]$ProjectDir)
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

# --- エージェント開発ダッシュボード連携（任意・別リポジトリ） ---
# **導入されていない環境では何も変えない**: pytest の引数も増やさず、ファイルも作らない。
# JUnit XML は件数の記録にしか使わないので、連携が有効なときだけ出力する
$emitHelper = Join-Path $PSScriptRoot "emit-status.ps1"
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
    <# 連携が有効なときだけ pytest に渡す --junitxml を組み立てる。
       出力先は**ターゲットごとに分ける**（同一プロジェクトの並行実行が互いの XML を壊さないため）。
       準備に失敗したら連携を諦めて空配列を返す（テスト実行を止めない）。 #>
    param([Parameter(Mandatory)][string]$Tag)

    if (-not $script:dashEnabled) { return @() }
    try {
        $safeTag = ($Tag -replace '[^A-Za-z0-9._-]', '_')
        $script:junitPath = Join-Path $root "Builds\e2e-results-$projectName-$safeTag.xml"
        New-Item -ItemType Directory -Force (Split-Path $script:junitPath -Parent) | Out-Null
        Remove-Item $script:junitPath -ErrorAction SilentlyContinue   # 前回結果を誤読しない
        return @("--junitxml=$script:junitPath")
    } catch {
        $script:junitPath = $null
        $script:dashEnabled = $false
        return @()
    }
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
    if ($JourneyDir -and (Test-Path (Join-Path $JourneyDir "report.html"))) {
        $data.journeyReport = Join-Path $JourneyDir "report.html"
    }
    if ($FailureDir -and (Test-Path $FailureDir)) { $data.failureDir = $FailureDir }
    Send-DashEvent -Kind "evidence.e2e" -StartPath $root -Data $data
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
                -ArgumentList @("status", "--project-path", "`"$projectDir`"", "--format", "json", "--no-banner") `
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
        Start-Process -FilePath $unityCli -ArgumentList @("open", "`"$projectDir`"") | Out-Null
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
    # **`unity status` が ready を返すことと、pipeline コマンドに応答できることは別**。
    # コールドスタート直後のエディタはアセットインポートとスクリプトコンパイルで手が塞がっており、
    # この軽い eval でも既定 30 秒（--timeout の既定値）でタイムアウトする。
    # インポートが終われば同じコマンドが 1 秒未満で返るので、**タイムアウトの間は待って再試行**する
    # （--timeout を伸ばすだけだと「本当に固まっている」ケースと区別できない）。
    # タイムアウト以外の失敗＝版差なので、待たずに下の判定へ落とす
    $probe = $null
    $probeWait = [System.Diagnostics.Stopwatch]::StartNew()
    $probeNotified = $false
    while ($true) {
        $probe = Invoke-UnityCli @("cmd", "eval", "--code", 'return "ok";') -AllowFail
        if ($probe -and $probe.success) { break }
        $probeError = if ($probe.errors) { ($probe.errors | ForEach-Object { $_.message }) -join " / " } else { "応答なし" }
        if ($probeError -notmatch "timed out|timeout") { break }
        if (-not $probeNotified) {
            Write-Host ("[$projectName] エディタは接続済みだが pipeline コマンドに応答しない" +
                        "（インポート/コンパイル中の可能性）。最大 $EditorReadyTimeoutSeconds 秒待ちます...")
            $probeNotified = $true
        }
        if ($probeWait.Elapsed.TotalSeconds -ge $EditorReadyTimeoutSeconds) {
            throw ("エディタが $([int]$probeWait.Elapsed.TotalSeconds) 秒たっても pipeline コマンドに応答しません: $probeError。" +
                   "エディタ側でインポート/コンパイルが終わらない、または Console でエラーが出ていないか確認する" +
                   "（待ち時間は -EditorReadyTimeoutSeconds で延ばせる）")
        }
        Write-Host "[$projectName] 待機 $([int]$probeWait.Elapsed.TotalSeconds) 秒"
        Start-Sleep -Seconds 3
    }
    if ($probeNotified) { Write-Host "[$projectName] エディタ応答を確認（待機 $([int]$probeWait.Elapsed.TotalSeconds) 秒）" }
    if (-not $probe -or -not $probe.success -or $probe.data.result.result -ne "ok") {
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
    if ($JourneyDir) { Write-Host "[$projectName] ジャーニー記録: $JourneyDir（Game view を Unity CLI で撮影）" }

    $env:UAPP_E2E_EDITOR = "1"
    # ジャーニーのスクリーンショットは adb ではなく Unity CLI の screenshot で撮る
    # （エディタ直結で adb を使うと実機を検証してしまうため、経路自体を分けている）。
    # 複数エディタが起動していても宛先を誤らないよう、対象プロジェクトも渡す
    $env:UAPP_E2E_UNITY_CLI = $unityCli
    $env:UAPP_E2E_PROJECT_PATH = $projectDir
    if ($JourneyDir) { $env:UAPP_E2E_JOURNEY_DIR = $JourneyDir }
    Push-Location (Join-Path $root "driver")
    try {
        # @(...) で必ず配列にする: 1要素の戻り値はスカラー文字列に化け、@splat が1文字ずつ展開される
        $junitArgs = @(Enable-JunitOutput -Tag "editor")
        if ($PytestArgs) {
            python -m pytest $config.tests @($PytestArgs -split " ") @junitArgs -v
        } else {
            python -m pytest $config.tests @junitArgs -v
        }
        $exit = $LASTEXITCODE
        # 失敗証跡: エディタ直結でも「AI が読める画像」を残す（Play を止める前に撮る）。
        # これが無いと -Editor の失敗時に「Console と Editor.log を見ろ」しか言えず、
        # AI から見える証跡がゼロになる
        if ($exit -ne 0) {
            $editorFailureDir = Join-Path $root "Builds\failure"
            New-Item -ItemType Directory -Force $editorFailureDir | Out-Null
            $shot = Join-Path $editorFailureDir "screen.png"
            python -c "from e2e_driver import editor_screenshot as es; import sys; sys.exit(0 if es.capture(sys.argv[1]) else 1)" $shot
            if ($LASTEXITCODE -eq 0) { Write-Host "失敗時のスクリーンショット: $shot" }
        }
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

    Send-E2eEvidence -ExitCode $exit -Mode "editor"
    if ($exit -ne 0) {
        $shot = Join-Path $root "Builds\failure\screen.png"
        Write-Host ("失敗解析: " + $(if (Test-Path $shot) { "$shot（画像として読む） → " } else { "" }) +
                    "エディタの Console と Editor.log（%LOCALAPPDATA%\Unity\Editor\Editor.log）を確認")
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
    $installOutput = (adb @adbTarget install -r -g $Apk 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw (Format-InstallFailure -Output $installOutput -ExitCode $LASTEXITCODE -Apk $Apk `
                                     -Package $package -FreeBytes $freeBytes)
    }
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
    # ターゲット（デバイス・ホスト側ポート）ごとに XML を分ける＝並行実行が互いを壊さない。
    # @(...) は必須（1要素の戻り値がスカラー化すると @splat が1文字ずつ展開される）
    $junitArgs = @(Enable-JunitOutput -Tag ("device-" + $(if ($DeviceSerial) { "$DeviceSerial-" } else { "" }) + $HostPort))
    if ($PytestArgs) {
        python -m pytest $config.tests @($PytestArgs -split " ") @junitArgs -v
    } else {
        python -m pytest $config.tests @junitArgs -v
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
    Send-E2eEvidence -ExitCode $exit -Mode "device" -FailureDir $evidence
    exit $exit
}
Send-E2eEvidence -ExitCode $exit -Mode "device"
Write-Host "[$projectName] E2E テスト成功。"



