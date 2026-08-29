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
    # デスクトップ向けや「まずエディタだけで回す」立ち上げ期はこちら。
    # ios は iOS（シミュレータ/実機）だけで回す構成（0.1.9 で追加。実行は macOS のみ）:
    # Android の define・AVD・activity を要求せず、iosSimulatorPort と package（bundle id）を
    # 必須扱いにする。恒久 define は不要（BuildEntry が一時付与・復元する）
    [ValidateSet("editor", "device", "both", "ios")][string]$Mode = "both",
    [switch]$IncludeSampleTests,
    [switch]$RootAgentsMd,
    # 導入は行わず、kit-manifest.json とファイル実体の照合だけを行って終了する。
    # 導入先が「自分が改変したのか、更新の副作用か」をその場で切り分けるための確認口
    # （issue #33。導入先が素の SHA256 で自前照合し、全件不一致に見えて混乱した）
    [switch]$VerifyManifest
)

$ErrorActionPreference = "Stop"

# OS 差分の吸収（Windows / macOS。mac は暫定・未検証）。
# **installer だけは 2 つのレイアウトで動く**ので、ヘルパの場所も両方から探す:
#   配布キット …… <kit>\install-to-project.ps1 と <kit>\scripts\uapp-platform.ps1（隣ではない）
#   開発リポジトリ … scripts\install-to-project.ps1 と scripts\uapp-platform.ps1（隣）
# 隣だけを見て `.` すると、**展開した zip から実行したときに必ず落ちる**（レビューで実測）
$platformHelper = @((Join-Path $PSScriptRoot "uapp-platform.ps1"),
                    (Join-Path (Join-Path $PSScriptRoot "scripts") "uapp-platform.ps1")) |
                  Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $platformHelper) {
    throw ("uapp-platform.ps1 が見つかりません（$PSScriptRoot とその scripts\ を探した）。" +
           "キットの展開が不完全か、配布物からファイルが欠けています")
}
. $platformHelper

$installClaude = $Agents -in @("claude", "both")
$installCodex = $Agents -in @("codex", "both")

# 改変検知に使うハッシュ。**テキストは改行を LF に正規化してから取る**。
# 生バイトのままだと、Windows で導入・記録 → commit → mac で LF チェックアウト → 更新、
# の経路で**編集していないキット所有ファイルが一斉に「改変された」**になる
# （kit-manifest.json は導入先で git 管理されるので、Windows と mac が混在するチームは必ず踏む）。
# 警告が嘘になると「警告を無視する習慣」がついて、改変検知そのものが無意味になる。
# **テキストかどうかは拡張子で決めない**。列挙は必ず漏れる（実際に `.html`＝viewer.html が
# 漏れていた）。NUL バイトの有無で判定すれば、新しい種類のファイルが増えても勝手に追随する。
# **先頭だけでなく全体を見る**（先頭 8000 バイトだけの判定だと、NUL がもっと後ろにある
# バイナリを「テキスト」と誤認し、CR の削除で別内容が同じハッシュになりうる）。
# 残る限界: NUL を 1 つも含まないバイナリはテキスト扱いになる（現行の配布物には無い）
function Get-KitFileHash([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    }
    # バイト列のまま CRLF の CR だけを落とす（文字コードを解釈し直すと BOM や
    # 不正なバイト列で内容が変わってしまうため、デコードは経由しない）
    $out = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 13 -and ($i + 1) -lt $bytes.Length -and $bytes[$i + 1] -eq 10) { continue }
        $out.Add($bytes[$i])
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($out.ToArray()) | ForEach-Object { $_.ToString("X2") }) -join "")
    } finally { $sha.Dispose() }
}

# manifest の 1 エントリと実体の照合。**判定はここだけに置く**（更新時の警告と
# -VerifyManifest の表示が違う根拠で数えると、どちらを信じるか分からなくなる）。
# **生バイト一致でも改行正規化一致でも「未改変」とみなす** — 記録側は正規化値で書くが、
# 旧版の記録は生ハッシュなので、これが無いと版を上げた直後の 1 回だけ全件が改変扱いになる。
function Test-KitFileUnchanged([string]$Full, [string]$Recorded) {
    if (-not (Test-Path -LiteralPath $Full)) { return $false }
    return ((Get-KitFileHash $Full) -eq $Recorded) -or
           ((Get-FileHash -LiteralPath $Full -Algorithm SHA256).Hash -eq $Recorded)
}

# manifest 全体の照合結果を返す（@{ Manifest; Modified; Missing; Checked }）。
# Modified / Missing は相対パスの配列。manifest が無ければ $null。
function Get-KitManifestStatus([string]$Target) {
    $manifestPath = Join-UappPath (Join-UappPath $Target "uapp_e2e") "kit-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) { return $null }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $modified = @(); $missing = @(); $checked = 0
    foreach ($entry in $manifest.PSObject.Properties) {
        if ($entry.Name -like "__*") { continue }  # ファイルでないメタ記録
        $checked++
        # キーは記録した OS の区切りで入る（Windows なら `\`）。Join-UappPath は
        # どちらの区切りも解釈するので、別 OS で作られたマニフェストでも読める
        $full = Join-UappPath $Target $entry.Name
        if (-not (Test-Path -LiteralPath $full)) { $missing += $entry.Name; continue }
        if (-not (Test-KitFileUnchanged $full $entry.Value)) { $modified += $entry.Name }
    }
    return @{ Manifest = $manifest; Modified = $modified; Missing = $missing; Checked = $checked;
              Path = $manifestPath }
}

