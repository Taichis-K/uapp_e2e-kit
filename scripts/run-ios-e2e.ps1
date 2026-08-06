# iOS での E2E 一括（準備 → install → 起動 → pytest → 失敗証跡収集）。
# 使い方: ./scripts/run-ios-e2e.ps1 [-Project unity-nis] [-Build] [-SkipInstall] [-PytestArgs "-k xxx"]
#         ./scripts/run-ios-e2e.ps1 -Project unity-nis -Target device -Build   # USB 接続した実機
# **macOS 専用**（xcrun / simctl が必要。実機は加えて iproxy = libimobiledevice）。
#
# 実機（-Target device）の違い:
#   - **配備経路は端末の iOS バージョンで変わる**（ideviceinfo で判定して自動分岐）。
#     iOS 17 以降 = devicectl（install / process launch。ポートは DEVICECTL_CHILD_ 接頭辞で渡す）/
#     iOS 16 以前 = ideviceinstaller + idevicedebug（`--detach` 必須・ポートは `--env` で渡す）。
#     いずれも署名済みビルドが前提（build-ios.ps1 -Target device）
#   - 必要な外部コマンド: xcrun（共通）/ **ideviceinfo（実機は必須）** / iproxy /
#     iOS 16 以前はさらに ideviceinstaller・idevicedebug（いずれも libimobiledevice）
#   - **USB トンネルが必須** — ブリッジは IPAddress.Loopback に bind するので、ホストからは
#     iproxy <ホスト側>:<デバイス側> -u <UDID> でしか届かない（Android の adb forward と同じ役割）。
#     ホスト側ポートは -HostPort（既定 iosSimulatorPort + 10）で、**デバイス側は iosSimulatorPort を流用**
#   - 実機は開発者の端末を占有する。verify-all には組み込まない（明示実行のみ）
#
# ポート設計: シミュレータのアプリは**ホストのポート名前空間で直接 LISTEN する**ため、
# e2e-config.json の iosSimulatorPort は devicePort・editorBridgePort・ホスト側 forward ポートの
# **どれとも別番号**にすること（同居できるのが Android との違いであり罠でもある）。
# ポートはアプリへ SIMCTL_CHILD_UAPP_E2E_BRIDGE_PORT 環境変数で渡す
# （simctl launch の後置引数は argv には届くが Unity の managed 側から見えない。実測 2026-08-05）。
#
# OS レイヤーエージェント（-OsAgent。XCUITest でアプリの外を操作・OS 合成のスクショ）:
#   ./scripts/run-ios-e2e.ps1 -Project unity-nis -Target device -Udid <UDID> -OsAgent
#   **実機では端末側の設定が 2 つ要る** — 「設定 → プライバシーとセキュリティ → デベロッパモード」
#   に加えて、**「設定 → デベロッパ → UI オートメーションを有効」**。
#   後者が無いときの症状は原因を全く示さない: install も起動も通り、ランナーも起動して
#   「Automation Running」まで出るのに、**約 8 秒で The connection was invalidated**
#   となり、クラッシュレポートも残らない（2026-08-06 に実測）。
#   **iOS 16 以前の実機では OS エージェント自体が使えない**（CoreDevice に載らないため。
#   起動前に pairingState を見て明示エラーで止める）
#
# adb を直接使うテスト（logcat 断アサート等）は UAPP_E2E_IOS=1 で明示エラーになる。
# -PytestArgs 未指定時は既知の該当テスト（現在 2 件）を除外して回す。
param(
    [string]$Project = "unity-nis",
    [string]$ProjectPath,
    [string]$App,                     # .app の明示指定（省略時は build-ios.ps1 の既定出力から解決）
    # 実行対象。simulator=シミュレータ / device=USB 接続した実機（署名済みビルドが要る）
    [ValidateSet("simulator", "device")][string]$Target = "simulator",
    [ValidateSet("arm64", "x86_64")][string]$Arch,
    [switch]$Build,                   # 先に build-ios.ps1 を実行する
    [switch]$SkipInstall,             # インストール・再起動をスキップ（起動済みアプリへ接続）
    [string]$Device,                  # simulator: simctl のデバイス名（既定: config/local.json の iosSimulatorDevice → "iPhone 16"）
    [string]$Udid,                    # device: 対象実機の UDID（既定: config/local.json の iosDeviceUdid → 接続中が 1 台ならそれ）
    [int]$HostPort,                   # device: ホスト側トンネルポート（既定 iosSimulatorPort + 10）
    # ブリッジ（アプリ内）でスクショを撮る。**既定オフ** — 撮る瞬間だけアプリ側のフレームに
    # コストがかかり、その大きさは実プロジェクトの描画負荷と解像度に依存するため、標準にしない。
    # iOS 実機で画面を残したいときは明示的に付ける（他に手段が無い）
    [switch]$BridgeScreenshot,
    [int]$ScreenshotMaxWidth,         # ブリッジ撮影の縮小幅（既定: 等倍）
    # OS レイヤーエージェント（XCUITest）を起動する。**アプリの外**（外部ブラウザ・
    # システムダイアログ・WebView）を操作でき、**OS が合成した画面**を撮れる。
    # 既定オフ — 起動に十数秒かかり、可動部品が 1 つ増えるため、必要なときだけ使う
    [switch]$OsAgent,
    [int]$OsAgentPort,                # エージェントの**デバイス側**ポート（既定 8200）。実機はホスト側が +1（既定 8201）でトンネルされる
    # OS エージェント（XCUITest ランナー）の bundle id。**実機で署名するときは導入先ごとに変える**
    # — bundle id は Apple の App ID として一意なので、他チームが登録済みの識別子は自動署名で取れない。
    # 既定は config/local.json の iosOsAgentBundleId → プロジェクト既定値。
    # **このエージェント用プロジェクトはターゲットが 1 つだけ**なので、xcodebuild へ
    # PRODUCT_BUNDLE_IDENTIFIER を渡しても全ターゲットに波及する問題は起きない
    # （アプリ側で UnityFramework と衝突した件とは条件が違う）
    [string]$OsAgentBundleId,
    [string]$JourneyDir,              # ジャーニー記録の出力先（未指定: Builds/journey-ios/<プロジェクト>）
    [switch]$NoJourney,               # ジャーニー記録を無効化する
    [string]$PytestArgs
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "uapp-platform.ps1")

$root = (Resolve-Path (Join-UappPath $PSScriptRoot "..")).Path

# xcrun の解決が macOS 専用ガードを兼ねる
$xcrun = Get-UappCommandPath "xcrun"
if (-not $xcrun) { throw "xcrun が見つかりません。このスクリプトは macOS 専用です（Xcode を導入してください）" }

if (-not $Arch) {
    $Arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq
                [System.Runtime.InteropServices.Architecture]::Arm64) { "arm64" } else { "x86_64" }
}

# --------------------------------------------------------------- プロジェクトと設定
# **サンプル判定は代入より先に取る**。PowerShell の変数名は大小文字を区別しないため、
# 下の `$projectPath = ...` はパラメータ `$ProjectPath` と同一変数＝上書きになる
$isSample = $false
if ($ProjectPath) { $projectPath = (Resolve-Path $ProjectPath).Path }
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

