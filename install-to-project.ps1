# E2EBridge と E2E キット一式を既存の Unity プロジェクトへ導入する。
# 使い方: .\install-to-project.ps1 -ProjectPath <Unityプロジェクトのパス> [-Agents claude|codex|both] [-IncludeSampleTests] [-RootAgentsMd]
# 実行元は 配布キット（package-kit.ps1 が生成した zip の展開先）/ 開発リポジトリ のどちらでもよい（自動判定）。
# -Agents: 配置する AI エージェント導線の選択（既定 both）。
#          claude = .claude\skills + .claude\rules\uapp-e2e.md
#          codex  = .agents\skills + uapp_e2e\AGENTS.md + ルート AGENTS.md の案内/-RootAgentsMd
#          再実行すれば後から追加できる（例: claude 導入済みへ -Agents codex）。
#          既配置分の自動削除はしない（外し方は docs/05 のアンインストール参照）
# -RootAgentsMd: プロジェクトルートに AGENTS.md（Codex 等向けポインタ）が無い場合のみ新規作成する
#                （既存の AGENTS.md は変更しない。省略時はスニペット案内のみ。-Agents claude では無効）
# 導入後の手動手順（パッケージ追加・define付与）は最後に表示される。詳細: docs/05-install-to-project.md
param(
    [Parameter(Mandatory = $true)][string]$ProjectPath,
    [ValidateSet("claude", "codex", "both")][string]$Agents = "both",
    # 運用モード。editor はエディタ直結E2Eだけで回す構成（Android を使わない）:
    # define の検出対象を Standalone にし、package / activity / avd を必須扱いから外す。
    # デスクトップ向けや「まずエディタだけで回す」立ち上げ期はこちら
    [ValidateSet("editor", "device", "both")][string]$Mode = "both",
    [switch]$IncludeSampleTests,
    [switch]$RootAgentsMd
)

$ErrorActionPreference = "Stop"

$installClaude = $Agents -in @("claude", "both")
$installCodex = $Agents -in @("codex", "both")

