# E2EBridge と E2E キット一式を既存の Unity プロジェクトへ導入する。
# 使い方: .\install-to-project.ps1 -ProjectPath <Unityプロジェクトのパス> [-IncludeSampleTests]
# 実行元は 配布キット（package-kit.ps1 が生成した zip の展開先）/ 開発リポジトリ のどちらでもよい（自動判定）。
# 導入後の手動手順（パッケージ追加・define付与）は最後に表示される。詳細: docs/05-install-to-project.md
param(
    [Parameter(Mandatory = $true)][string]$ProjectPath,
    [switch]$IncludeSampleTests
)

$ErrorActionPreference = "Stop"

# キット所有ファイル（=上書き更新の対象）の列挙。改変検知マニフェストとバックアップで共用する。
# プロジェクト所有（e2e-config.json / conftest.py / 自作テスト / config\local.json / Builds\）は含めない。
function Get-KitOwnedFiles($target) {
    $kit = Join-Path $target "uapp_e2e"
    $paths = @()
    foreach ($dir in @((Join-Path $target "Assets\uapp_e2e\E2EBridge"),
                       (Join-Path $kit "scripts"),
                       (Join-Path $kit "driver\e2e_driver"),
                       (Join-Path $kit "docs"),
                       (Join-Path $target ".claude\skills"))) {
        if (Test-Path $dir) {
            $paths += Get-ChildItem $dir -Recurse -File | Where-Object { $_.FullName -notmatch "__pycache__" } | ForEach-Object { $_.FullName }
        }
    }
    foreach ($f in @((Join-Path $target "Assets\uapp_e2e\E2EBridge.meta"),
                     (Join-Path $kit "driver\pytest.ini"),
                     (Join-Path $kit "driver\requirements.txt"),
                     (Join-Path $kit "driver\tests\test_journey_unit.py"),
                     (Join-Path $kit "driver\tests\test_adb_ui.py"),
                     (Join-Path $kit "driver\tests\test_client_unit.py"),
                     (Join-Path $kit "config\local.sample.json"),
                     (Join-Path $kit "config\e2e-config.sample.json"),
                     (Join-Path $kit "CLAUDE.md"),
                     (Join-Path $kit "SETUP.md"),
                     (Join-Path $kit "VERSION"),
                     (Join-Path $target ".claude\rules\uapp-e2e.md"))) {
        if (Test-Path $f) { $paths += $f }
    }
    $paths
}

# --- 実行元レイアウトの自動判定 ---
#   配布キット:     <kit>\install-to-project.ps1（自己完結。bridge\E2EBridge が同階層にある）
#   開発リポジトリ: scripts\install-to-project.ps1（計装マスターは unity-nis）
if (Test-Path (Join-Path $PSScriptRoot "bridge\E2EBridge")) {
    $root = $PSScriptRoot
    $src = @{
        Bridge      = Join-Path $root "bridge\E2EBridge"
        BridgeMeta  = Join-Path $root "bridge\E2EBridge.meta"
        Scripts     = Join-Path $root "scripts"
        Driver      = Join-Path $root "driver"
        SampleTests = Join-Path $root "driver\sample-tests"
        Config      = Join-Path $root "config"
        Doc02       = Join-Path $root "docs\02-protocol.md"
        Doc05       = Join-Path $root "docs\05-install-to-project.md"
        Doc07       = Join-Path $root "docs\07-viewer.md"
        AiLoop      = Join-Path $root "docs\ai-loop.md"
        ClaudeMd    = Join-Path $root "CLAUDE.md"
        SetupMd     = Join-Path $root "SETUP.md"
        Skills      = Join-Path $root "skills"
        Rules       = Join-Path $root "rules"
        Version     = Join-Path $root "VERSION"
    }
    Write-Host "実行元: 配布キット ($root)"
}
elseif (Test-Path (Join-Path $PSScriptRoot "..\unity-nis\Assets\uapp_e2e\E2EBridge")) {
    $root = (Resolve-Path "$PSScriptRoot\..").Path
    $src = @{
        Bridge      = Join-Path $root "unity-nis\Assets\uapp_e2e\E2EBridge"
        BridgeMeta  = Join-Path $root "unity-nis\Assets\uapp_e2e\E2EBridge.meta"
        Scripts     = Join-Path $root "scripts"
        Driver      = Join-Path $root "driver"
        SampleTests = Join-Path $root "driver\tests"
        Config      = Join-Path $root "config"
        Doc02       = Join-Path $root "docs\02-protocol.md"
        Doc05       = Join-Path $root "docs\05-install-to-project.md"
        Doc07       = Join-Path $root "docs\07-viewer.md"
        AiLoop      = Join-Path $root "kit\docs\ai-loop.md"
        ClaudeMd    = Join-Path $root "kit\CLAUDE.md"
        SetupMd     = Join-Path $root "kit\SETUP.md"
        Skills      = Join-Path $root "kit\skills"
        Rules       = Join-Path $root "kit\rules"
        Version     = Join-Path $root "kit\VERSION"
    }
    Write-Host "実行元: 開発リポジトリ ($root)"
}
else {
    throw "実行元レイアウトを判定できません（bridge\E2EBridge も ..\unity-nis も見つからない）: $PSScriptRoot"
}

