# Android エミュレーターを起動し、ブート完了まで待機する。複数AVDの同時起動に対応。
# AVD 名は -Avd 引数 → config\local.json の avd の順で解決。
# 使い方: .\scripts\start-emulator.ps1 [-Avd <名前>]
#   例（3台同時）: それぞれ別のAVD名で3回実行する
param(
    [string]$Avd
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "uapp-platform.ps1")   # OS 差分の吸収（Windows / macOS。mac は暫定・未検証）
$root = (Resolve-Path -LiteralPath (Join-UappPath $PSScriptRoot "..")).Path

if (-not $Avd) {
    $localConfig = Join-UappPath $root "config\local.json"
    if (Test-Path -LiteralPath $localConfig) {
        $Avd = (Get-Content -LiteralPath $localConfig -Raw | ConvertFrom-Json).avd
    }
    if (-not $Avd) { throw "AVD が未指定です（config\local.json の avd か -Avd 引数で指定）" }
}

# emulator の実体（Windows は emulator.exe / mac は emulator）。SDK の場所は
# ANDROID_HOME → ANDROID_SDK_ROOT → OS 既定（mac は ~/Library/Android/sdk）の順で解決する
$emulator = Get-UappAndroidTool -Name emulator
if (-not $emulator) {
    throw ("emulator が見つかりません（ANDROID_HOME / ANDROID_SDK_ROOT を設定するか、" +
           "Android SDK の emulator を導入してください）")
}

# adb が PATH に無ければ SDK の platform-tools を PATH へ足す（mac では通っていないことが多い）
$adbPathAdded = Initialize-UappAndroidPath
if ($adbPathAdded) { Write-Host "adb を PATH に追加しました: $adbPathAdded" }
# 解決した実体を保持して以降は `& $script:adbExe` で呼ぶ（同名の関数・エイリアスに入らないため）
$script:adbExe = Get-UappCommandPath "adb"
if (-not $script:adbExe) {
    throw "adb が見つかりません（Android SDK Platform-Tools を PATH に追加してください）"
}

# **列挙の失敗を「1 台も無い」に化けさせない**（adb server の異常などで空になると、
# 起動済みのエミュレーターを見落として二重起動しにいく）。
# **初回もポーリングも同じ関数を通す**（片方だけ厳格にしても意味がない）
function Get-EmulatorSerial {
    param([string]$StatePattern = "^emulator-\d+\s+device")
    $output = @(& $script:adbExe devices)
    if ($LASTEXITCODE -ne 0) {
        throw "adb devices が失敗しました（終了コード $LASTEXITCODE）。adb server の状態を確認してください"
    }
    return @($output -match $StatePattern | ForEach-Object { ($_ -split "\s+")[0] })
}

# この AVD が既に起動しているかをシリアル単位で確認（他のAVDが起動していても妨げない）
$serials = Get-EmulatorSerial
# **名前が取れなかったことを「別の AVD」と解釈しない**。空文字に倒すと、起動済みの
# 同じ AVD をもう一度起動しにいって重複起動エラーか 5 分待ちになる（判定が反転する握り潰し）
foreach ($serial in $serials) {
    $name = $null
    foreach ($attempt in 1..2) {
        $raw = (& $script:adbExe -s $serial emu avd name 2>$null | Select-Object -First 1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $raw) { $name = $raw; break }
        if ($attempt -eq 1) { Start-Sleep -Seconds 1 }   # 起動直後は console がまだ応答しないことがある
    }
    if ($null -eq $name) {
        Write-Warning ("$serial の AVD 名を取得できませんでした。" +
                       "この端末が '$Avd' かどうか判定できないため、二重起動を避けて中止します" +
                       "（`adb -s $serial emu avd name` を手で確認してください）")
        exit 1
    }
    if ($name -eq $Avd) {
        Write-Host "AVD '$Avd' は既に起動しています: $serial"
        exit 0
    }
}

Write-Host "エミュレーター '$Avd' を起動します..."
$before = @($serials)
Start-Process -FilePath $emulator -ArgumentList "-avd", $Avd

# 新しく現れたシリアルを特定してブート完了を待つ
Write-Host "ブート完了を待機中..."
$deadline = (Get-Date).AddMinutes(5)
$newSerial = $null
while ((Get-Date) -lt $deadline) {
    $now = Get-EmulatorSerial -StatePattern "^emulator-\d+\s+"   # 失敗は即座に例外（5 分待って誤診しない）
    $newSerial = $now | Where-Object { $before -notcontains $_ } | Select-Object -First 1
    if ($newSerial) {
        $boot = (& $script:adbExe -s $newSerial shell getprop sys.boot_completed 2>$null | Out-String).Trim()
        if ($boot -eq "1") {
            Write-Host "ブート完了: $newSerial（AVD: $Avd）"
            exit 0
        }
    }
    Start-Sleep -Seconds 3
}
throw "5分以内にブートが完了しませんでした（AVD: $Avd）"