# 設定解決: キット内（導入配置: <project>\uapp_e2e\e2e-config.json）→ プロジェクト直下
# （本リポジトリのサンプル配置）。run-e2e.ps1 と同じ規則
$configPath = Join-UappPath $root "e2e-config.json"
if (-not (Test-Path $configPath)) {
    $configPath = Join-UappPath $projectPath "e2e-config.json"
}
if (-not (Test-Path $configPath)) { throw "e2e-config.json がありません（$root または $projectPath 直下）" }
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$package = $config.package
if (-not $package) { throw "e2e-config.json に package がありません（iOS では bundle id として使う）" }
# **値域まで厳格に検査する**（Unity 側・Python 側は不正値を警告してフォールバックするため、
# ここで通すと両者が別々のポートへ向かい「起動はしたのに接続できない」になる）
$portRaw = $config.iosSimulatorPort
$port = 0
if ($null -eq $portRaw -or -not [int]::TryParse("$portRaw", [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
    throw ("e2e-config.json の iosSimulatorPort が不正または未設定です（値: '$portRaw'。1〜65535 の整数）。" +
           "**他プロジェクトの iosSimulatorPort・全プロジェクトの editorBridgePort・ホスト側 forward ポートの" +
           "どれとも別番号**にしてください（シミュレータはホストのポートを直接使うため、同番号だと取り合いになる）")
}

$buildsDir = Join-UappPath $root "Builds"
New-Item -ItemType Directory -Force $buildsDir | Out-Null

# ジャーニー記録（run-e2e.ps1 と同じ約束。**Android の記録と混ぜない** — スクショが
# プラットフォーム間で上書きし合うため、既定の置き場を journey-ios に分ける）
if (-not $NoJourney) {
    if (-not $JourneyDir) { $JourneyDir = Join-UappPath $buildsDir "journey-ios" $projectName }
    if (-not [System.IO.Path]::IsPathRooted($JourneyDir)) {
        $JourneyDir = Join-UappPath (Get-Location).Path $JourneyDir
    }
    $JourneyDir = [System.IO.Path]::GetFullPath($JourneyDir)
} else {
    $JourneyDir = $null
}

# --------------------------------------------------------------- ビルド（オプトイン）
# **-Build と -SkipInstall は両立しない**。ビルドしたのに配備を飛ばすと、端末に残っている
# 旧ビルド（同じ bundle id）を検証して「新しいビルドが通った」ように見える＝偽の緑（レビュー指摘）
if ($Build -and $SkipInstall) {
    throw "-Build と -SkipInstall は同時に指定できません（新ビルドを配備せず旧版を検証してしまうため）"
}
if ($Build) {
    $buildArgs = @{ Arch = $Arch; Target = $Target }
    if ($isSample) { $buildArgs.Project = $Project } else { $buildArgs.ProjectPath = $projectPath }
    & (Join-UappPath $PSScriptRoot "build-ios.ps1") @buildArgs
}

$isDevice = ($Target -eq "device")
if ($isDevice) { $Arch = "arm64" }   # 実機は arm64 のみ（DerivedData の分離キーと揃える）
if (-not $App) {
    $appDir = if ($isDevice) {
        Join-UappPath $buildsDir "ios-device" $projectName "DerivedData-$Arch/Build/Products/Debug-iphoneos"
    } else {
        Join-UappPath $buildsDir "ios-sim" $projectName "DerivedData-$Arch/Build/Products/Debug-iphonesimulator"
    }
    $apps = @(Get-ChildItem -LiteralPath $appDir -Filter "*.app" -Directory -ErrorAction SilentlyContinue)
    if ($apps.Count -ne 1) {
        throw (".app を特定できません: $appDir（先に ./scripts/build-ios.ps1 -Project $projectName -Target $Target を実行するか、-App で明示してください）")
    }
    $App = $apps[0].FullName
}

# 実機の bundle id は署名の都合で e2e-config の package と別（チーム配下の値）にすることがある。
# **実機では .app の CFBundleIdentifier を正とする**（照合の基準もこちらへ揃える）
$plutilPath = Get-UappCommandPath "plutil"
if (-not $plutilPath) { throw "plutil が見つかりません（macOS 標準ツール）" }
$appBundleId = (& $plutilPath -extract CFBundleIdentifier raw (Join-UappPath $App "Info.plist")) -join ""
if ($LASTEXITCODE -ne 0 -or -not $appBundleId) { throw ".app の CFBundleIdentifier を読めません: $App" }
if ($isDevice) { $package = $appBundleId }


# --------------------------------------------------------------- 端末単位の排他
# **同じ端末へ 2 本走らせない**。install と `--terminate-existing` の launch は
# **相手のアプリを差し替えて再起動してしまう**ので、ポート衝突で後から気づいても手遅れになる
# （同じ bundle id に起動セッションの識別が無いため、1 本目が 2 本目の個体へ繋ぎ直して
# 偽の緑になる余地がある）。**UDID が確定した直後・配備より前**に取る。
# スコープは `-Editor` の同時実行ガードと同じホスト全体（Get-UappHostMutexName）
$script:deviceMutex = $null
function Lock-UappIosDevice([string]$Udid) {
    $name = Get-UappHostMutexName "uapp_e2e_ios_$Udid"
    $m = New-Object System.Threading.Mutex($false, $name)
    # **前回が異常終了していると「放棄された Mutex」になる**。OS は解放するが、
    # .NET の WaitOne は AbandonedMutexException を投げる（このとき所有権は取得済み）。
    # これを捕まえないと、一度落ちた端末が以後ずっとロックされているように見える
    $acquired = $false
    try { $acquired = $m.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] {
        Write-Warning "前回の run-ios-e2e が異常終了した形跡があります（UDID $Udid の排他が放棄されていた）。続行します"
        $acquired = $true
    }
    if (-not $acquired) {
        $m.Dispose()
        throw ("この端末に対する run-ios-e2e が既に実行中です（UDID $Udid）。" +
               "**install と launch は相手のアプリを差し替えて再起動する**ため、" +
               "同じ端末への並行実行は許可していません。先行の実行が終わってから再試行してください")
    }
    $script:deviceMutex = $m
}

# --------------------------------------------------------------- デバイス準備（実機 / シミュレータ）
$tunnelProc = $null
if ($isDevice) {
    # 実機: UDID を確定して以後の全操作を同一個体へ固定する（シミュレータ側と同じ約束）
    if (-not $Udid) {
        $localConfigPath = Join-UappPath $root "config\local.json"
        $local = if (Test-Path $localConfigPath) { Get-Content $localConfigPath -Raw | ConvertFrom-Json } else { $null }
        if ($local -and $local.iosDeviceUdid) { $Udid = $local.iosDeviceUdid }
    }
    $ideviceId = Get-UappCommandPath "idevice_id"
    if (-not $Udid) {
        if (-not $ideviceId) {
            throw ("実機の UDID を決められません。-Udid を渡すか、config\local.json の iosDeviceUdid を" +
                   "設定するか、libimobiledevice（brew install libimobiledevice）を導入してください")
        }
        $connected = @(& $ideviceId -l 2>$null | Where-Object { $_ })
        if ($connected.Count -eq 1) { $Udid = $connected[0].Trim() }
        elseif ($connected.Count -eq 0) { throw "USB 接続された実機が見つかりません（idevice_id -l が空）" }
        else { throw "実機が複数接続されています: $($connected -join ', ')。-Udid で対象を指定してください" }
    }
    $udid = $Udid
    Lock-UappIosDevice $udid

    # **iOS の版で配備経路が変わる**。iOS 17 で Apple が開発者サービスを CoreDevice へ移したため:
    #   iOS 17 以降 … devicectl（Xcode 同梱）。libimobiledevice の各サービスは使えない
    #   iOS 16 以前 … ideviceinstaller / idevicedebug（libimobiledevice）。devicectl は非対応
    # 版の取得は ideviceinfo（どちらの世代でも lockdown の基本情報は読める）
    $ideviceinfo = Get-UappCommandPath "ideviceinfo"
    $iosMajor = 0
    if ($ideviceinfo) {
        $productVersion = (& $ideviceinfo -u $udid -k ProductVersion 2>$null) -join ""
        if ($productVersion -match '^(\d+)') { $iosMajor = [int]$Matches[1] }
    }
    if ($iosMajor -eq 0) {
        throw ("実機の iOS バージョンを取得できません（ideviceinfo が無いか、端末が応答しない）。" +
               "libimobiledevice を導入（brew install libimobiledevice）し、USB 接続・ロック解除・" +
               "信頼設定を確認してください")
    }
    $useDevicectl = ($iosMajor -ge 17)
    Write-Host "実機 iOS $productVersion → 配備経路: $(if ($useDevicectl) { 'devicectl' } else { 'libimobiledevice' })"

    if ($useDevicectl) {
        # **接続中であることを、対象そのものへ問い合わせて確かめる**（未接続のまま install へ行くと
        # 分かりにくい失敗になる）。**一覧の文字列照合はしない** — `devicectl list devices` が表示するのは
        # CoreDevice の識別子で、`--device` に渡せるハードウェア UDID とは別物（2026-08-05 に実測で判明）
        & $xcrun devicectl device info details --device $udid *> (Join-UappPath $buildsDir "devicectl-info-$projectName.log")
        if ($LASTEXITCODE -ne 0) {
            throw ("指定した実機（$udid）へ devicectl で問い合わせできません。USB 接続・ロック解除・" +
                   "信頼設定を確認してください（詳細: $(Join-UappPath $buildsDir "devicectl-info-$projectName.log")）")
        }
    }

    # ホスト側トンネルポート（デバイス側は iosSimulatorPort を流用）。
    # **シミュレータ用と別番号にする** — 同じホスト上で両方走ると取り合いになる
    if (-not $HostPort) { $HostPort = $port + 10 }
    if ($HostPort -lt 1 -or $HostPort -gt 65535) { throw "-HostPort が値域外です: $HostPort（1〜65535）" }

    if (-not $SkipInstall) {
        if ($useDevicectl) {
            # **install は一過性の失敗をする**（実測: CoreDeviceError 3002 "Connection interrupted"。
            # 同じコマンドの再試行で成功した）。install は冪等なので数回だけ再試行する —
            # ただし**回数は絞る**（署名エラーのような恒久的失敗を延々と粘らない）
            $installLog = Join-UappPath $buildsDir "devicectl-install-$projectName.log"
            $installed = $false
            for ($attempt = 1; $attempt -le 5; $attempt++) {
                & $xcrun devicectl device install app --device $udid $App *> $installLog
                if ($LASTEXITCODE -eq 0) { $installed = $true; break }
                if ($attempt -lt 5) {
                    Write-Warning "devicectl install に失敗（$attempt/5）。5 秒後に再試行します"
                    Start-Sleep -Seconds 5
                }
            }
            if (-not $installed) {
                throw ("devicectl install に失敗しました（5 回試行。詳細: $installLog）。" +
                       "署名・プロビジョニングと、デバイスのロック解除・USB 接続を確認してください。" +
                   "**CoreDeviceError 3002（Connection interrupted）が続くなら USB を挿し直す** — " +
                   "devicectl から見えていても install だけが失敗し続ける状態を実測している")
            }
            # **ポートは DEVICECTL_CHILD_ プレフィクスの環境変数で渡す**（simctl の
            # SIMCTL_CHILD_ と同じ仕組み。実機には Intent 相当の経路が無いので、これを使わないと
            # 既定 13333 で待ち受けてしまい、設定した iosSimulatorPort と食い違う。2026-08-05 に実測）
            $prevChildPort = $env:DEVICECTL_CHILD_UAPP_E2E_BRIDGE_PORT
            try {
                $env:DEVICECTL_CHILD_UAPP_E2E_BRIDGE_PORT = "$port"
                # launch も install と同じ一過性エラーを起こす（実測: CoreDeviceError 4000
                # "The device disconnected immediately after connecting"。再試行で成功）
                $launchLog = Join-UappPath $buildsDir "devicectl-launch-$projectName.log"
                $launched = $false
                for ($attempt = 1; $attempt -le 5; $attempt++) {
                    # **--terminate-existing で必ず起動し直す**（既存プロセスが再利用されると、
                    # 環境変数のポート指定も新しいビルドも反映されない。レビュー指摘）
                    & $xcrun devicectl device process launch --terminate-existing --device $udid $package *> $launchLog
                    if ($LASTEXITCODE -eq 0) { $launched = $true; break }
                    if ($attempt -lt 5) {
                        Write-Warning "devicectl process launch に失敗（$attempt/5）。5 秒後に再試行します"
                        Start-Sleep -Seconds 5
                    }
                }
                if (-not $launched) { throw "devicectl process launch に失敗しました（5 回試行。詳細: $launchLog）: $package" }
            }
            finally {
                if ($null -eq $prevChildPort) { Remove-Item Env:\DEVICECTL_CHILD_UAPP_E2E_BRIDGE_PORT -ErrorAction SilentlyContinue }
                else { $env:DEVICECTL_CHILD_UAPP_E2E_BRIDGE_PORT = $prevChildPort }
            }
            Start-Sleep -Seconds 5   # ブリッジが listen を張るまでの猶予（接続側でもリトライする）
    }
    else {
        # --- iOS 16 以前: libimobiledevice 経路 ---------------------------------
        # devicectl（CoreDevice）は iOS 17 以降専用なので、旧端末（iPhone 8 等）はこちら。
        # **ポートは idevicedebug の --env で渡す**（DEVICECTL_CHILD_ に相当）。
        # **--detach を付ける** — 付けないとデバッガに繋がったままプロセスを掴み続ける
        $ideviceinstaller = Get-UappCommandPath "ideviceinstaller"
        $idevicedebug = Get-UappCommandPath "idevicedebug"
        if (-not $ideviceinstaller -or -not $idevicedebug) {
            throw ("iOS $iosMajor の実機には libimobiledevice が要ります" +
                   "（brew install libimobiledevice ideviceinstaller）")
        }
        $installLog = Join-UappPath $buildsDir "ideviceinstaller-$projectName.log"
        $installed = $false
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            & $ideviceinstaller -u $udid install $App *> $installLog
            if ($LASTEXITCODE -eq 0) { $installed = $true; break }
            if ($attempt -lt 5) {
                Write-Warning "ideviceinstaller install に失敗（$attempt/5）。5 秒後に再試行します"
                Start-Sleep -Seconds 5
            }
        }
        if (-not $installed) {
            throw ("ideviceinstaller install に失敗しました（5 回試行。詳細: $installLog）。" +
                   "署名と、デバイスのロック解除・信頼設定を確認してください")
        }
        $launchLog = Join-UappPath $buildsDir "idevicedebug-$projectName.log"
        $launched = $false
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            & $idevicedebug -u $udid --detach --env "UAPP_E2E_BRIDGE_PORT=$port" run $package *> $launchLog
            if ($LASTEXITCODE -eq 0) { $launched = $true; break }
            if ($attempt -lt 5) {
                Write-Warning "idevicedebug run に失敗（$attempt/5）。5 秒後に再試行します"
                Start-Sleep -Seconds 5
            }
        }
        if (-not $launched) {
            throw ("idevicedebug run に失敗しました（5 回試行。詳細: $launchLog）。" +
                   "Developer Disk Image がマウントされているか確認してください" +
                   "（Xcode で一度実行するか ideviceimagemounter）")
        }
        Start-Sleep -Seconds 5
    }
}

    # USB トンネル（iproxy）。**このスクリプトが張ったものは finally で必ず落とす**
    $iproxy = Get-UappCommandPath "iproxy"
    if (-not $iproxy) {
        throw ("iproxy が見つかりません（brew install libimobiledevice）。実機はブリッジが loopback へ" +
               "bind するため、USB トンネル無しではホストから接続できません")
    }
    if (@(& (Get-UappCommandPath "lsof") -nP "-iTCP:$HostPort" -sTCP:LISTEN -t 2>$null).Count) {
        throw "ホスト側ポート $HostPort は既に使用中です。-HostPort で別番号を指定してください"
    }
    $tunnelProc = Start-UappBackgroundProcess -FilePath $iproxy `
        -ArgumentList @("$HostPort`:$port", "-u", $udid) `
        -LogPath (Join-UappPath $buildsDir "iproxy-$projectName.log")
    if (-not $tunnelProc) { throw "iproxy を起動できませんでした" }
    # **起動直後の検査で失敗しても iproxy を残さない**（末尾の finally はここより後ろから
    # 有効になるので、この区間だけは自分で落としてから送出する。レビュー指摘）
    try {
        # **待受プロセスが「自分が起動した iproxy」であることまで確認する**（事前確認と bind の
        # 間に並行実行が割り込むと、他人のトンネル＝別 UDID へ繋いだまま緑になりうる）
        $lsofPath = Get-UappCommandPath "lsof"
        $deadline = (Get-Date).AddSeconds(20)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            if ($tunnelProc.HasExited) {
                throw ("iproxy が起動直後に終了しました（exit=$($tunnelProc.ExitCode)）。" +
                       "詳細: $(Join-UappPath $buildsDir "iproxy-$projectName.log")")
            }
            $listenPids = @(& $lsofPath -nP "-iTCP:$HostPort" -sTCP:LISTEN -t 2>$null)
            if ($listenPids.Count) {
                if ($listenPids -notcontains "$($tunnelProc.Id)") {
                    throw ("ホスト側ポート $HostPort を別プロセス（PID $($listenPids -join ',')）が" +
                           "待ち受けています。自分の iproxy（PID $($tunnelProc.Id)）ではありません — " +
                           "並行実行の衝突です。-HostPort で別番号を指定してください")
                }
                $ready = $true
                break
            }
            Start-Sleep -Seconds 1
        }
        if (-not $ready) { throw "iproxy がホスト側ポート $HostPort を待ち受けません（20 秒）" }
    }
    catch {
        Stop-UappProcessTree -ProcessId $tunnelProc.Id
        $tunnelProc = $null
        throw
    }
    Write-Host "USB トンネル: localhost:$HostPort -> device:$port (UDID $udid)"
    $port = $HostPort   # 以降（pytest への受け渡し）はホスト側ポートを使う
}
else {
    # --------------------------------------------------------------- シミュレータ準備
    # **対象は名前 → UDID に解決して以後の全操作を同一 UDID へ固定する**。
    # 「何かが Booted なら booted 指定」だと、別機種・別 OS が起動済みのときに
    # そちらを検証してしまう（レビュー指摘）。-Device には UDID の直接指定も使える
    $deviceExplicit = [bool]$Device
    if (-not $Device) {
        $localConfigPath = Join-UappPath $root "config\local.json"
        $local = if (Test-Path $localConfigPath) { Get-Content $localConfigPath -Raw | ConvertFrom-Json } else { $null }
        $Device = if ($local -and $local.iosSimulatorDevice) { $local.iosSimulatorDevice } else { "iPhone 16" }
    }

    $udid = $null
    if ($Device -match '^[0-9A-Fa-f-]{36}$') {
        $udid = $Device
    } else {
        $listRaw = & $xcrun simctl list devices available
        if ($LASTEXITCODE -ne 0) { throw "simctl list に失敗しました" }
        $matched = @($listRaw | Where-Object { $_ -match '^\s*(.+?)\s+\(([0-9A-Fa-f-]{36})\)\s+\((Booted|Shutdown)' } |
            ForEach-Object { [pscustomobject]@{ Name = $Matches[1]; Udid = $Matches[2]; State = $Matches[3] } } |
            Where-Object { $_.Name -eq $Device })
        if (-not $matched.Count) {
            throw "シミュレータ '$Device' が見つかりません（xcrun simctl list devices available で確認）"
        }
        # 同名デバイスが複数の OS ランタイムに居ることがある（例: iPhone 16 が iOS 18.3 と 18.6 の両方）。
        # **起動済みを優先するが、黙って選ばない** — 選択結果と他候補を必ず表示する。
        # 特定のランタイムに固定したいときは -Device に UDID を指定する
        $bootedMatch = @($matched | Where-Object { $_.State -eq "Booted" })
        if ($bootedMatch.Count -eq 1) {
            $udid = $bootedMatch[0].Udid
            if ($matched.Count -gt 1) {
                $others = @($matched | Where-Object { $_.Udid -ne $udid } | ForEach-Object { $_.Udid })
                Write-Warning ("'$Device' は $($matched.Count) 台あります。起動済みの $udid を使います" +
                               "（他: $($others -join ', ')。固定するには -Device <UDID>）")
            }
        }
        elseif ($bootedMatch.Count -gt 1) {
            throw "同名のシミュレータが複数起動中です: $($bootedMatch.Udid -join ', ')。-Device に UDID を指定してください"
        }
        elseif ($matched.Count -eq 1) { $udid = $matched[0].Udid }
        else {
            throw ("シミュレータ '$Device' が複数の OS ランタイムにあり、どれも起動していません: " +
                   "$(@($matched | ForEach-Object { $_.Udid }) -join ', ') — -Device に UDID を指定してください")
        }
    }

    Lock-UappIosDevice $udid

    $state = (& $xcrun simctl list devices) -join "`n"
    if ($state -notmatch [regex]::Escape($udid) + '\)\s+\(Booted') {
        Write-Host "シミュレータを起動します: $Device ($udid)"
        & $xcrun simctl boot $udid
        if ($LASTEXITCODE -ne 0) { throw "simctl boot に失敗しました（UDID $udid）" }
        & $xcrun simctl bootstatus $udid -b | Out-Null
    }

    $launchPid = $null
    if (-not $SkipInstall) {
        # **これから入れる .app が設定の package（bundle id）と同一であることを先に確かめる**。
        # 照合しないと、シミュレータに旧版の $package が残っている場合、別アプリの .app を
        # 誤指定しても「install 成功 → 旧版を launch → テスト成功」で緑になる（レビュー指摘）
        $plutil = Get-UappCommandPath "plutil"
        if (-not $plutil) { throw "plutil が見つかりません（macOS 標準ツール。PATH を確認してください）" }
        $bundleId = (& $plutil -extract CFBundleIdentifier raw (Join-UappPath $App "Info.plist")) -join ""
        if ($LASTEXITCODE -ne 0 -or -not $bundleId) { throw ".app の CFBundleIdentifier を読めません: $App" }
        if ($bundleId -ne $package) {
            throw (".app の bundle id（$bundleId）が e2e-config.json の package（$package）と一致しません。" +
                   "別プロジェクトの .app を指している可能性があります: $App")
        }

        & $xcrun simctl terminate $udid $package 2>$null
        Start-Sleep -Seconds 1
        & $xcrun simctl install $udid $App
        if ($LASTEXITCODE -ne 0) { throw "simctl install に失敗しました: $App" }

        # ポートは環境変数で渡す（SIMCTL_CHILD_ プレフィクスで子プロセスへ届く）。呼び出し元の値は汚さない
        $prevChildPort = $env:SIMCTL_CHILD_UAPP_E2E_BRIDGE_PORT
        try {
            $env:SIMCTL_CHILD_UAPP_E2E_BRIDGE_PORT = "$port"
            $launchOut = (& $xcrun simctl launch $udid $package) -join ""
            if ($LASTEXITCODE -ne 0) { throw "simctl launch に失敗しました: $package" }
        }
        finally {
            if ($null -eq $prevChildPort) { Remove-Item Env:\SIMCTL_CHILD_UAPP_E2E_BRIDGE_PORT -ErrorAction SilentlyContinue }
            else { $env:SIMCTL_CHILD_UAPP_E2E_BRIDGE_PORT = $prevChildPort }
        }
        # **PID が取れない・lsof が無い、は fail-open にしない**（照合が静かに無効になると
        # 「別プロセスがポートを握ったまま緑」を素通しする。レビュー指摘）
        if ($launchOut -notmatch ":\s*(\d+)\s*$") {
            throw "simctl launch の出力から PID を解析できません: '$launchOut'（照合できないまま進むと偽の緑になりうるため停止）"
        }
        $launchPid = [int]$Matches[1]
        $lsof = Get-UappCommandPath "lsof"
        if (-not $lsof) { throw "lsof が見つかりません（macOS 標準ツール。PID 照合ができないため停止）" }

        # **起動した個体がこのポートで待ち受けたことを結び付けて確認する**
        $deadline = (Get-Date).AddSeconds(60)
        $bound = $false
        while ((Get-Date) -lt $deadline) {
            $listenPids = @(& $lsof -nP "-iTCP:$port" -sTCP:LISTEN -t 2>$null)
            if ($listenPids.Count -gt 0) {
                if ($listenPids -notcontains "$launchPid") {
                    throw ("ポート $port を別プロセス（PID $($listenPids -join ',')）が待ち受けています。" +
                           "起動したアプリ（PID $launchPid）と一致しません — iosSimulatorPort の衝突。" +
                           "lsof -nP -iTCP:$port -sTCP:LISTEN で相手を確認してください")
                }
                $bound = $true
                break
            }
            Start-Sleep -Seconds 1
        }
        if (-not $bound) {
            throw ("アプリがポート $port で待ち受けを開始しません（60 秒）。" +
                   "起動失敗か bind 失敗の可能性 — simctl spawn $udid log show --last 2m で確認してください")
        }
    }
    else {
        # **-SkipInstall でも「指定 UDID 上のアプリ」であることまで結び付ける**（レビュー指摘。
        # bundle id と platform の照合だけでは、**別シミュレータ**で動く同一アプリを識別できない。
        # シミュレータのプロセスは実行ファイルが /Devices/<UDID>/ 配下にあるので、
        # LISTEN プロセスのパスで機械的に判定できる）
        $lsof = Get-UappCommandPath "lsof"
        if (-not $lsof) { throw "lsof が見つかりません（macOS 標準ツール。接続先の照合ができないため停止）" }
        $psExe = Get-UappCommandPath "ps"
        if (-not $psExe) { throw "ps が見つかりません（接続先の照合ができないため停止）" }
        $listenPids = @(& $lsof -nP "-iTCP:$port" -sTCP:LISTEN -t 2>$null)
        if (-not $listenPids.Count) {
            throw ("-SkipInstall ですが、ポート $port を待ち受けるプロセスがありません。" +
                   "アプリを先に起動するか、-SkipInstall を外してください")
        }
        foreach ($listenPid in $listenPids) {
            $exe = (& $psExe -p $listenPid -o comm=) -join ""
            if ($exe -notmatch [regex]::Escape("/Devices/$udid/")) {
                throw ("ポート $port の待受プロセス（PID ${listenPid}: $exe）が指定シミュレータ" +
                       "（UDID $udid）上のアプリではありません。別のシミュレータ・別プロセスに接続する" +
                       "偽の緑を防ぐため停止します")
            }
        }
    }
}