$target = (Resolve-Path $ProjectPath).Path

# Unity プロジェクトであることの検証
if (-not ((Test-Path (Join-Path $target "Assets")) -and (Test-Path (Join-Path $target "ProjectSettings")))) {
    throw "Unity プロジェクトではありません（Assets/ProjectSettings が見つからない）: $target"
}

Write-Host "導入先: $target"

# --- 0. 更新時バックアップ（既導入の場合のみ） ---
# 上書き対象（キット所有領域）を uapp_e2e\Builds\update-backup-<日時>.zip へ退避する。
# Builds\（ジャーニー記録・過去バックアップ・APK）は容量が大きく、かつ上書き対象外なので含めない。
$kit = Join-Path $target "uapp_e2e"
if (Test-Path $kit) {
    $backupPaths = @(Get-ChildItem $kit -Exclude "Builds" | ForEach-Object { $_.FullName })
    foreach ($p in @((Join-Path $target "Assets\uapp_e2e"),
                     (Join-Path $target ".claude\skills"),
                     (Join-Path $target ".claude\rules\uapp-e2e.md"))) {
        if (Test-Path $p) { $backupPaths += $p }
    }
    if ($backupPaths.Count -gt 0) {
        # ミリ秒まで含める（同一秒内の連続実行で名前が衝突して Compress-Archive が失敗するため）
        $backupZip = Join-Path $kit ("Builds\update-backup-" + (Get-Date -Format "yyyyMMdd-HHmmss-fff") + ".zip")
        New-Item -ItemType Directory -Force (Split-Path $backupZip) | Out-Null
        Compress-Archive -Path $backupPaths -DestinationPath $backupZip
        Write-Host "  [OK] 更新前バックアップ: $backupZip"
    }

    # --- 0.5 ローカル改変の検知 ---
    # 前回導入時に記録したハッシュ（kit-manifest.json）と現状を照合し、
    # 導入先で独自改修されたキット所有ファイル（例: viewer.html のカスタマイズ）を警告する。
    $manifestPath = Join-Path $kit "kit-manifest.json"
    if (Test-Path $manifestPath) {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $modified = @()
        foreach ($entry in $manifest.PSObject.Properties) {
            $full = Join-Path $target $entry.Name
            if (-not (Test-Path $full)) { $modified += "$($entry.Name)（削除されている）"; continue }
            if ((Get-FileHash $full -Algorithm SHA256).Hash -ne $entry.Value) { $modified += $entry.Name }
        }
        if ($modified.Count -gt 0) {
            Write-Host ""
            Write-Host "  [警告] 前回導入後にローカル改変されたキット所有ファイルを検知（このまま上書き更新します）:"
            foreach ($m in $modified) { Write-Host "    - $m" }
            Write-Host "  改変内容は上のバックアップzipに退避済み。恒久化したい変更は差分を確認してキット側へ還元すること"
            Write-Host ""
        }
    }
}