function Test-KitOwnedRelativePath {
    <#
      .SYNOPSIS
      「導入先のこのファイルは、キットが配ったものか」を判定する（所有判定の唯一の場所）。

      .NOTES
      **manifest / uninstall が使う所有判定と、[情報] で並べる「キットが配ったものではない
      ファイル」の判定は、同じ規則でなければならない**。以前は同じ規則を 2 か所へ手書きしており、
      **開発専用スクリプトと同名の自作**（例: `scripts\verify-all.ps1`）で食い違っていた:
        所有側 …… 除外されるので manifest に載らない（正しい）
        stray 側 … 「キット側に実在する」で所有と見なし、**一覧から落ちる**（誤り）
      その結果、**#40 で報告された当の名前だけ退避の案内が出ない**のに、
      `uninstall.ps1` は `uapp_e2e\scripts\` を丸ごと消す＝黙って消える側に回っていた
      （2026-08-25 に mac セッションの独立検証が発見）。
    #>
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Rel,
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$ScriptsDir
    )
    # 値が**ファイル名の配列**なら列挙（docs のようにコピー元がばらばらな場所）、
    # **ディレクトリ**なら同じ相対パスの実在で判定する
    if ($Source -is [array]) { return ($Source -contains $Rel) }
    if (-not (Test-Path -LiteralPath (Join-UappPath $Source $Rel))) { return $false }
    # **キット側に在っても、配らないものは所有ではない**。開発リポジトリから導入すると
    # `$src.Scripts` には開発専用スクリプトも実在するので、**導入先が同名の自作を置いていると
    # 「キット所有」に化け、次の更新で掃除ループが無警告で削除する**（配布 zip 経由では起きない
    # ＝ docs/06 の zip 経由の検証では原理的に捕まらない型）
    if ($Dir -eq $ScriptsDir -and ((Get-UappDevOnlyScript) -contains $Rel)) { return $false }
    return $true
}

# キット所有ファイル（=上書き更新の対象）の列挙。改変検知マニフェストとバックアップで共用する。
# プロジェクト所有（e2e-config.json / conftest.py / 自作テスト / config\local.json / Builds\）は含めない。
function Get-KitOwnedFiles($target, $sourceRoots) {
    <#
      .SYNOPSIS
      導入先のうち**キットが配ったファイル**を列挙する（改変検知・uninstall の対象）。

      .NOTES
      **導入先が置いた自作ファイルを含めてはいけない**（issue #40）。
      以前は `uapp_e2e\scripts\` などを**丸ごと走査**していたため、
      `scripts-local\` が規定される前にそこへ置かれた導入先の自作 .ps1 が
      「キット所有」として manifest に載り、**更新のたびに改変警告、移動すると
      `-VerifyManifest` が不在で exit 1** になっていた（導入先が報告）。

      `$sourceRoots` は「**導入先の絶対ディレクトリ → 対応するキット側のディレクトリ**」。
      載せたディレクトリでは、**キット側に同じ相対パスのファイルが在るものだけ**を所有とする。

      **呼び出し元はこの下の 1 か所だけで、必ず対応表を渡す**。
      `$sourceRoots` が無いときの分岐は**今は到達しない**（将来 2 つ目の呼び出しが
      増えたときに旧挙動へ落とすための保険）。
      **`uninstall.ps1` はこの関数を呼ばない** ― あちらは固定リストで
      `uapp_e2e\scripts\` などを**ディレクトリごと消し、manifest を参照しない**。
      つまり **#40 で消えたのは「警告」だけで、削除される事実は変わっていない**。
      そのため下で「キット側に無いファイル」を [情報] として並べ、移動を促す。
    #>
    $kit = Join-UappPath $target "uapp_e2e"
    $scriptsDir = Join-UappPath $kit "scripts"
    $paths = @()
    # スキルはキットの e2e-* の4つのみ（skills\ 全体を列挙するとユーザーの無関係スキルまで
    # 「キット所有」として改変検知の警告対象になってしまう。uninstall.ps1 の削除対象とも同期）
    $skillDirs = @()
    foreach ($skillsRoot in @(".claude\skills", ".agents\skills")) {
        foreach ($name in @("e2e-setup", "e2e-run", "e2e-write-test", "e2e-dump")) {
            $skillDirs += Join-UappPath $target "$skillsRoot\$name"
        }
    }
    foreach ($dir in (@((Join-UappPath $target "Assets\uapp_e2e\E2EBridge"),
                        (Join-UappPath $kit "scripts"),
                        (Join-UappPath $kit "driver\e2e_driver"),
                        (Join-UappPath $kit "docs"),
                        # iOS の OS レイヤーエージェント（0.1.9 で同梱）
                        (Join-UappPath $kit "oslayer")) + $skillDirs)) {
        if (Test-Path -LiteralPath $dir) {
            # DerivedData は oslayer を導入先でビルドしたキャッシュ＝プロジェクト側の生成物なので
            # 所有に含めない（含めると毎回「ローカル改変」警告になる）。
            # **判定は列挙起点からの相対パスのセグメント一致**で行う（フルパスへの部分一致だと、
            # 導入先の祖先ディレクトリ名に DerivedData を含むだけで全ファイルが所有から脱落し、
            # 改変検知が丸ごと無効になる ― 外部レビュー指摘）
            $dirFull = Resolve-UappFsPath $dir
            $paths += Get-UappTreeFile $dir | Where-Object {
                $rel = $_.Substring($dirFull.Length).TrimStart('\', '/')
                $segments = $rel -split '[\\/]'
                if (($segments -contains '__pycache__') -or ($segments -contains 'DerivedData')) { return $false }
                # **キット側に同じファイルが在るときだけ所有**（issue #40）。
                # 対応表が無い呼び出しでは従来どおり全部通す
                # **`$null` かどうかで見る**。`-not` だと**空配列も真**になり、
                # 「対応表が無い＝全部所有」へ落ちる（inject の記録が空配列で define を
                # 全消しした事故と同じクラス。レビュー指摘）
                if ($null -eq $sourceRoots) { return $true }
                if (-not $sourceRoots.Contains($dir)) { return $true }
                $source = $sourceRoots[$dir]
                return (Test-KitOwnedRelativePath -Dir $dir -Rel $rel -Source $source -ScriptsDir $scriptsDir)
            }
        }
    }
    foreach ($f in @((Join-UappPath $target "Assets\uapp_e2e\E2EBridge.meta"),
                     (Join-UappPath $kit "driver\pytest.ini"),
                     (Join-UappPath $kit "driver\requirements.txt"),
                     (Join-UappPath $kit "driver\tests\test_journey_unit.py"),
                     (Join-UappPath $kit "driver\tests\test_adb_ui.py"),
                     (Join-UappPath $kit "driver\tests\test_client_unit.py"),
                     (Join-UappPath $kit "driver\tests\test_bridge_smoke.py"),
                     (Join-UappPath $kit "driver\tests\test_metrics_unit.py"),
                     (Join-UappPath $kit "config\local.sample.json"),
                     (Join-UappPath $kit "config\e2e-config.sample.json"),
                     # scripts-local は**中身がプロジェクト所有**。README だけキットが管理する
                     # （ディレクトリごと列挙すると自作スクリプトが上書き・削除の対象になる）
                     (Join-UappPath $kit "scripts-local\README.md"),
                     (Join-UappPath $kit "CLAUDE.md"),
                     (Join-UappPath $kit "AGENTS.md"),
                     (Join-UappPath $kit "SETUP.md"),
                     (Join-UappPath $kit "VERSION"),
                     (Join-UappPath $target ".claude\rules\uapp-e2e.md"))) {
        if (Test-Path -LiteralPath $f) { $paths += $f }
    }
    $paths
}

# --- 実行元レイアウトの自動判定 ---
#   配布キット:     <kit>\install-to-project.ps1（自己完結。bridge\E2EBridge が同階層にある）
#   開発リポジトリ: scripts\install-to-project.ps1（計装マスターは unity-nis）
if (Test-Path -LiteralPath (Join-UappPath $PSScriptRoot "bridge\E2EBridge")) {
    $root = $PSScriptRoot
    $src = @{
        Bridge      = Join-UappPath $root "bridge\E2EBridge"
        BridgeMeta  = Join-UappPath $root "bridge\E2EBridge.meta"
        Scripts     = Join-UappPath $root "scripts"
        Driver      = Join-UappPath $root "driver"
        SampleTests = Join-UappPath $root "driver\sample-tests"
        Config      = Join-UappPath $root "config"
        Doc02       = Join-UappPath $root "docs\02-protocol.md"
        Doc05       = Join-UappPath $root "docs\05-install-to-project.md"
        Doc07       = Join-UappPath $root "docs\07-viewer.md"
        Doc09       = Join-UappPath $root "docs\09-ios16-osagent.md"
        AiLoop      = Join-UappPath $root "docs\ai-loop.md"
        ClaudeMd    = Join-UappPath $root "CLAUDE.md"
        AgentsMd    = Join-UappPath $root "AGENTS.md"
        SetupMd     = Join-UappPath $root "SETUP.md"
        Skills      = Join-UappPath $root "skills"
        Rules       = Join-UappPath $root "rules"
        OsLayer     = Join-UappPath $root "oslayer"
        Version     = Join-UappPath $root "VERSION"
        Retired     = Join-UappPath $root "retired-files.json"
    }
    Write-Host "実行元: 配布キット ($root)"
}
elseif (Test-Path -LiteralPath (Join-UappPath $PSScriptRoot "..\unity-nis\Assets\uapp_e2e\E2EBridge")) {
    $root = (Resolve-Path -LiteralPath (Join-UappPath $PSScriptRoot "..")).Path
    $src = @{
        Bridge      = Join-UappPath $root "unity-nis\Assets\uapp_e2e\E2EBridge"
        BridgeMeta  = Join-UappPath $root "unity-nis\Assets\uapp_e2e\E2EBridge.meta"
        Scripts     = Join-UappPath $root "scripts"
        Driver      = Join-UappPath $root "driver"
        SampleTests = Join-UappPath $root "driver\tests"
        Config      = Join-UappPath $root "config"
        Doc02       = Join-UappPath $root "docs\02-protocol.md"
        Doc05       = Join-UappPath $root "docs\05-install-to-project.md"
        Doc07       = Join-UappPath $root "docs\07-viewer.md"
        Doc09       = Join-UappPath $root "docs\09-ios16-osagent.md"
        AiLoop      = Join-UappPath $root "kit\docs\ai-loop.md"
        ClaudeMd    = Join-UappPath $root "kit\CLAUDE.md"
        AgentsMd    = Join-UappPath $root "kit\AGENTS.md"
        SetupMd     = Join-UappPath $root "kit\SETUP.md"
        Skills      = Join-UappPath $root "kit\skills"
        Rules       = Join-UappPath $root "kit\rules"
        OsLayer     = Join-UappPath $root "oslayer"
        Version     = Join-UappPath $root "kit\VERSION"
        Retired     = Join-UappPath $root "kit\retired-files.json"
    }
    Write-Host "実行元: 開発リポジトリ ($root)"
}
else {
    throw "実行元レイアウトを判定できません（bridge\E2EBridge も ..\unity-nis も見つからない）: $PSScriptRoot"
}

$target = (Resolve-Path -LiteralPath $ProjectPath).Path

# Unity プロジェクトであることの検証
if (-not ((Test-Path -LiteralPath (Join-UappPath $target "Assets")) -and (Test-Path -LiteralPath (Join-UappPath $target "ProjectSettings")))) {
    throw "Unity プロジェクトではありません（Assets/ProjectSettings が見つからない）: $target"
}

Write-Host "導入先: $target"

# --- -VerifyManifest: 照合だけして終了（導入は行わない。issue #33） ---
# 導入先が「キット所有ファイルを自分が改変したのか、更新の副作用か」を切り分けるための口。
# **判定は更新時の警告と同じ関数**（Get-KitManifestStatus）を使う ― 表示と警告で
# 数え方が違うと、どちらを信じるか分からなくなる。
if ($VerifyManifest) {
    $status = Get-KitManifestStatus $target
    if (-not $status) {
        Write-Host ""
        # **注入モードの対象では installer を勧めてはいけない**（レビュー指摘）。
        # inject 側は「フル導入済みの対象への注入」を常に拒否するので、
        # 案内どおり installer を流すと**以後 -Eject の前提が崩れる**
        if (Test-Path -LiteralPath (Join-UappPath $target "uapp_e2e-inject.json")) {
            Write-Host "この対象は**注入モード**です（uapp_e2e-inject.json があります）。"
            Write-Host "  改変検知（kit-manifest.json）はフル導入向けの機能で、注入対象には記録がありません。"
            Write-Host "  **installer を実行しないでください** ― フル導入になると -Eject の前提が崩れます。"
            Write-Host "  注入したものの確認は inject-to-project.ps1 -List、撤去は -Eject です。"
            exit 2
        }
        Write-Host "kit-manifest.json がありません（未導入か、旧版の導入で記録が無い）:"
        Write-Host "  $(Join-UappPath (Join-UappPath $target 'uapp_e2e') 'kit-manifest.json')"
        Write-Host "この状態では改変検知は働きません。installer を実行し直すと記録が作られます"
        exit 2
    }
    Write-Host ""
    Write-Host "kit-manifest.json との照合: $($status.Path)"
    Write-Host "  対象 $($status.Checked) 件 / 改変 $($status.Modified.Count) 件 / 不在 $($status.Missing.Count) 件"
    foreach ($m in $status.Modified) { Write-Host "  [改変] $m" }
    foreach ($m in $status.Missing)  { Write-Host "  [不在] $m" }
    Write-Host ""
    # **自前照合との食い違いを先回りで説明する**（この案内が無いと、素の SHA256 で
    # 突き合わせた導入先が「全件壊れている」と誤読する ― 実際にそう報告された）
    Write-Host "注意: manifest のハッシュは**テキストの改行を LF に正規化してから**取っている"
    Write-Host "      （Windows で記録 → mac でチェックアウト、で全件誤発火するのを防ぐため）。"
    Write-Host "      素の Get-FileHash / sha256sum の値と直接比べても CRLF のファイルは一致しない。"
    Write-Host "      照合はこのコマンドで行うこと（installer 本体の警告と同じ判定を使う）"
    if ($status.Modified.Count -gt 0 -or $status.Missing.Count -gt 0) {
        Write-Host ""
        Write-Host "改変・不在があるので終了コード 1 を返す（キット所有ファイルへの変更は次回更新で上書きされる）"
        exit 1
    }
    Write-Host "すべて記録どおり（ローカル改変なし）"
    exit 0
}

# --- 0. 更新時バックアップ（既導入の場合のみ） ---
# 上書き対象（キット所有領域）を uapp_e2e\Builds\update-backup-<日時>.zip へ退避する。
# Builds\（ジャーニー記録・過去バックアップ・APK）は容量が大きく、かつ上書き対象外なので含めない。
$kit = Join-UappPath $target "uapp_e2e"
# 前回導入時にキットが所有していたファイル一覧（新規導入では $null のまま）
$prevOwned = $null
if (Test-Path -LiteralPath $kit) {
    $backupPaths = @(Get-UappTreeEntry $kit | Where-Object { (Split-Path $_ -Leaf) -ne "Builds" })
    foreach ($p in @((Join-UappPath $target "Assets\uapp_e2e"),
                     (Join-UappPath $target ".claude\skills"),
                     (Join-UappPath $target ".agents\skills"),
                     (Join-UappPath $target ".claude\rules\uapp-e2e.md"))) {
        if (Test-Path -LiteralPath $p) { $backupPaths += $p }
    }
    if ($backupPaths.Count -gt 0) {
        # ミリ秒まで含める（同一秒内の連続実行で名前が衝突して圧縮が失敗するため）
        $backupZip = Join-UappPath $kit ("Builds\update-backup-" + (Get-Date -Format "yyyyMMdd-HHmmss-fff") + ".zip")
        New-Item -ItemType Directory -Force (Split-Path $backupZip) | Out-Null
        # zip内は導入先ルートからの相対パスを保つ（Compress-Archive に複数パスを直接渡すと
        # 末端名で格納され .claude\skills と .agents\skills が同名衝突して復元不能になるため、
        # ステージングへ相対パス付きで複製してからディレクトリごと圧縮する）
        # ステージングは TEMP でなく Builds\ 配下（gitignore 済み）: サンドボックス環境では TEMP が
        # 8.3 短縮パスで渡り、Move-Item / Remove-Item が抑止不能の失敗になる（導入先で実測）
        $backupStage = Join-UappPath $kit ("Builds\tmp-backup-" + [System.IO.Path]::GetRandomFileName())
        try {
            foreach ($p in $backupPaths) {
                $dest = Join-UappPath $backupStage $p.Substring($target.Length + 1)
                New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
                if (Test-Path -LiteralPath $p -PathType Container) {
                    # oslayer\DerivedData（Xcode のビルドキャッシュ。数百 MB 級・再生成可能）を
                    # バックアップへ入れない — 毎回の更新で複製・圧縮すると極端に遅くなる。
                    # Copy-UappTree の -ExcludeDirectory は名前単位なので、他の場所の
                    # DerivedData という名の利用者ディレクトリまで除外しうるが、
                    # ビルドキャッシュの慣用名であり実害より安全側と判断
                    Copy-UappTree -Source $p -Destination $dest -ExcludeDirectory @("DerivedData")
                } else {
                    Copy-Item -LiteralPath $p $dest
                }
            }
            [System.IO.Compression.ZipFile]::CreateFromDirectory($backupStage, $backupZip)
        } finally {
            Remove-UappTree $backupStage
        }
        Write-Host "  [OK] 更新前バックアップ: $backupZip"
    }

    # --- 0.5 ローカル改変の検知 ---
    # 前回導入時に記録したハッシュ（kit-manifest.json）と現状を照合し、
    # 導入先で独自改修されたキット所有ファイル（例: viewer.html のカスタマイズ）を警告する。
    $status = Get-KitManifestStatus $target
    if ($status) {
        $manifest = $status.Manifest
        # 「前回の導入でキットが所有していたファイル」の一覧。
        # キットが新しく所有し始めた名前と、導入先の自作ファイルとの衝突判定に使う
        # **区切りを `/` に正規化して持つ**。マニフェストのキーは記録した OS の区切りで入るため、
        # Windows で導入したツリーを mac で更新する（逆も同様）と、そのままでは全件が
        # 「所有記録なし」に見えて自作ファイルの上書き警告が誤発火する
        $prevOwned = @($manifest.PSObject.Properties.Name | ForEach-Object { ConvertTo-UappPathKey $_ })
        # **配布対象から外れたスクリプトの掃除に使う**（下の「除外対象の掃除」）。
        # 前回こちらが置いたものだけを消すため、記録そのものを保持しておく
        $script:prevManifest = $manifest
        $modified = @($status.Modified) + @($status.Missing | ForEach-Object { "$_（削除されている）" })
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
$bridgeDest = Join-UappPath $target "Assets\uapp_e2e\E2EBridge"
Copy-UappTree -Source $src.Bridge -Destination $bridgeDest
Copy-Item -LiteralPath $src.BridgeMeta (Join-UappPath $target "Assets\uapp_e2e\E2EBridge.meta") -ErrorAction SilentlyContinue
Write-Host "  [OK] Assets\uapp_e2e\E2EBridge（計装SDK）"

# --- 2. E2E キット（scripts / driver / config テンプレ） ---
$kit = Join-UappPath $target "uapp_e2e"
foreach ($dir in @("scripts", "config")) {
    New-Item -ItemType Directory -Force (Join-UappPath $kit $dir) | Out-Null
}
# Builds\ は導入直後から在る前提の置き場（ジャーニー記録・失敗証跡・一時ファイル）。
# **無いと pytest の `--basetemp ..\Builds\pytest-tmp`（SETUP.md がサンドボックス環境向けに
# 案内している回避策）が「親が無い」で落ちる**。gitignore 対象なので作っても追跡はされない
New-Item -ItemType Directory -Force (Join-UappPath $kit "Builds") | Out-Null
# **導入先が自作する運用スクリプトの置き場**（issue #35-D）。`scripts\` はキット所有で
# uninstall がディレクトリごと消すため、そこへ自作分を置くと消える（導入先で実際に踏まれた）。
# ここはプロジェクト所有＝更新でも uninstall でも触らない。README だけキットが管理する
$scriptsLocal = Join-UappPath $kit "scripts-local"
New-Item -ItemType Directory -Force $scriptsLocal | Out-Null
# **非展開ヒアドキュメント（@'…'@）で書く**。展開版だと本文中の `` `u `` が
# PowerShell の Unicode エスケープとして解釈され、スクリプト全体が字句解析に失敗する
Set-Content -LiteralPath (Join-UappPath $scriptsLocal "README.md") -Encoding utf8 -Value @'
# scripts-local（プロジェクト所有）

このプロジェクト専用の運用スクリプト（通し実行の walker・注入や撤去の補助など）はここへ置く。

- **キットの更新でも既定の uninstall でも触られない**（この README を除く）。
  ただし `uninstall.ps1 -Purge` は uapp_e2e\ 全体を消すので、そこには含まれる
- 逆に `uapp_e2e\scripts\` はキット所有で、**更新で上書き・uninstall で丸ごと削除**される。
  自作分をそこへ置かないこと
- 自作テストの置き場は `uapp_e2e\driver	ests\`（同じくプロジェクト所有）
'@
Write-Host "  [OK] uapp_e2e\scripts-local（導入先の自作スクリプト置き場・更新と削除の対象外）"
# **配るスクリプトを列挙しない**。v0.1.6 で追加した unity-editor-status.ps1 が
# この列挙から漏れ、キットの CLAUDE.md が案内するコマンドが導入先に存在しない状態になった
# （エラーにならず静かに欠けるので、AI が実行して「ファイルが無い」で初めて気づく）。
# 配布キットから実行する場合、scripts\ の中身はそれ自体が配布対象。開発リポジトリから
# 実行する場合だけ、**導入先では使わない開発専用スクリプト**を除く（除外は増えにくく、
# 配布対象が増えたときは何もしなくても届く＝同じ漏れ方をしない）
# **package-kit と同じ一覧を使う**（Get-UappDevOnlyScript）。ここに手書きで持つと、
# zip 経路では除外されているものが開発リポジトリ経路でだけ導入先へ届く（実際に起きた）
$devOnlyScripts = Get-UappDevOnlyScript
foreach ($script in (Get-ChildItem (Join-UappPath $src.Scripts "*.ps1") |
                     Where-Object { $devOnlyScripts -notcontains $_.Name })) {
    Copy-Item -LiteralPath $script.FullName (Join-UappPath $kit "scripts\$($script.Name)") -Force
}
# **除外対象の掃除**。コピーしないだけでは、以前配ってしまったものが導入先に残り続ける
# （しかも下の Get-KitOwnedFiles が scripts\ を丸ごと列挙するので、新しい manifest へ
# 「キット所有」として再登録され、永続する）。**前回こちらが置いた記録があるものだけ**消す —
# 導入先が自分で置いた同名ファイルを消さないため。改変されていたら消さずに警告する
foreach ($name in $devOnlyScripts) {
    $stale = Join-UappPath $kit "scripts\$name"
    if (-not (Test-Path -LiteralPath $stale)) { continue }
    $key = ConvertTo-UappPathKey ($stale.Substring($target.Length + 1))
    $recorded = $null
    if ($script:prevManifest) {
        foreach ($e in $script:prevManifest.PSObject.Properties) {
            if ((ConvertTo-UappPathKey $e.Name) -eq $key) { $recorded = $e.Value; break }
        }
    }
    if (-not $recorded) {
        Write-Host "  [情報] 配布対象外のスクリプトが導入先にありますが、キットが置いた記録が無いので残します: scripts\$name"
        continue
    }
    $unchanged = ((Get-KitFileHash $stale) -eq $recorded) -or
                 ((Get-FileHash -LiteralPath $stale -Algorithm SHA256).Hash -eq $recorded)
    if ($unchanged) {
        Remove-Item -LiteralPath $stale -Force
        Write-Host "  [情報] 配布対象外になったスクリプトを削除しました: scripts\$name"
    } else {
        Write-Host "  [警告] 配布対象外になったスクリプトがローカル改変されているため残します: scripts\$name"
    }
}
Copy-UappTree -Source (Join-UappPath $src.Driver "e2e_driver") -Destination (Join-UappPath $kit "driver\e2e_driver") -ExcludeDirectory @("__pycache__")
Copy-Item -LiteralPath (Join-UappPath $src.Driver "pytest.ini") (Join-UappPath $kit "driver\pytest.ini") -Force
Copy-Item -LiteralPath (Join-UappPath $src.Driver "requirements.txt") (Join-UappPath $kit "driver\requirements.txt") -Force
New-Item -ItemType Directory -Force (Join-UappPath $kit "driver\tests") | Out-Null
# conftest.py は初回のみ生成（プロジェクトが拡張し得るため上書きしない。
# キット機能の更新は driver\e2e_driver\ の差し替えで届く。docs\07 の更新ランブック参照）
$conftestDest = Join-UappPath $kit "driver\tests\conftest.py"
if (-not (Test-Path -LiteralPath $conftestDest)) {
    Copy-Item -LiteralPath (Join-UappPath $src.Driver "tests\conftest.py") $conftestDest
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
foreach ($t in @("test_journey_unit.py", "test_adb_ui.py", "test_client_unit.py", "test_bridge_smoke.py",
                 "test_metrics_unit.py")) {
    $testDest = Join-UappPath $kit "driver\tests\$t"
    if ((Test-Path -LiteralPath $testDest) -and (($null -eq $prevOwned) -or ($prevOwned -notcontains (ConvertTo-UappPathKey "uapp_e2e\driver\tests\$t")))) {
        $testNameConflicts += $t
    }
    Copy-Item -LiteralPath (Join-UappPath $src.Driver "tests\$t") $testDest -Force
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
        $sampleDest = Join-UappPath $kit "driver\tests\$t"
        if (-not (Test-Path -LiteralPath $sampleDest)) {
            Copy-Item -LiteralPath (Join-UappPath $src.SampleTests $t) $sampleDest
        } else {
            Write-Host "  [SKIP] driver\tests\$t（既存を維持）"
        }
    }
}
Copy-Item -LiteralPath (Join-UappPath $src.Config "local.sample.json") (Join-UappPath $kit "config\local.sample.json") -Force
# iOS の OS レイヤーエージェント（run-ios-e2e.ps1 -OsAgent が導入先でビルドする。macOS 専用だが
# 配布はどの OS からでも行う — 導入先リポジトリを mac で開いたときに使えるように）。
# **今回からキット所有になった領域**なので、前回の所有記録が無いのに実在する場合は
# 「利用者が自分で置いたものかもしれない」＝上書きしたことを警告する（テスト移行ガードと同型。
# 上書き前の内容は 0. の更新バックアップに入っている）
$oslayerDest = Join-UappPath $kit "oslayer"
$oslayerConflict = (Test-Path -LiteralPath $oslayerDest) -and
                   (($null -eq $prevOwned) -or
                    -not ($prevOwned | Where-Object { $_ -like "uapp_e2e/oslayer/*" }))
Copy-UappTree -Source $src.OsLayer -Destination $oslayerDest -ExcludeDirectory @("DerivedData")
if ($oslayerConflict) {
    Write-Host ""
    Write-Host "  [警告] キット所有と記録されていない uapp_e2e\oslayer\ を上書きしました（このまま更新を続けます）:"
    Write-Host "    キットが新しく所有し始めた領域か、前回の所有記録（kit-manifest.json）が無い導入です。"
    Write-Host "    自作の Xcode/Swift ファイルだった場合は上のバックアップzipから取り出し、別の場所へ戻すこと"
    Write-Host ""
}
Write-Host "  [OK] uapp_e2e\（scripts / driver / config テンプレ / oslayer）"

# --- 2.5 ドキュメントと AI 向け運用ガイド ---
New-Item -ItemType Directory -Force (Join-UappPath $kit "docs") | Out-Null
Copy-Item -LiteralPath $src.Doc02 (Join-UappPath $kit "docs\02-protocol.md") -Force
# **docs/05 だけはリンクをキット同梱の形へ直してから配る**（package-kit と共通の Copy-UappKitDoc05）。
# zip レイアウトでは既に置換済みで、置換は冪等なので同じバイト列になる
Copy-UappKitDoc05 -Source $src.Doc05 -Destination (Join-UappPath $kit "docs\05-install-to-project.md")
Copy-Item -LiteralPath $src.Doc07 (Join-UappPath $kit "docs\07-viewer.md") -Force
# **09 は iOS 実機の手順書**（issue #43）。踏んだときに導入先で読めないと意味がないので配る
Copy-Item -LiteralPath $src.Doc09 (Join-UappPath $kit "docs\09-ios16-osagent.md") -Force
Copy-Item -LiteralPath $src.AiLoop (Join-UappPath $kit "docs\ai-loop.md") -Force
Copy-Item -LiteralPath $src.ClaudeMd (Join-UappPath $kit "CLAUDE.md") -Force
if ($installCodex) {
    Copy-Item -LiteralPath $src.AgentsMd (Join-UappPath $kit "AGENTS.md") -Force
}
Copy-Item -LiteralPath $src.SetupMd (Join-UappPath $kit "SETUP.md") -Force
Copy-Item -LiteralPath $src.Version (Join-UappPath $kit "VERSION") -Force
$installedVersion = (Get-Content -LiteralPath (Join-UappPath $kit "VERSION") -TotalCount 1).Trim()
Write-Host "  [OK] uapp_e2e\docs\ + CLAUDE.md（AI向け運用ガイド）$(if ($installCodex) { " + AGENTS.md（Codex等向けポインタ）" }) + VERSION=$installedVersion"

# --- 2.6 AIスキル（Claude Code: .claude\skills / Codex v0.94.0+: .agents\skills。内容は同一） ---
$skillsDests = @()
if ($installClaude) { $skillsDests += Join-UappPath $target ".claude\skills" }
if ($installCodex) { $skillsDests += Join-UappPath $target ".agents\skills" }
foreach ($skillsDest in $skillsDests) {
    New-Item -ItemType Directory -Force $skillsDest | Out-Null
    Copy-UappTree -Source $src.Skills -Destination $skillsDest
}
$skillsLabel = @()
if ($installClaude) { $skillsLabel += ".claude\skills\" }
if ($installCodex) { $skillsLabel += ".agents\skills\" }
Write-Host "  [OK] $($skillsLabel -join " + ")（e2e-setup / e2e-run / e2e-write-test / e2e-dump）"

# --- 2.7 Claude Code ルール（軽量ポインタ。対象プロジェクトの CLAUDE.md は書き換えない） ---
if ($installClaude) {
    $rulesDest = Join-UappPath $target ".claude\rules"
    New-Item -ItemType Directory -Force $rulesDest | Out-Null
    Copy-Item -LiteralPath (Join-UappPath $src.Rules "uapp-e2e.md") (Join-UappPath $rulesDest "uapp-e2e.md") -Force
    Write-Host "  [OK] .claude\rules\uapp-e2e.md（uapp_e2e\CLAUDE.md への参照ルール）"
}

# --- 2.8 ルート AGENTS.md（Codex 等向けの発見性向上。オプトイン・既存ファイルは絶対に変更しない） ---
# Codex はルート起動時に uapp_e2e\AGENTS.md を読まない（サブディレクトリ AGENTS.md は
# そこを CWD にした場合のみ読込）ため、ルートへのポインタ配置が発見性の本命になる。
# ただしプロジェクト本体への成果物追加なので、既定では作成せず案内のみ。
if ($RootAgentsMd -and -not $installCodex) {
    Write-Host "  [SKIP] -RootAgentsMd は -Agents codex/both のときのみ有効（今回は -Agents $Agents のため何もしない）"
}
$rootAgentsPath = Join-UappPath $target "AGENTS.md"
# この生成内容を変更したら uninstall.ps1 の「未編集判定」の期待値も同期すること
$rootAgentsSnippet = @"
## uapp_e2e（E2Eテスト基盤・導入済み）

E2Eテストの作成・実行・デバッグ、計装SDK（``Assets/uapp_e2e/E2EBridge/``）、
エミュレーター/エディタ再生への接続に関わる作業を始める前に、必ず
``uapp_e2e/CLAUDE.md``（エージェント共通の規約・コマンド・失敗解析手順）を読むこと。
セットアップ・修復の入口は ``uapp_e2e/SETUP.md``。
定型作業は ``.agents/skills/e2e-*`` スキル（setup / run / write-test / dump）にある。
"@
$rootAgentsExists = Test-Path -LiteralPath $rootAgentsPath
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
$configDest = Join-UappPath $kit "e2e-config.json"
$configExisted = Test-Path -LiteralPath $configDest
if (-not $configExisted) {
    Copy-Item -LiteralPath (Join-UappPath $src.Config "e2e-config.sample.json") $configDest
    # **生成したファイルも LF へ**（issue #55）。導入先が編集してコミットするので、
    # CRLF のままだとキット所有ファイルと同じ差分ノイズが出る
    [void](Convert-UappFileToLf -Path $configDest)
    Write-Host "  [OK] e2e-config.json（テンプレから生成 → package 等を編集してください）"
} else {
    Write-Host "  [SKIP] e2e-config.json（既存を維持）"
}

# --- 4. 改変検知用マニフェスト（今回導入したキット所有ファイルのハッシュ）を記録 ---
# ルート AGENTS.md を「installer が作成した」記録も残す（uninstall -Purge が削除してよいかの
# 判定に使う。ユーザーが元々置いていた同内容ファイルを誤って消さないため）。再実行時は引き継ぐ
$manifestPath = Join-UappPath $kit "kit-manifest.json"
$prevRootAgentsMarker = $false
if (-not $rootAgentsCreated -and (Test-Path -LiteralPath $manifestPath)) {
    try { $prevRootAgentsMarker = [bool]((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)."__rootAgentsMdByInstaller") } catch {}
}
$manifestEntries = [ordered]@{}
if (($rootAgentsCreated -or $prevRootAgentsMarker) -and (Test-Path -LiteralPath $rootAgentsPath)) {
    $manifestEntries["__rootAgentsMdByInstaller"] = $true
}
# **キット側の実体と突き合わせて所有を決める**（issue #40）。
# 走査だけだと、導入先が `uapp_e2e\scripts\` へ置いた自作ファイルまで
# 「キット所有」として記録され、更新のたびに改変警告 → 移動すると不在で exit 1 になっていた。
# **キーは走査するディレクトリ、値は対応するキット側のディレクトリ**。
# ここに載せていないディレクトリ（スキル等）は従来どおり全部所有として扱う
# （それらはキット固有の名前で、導入先の物が混ざる余地が無い）
$ownedSourceMap = @{
    (Join-UappPath $target "Assets\uapp_e2e\E2EBridge") = $src.Bridge
    (Join-UappPath $kit "scripts")                       = $src.Scripts
    (Join-UappPath $kit "driver\e2e_driver")             = (Join-UappPath $src.Driver "e2e_driver")
    (Join-UappPath $kit "oslayer")                       = $src.OsLayer
    # **docs はコピー元がばらばら**（$src.Doc02 等）なのでディレクトリで対応付けられない。
    # 配るファイル名を列挙する。**ここを更新し忘れると、そのファイルが所有から落ちて
    # 改変検知と uninstall の照合が効かなくなる**ので、下の検査で件数を見る
    (Join-UappPath $kit "docs") = @("02-protocol.md", "05-install-to-project.md",
                                    "07-viewer.md", "09-ios16-osagent.md", "ai-loop.md")
}
# **対応表が壊れていたら止める**（レビューが実測）。値を間違えると、そのディレクトリ配下が
# **無警告で manifest から丸ごと消え**、`-VerifyManifest` は真っ緑のまま改変検知だけが死ぬ。
# ①コピー元（ディレクトリ指定のもの）が実在するか ②配置済みの各ディレクトリから
# 1 件以上を所有と判定できているか、の 2 つを見る
foreach ($entry in $ownedSourceMap.GetEnumerator()) {
    if ($entry.Value -is [array]) {
        # **配列（ファイル名の列挙）は、その名前が実際に配置されているかを見る**。
        # 件数も実在も見ないと、綴り違い 1 つでそのファイルが所有から落ちる
        if (-not $entry.Value) {
            throw "キット所有の対応表が壊れています（空の一覧）: $($entry.Key)"
        }
        foreach ($name in $entry.Value) {
            if ((Test-Path -LiteralPath $entry.Key) -and
                -not (Test-Path -LiteralPath (Join-UappPath $entry.Key $name))) {
                throw ("キット所有の対応表が壊れています（配置されていないファイル名）: " +
                       "$($entry.Key) の一覧に $name があるが実体が無い")
            }
        }
        continue
    }
    if (-not (Test-Path -LiteralPath $entry.Value)) {
        throw ("キット所有の対応表が壊れています（コピー元が見つからない）: " +
               "$($entry.Key) → $($entry.Value)。install-to-project.ps1 の " +
               '$ownedSourceMap を直してください（放置すると、そのディレクトリが manifest から' +
               "無警告で落ち、改変検知と uninstall の照合が効かなくなります）")
    }
}
# **キット所有でないものを [情報] で並べる**（issue #40）。
# #40 の前は、これらが「キット所有」として記録されていたので**改変警告が出て**、
# 結果的に「`scripts-local\` へ移せ」と気づけていた。#40 で警告は消えたが、
# **`uninstall.ps1` は今も `uapp_e2e\scripts\` などをディレクトリごと消す**
# （あちらは manifest を見ない）。**気づく機会だけ消して削除は残る**のは割に合わないので、
# 移動を促す 1 行を出す。**警告ではなく情報**（正常な運用を止めない）
# **配布をやめたファイルの一覧を先に読む**（issue #42）。下の stray 判定から除外するため ―
# 一覧に載っているものは**由来がはっきりしている**（キットが配ったと分かっている）ので、
# 「由来が分からない」側の一覧に混ぜると**同じ事実を 2 回、しかも違う言い方で**述べることになる
$retiredEntries = @()
if ($src.Retired -and (Test-Path -LiteralPath $src.Retired)) {
    try {
        $retiredEntries = @((Get-Content -LiteralPath $src.Retired -Raw | ConvertFrom-Json).files)
    } catch {
        Write-Warning "配布終了ファイルの一覧を読めませんでした（$($src.Retired)）: $($_.Exception.Message)"
    }
}
$retiredKeys = @($retiredEntries | Where-Object { $_.path } |
                 ForEach-Object { ConvertTo-UappPathKey $_.path })

$strays = @()
foreach ($entry in $ownedSourceMap.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Key)) { continue }
    $keyFull = Resolve-UappFsPath $entry.Key
    foreach ($f in (Get-UappTreeFile $entry.Key)) {
        $rel = $f.Substring($keyFull.Length).TrimStart('\', '/')
        $segments = $rel -split '[\\/]'
        if (($segments -contains '__pycache__') -or ($segments -contains 'DerivedData')) { continue }
        # **所有判定は Test-KitOwnedRelativePath に寄せる**（同じ規則を 2 か所へ書かない）。
        # ここが所有側とずれると、キットが配っていないファイルが一覧から落ちる
        $owned = Test-KitOwnedRelativePath -Dir $entry.Key -Rel $rel -Source $entry.Value `
                                           -ScriptsDir (Join-UappPath $kit "scripts")
        if (-not $owned) {
            $strayPath = $f.Substring((Resolve-UappFsPath $target).Length).TrimStart('\', '/')
            # **引退一覧に載っているものは下の 4.6 でまとめて報告する**（二重に言わない）
            if ($retiredKeys -contains (ConvertTo-UappPathKey $strayPath)) { continue }
            # **由来を 3 つに分ける**（キットが配った / 導入先が置いた / 判定できない）。
            # 判定材料は**前回の kit-manifest.json** しかないので、記録が無い導入
            # （手で入れた・記録を消した・注入モードの対象）では**どちらとも言えない**。
            # 2 択へ押し込むと、どちらかの断定が必ず嘘になる（mac セッションの指摘）。
            # **由来で案内が変わる** ― キットが配った残骸に `scripts-local\` を案内すると、
            # **古い配布物を導入先の資産として保存させる**ことになる
            $origin = if ($null -eq $script:prevManifest) { "unknown" }
                      elseif ($prevOwned -contains (ConvertTo-UappPathKey $strayPath)) { "kit-stale" }
                      else { "local" }
            $strays += [pscustomobject]@{
                Path   = $strayPath
                Area   = $entry.Key
                Origin = $origin
            }
        }
    }
}
if ($strays) {
    # **領域ごとに違う退避先を出す**（レビュー指摘）。一律で `scripts-local\` を案内していたが、
    # **Assets 配下の .cs をそこへ移すとコンパイル対象から外れ、e2e_driver のモジュールは
    # import できなくなる** ― 案内どおり動くと壊れる領域があった
    $advice = [ordered]@{
        (Join-UappPath $kit "scripts")           = "uapp_e2e\scripts-local\（既定の uninstall で保持されます）"
        (Join-UappPath $kit "docs")              = "uapp_e2e\scripts-local\ など、キットが触らない場所へ"
        (Join-UappPath $kit "driver\e2e_driver") = "driver\ の外（import 元を変える必要があります）"
        (Join-UappPath $kit "oslayer")           = "キットが触らない場所へ"
        (Join-UappPath $target "Assets\uapp_e2e\E2EBridge") =
            "**Assets\ の中の別フォルダへ**（Assets の外へ出すとコンパイル対象から外れます）"
    }
    # 由来ごとに、見出しと「どうすればよいか」を変える。**観測したことだけを書く**
    $strayGroups = [ordered]@{
        "local"     = @{
            # **「キットが配ったものではない」と断定しない。** 前回の記録に無いことから言えるのは
            # 「**直前の導入では配っていない**」までで、もっと前のキットが配った残骸かもしれない。
            # 記録は毎回上書きされ、キット所有でないものは載らないので、**配布対象から外れた
            # ファイルが kit-stale と判定されるのは、外れた直後の 1 回だけ**（実測）。
            # 2 回目以降はここへ落ちてくるため、ここで断定すると必ず嘘になる
            Head = "[情報] いまのキットが配っていないファイルが、キットの領域にあります:"
            Tail = ("  導入先が置いたものか、以前のキットが配った残骸かは、記録からは分かりません" +
                    "（記録に残るのは直前の導入ぶんだけです）。" + [Environment]::NewLine +
                    "  **uninstall.ps1 はこれらのディレクトリを丸ごと消します。** 導入先の資産だった場合の退避先:")
            ShowAdvice = $true
        }
        "kit-stale" = @{
            Head = "[情報] 以前のキットが配ったもので、いまは配布対象ではないファイルがあります:"
            Tail = ("  キットの更新では消えません（自動で消すのは開発専用スクリプトの名前だけです）。" +
                    [Environment]::NewLine +
                    "  **導入先の資産ではないので、不要なら削除してよいものです。**")
            ShowAdvice = $false
        }
        "unknown"   = @{
            Head = "[情報] キットが置いたのか導入先が置いたのか判定できないファイルが、キットの領域にあります:"
            Tail = ("  前回の所有記録（kit-manifest.json）が無い導入なので、由来を確かめられません。" +
                    [Environment]::NewLine +
                    "  **中身を見て決めてください。** 導入先の資産だった場合の退避先:")
            ShowAdvice = $true
        }
    }
    foreach ($originKey in $strayGroups.Keys) {
        $group = @($strays | Where-Object { $_.Origin -eq $originKey })
        if (-not $group) { continue }
        $g = $strayGroups[$originKey]
        Write-Host ""
        Write-Host $g.Head
        foreach ($f in ($group | Sort-Object Path | Select-Object -First 10)) { Write-Host "  $($f.Path)" }
        if ($group.Count -gt 10) { Write-Host "  …ほか $($group.Count - 10) 件" }
        Write-Host $g.Tail
        if ($g.ShowAdvice) {
            foreach ($area in ($group | Select-Object -ExpandProperty Area -Unique)) {
                $rel = $area.Substring((Resolve-UappFsPath $target).Length).TrimStart('\', '/')
                Write-Host "    $rel → $($advice[$area])"
            }
        }
    }
}

# **配置したキット所有ファイルの改行を LF へ揃える**（issue #55）。
# 配布 zip 側は package-kit が梱包の出口で揃えるが、**開発リポジトリから直接導入する経路**は
# そこを通らない。片方だけ直すと、**そちらの経路でだけ CRLF が導入先へ届く**
# （「同じ規約を 2 か所へ手書きしない」と同型で、実装は uapp-platform に 1 つだけ置く）。
# 記録より**先に**揃える ― 後だと manifest が正規化前の内容で書かれ、
# 直後の -VerifyManifest が「改変」と言う（記録側も LF 正規化するので実害は無いが、
# 「記録した中身」と「置いた中身」が食い違うのは避ける）
$lfChanged = 0
foreach ($f in (Get-KitOwnedFiles $target $ownedSourceMap)) {
    if (Convert-UappFileToLf -Path $f) { $lfChanged++ }
}
if ($lfChanged -gt 0) { Write-Host "  [OK] 改行を LF へ正規化: $lfChanged ファイル（BOM は保つ）" }

foreach ($f in (Get-KitOwnedFiles $target $ownedSourceMap | Sort-Object)) {
    $rel = $f.Substring($target.Length + 1)
    # **大小文字だけが違うキーは 1 つに潰れる**（`[ordered]@{}` は大小文字を区別しない）。
    # **大小文字を区別する FS では `run-e2e.ps1` と `Run-E2E.ps1` が共存できる**ので、
    # 後から入れた方が勝って**キット本体のエントリが manifest から黙って消える** ―
    # その状態で `-VerifyManifest` を回すと「改変 0 件・exit 0」＝**偽の緑**になり、
    # 改変検知だけが無効のまま気づけない（2026-08-25 に mac セッションが
    # case-sensitive APFS で実測。**#40 の退行ではなく元からの性質**）。
    # **Ordinal 化はしない** ― 大小文字違いのキーを 2 つ書けてしまい、読み側の
    # `ConvertFrom-Json` が `keys with different casing` で落ちて**記録が二度と読めなくなる**
    # （注入モードの台帳で同じ罠を踏んでいる）。**書く前に止めて、人に名前を直してもらう**
    if ($manifestEntries.Contains($rel)) {
        $existing = @($manifestEntries.Keys) | Where-Object { $_ -eq $rel } | Select-Object -First 1
        throw ("大小文字だけが違うファイルがキットの領域にあります（改変検知の記録が作れません）:" + [Environment]::NewLine +
               "  $existing" + [Environment]::NewLine +
               "  $rel" + [Environment]::NewLine +
               "kit-manifest.json のキーは大小文字を区別しないため、この 2 つは 1 件に潰れ、" +
               "**キット本体のファイルが記録から消えて改変検知が無効になります**" +
               "（-VerifyManifest が『改変 0 件』と言う偽の緑）。" +
               "導入先の自作ファイルの名前を変える（または uapp_e2e\scripts-local\ へ移す）" +
               "→ installer を再実行してください。" + [Environment]::NewLine +
               "**ファイルの配置自体は完了しています。前回の kit-manifest.json はそのまま残しました**" + [Environment]::NewLine +
               "そのため、この実行で更新されたファイルは -VerifyManifest から「改変」に見えます（記録が前回のままなので当然です）。名前を直して再実行すれば揃います")
    }
    $manifestEntries[$rel] = Get-KitFileHash $f   # テキストは改行を正規化して記録（OS 間で揃える）
}
$manifestEntries | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding utf8
# **生成したファイルも LF へ**（issue #55）。導入先で git 管理されるので、
# CRLF のままだとキット所有ファイルと同じ差分ノイズが出る
[void](Convert-UappFileToLf -Path $manifestPath)
Write-Host "  [OK] uapp_e2e\kit-manifest.json（次回更新時のローカル改変検知用）"

# --- 4.6 配布をやめたファイルの報告（issue #42） ---------------------------
# **キットは削除しない。** 導入先がそのファイルを使い続けているかを知る手段が無いので、
# **判断材料だけ渡して、消すかどうかは導入先に決めてもらう**。
# #40 は「消しすぎ」（導入先の自作をキット所有と誤判定して無警告削除）で起きたので、
# **自動削除の側へは倒さない**。
#
# **既存の「開発専用スクリプトの掃除」（上）はそのまま**。あれは
# **キット自身が置いたと分かっているものだけ**を対象にした狭い経路で、#40 で安全側に寄せてある。
if ($retiredEntries.Count -gt 0) {
    $retiredFound = @()
    foreach ($entry in $retiredEntries) {
        if (-not $entry.path) { continue }
        $rel = ($entry.path -replace '/', [IO.Path]::DirectorySeparatorChar)
        $abs = Join-UappPath $target $rel
        if (-not (Test-Path -LiteralPath $abs)) { continue }
        # **改変されているかは前回の記録と突き合わせる**（記録が無ければ「判定できない」）。
        # ここでも**断定しない** ― 記録が無い導入（手動・記録の削除・注入モード）が普通にある
        $recorded = $null
        if ($script:prevManifest) {
            $key = ConvertTo-UappPathKey $rel
            foreach ($e in $script:prevManifest.PSObject.Properties) {
                if ((ConvertTo-UappPathKey $e.Name) -eq $key) { $recorded = $e.Value; break }
            }
        }
        $state = if (-not $recorded) { "前回の記録が無く、改変されているかは判定できません" }
                 elseif ((Get-KitFileHash $abs) -eq $recorded) { "内容はキットが配ったままです" }
                 else { "**改変されています**" }
        $retiredFound += [pscustomobject]@{
            Rel = $rel
            RetiredIn = $(if ($entry.retiredIn) { $entry.retiredIn } else { "版は不明" })
            State = $state
            Note = $entry.note
        }
    }
    if ($retiredFound.Count -gt 0) {
        Write-Host ""
        Write-Host "[情報] キットが配布をやめたファイルが残っています（$($retiredFound.Count) 件）:"
        foreach ($f in ($retiredFound | Sort-Object Rel)) {
            Write-Host "  $($f.Rel)"
            Write-Host "    $($f.RetiredIn) で配布終了 / $($f.State)"
            if ($f.Note) { Write-Host "    $($f.Note)" }
        }
        Write-Host "  **キットは削除しません。** 使っていなければ導入先の判断で削除してください"
        Write-Host "  （使い続けるなら uapp_e2e\scripts-local\ など、キットが触らない場所へ移すと更新で消えません）"
    }
}

# --- 4.5 ドキュメントが案内するスクリプトが実在するかの検査 ---
# キットの文書は `.\scripts\<名前>.ps1` の形でコマンドを案内する。
# **案内しているのに配られていない**と、読んだ AI が実行して初めて「ファイルが無い」と気づく
# （v0.1.6 で実際に起きた: unity-editor-status.ps1 が配布の列挙から漏れていた）。
# 配布の仕組みを列挙から一括コピーへ変えたうえで、食い違いをここでも検出する。
# **見る文書も列挙しない**（同じ漏れ方をする）。AI が読むのは CLAUDE.md / SETUP.md だけでなく、
# docs\ai-loop.md やスキル（.claude\skills / .agents\skills）にも `.\scripts\*.ps1` が出てくる
$docRoots = @((Join-UappPath $kit "CLAUDE.md"), (Join-UappPath $kit "AGENTS.md"),
              (Join-UappPath $kit "SETUP.md"), (Join-UappPath $kit "docs"),
              (Join-UappPath $target ".claude\rules\uapp-e2e.md"))
# **スキルはキット所有の e2e-* だけ**を見る（Get-KitOwnedFiles と同じ範囲）。
# skills\ 全体を走査すると、ユーザーの無関係なスキル文書が `scripts\…ps1` に言及しただけで
# 「キットが案内しているのに無い」と誤警告する
foreach ($skillsRoot in @(".claude\skills", ".agents\skills")) {
    foreach ($name in @("e2e-setup", "e2e-run", "e2e-write-test", "e2e-dump")) {
        $docRoots += Join-UappPath $target "$skillsRoot\$name"
    }
}
$docFiles = @()
foreach ($docRoot in $docRoots) {
    if (-not (Test-Path -LiteralPath $docRoot)) { continue }
    if (Test-Path -LiteralPath $docRoot -PathType Container) {
        $docFiles += @(Get-UappTreeFile $docRoot |
                       Where-Object { [System.IO.Path]::GetExtension($_) -ieq ".md" })
    } else {
        $docFiles += $docRoot
    }
}
$docScriptRefs = @()
foreach ($doc in ($docFiles | Select-Object -Unique)) {
    # **空ファイルで落とさない**。`Get-Content -Raw` は $null を返し、[regex]::Matches が
    # 例外になる（$ErrorActionPreference=Stop なので、ここまでのコピーを済ませた状態で
    # installer 全体が中断する）。検査は付加価値であって、導入を止める理由にしない
    $raw = Get-Content -LiteralPath $doc -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($raw)) { continue }
    foreach ($m in [regex]::Matches($raw, 'scripts[\\/]([A-Za-z0-9._-]+\.ps1)')) {
        $docScriptRefs += $m.Groups[1].Value
    }
}
# 開発専用スクリプトは除く。文書は「開発リポジトリから実行する場合」として
# `.\scripts\install-to-project.ps1 …` にも言及するが、これは導入先に置くものではない
$missingDocScripts = @($docScriptRefs | Select-Object -Unique |
                       Where-Object { $devOnlyScripts -notcontains $_ } |
                       Where-Object { -not (Test-Path -LiteralPath (Join-UappPath $kit "scripts\$_")) })