# --------------------------------------------------------------- pytest
# **ここから先は必ず try/finally で包む**（途中の例外で終端の停止処理に到達しないと
# iproxy が残り、ホスト側ポートを握り続ける）
try {
$driverDir = Join-UappPath $root "driver"
if (-not (Test-Path $driverDir)) { $driverDir = Join-UappPath $root "uapp_e2e\driver" }
if (-not (Test-Path $driverDir)) { throw "driver ディレクトリが見つかりません（開発リポ: driver/ 導入先: uapp_e2e/driver/）" }

$pythonExe = Get-UappPython
if (-not $pythonExe) { throw "python が見つかりません（python3 を導入してください）" }

# 実行対象は e2e-config.json の tests に従う（run-e2e.ps1 と同じ約束。
# 無視して全体を回すと、別プロジェクト向けのテストまでこのアプリに対して走る）
$testsPath = if ($config.tests) { ConvertTo-UappNativePath $config.tests } else { "tests" }
$junit = Join-UappPath $buildsDir "pytest-ios-$projectName.xml"
$pytestArgList = @("-m", "pytest", "-q", $testsPath, "--junitxml", $junit)
if ($PytestArgs) {
    $pytestArgList += ($PytestArgs -split "\s+" | Where-Object { $_ })
} else {
    # adb を直接使う既知のテストを既定で除外する（UAPP_E2E_IOS=1 では明示エラーになるため。
    # 自分で -PytestArgs を渡す場合は除外も含めて自分で制御する）。
    # **テスト指定に含まれるファイルのぶんだけ**除外する — --deselect は収集されない id を
    # 指すと pytest がエラーになる
    $knownAdbTests = @(
        "tests/test_smoke.py::test_hold_a_tap_b_then_release",
        "tests/test_ngui_legacy.py::test_real_tap_via_adb_reaches_legacy_ngui"
    )
    # 表記ゆれ（./tests, tests/, 末尾スラッシュ）を正規化してから比較する。
    # さらに**ファイルが実在するときだけ**除外を足す — --deselect は収集されない id を
    # 指すと pytest 自体がエラーになる（tests 指定でも該当ファイルが無い配置がある）
    $testsKey = ((ConvertTo-UappPathKey $testsPath) -replace '^\./', '').TrimEnd('/')
    foreach ($known in $knownAdbTests) {
        $file = ($known -split "::")[0]
        $covered = ($testsKey -eq "tests" -or $testsKey -eq $file)
        if ($covered -and (Test-Path (Join-UappPath $driverDir $file))) {
            $pytestArgList += @("--deselect", $known)
        }
    }
}


function Stop-OsAgentAndFoldResult {
    <#
      .SYNOPSIS
      OS エージェントを止め、その成否を $script:agentFailed へ記録する（**冪等**）。

      .NOTES
      **pytest の直後に呼ぶ**こと。証跡収集・ダッシュボード送信より後ろで判定すると、
      「CLI は失敗なのに evidence.e2e は exitCode=0、失敗証跡も無い」という食い違いになる
      （レビュー指摘）。finally からも呼ばれるが、二度目は何もしない。
    #>
    if ($script:agentStopped) { return }
    $script:agentStopped = $true
    if ($script:agentUrl) {
        try {
            Invoke-RestMethod -Uri "$($script:agentUrl)/stop" -Method Post -Body "{}" `
                -ContentType "application/json" -Headers @{ "X-Uapp-Token" = $script:agentToken } `
                -TimeoutSec 10 | Out-Null
        } catch { }
    }
    if ($script:agentProc) {
        for ($i = 0; $i -lt 10; $i++) { if ($script:agentProc.HasExited) { break }; Start-Sleep -Seconds 1 }
        # **エージェント側の失敗を結果へ合成する**。/stop で行儀よく終われば 0 になるので、
        # 非ゼロは「途中でクラッシュした」「XCTest が失敗を記録した」を意味する。
        # ここを見ないと、撮影や操作が壊れていても pytest の結果だけで成功表示になる
        if ($script:agentProc.HasExited) {
            if ($script:agentProc.ExitCode -ne 0) {
                Write-Warning "OS エージェントが異常終了しました（exit=$($script:agentProc.ExitCode)。詳細: $script:agentLog）"
                $script:agentFailed = $true
            }
        } else {
            Stop-UappProcessTree -ProcessId $script:agentProc.Id
            Write-Warning "OS エージェントが停止要求に応じず強制終了しました（詳細: $script:agentLog）"
            $script:agentFailed = $true
        }
        Write-Host "OS エージェントを停止しました"
    }
    if ($script:agentTunnel) { Stop-UappProcessTree -ProcessId $script:agentTunnel.Id }
}

# --------------------------------------------------------------- OS レイヤーエージェント
# **プロジェクトの外にある Xcode プロジェクトを別プロセスで走らせる**ので、
# 起動と停止の対応を崩さない（停止漏れはポートを握ったまま次回を止める）。
$script:agentProc = $null
$script:agentTunnel = $null
$script:agentUrl = $null
$script:agentToken = $null
$script:agentLog = $null
$script:agentFailed = $false
$script:agentStopped = $false
if ($OsAgent) {
    if (-not $OsAgentPort) { $OsAgentPort = 8200 }
    if ($OsAgentPort -lt 1 -or $OsAgentPort -gt 65535) { throw "-OsAgentPort が値域外です: $OsAgentPort" }
    $agentProject = Join-UappPath $root "oslayer/UappOsAgent/UappOsAgent.xcodeproj"
    if (-not (Test-Path $agentProject)) {
        throw ("OS エージェントのプロジェクトがありません: $agentProject" +
               "（配布キットでは oslayer/ を導入先でビルドする）")
    }
    # **実際にホスト側で待ち受ける番号**を検査する（実機はトンネルの手前側 = +1）。
    # デバイス側の番号だけ見ても意味がない（レビュー指摘で発覚した不整合）
    $agentHostPort = if ($isDevice) { $OsAgentPort + 1 } else { $OsAgentPort }
    if (@(& (Get-UappCommandPath "lsof") -nP "-iTCP:$agentHostPort" -sTCP:LISTEN -t 2>$null).Count) {
        throw "ポート $agentHostPort は既に使用中です。-OsAgentPort で別番号を指定してください"
    }
    # **起動ごとの秘密トークン**。エージェントは全要求でこれを要求し、`/status` の
    # `authenticated` で「自分が起動した個体か」を判定できるようにする。
    # 並行実行・古いトンネルの残骸へ繋いで別個体を操作する偽の緑を防ぐ
    $script:agentToken = [guid]::NewGuid().ToString("N")
    # **エージェントはテストとして走り続ける**（終わらないテストの中で HTTP を待ち受ける）。
    # そのため待たずに起動し、待受を確認してから先へ進む
    $script:agentLog = Join-UappPath $buildsDir "os-agent-$projectName.log"
    # **走らせるのは常駐テストだけに固定する**。切り分け用の対照テスト（testTrivial）が
    # 同じバンドルに居るので、指定しないと実行順に依存して挙動が変わる
    $agentArgs = @("test", "-project", $agentProject, "-scheme", "UappOsAgentRunner",
                   "-only-testing:UappOsAgentRunner/UappOsAgent/testRunAgent",
                   "-destination", "id=$udid",   # 実機・シミュレータとも UDID で一意に指定する
                   "-derivedDataPath", (Join-UappPath $root "oslayer/UappOsAgent/DerivedData"))
    if ($isDevice) {
        # **CoreDevice に載らない端末では XCUITest を走らせられない**（iOS 16 の実機で実測）。
        # xcodebuild の実機の宛先は CoreDevice 由来なので、載っていないと
        # 「Logic Testing on iOS devices is not supported」という**症状と無関係な文言**で落ちる。
        # `xctrace list devices` や libimobiledevice には出るので「見えている＝使える」ではない。
        # ここで先に判定して、何が足りないのかを言って止める
        # **fail-closed で判定する**。取得前に消し、終了コード・ファイル生成・解析の全てを要求する
        # — 消さずに「在れば読む」だと、CoreDevice が一過性に落ちた回に**前回 paired だった
        # 古い JSON** を読んでガードを素通りする（この環境では実際に CoreDevice が
        # 何度も unavailable へ落ちている）
        $coreDeviceJson = Join-UappPath $buildsDir "devicectl-list-$projectName.json"
        Remove-Item -LiteralPath $coreDeviceJson -Force -ErrorAction SilentlyContinue
        & $xcrun devicectl list devices --json-output $coreDeviceJson *> $null
        $listExit = $LASTEXITCODE
        if ($listExit -ne 0 -or -not (Test-Path $coreDeviceJson)) {
            throw ("CoreDevice の端末一覧を取得できません（devicectl list devices の終了コード $listExit）。" +
                   "-OsAgent は XCUITest を使うので、CoreDevice に載っていることを確認できないまま進めません。" +
                   "USB 接続とロック解除を確認してください")
        }
        $pairing = $null
        try {
            $listed = (Get-Content $coreDeviceJson -Raw | ConvertFrom-Json).result.devices |
                Where-Object { $_.hardwareProperties.udid -eq $udid }
        } catch {
            throw "CoreDevice の端末一覧を解析できません（$coreDeviceJson）: $($_.Exception.Message)"
        }
        if ($listed) { $pairing = $listed.connectionProperties.pairingState }
        if ($pairing -ne "paired") {
            throw ("この端末では -OsAgent（XCUITest の OS レイヤーエージェント）を使えません" +
                   "（CoreDevice の pairingState=$(if ($pairing) { $pairing } else { '未登録' })）。" +
                   "CoreDevice に載らない端末は xcodebuild のテスト宛先にならず、" +
                   "『Logic Testing on iOS devices is not supported』という無関係な文言で落ちます。" +
                   "この場合はブリッジ経路で実行し、スクリーンショットは idevicescreenshot" +
                   "（iOS 16 以前で使える）に任せてください")
        }
        # **物理デバイスの列挙を待つ**。xcodebuild の既定の待ち時間は短く、USB 接続の端末が
        # 間に合わないと「Unable to find a destination matching...」で即死する
        # （直前まで手動の -showdestinations には出ていたのに落ちる＝競合。実測）
        $agentArgs += @("-destination-timeout", "120")
        if (-not $Team) {
            $localConfigPath2 = Join-UappPath $root "config\local.json"
            $local2 = if (Test-Path $localConfigPath2) { Get-Content $localConfigPath2 -Raw | ConvertFrom-Json } else { $null }
            if ($local2 -and $local2.iosTeamId) { $Team = $local2.iosTeamId }
        }
        if (-not $Team) { throw "実機で -OsAgent を使うには署名チームが要ります（config/local.json の iosTeamId）" }
        # 実機は**署名する**（プロジェクト側はシミュレータのときだけ署名を切っている）
        $agentArgs += @("-allowProvisioningUpdates", "DEVELOPMENT_TEAM=$Team",
                        "CODE_SIGN_STYLE=Automatic", "CODE_SIGNING_ALLOWED=YES")
        if (-not $OsAgentBundleId) {
            $localConfigPath3 = Join-UappPath $root "config\local.json"
            $local3 = if (Test-Path $localConfigPath3) { Get-Content $localConfigPath3 -Raw | ConvertFrom-Json } else { $null }
            if ($local3 -and $local3.iosOsAgentBundleId) { $OsAgentBundleId = $local3.iosOsAgentBundleId }
        }
        if ($OsAgentBundleId) { $agentArgs += @("PRODUCT_BUNDLE_IDENTIFIER=$OsAgentBundleId") }
    }
    # **`TEST_RUNNER_` 接頭辞が要る** — xcodebuild は素の環境変数をテストランナーへ渡さない。
    # この接頭辞を付けたものだけが、接頭辞を外した名前でランナー側の環境に現れる
    # （実測: 接頭辞なしでは既定ポート・認証なしで起動してしまい、トークン検査が無効になっていた）
    $prevAgentPort = $env:TEST_RUNNER_UAPP_OS_AGENT_PORT
    $prevAgentToken = $env:TEST_RUNNER_UAPP_OS_AGENT_TOKEN
    try {
        $env:TEST_RUNNER_UAPP_OS_AGENT_PORT = "$OsAgentPort"
        $env:TEST_RUNNER_UAPP_OS_AGENT_TOKEN = $agentToken
        # **実機は USB 越しの配備が一過性で落ちる**（`Connection interrupted` /
        # CoreDeviceError 3002）。アプリ側の install / launch と同じ理由なので同じだけ再試行する。
        # 判定は「起動から 45 秒以内に終了した」— 正常時のエージェントは終了しないので、
        # 早期終了はすべて配備の失敗とみなしてよい
        $agentAttempts = if ($isDevice) { 5 } else { 1 }
        for ($i = 1; $i -le $agentAttempts; $i++) {
            $script:agentProc = Start-UappBackgroundProcess -FilePath (Get-UappCommandPath "xcodebuild") `
                -ArgumentList $agentArgs -LogPath $script:agentLog
            if (-not $agentProc) { break }
            $earlyDeadline = (Get-Date).AddSeconds(45)
            while ((Get-Date) -lt $earlyDeadline -and -not $agentProc.HasExited) { Start-Sleep -Seconds 3 }
            if (-not $agentProc.HasExited) { break }
            if ($i -lt $agentAttempts) {
                Write-Warning "OS エージェントの配備に失敗（$i/$agentAttempts）。5 秒後に再試行します"
                Start-Sleep -Seconds 5
            }
        }
    }
    finally {
        if ($null -eq $prevAgentPort) { Remove-Item Env:\TEST_RUNNER_UAPP_OS_AGENT_PORT -ErrorAction SilentlyContinue }
        else { $env:TEST_RUNNER_UAPP_OS_AGENT_PORT = $prevAgentPort }
        if ($null -eq $prevAgentToken) { Remove-Item Env:\TEST_RUNNER_UAPP_OS_AGENT_TOKEN -ErrorAction SilentlyContinue }
        else { $env:TEST_RUNNER_UAPP_OS_AGENT_TOKEN = $prevAgentToken }
    }
    if (-not $agentProc) { throw "OS エージェントを起動できませんでした" }
    try {
        # 実機はシミュレータと違いホストから直接届かないので USB トンネルを張る
        if ($isDevice) {
            $script:agentTunnel = Start-UappBackgroundProcess -FilePath (Get-UappCommandPath "iproxy") `
                -ArgumentList @("$agentHostPort`:$OsAgentPort", "-u", $udid) `
                -LogPath (Join-UappPath $buildsDir "iproxy-osagent-$projectName.log")
            if (-not $agentTunnel) { throw "OS エージェント用の iproxy を起動できませんでした" }
        }
        $script:agentUrl = "http://127.0.0.1:$agentHostPort"
        # **ビルドから走るので待ち時間が長い**（初回は数分）。待受と /status の両方で確認する
        $deadline = (Get-Date).AddMinutes(6)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            if ($agentProc.HasExited) {
                throw ("OS エージェントが起動直後に終了しました（詳細: $script:agentLog）" +
                        "。**実機でこれが出るときは、まず端末の「設定 → デベロッパ → UI オートメーションを有効」を確認する** — これが OFF だと install も起動も通り「Automation Running」まで出るのに約 8 秒で接続が切られ、クラッシュレポートも残らない（2026-08-06 実測）。切り分けは、すぐ終わる対照テストを走らせること: xcodebuild test -only-testing:UappOsAgentRunner/UappOsAgent/testTrivial")
            }
            $probe = $null
            try {
                $probe = Invoke-RestMethod -Uri "$agentUrl/status" -TimeoutSec 5 `
                    -Headers @{ "X-Uapp-Token" = $agentToken }
            } catch { }
            # **トークンで認証できた個体だけを受け入れる**。名前の前方一致だけだと、
            # 並行実行や古いトンネルの相手を「正しいエージェント」と誤認する
            if ($probe -and "$($probe.agent)".StartsWith("uapp-os-agent") -and $probe.authenticated) {
                $ready = $true; break
            }
            Start-Sleep -Seconds 3
        }
        if (-not $ready) {
            throw ("OS エージェントが応答しません（6 分。詳細: $script:agentLog）" +
                   "。**実機でこれが出るときは、まず端末の「設定 → デベロッパ → UI オートメーションを有効」を確認する** — これが OFF だと install も起動も通り「Automation Running」まで出るのに約 8 秒で接続が切られ、クラッシュレポートも残らない（2026-08-06 実測）。切り分けは、すぐ終わる対照テストを走らせること: xcodebuild test -only-testing:UappOsAgentRunner/UappOsAgent/testTrivial")
        }
        Write-Host "OS エージェント: $agentUrl（$(if ($isDevice) { "USB トンネル経由" } else { "シミュレータ直" })）"
    }
    catch {
        # **ここで失敗したらエージェントを残さない**（末尾の finally はまだ有効でない）
        if ($agentTunnel) { Stop-UappProcessTree -ProcessId $agentTunnel.Id }
        if ($agentProc) { Stop-UappProcessTree -ProcessId $agentProc.Id }
        $script:agentProc = $null; $agentTunnel = $null
        throw
    }
}