# --- 1. 計装 SDK（ベンダー名前空間付き: Assets\uapp_e2e\E2EBridge） ---
$bridgeDest = Join-Path $target "Assets\uapp_e2e\E2EBridge"
robocopy $src.Bridge $bridgeDest /E /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { throw "E2EBridge のコピーに失敗 (robocopy exit=$LASTEXITCODE)" }
Copy-Item $src.BridgeMeta (Join-Path $target "Assets\uapp_e2e\E2EBridge.meta") -ErrorAction SilentlyContinue
Write-Host "  [OK] Assets\uapp_e2e\E2EBridge（計装SDK）"

# --- 2. E2E キット（scripts / driver / config テンプレ） ---
$kit = Join-Path $target "uapp_e2e"
foreach ($dir in @("scripts", "config")) {
    New-Item -ItemType Directory -Force (Join-Path $kit $dir) | Out-Null
}
foreach ($script in @("build-android.ps1", "run-e2e.ps1", "start-emulator.ps1")) {
    Copy-Item (Join-Path $src.Scripts $script) (Join-Path $kit "scripts\$script") -Force
}
robocopy (Join-Path $src.Driver "e2e_driver") (Join-Path $kit "driver\e2e_driver") /E /XD __pycache__ /NFL /NDL /NJH /NJS | Out-Null
Copy-Item (Join-Path $src.Driver "pytest.ini") (Join-Path $kit "driver\pytest.ini") -Force
Copy-Item (Join-Path $src.Driver "requirements.txt") (Join-Path $kit "driver\requirements.txt") -Force
New-Item -ItemType Directory -Force (Join-Path $kit "driver\tests") | Out-Null
# conftest.py は初回のみ生成（プロジェクトが拡張し得るため上書きしない。
# キット機能の更新は driver\e2e_driver\ の差し替えで届く。docs\07 の更新ランブック参照）
$conftestDest = Join-Path $kit "driver\tests\conftest.py"
if (-not (Test-Path $conftestDest)) {
    Copy-Item (Join-Path $src.Driver "tests\conftest.py") $conftestDest
} else {
    Write-Host "  [SKIP] driver\tests\conftest.py（既存を維持）"
}
foreach ($t in @("test_journey_unit.py", "test_adb_ui.py", "test_client_unit.py")) {
    Copy-Item (Join-Path $src.Driver "tests\$t") (Join-Path $kit "driver\tests\$t") -Force
}
if ($IncludeSampleTests) {
    # サンプルテストは「コピペして育てる」起点なので初回のみ生成（プロジェクトの改修を上書きしない）
    foreach ($t in @("test_smoke.py", "test_ngui_nis.py", "test_ngui_legacy.py")) {
        $sampleDest = Join-Path $kit "driver\tests\$t"
        if (-not (Test-Path $sampleDest)) {
            Copy-Item (Join-Path $src.SampleTests $t) $sampleDest
        } else {
            Write-Host "  [SKIP] driver\tests\$t（既存を維持）"
        }
    }
}
Copy-Item (Join-Path $src.Config "local.sample.json") (Join-Path $kit "config\local.sample.json") -Force
Write-Host "  [OK] uapp_e2e\（scripts / driver / config テンプレ）"

# --- 2.5 ドキュメントと AI 向け運用ガイド ---
New-Item -ItemType Directory -Force (Join-Path $kit "docs") | Out-Null
Copy-Item $src.Doc02 (Join-Path $kit "docs\02-protocol.md") -Force
Copy-Item $src.Doc05 (Join-Path $kit "docs\05-install-to-project.md") -Force
Copy-Item $src.Doc07 (Join-Path $kit "docs\07-viewer.md") -Force
Copy-Item $src.AiLoop (Join-Path $kit "docs\ai-loop.md") -Force
Copy-Item $src.ClaudeMd (Join-Path $kit "CLAUDE.md") -Force
Copy-Item $src.SetupMd (Join-Path $kit "SETUP.md") -Force
Copy-Item $src.Version (Join-Path $kit "VERSION") -Force
$installedVersion = (Get-Content (Join-Path $kit "VERSION") -TotalCount 1).Trim()
Write-Host "  [OK] uapp_e2e\docs\ + CLAUDE.md（AI向け運用ガイド） + VERSION=$installedVersion"