# キット所有ファイル（=上書き更新の対象）の列挙。改変検知マニフェストとバックアップで共用する。
# プロジェクト所有（e2e-config.json / conftest.py / 自作テスト / config\local.json / Builds\）は含めない。
function Get-KitOwnedFiles($target) {
    $kit = Join-Path $target "uapp_e2e"
    $paths = @()
    # スキルはキットの e2e-* の4つのみ（skills\ 全体を列挙するとユーザーの無関係スキルまで
    # 「キット所有」として改変検知の警告対象になってしまう。uninstall.ps1 の削除対象とも同期）
    $skillDirs = @()
    foreach ($skillsRoot in @(".claude\skills", ".agents\skills")) {
        foreach ($name in @("e2e-setup", "e2e-run", "e2e-write-test", "e2e-dump")) {
            $skillDirs += Join-Path $target "$skillsRoot\$name"
        }
    }
    foreach ($dir in (@((Join-Path $target "Assets\uapp_e2e\E2EBridge"),
                        (Join-Path $kit "scripts"),
                        (Join-Path $kit "driver\e2e_driver"),
                        (Join-Path $kit "docs")) + $skillDirs)) {
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
                     (Join-Path $kit "driver\tests\test_bridge_smoke.py"),
                     (Join-Path $kit "config\local.sample.json"),
                     (Join-Path $kit "config\e2e-config.sample.json"),
                     (Join-Path $kit "CLAUDE.md"),
                     (Join-Path $kit "AGENTS.md"),
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
        AgentsMd    = Join-Path $root "AGENTS.md"
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
        AgentsMd    = Join-Path $root "kit\AGENTS.md"
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
# 前回導入時にキットが所有していたファイル一覧（新規導入では $null のまま）
$prevOwned = $null
if (Test-Path $kit) {
    $backupPaths = @(Get-ChildItem $kit -Exclude "Builds" | ForEach-Object { $_.FullName })
    foreach ($p in @((Join-Path $target "Assets\uapp_e2e"),
                     (Join-Path $target ".claude\skills"),
                     (Join-Path $target ".agents\skills"),
                     (Join-Path $target ".claude\rules\uapp-e2e.md"))) {
        if (Test-Path $p) { $backupPaths += $p }
    }
    if ($backupPaths.Count -gt 0) {
        # ミリ秒まで含める（同一秒内の連続実行で名前が衝突して圧縮が失敗するため）
        $backupZip = Join-Path $kit ("Builds\update-backup-" + (Get-Date -Format "yyyyMMdd-HHmmss-fff") + ".zip")
        New-Item -ItemType Directory -Force (Split-Path $backupZip) | Out-Null
        # zip内は導入先ルートからの相対パスを保つ（Compress-Archive に複数パスを直接渡すと
        # 末端名で格納され .claude\skills と .agents\skills が同名衝突して復元不能になるため、
        # ステージングへ相対パス付きで複製してからディレクトリごと圧縮する）
        # ステージングは TEMP でなく Builds\ 配下（gitignore 済み）: サンドボックス環境では TEMP が
        # 8.3 短縮パスで渡り、Move-Item / Remove-Item が抑止不能の失敗になる（導入先で実測）
        $backupStage = Join-Path $kit ("Builds\tmp-backup-" + [System.IO.Path]::GetRandomFileName())
        try {
            foreach ($p in $backupPaths) {
                $dest = Join-Path $backupStage $p.Substring($target.Length + 1)
                New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
                Copy-Item $p $dest -Recurse
            }
            [System.IO.Compression.ZipFile]::CreateFromDirectory($backupStage, $backupZip)
        } finally {
            if (Test-Path $backupStage) { Remove-Item $backupStage -Recurse -Force }
        }
        Write-Host "  [OK] 更新前バックアップ: $backupZip"
    }

    # --- 0.5 ローカル改変の検知 ---
    # 前回導入時に記録したハッシュ（kit-manifest.json）と現状を照合し、
    # 導入先で独自改修されたキット所有ファイル（例: viewer.html のカスタマイズ）を警告する。
    $manifestPath = Join-Path $kit "kit-manifest.json"
    if (Test-Path $manifestPath) {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        # 「前回の導入でキットが所有していたファイル」の一覧。
        # キットが新しく所有し始めた名前と、導入先の自作ファイルとの衝突判定に使う
        $prevOwned = @($manifest.PSObject.Properties.Name)
        $modified = @()
        foreach ($entry in $manifest.PSObject.Properties) {
            if ($entry.Name -like "__*") { continue }  # ファイルでないメタ記録（__rootAgentsMdByInstaller 等）
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
# Builds\ は導入直後から在る前提の置き場（ジャーニー記録・失敗証跡・一時ファイル）。
# **無いと pytest の `--basetemp ..\Builds\pytest-tmp`（SETUP.md がサンドボックス環境向けに
# 案内している回避策）が「親が無い」で落ちる**。gitignore 対象なので作っても追跡はされない
New-Item -ItemType Directory -Force (Join-Path $kit "Builds") | Out-Null
# **配るスクリプトを列挙しない**。v0.1.6 で追加した unity-editor-status.ps1 が
# この列挙から漏れ、キットの CLAUDE.md が案内するコマンドが導入先に存在しない状態になった
# （エラーにならず静かに欠けるので、AI が実行して「ファイルが無い」で初めて気づく）。
# 配布キットから実行する場合、scripts\ の中身はそれ自体が配布対象。開発リポジトリから
# 実行する場合だけ、**導入先では使わない開発専用スクリプト**を除く（除外は増えにくく、
# 配布対象が増えたときは何もしなくても届く＝同じ漏れ方をしない）
$devOnlyScripts = @("install-to-project.ps1", "package-kit.ps1", "publish-kit.ps1", "verify-all.ps1")
foreach ($script in (Get-ChildItem (Join-Path $src.Scripts "*.ps1") |
                     Where-Object { $devOnlyScripts -notcontains $_.Name })) {
    Copy-Item $script.FullName (Join-Path $kit "scripts\$($script.Name)") -Force
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
# キット所有のテストは上書き更新する。ただし**キットが新しく所有し始めた名前**（例: 疎通スモーク）は、
# 旧版ではプロジェクト所有領域だったため、導入先が同名の自作テストを持っていることがある。
# 0.5 のローカル改変検知は「前回もキット所有だったファイル」しか見ないので、そのままだと
# 自作テストが無警告で消える（バックアップzipには残るが、実行ツリーからは失われる）。
# **前回の所有記録が無い場合（手動導入・kit-manifest.json の削除・不完全な導入）も警告する** —
# 「所有していた証拠が無い既存ファイル」は自作テストかもしれず、黙って消してよい根拠が無い
$testNameConflicts = @()
foreach ($t in @("test_journey_unit.py", "test_adb_ui.py", "test_client_unit.py", "test_bridge_smoke.py")) {
    $testDest = Join-Path $kit "driver\tests\$t"
    if ((Test-Path $testDest) -and (($null -eq $prevOwned) -or ($prevOwned -notcontains "uapp_e2e\driver\tests\$t"))) {
        $testNameConflicts += $t
    }
    Copy-Item (Join-Path $src.Driver "tests\$t") $testDest -Force
}
if ($testNameConflicts.Count -gt 0) {
    Write-Host ""
    Write-Host "  [警告] キット所有と記録されていない同名ファイルを上書きしました（このまま更新を続けます）:"
    foreach ($c in $testNameConflicts) { Write-Host "    - uapp_e2e\driver\tests\$c" }
    Write-Host "  キットが新しく所有し始めた名前か、前回の所有記録（kit-manifest.json）が無い導入です。"
    Write-Host "  自作テストだった場合は上のバックアップzipから取り出し、別名で戻すこと"
    Write-Host ""
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
if ($installCodex) {
    Copy-Item $src.AgentsMd (Join-Path $kit "AGENTS.md") -Force
}
Copy-Item $src.SetupMd (Join-Path $kit "SETUP.md") -Force
Copy-Item $src.Version (Join-Path $kit "VERSION") -Force
$installedVersion = (Get-Content (Join-Path $kit "VERSION") -TotalCount 1).Trim()
Write-Host "  [OK] uapp_e2e\docs\ + CLAUDE.md（AI向け運用ガイド）$(if ($installCodex) { " + AGENTS.md（Codex等向けポインタ）" }) + VERSION=$installedVersion"

# --- 2.6 AIスキル（Claude Code: .claude\skills / Codex v0.94.0+: .agents\skills。内容は同一） ---
$skillsDests = @()
if ($installClaude) { $skillsDests += Join-Path $target ".claude\skills" }
if ($installCodex) { $skillsDests += Join-Path $target ".agents\skills" }
foreach ($skillsDest in $skillsDests) {
    New-Item -ItemType Directory -Force $skillsDest | Out-Null
    robocopy $src.Skills $skillsDest /E /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "スキルのコピーに失敗 (robocopy exit=$LASTEXITCODE): $skillsDest" }
}
$skillsLabel = @()
if ($installClaude) { $skillsLabel += ".claude\skills\" }
if ($installCodex) { $skillsLabel += ".agents\skills\" }
Write-Host "  [OK] $($skillsLabel -join " + ")（e2e-setup / e2e-run / e2e-write-test / e2e-dump）"

# --- 2.7 Claude Code ルール（軽量ポインタ。対象プロジェクトの CLAUDE.md は書き換えない） ---
if ($installClaude) {
    $rulesDest = Join-Path $target ".claude\rules"
    New-Item -ItemType Directory -Force $rulesDest | Out-Null
    Copy-Item (Join-Path $src.Rules "uapp-e2e.md") (Join-Path $rulesDest "uapp-e2e.md") -Force
    Write-Host "  [OK] .claude\rules\uapp-e2e.md（uapp_e2e\CLAUDE.md への参照ルール）"
}

# --- 2.8 ルート AGENTS.md（Codex 等向けの発見性向上。オプトイン・既存ファイルは絶対に変更しない） ---
# Codex はルート起動時に uapp_e2e\AGENTS.md を読まない（サブディレクトリ AGENTS.md は
# そこを CWD にした場合のみ読込）ため、ルートへのポインタ配置が発見性の本命になる。
# ただしプロジェクト本体への成果物追加なので、既定では作成せず案内のみ。
if ($RootAgentsMd -and -not $installCodex) {
    Write-Host "  [SKIP] -RootAgentsMd は -Agents codex/both のときのみ有効（今回は -Agents $Agents のため何もしない）"
}
$rootAgentsPath = Join-Path $target "AGENTS.md"
# この生成内容を変更したら uninstall.ps1 の「未編集判定」の期待値も同期すること
$rootAgentsSnippet = @"
## uapp_e2e（E2Eテスト基盤・導入済み）

E2Eテストの作成・実行・デバッグ、計装SDK（``Assets/uapp_e2e/E2EBridge/``）、
エミュレーター/エディタ再生への接続に関わる作業を始める前に、必ず
``uapp_e2e/CLAUDE.md``（エージェント共通の規約・コマンド・失敗解析手順）を読むこと。
セットアップ・修復の入口は ``uapp_e2e/SETUP.md``。
定型作業は ``.agents/skills/e2e-*`` スキル（setup / run / write-test / dump）にある。
"@
$rootAgentsExists = Test-Path $rootAgentsPath
$rootAgentsCreated = $false
if ($installCodex -and $RootAgentsMd -and -not $rootAgentsExists) {
    # BOM付きUTF-8で直接書く（Set-Content の -Encoding utf8BOM は PowerShell 5.1 に無く、
    # UTF8 指定は 5.1=BOM付き/7=BOMなし と挙動が割れるため、バージョン非依存の .NET API を使う）
    [System.IO.File]::WriteAllText($rootAgentsPath, ("# AGENTS.md`r`n`r`n" + $rootAgentsSnippet + "`r`n"),
        (New-Object System.Text.UTF8Encoding $true))
    $rootAgentsCreated = $true
    Write-Host "  [OK] AGENTS.md（ルートに新規作成。Codex 等がルート起動時に E2E 導線を発見できる）"
} elseif ($installCodex -and $RootAgentsMd -and $rootAgentsExists) {
    Write-Host "  [SKIP] AGENTS.md（既存を維持。自動追記はしない — uapp_e2e への言及が無ければ末尾のスニペットを手動統合）"
}

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
# ルート AGENTS.md を「installer が作成した」記録も残す（uninstall -Purge が削除してよいかの
# 判定に使う。ユーザーが元々置いていた同内容ファイルを誤って消さないため）。再実行時は引き継ぐ
$manifestPath = Join-Path $kit "kit-manifest.json"
$prevRootAgentsMarker = $false
if (-not $rootAgentsCreated -and (Test-Path $manifestPath)) {
    try { $prevRootAgentsMarker = [bool]((Get-Content $manifestPath -Raw | ConvertFrom-Json)."__rootAgentsMdByInstaller") } catch {}
}
$manifestEntries = [ordered]@{}
if (($rootAgentsCreated -or $prevRootAgentsMarker) -and (Test-Path $rootAgentsPath)) {
    $manifestEntries["__rootAgentsMdByInstaller"] = $true
}
foreach ($f in (Get-KitOwnedFiles $target | Sort-Object)) {
    $rel = $f.Substring($target.Length + 1)
    $manifestEntries[$rel] = (Get-FileHash $f -Algorithm SHA256).Hash
}
$manifestEntries | ConvertTo-Json | Set-Content $manifestPath -Encoding utf8
Write-Host "  [OK] uapp_e2e\kit-manifest.json（次回更新時のローカル改変検知用）"

# --- 4.5 ドキュメントが案内するスクリプトが実在するかの検査 ---
# キットの文書は `.\scripts\<名前>.ps1` の形でコマンドを案内する。
# **案内しているのに配られていない**と、読んだ AI が実行して初めて「ファイルが無い」と気づく
# （v0.1.6 で実際に起きた: unity-editor-status.ps1 が配布の列挙から漏れていた）。
# 配布の仕組みを列挙から一括コピーへ変えたうえで、食い違いをここでも検出する。
# **見る文書も列挙しない**（同じ漏れ方をする）。AI が読むのは CLAUDE.md / SETUP.md だけでなく、
# docs\ai-loop.md やスキル（.claude\skills / .agents\skills）にも `.\scripts\*.ps1` が出てくる
$docRoots = @((Join-Path $kit "CLAUDE.md"), (Join-Path $kit "AGENTS.md"),
              (Join-Path $kit "SETUP.md"), (Join-Path $kit "docs"),
              (Join-Path $target ".claude\rules\uapp-e2e.md"))
# **スキルはキット所有の e2e-* だけ**を見る（Get-KitOwnedFiles と同じ範囲）。
# skills\ 全体を走査すると、ユーザーの無関係なスキル文書が `scripts\…ps1` に言及しただけで
# 「キットが案内しているのに無い」と誤警告する
foreach ($skillsRoot in @(".claude\skills", ".agents\skills")) {
    foreach ($name in @("e2e-setup", "e2e-run", "e2e-write-test", "e2e-dump")) {
        $docRoots += Join-Path $target "$skillsRoot\$name"
    }
}
$docFiles = @()
foreach ($docRoot in $docRoots) {
    if (-not (Test-Path $docRoot)) { continue }
    if (Test-Path $docRoot -PathType Container) {
        $docFiles += @(Get-ChildItem $docRoot -Recurse -Filter "*.md" -File | ForEach-Object { $_.FullName })
    } else {
        $docFiles += $docRoot
    }
}
$docScriptRefs = @()
foreach ($doc in ($docFiles | Select-Object -Unique)) {
    # **空ファイルで落とさない**。`Get-Content -Raw` は $null を返し、[regex]::Matches が
    # 例外になる（$ErrorActionPreference=Stop なので、ここまでのコピーを済ませた状態で
    # installer 全体が中断する）。検査は付加価値であって、導入を止める理由にしない
    $raw = Get-Content $doc -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($raw)) { continue }
    foreach ($m in [regex]::Matches($raw, 'scripts[\\/]([A-Za-z0-9._-]+\.ps1)')) {
        $docScriptRefs += $m.Groups[1].Value
    }
}
# 開発専用スクリプトは除く。文書は「開発リポジトリから実行する場合」として
# `.\scripts\install-to-project.ps1 …` にも言及するが、これは導入先に置くものではない
$missingDocScripts = @($docScriptRefs | Select-Object -Unique |
                       Where-Object { $devOnlyScripts -notcontains $_ } |
                       Where-Object { -not (Test-Path (Join-Path $kit "scripts\$_")) })
if ($missingDocScripts.Count -gt 0) {
    Write-Host ""
    Write-Host "  [警告] キットの文書が案内しているのに配置されていないスクリプトがあります:"
    foreach ($m in $missingDocScripts) { Write-Host "    - uapp_e2e\scripts\$m" }
    Write-Host "  キット側の不具合です（配布物の作り方かドキュメントのどちらかが間違っている）。報告してください"
    Write-Host ""
}

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
# **どのビルドターゲットに付いているか**を集める。define は Player Settings のターゲット別に
# 持つため、必要なターゲットは運用で変わる:
#   device … Android に付いていないと APK にブリッジが入らない（Android を必須にする）
#   editor … エディタが使うのは **Build Settings で選んでいるプラットフォーム**の define。
#            それは Android のことも Standalone のことも iOS のこともあるので、
#            特定のターゲットを決め打ちにせず「どこかに付いているか」で判定し、付いている
#            ターゲット名を並べて人が突き合わせられるようにする
# YAML を行単位で走査し、scriptingDefineSymbols: キー自身よりも深いインデントの行だけを
# ブロックとみなす（同じか浅いインデントで打ち切り。後続の別ブロックの行を拾わない）。
# シンボル名は両側語境界つきで照合（NOT_UAPP_E2E_BRIDGE / UAPP_E2E_BRIDGE_XXX に誤反応しない）
$defineTargets = @()          # UAPP_E2E_BRIDGE が付いているビルドターゲットのキー
if (Test-Path $projSettings) {
    $keyIndent = $null
    foreach ($line in (Get-Content $projSettings)) {
        if ($null -eq $keyIndent) {
            if ($line -match '^([ \t]*)scriptingDefineSymbols:\s*$') { $keyIndent = $Matches[1].Length }
            continue
        }
        if ($line -notmatch '^([ \t]*)\S') { continue }
        if ($Matches[1].Length -le $keyIndent) { break }  # ブロック終端
        if ($line -match '^\s*([A-Za-z0-9_]+):.*(^|[^A-Za-z0-9_])UAPP_E2E_BRIDGE($|[^A-Za-z0-9_])') {
            $defineTargets += $Matches[1]
        }
    }
}
# 旧シリアライズ形式の数値キーは名前に直して表示する（7 と言われても分からない）
$legacyTargetNames = @{ "1" = "Standalone"; "7" = "Android"; "4" = "iOS"; "13" = "WebGL" }
$defineTargets = @($defineTargets | ForEach-Object { if ($legacyTargetNames.ContainsKey($_)) { $legacyTargetNames[$_] } else { $_ } } | Select-Object -Unique)
$androidDefine = @($defineTargets | Where-Object { $_ -eq "Android" }).Count -gt 0
# device を含む運用は Android 必須。editor 専用ならどこかに付いていればよい
$defineFound = if ($Mode -eq "editor") { $defineTargets.Count -gt 0 } else { $androidDefine }
$localJsonDone = Test-Path (Join-Path $kit "config\local.json")
# 行単位で照合（コメント行や uapp_e2e/Builds-old のような別パスに誤反応しない。
# 区切りは / のみ受理: gitignore のバックスラッシュはパス区切りでなくエスケープなので無効な記述。
# 行頭空白もパターンの一部として扱われるため許容しない。末尾空白は Git が無視するので許容）。
# Unity プロジェクトが git ルートのサブディレクトリにある構成（<repo>\<unity-project>）では
# 除外はプロジェクト直下でなく上位の .gitignore や .git\info\exclude に書かれるため、
# .git が見つかるまで上位も照合する（上位では相対プレフィックス付きのパターンを要求する）
function Test-GitignoreEntries([string]$file, [string]$relPrefix) {
    if (-not (Test-Path $file -PathType Leaf)) { return $false }
    $p = [regex]::Escape($relPrefix)
    ((Select-String -Path $file -Pattern "^/?${p}uapp_e2e/config/local\.json\s*$" -Quiet) -and
     (Select-String -Path $file -Pattern "^/?${p}uapp_e2e/Builds/?\s*$" -Quiet))
}
$gitignoreDone = $false
$gitignoreProbe = $target
$gitignoreRel = ""
while ($true) {
    if (Test-GitignoreEntries (Join-Path $gitignoreProbe ".gitignore") $gitignoreRel) { $gitignoreDone = $true; break }
    if (Test-Path (Join-Path $gitignoreProbe ".git")) {
        # git ルートに到達。ローカル除外（.git\info\exclude）も同じ書式で照合する
        #（.git がファイルの worktree / submodule 構成では exclude の実体が別階層にあり、ここでは追わない）
        $gitignoreDone = Test-GitignoreEntries (Join-Path $gitignoreProbe ".git\info\exclude") $gitignoreRel
        break
    }
    $gitignoreParent = Split-Path $gitignoreProbe -Parent
    if (-not $gitignoreParent -or $gitignoreParent -eq $gitignoreProbe) { break }
    $gitignoreRel = (Split-Path $gitignoreProbe -Leaf) + "/" + $gitignoreRel
    $gitignoreProbe = $gitignoreParent
}
# e2e-config.json の判定: package が雛形のままでない かつ tests の指すパスが実在すること。
# **雛形の既定 `tests`（ディレクトリ）は常に実在するので、editor モードではこの印は
# 実質「壊れていない」の確認**（かつての既定 `tests/test_smoke.py` は -IncludeSampleTests なし導入だと
# 存在せず、導入直後の run-e2e が落ちた。テストファイルを明示指定へ変えた場合の実在検査として残す）。
# orientation は実アプリと突き合わせできないため自動確認の対象外 — 表示側で「何が確認済みで
# 何が人の判断か」を書き分けること（[済] を「全部やった」と読ませない）。
# **editor モードでは package / activity を見ない**（adb を使わないので実際に使われない。
# 使わない値の編集を求めると、直しようのない [未] が残り続ける）
$configEdited = $false
# 既存 e2e-config.json は更新でも上書きしないので、**古い既定値がそのまま残る**。
# 旧既定 tests/test_smoke.py は -IncludeSampleTests なし導入だと実在せず、
# run-e2e が pytest の「ファイルなし」で落ちる。既存導入の更新経路ではここでしか気付けないので、
# 「実在しない tests を指している」ことを名指しで出す
$testsStale = $null
if ($configExisted) {
    try {
        $cfg = Get-Content $configDest -Raw | ConvertFrom-Json
        $testsPath = if ($cfg.tests) { Join-Path $kit "driver\$($cfg.tests)" } else { $null }
        $packageOk = ($Mode -eq "editor") -or ($cfg.package -and ($cfg.package -ne "com.yourcompany.yourapp"))
        $configEdited = $packageOk -and $testsPath -and (Test-Path $testsPath)
        if ($testsPath -and -not (Test-Path $testsPath)) { $testsStale = $cfg.tests }
    } catch { $configEdited = $false }
}

# ポートの重なりは実行してみるまで気付けない（別プロジェクトのブリッジが待受を握ると
# 「bind failed」や別アプリへの誤接続として現れる）。導入時に静かに潰しておく
$portNote = $null
if (Test-Path $configDest) {     # 既存・新規生成のどちらでも見る（雛形の値のままでも重なりは重なり）
    try {
        $cfg = Get-Content $configDest -Raw | ConvertFrom-Json
        $device = [int]$cfg.devicePort
        $editor = [int]$cfg.editorBridgePort
        if ($device -eq $editor) {
            $portNote = "devicePort と editorBridgePort が同じ値（$device）。" +
                        "同一マシンでデバイス実行とエディタ直結を並行させると衝突するので、片方をずらす（例: editorBridgePort = $($device + 1)）"
        }
    } catch { }
}

Write-Host ""
Write-Host "=== 残りの手動手順（[済]=導入済みを検出。詳細: docs/05-install-to-project.md） ==="
if ($Mode -eq "editor") {
    Write-Host "モード: editor（エディタ直結E2Eのみ。Android ビルド・adb・AVD は使わない）"
}
Write-Host "1. Packages/manifest.json に以下を追加（Unityバージョンに応じて）:"
Write-Host "     $(Mark $inputSystemVer) com.unity.inputsystem（2022.3系:1.7.0 / Unity6系:1.14+）$(if ($inputSystemVer) { " → $inputSystemVer 導入済み" })"
Write-Host "     $(Mark $newtonsoftVer) com.unity.nuget.newtonsoft-json: 3.2.1$(if ($newtonsoftVer) { " → $newtonsoftVer 導入済み" })（既存 Newtonsoft DLL があれば不要）"
if ($Mode -eq "editor") {
    # [済] が意味するのは「tests の指すパスが実在する」だけ。既定 `tests` のままでも動くので
    # ここは基本 [済] になる。**orientation は人が実アプリに合わせる項目**で自動確認できないため、
    # [済] を「この行はもう何もしなくてよい」と読ませないよう、残る判断を明示する
    Write-Host "2. $(Mark $configEdited) $configDest の orientation を実アプリの画面向きに合わせる"
    Write-Host ("     （tests は既定の `"tests`" のままでよい＝同梱の単体テスト・疎通スモークと自作テストをまとめて実行する。" +
                "package / activity は editor モードでは使わないので空でよい。" +
                $(if ($configEdited) { "[済] は tests のパスが実在することのみ＝orientation は人が確認する" }
                  else { "tests の指すパスが見つからないか、まだ生成しただけ" }) + "）")
} else {
    Write-Host "2. $(Mark $configEdited) $configDest の package / orientation を実アプリに合わせて編集"
    Write-Host ("     （tests は既定の `"tests`" のままでよい。" +
                $(if ($configEdited) { "[済] は package 設定済み・tests のパスが実在することまで＝orientation は人が確認する" }
                  else { "package が雛形のまま、または tests の指すパスが見つからない" }) + "）")
}
if ($testsStale) {
    Write-Host ("     → **tests が実在しないパスを指しています: `"$testsStale`"**。" +
                "既存の e2e-config.json は更新でも上書きしないので、手で `"tests`" へ直すこと" +
                "（このままだと run-e2e が pytest のファイル未検出で落ちる）")
}
if ($Mode -eq "editor") {
    Write-Host "3. $(Mark $defineFound) UAPP_E2E_BRIDGE define を付与（**エディタが使うのは Build Settings で選んでいる"
    Write-Host "     プラットフォームの define**。Android のままエディタ再生する構成でも構わないが、そのプラットフォームに付いていること）"
} else {
    Write-Host "3. $(Mark $defineFound) テスト用ビルドに UAPP_E2E_BRIDGE define を付与（APK に入れるには Android 向けが必要）"
}
Write-Host "     $(if ($defineTargets.Count) { "→ 現在付いているターゲット: $($defineTargets -join ', ')" } else { "→ どのターゲットにも見つからない" })"
Write-Host "     （自前ビルドスクリプト側で付与する構成は ProjectSettings に現れないため [未] 表示のままでよい）"
if ($Mode -eq "editor") {
    Write-Host "4. $(Mark $localJsonDone) uapp_e2e\config\local.sample.json を local.json にコピー（avd は空のままでよい）"
} else {
    Write-Host "4. $(Mark $localJsonDone) uapp_e2e\config\local.sample.json を local.json にコピーして各自の環境を記入"
}
Write-Host "5. $(Mark $gitignoreDone) .gitignore に追加: uapp_e2e/config/local.json, uapp_e2e/Builds/"
# [済] が言えるのは「その行が .gitignore（または .git/info/exclude）にある」ことまで。
# 既に追跡済みのファイルは ignore 行を足しても追跡され続けるし、後続の否定規則（!…）で
# 再包含されることもある。判定できないことを [済] に含めて読ませない
Write-Host "     （判定はパターンの有無まで。既にコミット済みのファイルは行を足しても追跡され続けるので、"
Write-Host "     その場合は git rm --cached が別途必要）"
Write-Host "6. $(Mark (-not $portNote)) 待受ポートが他と重ならないこと（devicePort / editorBridgePort）"
if ($portNote) { Write-Host "     → $portNote" }
Write-Host "     （同一デバイスに計装アプリを複数入れる場合も devicePort をアプリごとに分ける）"
if ($Mode -eq "editor") {
    Write-Host "7. 初回の run-e2e.ps1 -Editor は Packages/manifest.json へ com.unity.pipeline（Unity CLI 連携）を"
    Write-Host "     自動追加する（追跡ファイルが変わる。コミットするか事前にチームで方針を決めておく）"
}
if ($installClaude) {
    Write-Host "（AI向け規約は .claude\rules\uapp-e2e.md 経由で自動参照される。CLAUDE.md の書き換えは不要）"
}
if ($installCodex) {
    Write-Host ""
    Write-Host "=== Codex（OpenAI Codex CLI v0.94.0 以降）で使う場合 ==="
    Write-Host "スキルは .agents\skills\ に配置済み: `$e2e-setup / `$e2e-run / `$e2e-write-test / `$e2e-dump（/skills で一覧確認）"
    if (-not (Test-Path $rootAgentsPath)) {
        Write-Host "ルートに AGENTS.md が無いため、Codex のルート起動では E2E 導線が自動読込されません。"
        Write-Host "  -RootAgentsMd を付けて再実行するとポインタを新規作成します（既存プロジェクトファイルは変更しない）"
    } elseif (-not ((Get-Content $rootAgentsPath -Raw) -match 'uapp_e2e')) {
        Write-Host "既存の AGENTS.md に uapp_e2e への言及がありません。以下のスニペットの統合を検討してください（自動追記はしない）:"
        Write-Host $rootAgentsSnippet
    }
}
if ($Agents -ne "both") {
    Write-Host ""
    Write-Host "（-Agents $Agents で導入。もう一方のエージェント導線は後から -Agents $(if ($Agents -eq "claude") { "codex" } else { "claude" }) の再実行で追加できる）"
}
Write-Host ""
Write-Host "外すとき: uapp_e2e\scripts\uninstall.ps1（既定=設定・自作テストは残す / -Purge=全消し。詳細: docs\05）"
exit 0  # robocopy の成功コード(1〜7)を漏らさない