# 呼び出し元の環境変数は尊重し、必ず復元する（run-e2e.ps1 の -Editor と同じ約束）。
# UAPP_E2E_IOS_BUNDLE_ID は**接続先の bundle id 照合**に使う（ドライバの iOS ガードが
# ping の app と突き合わせる。-SkipInstall でも効く二重の網）
$prevIos = $env:UAPP_E2E_IOS
$prevPort = $env:UAPP_E2E_BRIDGE_PORT
$prevBundle = $env:UAPP_E2E_IOS_BUNDLE_ID
$prevUdid = $env:UAPP_E2E_IOS_UDID
$prevJourney = $env:UAPP_E2E_JOURNEY_DIR
$prevAgentUrl = $env:UAPP_E2E_OS_AGENT_URL
$prevAgentClientToken = $env:UAPP_E2E_OS_AGENT_TOKEN
# 新設の変数も**呼び出し元の値を壊さない**（無条件削除だと同じシェルの後続処理が変わる）
$prevDeviceUdid = $env:UAPP_E2E_IOS_DEVICE_UDID
$prevDeviceMajor = $env:UAPP_E2E_IOS_DEVICE_MAJOR
$prevBridgeShot = $env:UAPP_E2E_BRIDGE_SCREENSHOT
$prevBridgeShotWidth = $env:UAPP_E2E_BRIDGE_SCREENSHOT_MAX_WIDTH
$testExit = 999
Push-Location $driverDir
try {
    $env:UAPP_E2E_IOS = "1"
    $env:UAPP_E2E_BRIDGE_PORT = "$port"
    $env:UAPP_E2E_IOS_BUNDLE_ID = $package
    # スクショの宛先を渡す。**シミュレータは simctl、実機は idevicescreenshot（OS 層）**で
    # 別経路なので環境変数も分ける（取り違えると存在しない個体を撮りにいく）。
    # 実機の `idevicescreenshot` は iOS 16 以前でのみ成立する。iOS 17 以降は
    # **-OsAgent（XCUITest）が OS 層の手段**で、それも使わないなら
    # ブリッジ側（-BridgeScreenshot・Unity の描画のみ）が最後の手段になる
    if ($isDevice) {
        Remove-Item Env:\UAPP_E2E_IOS_UDID -ErrorAction SilentlyContinue
        $env:UAPP_E2E_IOS_DEVICE_UDID = $udid
        $env:UAPP_E2E_IOS_DEVICE_MAJOR = "$iosMajor"   # 17 以降は OS 層の撮影を試さない
    } else {
        $env:UAPP_E2E_IOS_UDID = $udid
        Remove-Item Env:\UAPP_E2E_IOS_DEVICE_UDID -ErrorAction SilentlyContinue
    Remove-Item Env:\UAPP_E2E_IOS_DEVICE_MAJOR -ErrorAction SilentlyContinue
    }
    # -NoJourney のときは**継承された環境変数も一時的に外す**（残すと呼び出し元の
    # Android 用ディレクトリへ iOS の記録が混ざり、プラットフォーム分離を破る）
    if ($JourneyDir) { $env:UAPP_E2E_JOURNEY_DIR = $JourneyDir }
    else { Remove-Item Env:\UAPP_E2E_JOURNEY_DIR -ErrorAction SilentlyContinue }
    if ($agentUrl) {
        $env:UAPP_E2E_OS_AGENT_URL = $agentUrl
        $env:UAPP_E2E_OS_AGENT_TOKEN = $agentToken
    } else {
        Remove-Item Env:\UAPP_E2E_OS_AGENT_URL -ErrorAction SilentlyContinue
        Remove-Item Env:\UAPP_E2E_OS_AGENT_TOKEN -ErrorAction SilentlyContinue
    }
    if ($BridgeScreenshot) {
        $env:UAPP_E2E_BRIDGE_SCREENSHOT = "1"
        if ($ScreenshotMaxWidth -gt 0) { $env:UAPP_E2E_BRIDGE_SCREENSHOT_MAX_WIDTH = "$ScreenshotMaxWidth" }
    }
    $global:LASTEXITCODE = 999
    & $pythonExe @pytestArgList
    $testExit = $LASTEXITCODE
    # ジャーニーが記録されていれば自己完結レポートを更新する（失敗時も解析に使うため生成する）
    if ($JourneyDir -and (Test-Path (Join-UappPath $JourneyDir "journey.json"))) {
        & $pythonExe -m e2e_driver.journey $JourneyDir
        if ($LASTEXITCODE -eq 0) {
            Write-Host "ジャーニーレポート: $(Join-UappPath $JourneyDir 'report.html')"
        } else {
            Write-Warning "ジャーニーレポート生成に失敗（テスト結果には影響しない）: $JourneyDir"
        }
    }
}
finally {
    Pop-Location
    if ($null -eq $prevIos) { Remove-Item Env:\UAPP_E2E_IOS -ErrorAction SilentlyContinue } else { $env:UAPP_E2E_IOS = $prevIos }
    if ($null -eq $prevPort) { Remove-Item Env:\UAPP_E2E_BRIDGE_PORT -ErrorAction SilentlyContinue } else { $env:UAPP_E2E_BRIDGE_PORT = $prevPort }
    if ($null -eq $prevBundle) { Remove-Item Env:\UAPP_E2E_IOS_BUNDLE_ID -ErrorAction SilentlyContinue } else { $env:UAPP_E2E_IOS_BUNDLE_ID = $prevBundle }
    if ($null -eq $prevUdid) { Remove-Item Env:\UAPP_E2E_IOS_UDID -ErrorAction SilentlyContinue } else { $env:UAPP_E2E_IOS_UDID = $prevUdid }
    if ($null -eq $prevJourney) { Remove-Item Env:\UAPP_E2E_JOURNEY_DIR -ErrorAction SilentlyContinue } else { $env:UAPP_E2E_JOURNEY_DIR = $prevJourney }
    if ($null -eq $prevAgentUrl) { Remove-Item Env:\UAPP_E2E_OS_AGENT_URL -ErrorAction SilentlyContinue } else { $env:UAPP_E2E_OS_AGENT_URL = $prevAgentUrl }
    if ($null -eq $prevAgentClientToken) { Remove-Item Env:\UAPP_E2E_OS_AGENT_TOKEN -ErrorAction SilentlyContinue } else { $env:UAPP_E2E_OS_AGENT_TOKEN = $prevAgentClientToken }
    if ($null -eq $prevDeviceUdid) { Remove-Item Env:\UAPP_E2E_IOS_DEVICE_UDID -ErrorAction SilentlyContinue } else { $env:UAPP_E2E_IOS_DEVICE_UDID = $prevDeviceUdid }
    if ($null -eq $prevDeviceMajor) { Remove-Item Env:\UAPP_E2E_IOS_DEVICE_MAJOR -ErrorAction SilentlyContinue } else { $env:UAPP_E2E_IOS_DEVICE_MAJOR = $prevDeviceMajor }
    if ($null -eq $prevBridgeShot) { Remove-Item Env:\UAPP_E2E_BRIDGE_SCREENSHOT -ErrorAction SilentlyContinue } else { $env:UAPP_E2E_BRIDGE_SCREENSHOT = $prevBridgeShot }
    if ($null -eq $prevBridgeShotWidth) { Remove-Item Env:\UAPP_E2E_BRIDGE_SCREENSHOT_MAX_WIDTH -ErrorAction SilentlyContinue } else { $env:UAPP_E2E_BRIDGE_SCREENSHOT_MAX_WIDTH = $prevBridgeShotWidth }
}