# --- 2.6 Claude Code スキル（.claude\skills へ配置） ---
$skillsDest = Join-Path $target ".claude\skills"
New-Item -ItemType Directory -Force $skillsDest | Out-Null
robocopy $src.Skills $skillsDest /E /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { throw "スキルのコピーに失敗 (robocopy exit=$LASTEXITCODE)" }
Write-Host "  [OK] .claude\skills\（/e2e-setup /e2e-run /e2e-write-test /e2e-dump）"

# --- 2.7 Claude Code ルール（軽量ポインタ。対象プロジェクトの CLAUDE.md は書き換えない） ---
$rulesDest = Join-Path $target ".claude\rules"
New-Item -ItemType Directory -Force $rulesDest | Out-Null
Copy-Item (Join-Path $src.Rules "uapp-e2e.md") (Join-Path $rulesDest "uapp-e2e.md") -Force
Write-Host "  [OK] .claude\rules\uapp-e2e.md（uapp_e2e\CLAUDE.md への参照ルール）"

# --- 3. e2e-config.json（無ければテンプレから生成） ---
$configDest = Join-Path $kit "e2e-config.json"
$configExisted = Test-Path $configDest
if (-not $configExisted) {
    Copy-Item (Join-Path $src.Config "e2e-config.sample.json") $configDest
    Write-Host "  [OK] e2e-config.json（テンプレから生成 → package 等を編集してください）"
} else {
    Write-Host "  [SKIP] e2e-config.json（既存を維持）"
}

# --- 4. 改変検知用マニフェスト（今回導入したキット所有ファイルのハッシュ）を記録 ---
$manifestEntries = [ordered]@{}
foreach ($f in (Get-KitOwnedFiles $target | Sort-Object)) {
    $rel = $f.Substring($target.Length + 1)
    $manifestEntries[$rel] = (Get-FileHash $f -Algorithm SHA256).Hash
}
$manifestEntries | ConvertTo-Json | Set-Content (Join-Path $kit "kit-manifest.json") -Encoding utf8
Write-Host "  [OK] uapp_e2e\kit-manifest.json（次回更新時のローカル改変検知用）"

# --- 5. 残りの手動手順の表示（検出できる項目は導入状況を照合して [済]/[未] を付ける） ---
function Get-ManifestDependencyVersion($name) {
    $manifestJson = Join-Path $target "Packages\manifest.json"
    if (-not (Test-Path $manifestJson)) { return $null }
    try { (Get-Content $manifestJson -Raw | ConvertFrom-Json).dependencies.$name } catch { $null }
}
function Mark($done) { if ($done) { "[済]" } else { "[未]" } }
$inputSystemVer = Get-ManifestDependencyVersion "com.unity.inputsystem"
$newtonsoftVer = Get-ManifestDependencyVersion "com.unity.nuget.newtonsoft-json"
$projSettings = Join-Path $target "ProjectSettings\ProjectSettings.asset"
# Android 向けの define だけを対象に検出する（Standalone 等の他ターゲットのみへの付与は
# asmdef の defineConstraints を満たさず APK にブリッジが入らないため [済] にしない）。
# YAML を行単位で走査し、scriptingDefineSymbols: キー自身よりも深いインデントの行だけを
# ブロックとみなす（同じか浅いインデントで打ち切り。後続の別ブロックの Android: 行を拾わない）。
# キーは Android:（旧シリアライズ形式の数値キー 7: も許容）、シンボル名は両側語境界つきで照合
# （NOT_UAPP_E2E_BRIDGE / UAPP_E2E_BRIDGE_XXX に誤反応しない）
$defineFound = $false
if (Test-Path $projSettings) {
    $keyIndent = $null
    foreach ($line in (Get-Content $projSettings)) {
        if ($null -eq $keyIndent) {
            if ($line -match '^([ \t]*)scriptingDefineSymbols:\s*$') { $keyIndent = $Matches[1].Length }
            continue
        }
        if ($line -notmatch '^([ \t]*)\S') { continue }
        if ($Matches[1].Length -le $keyIndent) { break }  # ブロック終端
        if ($line -match '^\s*(Android|7):.*(^|[^A-Za-z0-9_])UAPP_E2E_BRIDGE($|[^A-Za-z0-9_])') {
            $defineFound = $true
            break
        }
    }
}
$localJsonDone = Test-Path (Join-Path $kit "config\local.json")
$gitignorePath = Join-Path $target ".gitignore"
# 行単位で照合（コメント行や uapp_e2e/Builds-old のような別パスに誤反応しない。
# 区切りは / のみ受理: gitignore のバックスラッシュはパス区切りでなくエスケープなので無効な記述。
# 行頭空白もパターンの一部として扱われるため許容しない。末尾空白は Git が無視するので許容）
$gitignoreDone = (Test-Path $gitignorePath) -and
    (Select-String -Path $gitignorePath -Pattern '^/?uapp_e2e/config/local\.json\s*$' -Quiet) -and
    (Select-String -Path $gitignorePath -Pattern '^/?uapp_e2e/Builds/?\s*$' -Quiet)