if ($missingDocScripts.Count -gt 0) {
    Write-Host ""
    Write-Host "  [警告] キットの文書が案内しているのに配置されていないスクリプトがあります:"
    foreach ($m in $missingDocScripts) { Write-Host "    - uapp_e2e\scripts\$m" }
    Write-Host "  キット側の不具合です（配布物の作り方かドキュメントのどちらかが間違っている）。報告してください"
    Write-Host ""
}

# --- 5. 残りの手動手順の表示（検出できる項目は導入状況を照合して [済]/[未] を付ける） ---
function Get-ManifestDependencyVersion($name) {
    $manifestJson = Join-UappPath $target "Packages\manifest.json"
    if (-not (Test-Path -LiteralPath $manifestJson)) { return $null }
    try { (Get-Content -LiteralPath $manifestJson -Raw | ConvertFrom-Json).dependencies.$name } catch { $null }
}
function Mark($done) { if ($done) { "[済]" } else { "[未]" } }
$inputSystemVer = Get-ManifestDependencyVersion "com.unity.inputsystem"
$newtonsoftVer = Get-ManifestDependencyVersion "com.unity.nuget.newtonsoft-json"
$projSettings = Join-UappPath $target "ProjectSettings\ProjectSettings.asset"
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
if (Test-Path -LiteralPath $projSettings) {
    $keyIndent = $null
    foreach ($line in (Get-Content -LiteralPath $projSettings)) {
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
# device を含む運用は Android 必須。editor 専用ならどこかに付いていればよい。
# ios は恒久 define 不要（BuildEntry がビルド時に一時付与・復元する）ため判定しない
$defineFound = if ($Mode -eq "editor") { $defineTargets.Count -gt 0 } else { $androidDefine }
# iOS ターゲット（新形式 iPhone / 旧形式 4→iOS）への**恒久付与は逆に警告対象**:
# BuildEntry の一時付与と重複するだけでなく、**本番の iOS ビルドに計装が混入する**
$iosDefineLeak = @($defineTargets | Where-Object { $_ -in @("iPhone", "iOS") }).Count -gt 0
$localJsonDone = Test-Path -LiteralPath (Join-UappPath $kit "config\local.json")
# 行単位で照合（コメント行や uapp_e2e/Builds-old のような別パスに誤反応しない。
# 区切りは / のみ受理: gitignore のバックスラッシュはパス区切りでなくエスケープなので無効な記述。
# 行頭空白もパターンの一部として扱われるため許容しない。末尾空白は Git が無視するので許容）。
# Unity プロジェクトが git ルートのサブディレクトリにある構成（<repo>\<unity-project>）では
# 除外はプロジェクト直下でなく上位の .gitignore や .git\info\exclude に書かれるため、
# .git が見つかるまで上位も照合する（上位では相対プレフィックス付きのパターンを要求する）
function Test-GitignoreEntries([string]$file, [string]$relPrefix) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
    $p = [regex]::Escape($relPrefix)
    ((Select-String -Path $file -Pattern "^/?${p}uapp_e2e/config/local\.json\s*$" -Quiet) -and
     (Select-String -Path $file -Pattern "^/?${p}uapp_e2e/Builds/?\s*$" -Quiet))
}
$gitignoreDone = $false
$gitignoreProbe = $target
$gitignoreRel = ""
while ($true) {
    if (Test-GitignoreEntries (Join-UappPath $gitignoreProbe ".gitignore") $gitignoreRel) { $gitignoreDone = $true; break }
    if (Test-Path -LiteralPath (Join-UappPath $gitignoreProbe ".git")) {
        # git ルートに到達。ローカル除外（.git\info\exclude）も同じ書式で照合する
        #（.git がファイルの worktree / submodule 構成では exclude の実体が別階層にあり、ここでは追わない）
        $gitignoreDone = Test-GitignoreEntries (Join-UappPath $gitignoreProbe ".git\info\exclude") $gitignoreRel
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
$iosBundleMismatch = $null
if ($configExisted) {
    try {
        $cfg = Get-Content -LiteralPath $configDest -Raw | ConvertFrom-Json
        $testsPath = if ($cfg.tests) { Join-UappPath $kit "driver\$($cfg.tests)" } else { $null }
        $packageOk = ($Mode -eq "editor") -or ($cfg.package -and ($cfg.package -ne "com.yourcompany.yourapp"))
        $configEdited = $packageOk -and $testsPath -and (Test-Path -LiteralPath $testsPath)
        if ($testsPath -and -not (Test-Path -LiteralPath $testsPath)) { $testsStale = $cfg.tests }
        # -Mode ios では package を bundle id として使う。ProjectSettings の iOS 側
        # applicationIdentifier と食い違っていると、build-ios（-AppId 未指定）は
        # プロジェクト設定のままビルドし、run-ios-e2e が .app との不一致で停止する
        # （外部レビュー指摘: Android の package を書き写した既存導入が [済] のまま実行時に
        # 初めて止まる）。ここは判定を [未] に倒すのではなく、食い違いを名指しする —
        # -AppId や BuildEntry で上書きする運用もあるため、一致だけを正とはしない
        if ($Mode -eq "ios" -and $packageOk) {
            $projSettingsPath = Join-UappPath $target "ProjectSettings\ProjectSettings.asset"
            if (Test-Path -LiteralPath $projSettingsPath) {
                $inAppId = $false
                foreach ($line in (Get-Content -LiteralPath $projSettingsPath)) {
                    if ($line -match '^\s*applicationIdentifier:') { $inAppId = $true; continue }
                    if ($inAppId) {
                        if ($line -match '^\s*iPhone:\s*(\S+)\s*$') {
                            if ($Matches[1] -ne $cfg.package) { $iosBundleMismatch = $Matches[1] }
                            break
                        }
                        if ($line -match '^\S') { break }   # ブロック終端
                    }
                }
            }
        }
    } catch { $configEdited = $false }
}

# ポートの重なりは実行してみるまで気付けない（別プロジェクトのブリッジが待受を握ると
# 「bind failed」や別アプリへの誤接続として現れる）。導入時に静かに潰しておく
#
# **比べるのは「ホスト側の forward ポート」と `editorBridgePort`**。デバイス実行は
# `adb forward tcp:<ホスト側> tcp:<devicePort>` を張り、**ホスト側は adb が LISTEN し続ける**ため、
# その番号が `editorBridgePort` と同じだと**エディタ直結の接続先を奪う**。
# devicePort 同士を比べるのは誤り（ホスト側は `-HostPort` / local.json の `bridgePort` で
# 独立に決まる。実例: ホスト側 13334・devicePort 13333・editorBridgePort 13333 は
# 「devicePort ≠ editorBridgePort」では検出できないのに実際は衝突しない、逆も起きる）。
# **並行実行に限らない**: forward は実行後も残るので、順番に回すだけで踏む（issue #25）
$portNote = $null
$iosPortMissing = $false    # iOS 案内（macOS のみ表示）で使う。欠落は衝突ではないのでここでは [未] にしない
if (Test-Path -LiteralPath $configDest) {     # 既存・新規生成のどちらでも見る（雛形の値のままでも重なりは重なり）
    # **型変換はすべてこのヘルパで行い、不正は $portNote に積む**。`[int]` キャストの例外は
    # 外側の catch に握り潰され、ポート検査全体が黙って死んで [済] が偽の緑になる
    # （外部レビュー指摘。`(if …)` の握り潰しと同じ型）。値域は 1〜65535（実行系と同じ）
    $parsePort = {
        param($raw)
        $v = 0
        if (($null -ne $raw) -and [int]::TryParse([string]$raw, [ref]$v) -and $v -ge 1 -and $v -le 65535) { $v }
        else { $null }
    }
    $badPorts = @()
    try {
        $cfg = Get-Content -LiteralPath $configDest -Raw | ConvertFrom-Json
        $editor = & $parsePort $cfg.editorBridgePort
        if ($null -eq $editor) {
            $badPorts += "editorBridgePort（'$($cfg.editorBridgePort)'）"
        }
        # ホスト側ポートは local.json の bridgePort。**導入時点ではまだ無いことが多い**
        # （残手順 4 で作る）ので、その場合は既定値で仮判定し、文面でもそう断る
        $hostPort = 13333
        $hostPortKnown = $false
        $localJson = Join-UappPath $kit "config\local.json"
        if (Test-Path -LiteralPath $localJson) {
            try {
                $lc = Get-Content -LiteralPath $localJson -Raw | ConvertFrom-Json
                if ($null -ne $lc.bridgePort) {
                    $parsedHost = & $parsePort $lc.bridgePort
                    if ($null -ne $parsedHost) { $hostPort = $parsedHost; $hostPortKnown = $true }
                    else { $badPorts += "config\local.json の bridgePort（'$($lc.bridgePort)'）" }
                }
            } catch { }
        }
        if ($editor -and $hostPort -eq $editor) {
            $basis = if ($hostPortKnown) { "config\local.json の bridgePort" }
                     else { "既定の 13333（config\local.json が未作成のため**仮の値**）" }
            # **local.json が無いときは断定しない**。エディタ専用運用（adb forward を張らない）や、
            # 実行時に -HostPort で別番号を渡す運用では、この一致は問題にならない
            # `$(if …)` のサブ式にする。`(if …)` は**構文解析を通るのに実行時に落ちる**
            # （括弧内では `if` がコマンド名として解釈される）。外側の catch が握り潰すため、
            # この警告全体が黙って死んでいた（Windows 側の A/B で発見）
            $portNote = ($(if ($hostPortKnown) { "" } else { "（参考・要確認）" }) +
                         "ホスト側の forward ポート（$basis）と editorBridgePort が同じ値（$editor）。" +
                         "デバイス実行が張った adb forward はホスト側ポートを LISTEN したまま残るため、" +
                         "**並行実行でなくても、デバイス実行のあとにエディタ直結を回すと接続先を奪われる**。" +
                         "editorBridgePort をずらす（例: $($editor + 30)）。" +
                         "**デバイス実行を使わない（エディタ専用）構成や、実行時に -HostPort で" +
                         "別番号を渡す構成なら、このままで問題ない**")
        }
        # iOS シミュレータの待受は**ホストのポート名前空間で直接 LISTEN する**ため、
        # devicePort・editorBridgePort・ホスト側 forward のどれとも別番号が必須（docs/02）。
        # **欠落**（iOS を使わない・旧テンプレ由来の設定）は衝突ではないのでここでは咎めず、
        # macOS の iOS 案内側で名指しする。**値があるのに不正**は握り潰さない — run-ios-e2e は
        # 同じ値を明示エラーにするので、ここで黙ると [済] が偽の緑になる（外部レビュー指摘）。
        # **上の editorBridgePort 警告より後で合成する**（前に置くと上の代入で上書きされる）
        $iosPort = $null
        $iosNote = $null
        if ($null -eq $cfg.iosSimulatorPort) {
            $iosPortMissing = $true
            if ($Mode -eq "ios") {
                # iOS 専用モードでは必須値（run-ios-e2e が明示エラーで止まる）。
                # 他モードでは任意機能なので咎めない（macOS の iOS 案内側で名指しする）
                $iosNote = ("e2e-config.json に iosSimulatorPort がありません（旧テンプレからの導入は" +
                            "既存設定を上書きしないため手で追記が必要。無いままだと run-ios-e2e.ps1 は明示エラーで止まる）")
            }
        } else {
            $iosPort = & $parsePort $cfg.iosSimulatorPort
            if ($null -eq $iosPort) {
                $iosNote = ("iosSimulatorPort（'$($cfg.iosSimulatorPort)'）が 1〜65535 の整数ではない" +
                            "（このままだと run-ios-e2e.ps1 が明示エラーで止まる）")
            }
        }
        $devPort = $null
        if ($null -ne $cfg.devicePort) {
            $devPort = & $parsePort $cfg.devicePort
            if ($null -eq $devPort) { $badPorts += "devicePort（'$($cfg.devicePort)'）" }
        }
        if ($iosPort -and (($editor -and $iosPort -eq $editor) -or $iosPort -eq $hostPort -or
                           ($devPort -and $iosPort -eq $devPort))) {
            $iosNote = ("iosSimulatorPort（$iosPort）が devicePort / editorBridgePort / ホスト側 forward ポートの" +
                        "いずれかと同じ値。シミュレータのアプリはホストのポートを直接 LISTEN するため、" +
                        "**どれとも別番号**にすること（例: $($iosPort + 40)）")
        }
        if ($iosNote) {
            $portNote = if ($portNote) { "$portNote / $iosNote" } else { $iosNote }
        }
        if ($badPorts.Count -gt 0) {
            $badNote = ("次の値が 1〜65535 の整数として読めない: " + ($badPorts -join "、") +
                        "。読めない値は衝突の判定からも外れているので、直してから再実行で確かめること")
            $portNote = if ($portNote) { "$portNote / $badNote" } else { $badNote }
        }
    } catch { }
}

Write-Host ""
Write-Host "=== 残りの手動手順（[済]=導入済みを検出。詳細: docs/05-install-to-project.md） ==="
if ($Mode -eq "editor") {
    Write-Host "モード: editor（エディタ直結E2Eのみ。Android ビルド・adb・AVD は使わない）"
}
if ($Mode -eq "ios") {
    Write-Host "モード: ios（iOS シミュレータ/実機のみ。Android ビルド・adb・AVD は使わない）"
    if (-not (Test-UappIosSupported)) {
        Write-Host "     ※ iOS の実行（build-ios / run-ios-e2e）は macOS のみ。このマシンでは導入までで、実行はチームの mac で行う"
    }
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
} elseif ($Mode -eq "ios") {
    Write-Host "2. $(Mark $configEdited) $configDest の package / orientation を実アプリに合わせて編集"
    Write-Host ("     （**iOS では package を bundle id として使う**。activity は使わないので空でよい。" +
                "tests は既定の `"tests`" のままでよい。" +
                $(if ($configEdited) { "[済] は package 設定済み・tests のパスが実在することまで＝orientation は人が確認する" }
                  else { "package が雛形のまま、または tests の指すパスが見つからない" }) + "）")
    if ($iosBundleMismatch) {
        Write-Host "     → [注意] ProjectSettings の iOS bundle id（$iosBundleMismatch）と package が食い違っています。"
        Write-Host "       **シミュレータ経路**は build-ios.ps1 が -AppId 未指定だとプロジェクト設定のまま"
        Write-Host "       ビルドするため、run-ios-e2e.ps1 が .app との不一致で停止します（どちらかへ揃えるか -AppId で明示）。"
        Write-Host "       実機経路を -AppId / config\local.json の iosDeviceAppId で上書きする構成なら、そちらはこのままでよい"
    }
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
} elseif ($Mode -eq "ios") {
    # iOS は BuildEntry がビルド時に一時付与・復元するので、ビルドのための恒久付与は不要。
    # [済/未] の判定対象にせず、付いている場合は**意図を区別して**注意を出す:
    # エディタ直結（Play）を iOS プラットフォームのまま使う構成では恒久付与が正当
    # （エディタはアクティブターゲットの define でコンパイルする）。危険なのは、
    # その define が残ったまま BuildEntry 以外（自前パイプライン・手動）で本番 iOS ビルドを
    # 作る場合＝計装が混入する
    Write-Host "3. [不要] UAPP_E2E_BRIDGE define の恒久付与は不要（build-ios.ps1 の BuildEntry がビルド時に一時付与し、終了時に復元する）"
    if ($iosDefineLeak) {
        Write-Host "     → [注意] iOS ターゲットに UAPP_E2E_BRIDGE が恒久付与されています。"
        Write-Host "       **エディタ直結（iOS プラットフォームのまま Play）を使うための付与なら妥当**ですが、"
        Write-Host "       **BuildEntry を通さない本番 iOS ビルド（自前パイプライン・手動）には計装が混入**します。"
        Write-Host "       本番ビルド前に外す運用をチームで明確にしておくこと"
    }
} else {
    Write-Host "3. $(Mark $defineFound) テスト用ビルドに UAPP_E2E_BRIDGE define を付与（APK に入れるには Android 向けが必要）"
}
if ($Mode -ne "ios") {
    Write-Host "     $(if ($defineTargets.Count) { "→ 現在付いているターゲット: $($defineTargets -join ', ')" } else { "→ どのターゲットにも見つからない" })"
    Write-Host "     （自前ビルドスクリプト側で付与する構成は ProjectSettings に現れないため [未] 表示のままでよい）"
}
if ($Mode -eq "editor") {
    Write-Host "4. $(Mark $localJsonDone) uapp_e2e\config\local.sample.json を local.json にコピー（avd は空のままでよい）"
} elseif ($Mode -eq "ios") {
    Write-Host "4. $(Mark $localJsonDone) uapp_e2e\config\local.sample.json を local.json にコピー（avd は空のままでよい。"
    Write-Host "     実機を使うなら iosTeamId / iosDeviceAppId / iosOsAgentBundleId を記入。シミュレータだけなら空のままでよい）"
} else {
    Write-Host "4. $(Mark $localJsonDone) uapp_e2e\config\local.sample.json を local.json にコピーして各自の環境を記入"
}
Write-Host "5. $(Mark $gitignoreDone) .gitignore に追加: uapp_e2e/config/local.json, uapp_e2e/Builds/"
# [済] が言えるのは「その行が .gitignore（または .git/info/exclude）にある」ことまで。
# 既に追跡済みのファイルは ignore 行を足しても追跡され続けるし、後続の否定規則（!…）で
# 再包含されることもある。判定できないことを [済] に含めて読ませない
Write-Host "     （判定はパターンの有無まで。既にコミット済みのファイルは行を足しても追跡され続けるので、"
Write-Host "     その場合は git rm --cached が別途必要）"
Write-Host "6. $(Mark (-not $portNote)) 待受ポートが他と重ならないこと（devicePort / editorBridgePort / iosSimulatorPort）"
if ($portNote) { Write-Host "     → $portNote" }
Write-Host "     （同一デバイスに計装アプリを複数入れる場合も devicePort をアプリごとに分ける）"
if ($Mode -eq "editor") {
    Write-Host "7. 初回の run-e2e.ps1 -Editor は Packages/manifest.json へ com.unity.pipeline（Unity CLI 連携）を"
    Write-Host "     自動追加する（追跡ファイルが変わる。コミットするか事前にチームで方針を決めておく）"
}
if ((Test-UappIosSupported) -or ($Mode -eq "ios")) {
    # iOS 経路は macOS でしか動かない（xcodebuild / simctl）ので、mac で導入したときだけ案内する。
    # ただし -Mode ios の明示宣言があれば OS を問わず出す（Windows から導入してチームの mac で
    # 実行する構成のため。その場合の実行制約はモード行の ※ で断ってある）
    Write-Host ""
    Write-Host "=== iOS で使う場合（macOS のみ・任意） ==="
    if (Test-UappIosSupported) {
        # **xcrun の存在では判定しない**（Command Line Tools だけでも xcrun は居る — 外部レビュー指摘）。
        # iphonesimulator SDK が実際に解決できるかで見る（= Xcode 本体＋iOS SDK が要る。
        # Unity の iOS Support モジュールまでは判定できないので文言で案内）
        $xcodeOk = $false
        $xcrunPath = Get-UappCommandPath "xcrun"
        if ($xcrunPath) {
            try {
                & $xcrunPath --sdk iphonesimulator --show-sdk-path *> $null
                $xcodeOk = ($LASTEXITCODE -eq 0)
            } catch { }
        }
        Write-Host "  $(Mark $xcodeOk) Xcode（iphonesimulator SDK が解決できる$(if (-not $xcodeOk) { "。Xcode 本体を導入し `xcodebuild -runFirstLaunch` を済ませること" })。Unity の iOS Support モジュールは別途 Hub から追加）"
    }
    Write-Host "  シミュレータ: uapp_e2e\scripts\build-ios.ps1 → run-ios-e2e.ps1（前提: Xcode＋Unity の iOS Support）"
    Write-Host "  実機:        build-ios.ps1 -Target device → run-ios-e2e.ps1 -Target device（Apple Development 署名）"
    Write-Host "  e2e-config.json の iosSimulatorPort を devicePort / editorBridgePort と別番号で設定すること。"
    if ($iosPortMissing -and $Mode -ne "ios") {
        # -Mode ios では手順 6 のポート検査が [未] として名指し済み（二重に言わない）
        Write-Host "  → **e2e-config.json に iosSimulatorPort がありません**（旧テンプレからの導入。"
        Write-Host "     既存の設定は上書きしないため手で追記が必要。無いままだと run-ios-e2e.ps1 は明示エラーで止まる）"
    }
    Write-Host "  制約（アプリ外は操作不可・スクショの取得経路）は SETUP.md の「iOS で使う場合」を先に読むこと"
}
if ($installClaude) {
    Write-Host "（AI向け規約は .claude\rules\uapp-e2e.md 経由で自動参照される。CLAUDE.md の書き換えは不要）"
}
if ($installCodex) {
    Write-Host ""
    Write-Host "=== Codex（OpenAI Codex CLI v0.94.0 以降）で使う場合 ==="
    Write-Host "スキルは .agents\skills\ に配置済み: `$e2e-setup / `$e2e-run / `$e2e-write-test / `$e2e-dump（/skills で一覧確認）"
    if (-not (Test-Path -LiteralPath $rootAgentsPath)) {
        Write-Host "ルートに AGENTS.md が無いため、Codex のルート起動では E2E 導線が自動読込されません。"
        Write-Host "  -RootAgentsMd を付けて再実行するとポインタを新規作成します（既存プロジェクトファイルは変更しない）"
    } elseif (-not ((Get-Content -LiteralPath $rootAgentsPath -Raw) -match 'uapp_e2e')) {
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
exit 0
