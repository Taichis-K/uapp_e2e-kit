# Android エミュレーターを起動し、ブート完了まで待機する。複数AVDの同時起動に対応。
# AVD 名は -Avd 引数 → config\local.json の avd の順で解決。
# 使い方: .\scripts\start-emulator.ps1 [-Avd <名前>]
#   例（3台同時）: それぞれ別のAVD名で3回実行する
param(
    [string]$Avd
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path "$PSScriptRoot\..").Path

if (-not $Avd) {
    $localConfig = Join-Path $root "config\local.json"
    if (Test-Path $localConfig) {
        $Avd = (Get-Content $localConfig -Raw | ConvertFrom-Json).avd
    }
    if (-not $Avd) { throw "AVD が未指定です（config\local.json の avd か -Avd 引数で指定）" }
}

$emulator = Join-Path $env:ANDROID_HOME "emulator\emulator.exe"
if (-not (Test-Path $emulator)) { throw "emulator.exe が見つかりません: $emulator" }

# この AVD が既に起動しているかをシリアル単位で確認（他のAVDが起動していても妨げない）
$serials = (adb devices) -match "^emulator-\d+\s+device" | ForEach-Object { ($_ -split "\s+")[0] }
foreach ($serial in $serials) {
    $name = (adb -s $serial emu avd name 2>$null | Select-Object -First 1 | Out-String).Trim()
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
    $now = (adb devices) -match "^emulator-\d+\s+" | ForEach-Object { ($_ -split "\s+")[0] }
    $newSerial = $now | Where-Object { $before -notcontains $_ } | Select-Object -First 1
    if ($newSerial) {
        $boot = (adb -s $newSerial shell getprop sys.boot_completed 2>$null | Out-String).Trim()
        if ($boot -eq "1") {
            Write-Host "ブート完了: $newSerial（AVD: $Avd）"
            exit 0
        }
    }
    Start-Sleep -Seconds 3
}
throw "5分以内にブートが完了しませんでした（AVD: $Avd）"