# e2e-config.json は「存在」でなく「編集済み」で判定する:
# package が雛形のままでない かつ tests の指すパスが実在する（-IncludeSampleTests なし導入だと
# 既定の tests/test_smoke.py は配置されないため、package だけ直して [済] になる偽陽性を防ぐ）。
# orientation は実アプリと突き合わせできないため自動確認の対象外。
$configEdited = $false
if ($configExisted) {
    try {
        $cfg = Get-Content $configDest -Raw | ConvertFrom-Json
        $testsPath = if ($cfg.tests) { Join-Path $kit "driver\$($cfg.tests)" } else { $null }
        $configEdited = $cfg.package -and ($cfg.package -ne "com.yourcompany.yourapp") -and
            $testsPath -and (Test-Path $testsPath)
    } catch { $configEdited = $false }
}

Write-Host ""
Write-Host "=== 残りの手動手順（[済]=導入済みを検出。詳細: docs/05-install-to-project.md） ==="
Write-Host "1. Packages/manifest.json に以下を追加（Unityバージョンに応じて）:"
Write-Host "     $(Mark $inputSystemVer) com.unity.inputsystem（2022.3系:1.7.0 / Unity6系:1.14+）$(if ($inputSystemVer) { " → $inputSystemVer 導入済み" })"
Write-Host "     $(Mark $newtonsoftVer) com.unity.nuget.newtonsoft-json: 3.2.1$(if ($newtonsoftVer) { " → $newtonsoftVer 導入済み" })（既存 Newtonsoft DLL があれば不要）"
Write-Host "2. $(Mark $configEdited) $configDest の package / tests / orientation を実アプリに合わせて編集$(if ($configEdited) { "（package 設定済み・tests 実在。orientation は自動確認外）" })"
Write-Host "3. $(Mark $defineFound) テスト用ビルドに UAPP_E2E_BRIDGE define を付与（検出対象は Player Settings の Android 向け define のみ。"
Write-Host "     自前ビルドスクリプト側で付与する構成は ProjectSettings に現れないため [未] 表示のままでよい）"
Write-Host "4. $(Mark $localJsonDone) uapp_e2e\config\local.sample.json を local.json にコピーして各自の環境を記入"
Write-Host "5. $(Mark $gitignoreDone) .gitignore に追加: uapp_e2e/config/local.json, uapp_e2e/Builds/"
Write-Host "（AI向け規約は .claude\rules\uapp-e2e.md 経由で自動参照される。CLAUDE.md の書き換えは不要）"
exit 0  # robocopy の成功コード(1〜7)を漏らさない