# **エージェントの停止と成否合成は、証跡収集・ダッシュボード送信より前に行う**
Stop-OsAgentAndFoldResult
if ($script:agentFailed -and $testExit -eq 0) {
    Write-Warning "pytest は成功しましたが OS エージェントが異常終了したため失敗として扱います"
    $testExit = 1
}

# --------------------------------------------------------------- 失敗証跡
if ($testExit -ne 0) {
    $failureDir = Join-UappPath $buildsDir "failure"
    New-Item -ItemType Directory -Force $failureDir | Out-Null
    try {
        if ($isDevice) {
            # 実機は simctl の io / log show が使えない。devicectl でデバイス情報だけ残す
            # （スクリーンショットの取得手段は未整備＝issue #27 に残す）
            & $xcrun devicectl device info details --device $udid *> (Join-UappPath $failureDir "ios-device-info.txt")
            Write-Host "失敗証跡: $failureDir（ios-device-info.txt。実機のスクショ・ログ収集は未整備）"
            $collected = $true
        }
        if (-not $isDevice) {
        & $xcrun simctl io $udid screenshot (Join-UappPath $failureDir "ios-screen.png") 2>$null | Out-Null
        & $xcrun simctl spawn $udid log show --last 5m --predicate "processImagePath CONTAINS `"$((Split-Path $App -Leaf) -replace '\.app$','')`"" *> (Join-UappPath $failureDir "ios-unity-log.txt")
        Write-Host "失敗証跡: $failureDir（ios-screen.png / ios-unity-log.txt）"
        }
    } catch {
        Write-Warning "失敗証跡の収集に失敗しました（$($_.Exception.Message)）"
    }
}

# ダッシュボードが導入されていれば記録（無ければ no-op）
$emitHelper = Join-UappPath $PSScriptRoot "emit-status.ps1"
if (Test-Path -LiteralPath $emitHelper -PathType Leaf) {
    . $emitHelper
    $counts = $null
    try {
        $suite = (Select-Xml -Path $junit -XPath "//testsuite").Node
        if ($suite) {
            $counts = @{
                tests = [int]$suite.tests; failures = [int]$suite.failures
                errors = [int]$suite.errors; skipped = [int]$suite.skipped
            }
        }
    } catch { }
    $data = @{ target = $(if ($isDevice) { "iOSDevice" } else { "iOSSimulator" })
               project = $projectName; exitCode = $testExit; junitPath = $junit }
    if ($counts) { $counts.GetEnumerator() | ForEach-Object { $data[$_.Key] = $_.Value } }
    Send-DashEvent -Kind "evidence.e2e" -StartPath $root -Data $data
}

}
finally {
    # **端末の排他は最後に返す**（この時点でアプリの配備・テスト・後始末はすべて終わっている）
    if ($script:deviceMutex) {
        try { $script:deviceMutex.ReleaseMutex() } catch { }
        $script:deviceMutex.Dispose()
        $script:deviceMutex = $null
    }
    # **このスクリプトが張ったトンネルは必ず落とす**
    if ($tunnelProc) {
        Stop-UappProcessTree -ProcessId $tunnelProc.Id
        Write-Host "USB トンネルを停止しました (localhost:$HostPort)"
    }
    # 例外で本文を抜けた場合の保険（正常系では pytest 直後に済んでいる。冪等なので二重呼び出し可）
    Stop-OsAgentAndFoldResult
}

$label = if ($isDevice) { "iOS 実機" } else { "iOS シミュレータ" }
if ($testExit -eq 0) { Write-Host "[$projectName] $label E2E 成功" }
else { Write-Host "[$projectName] $label E2E 失敗 (exit=$testExit)" }
exit $testExit
