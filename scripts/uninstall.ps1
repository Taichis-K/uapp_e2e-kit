# E2E キット一式をプロジェクトから取り外す（install-to-project.ps1 の対）。
# 導入時に <プロジェクト>\uapp_e2e\scripts\uninstall.ps1 として配布され、kit zip が無くても単体で実行できる。
# 使い方: .\uninstall.ps1 [-ProjectPath <Unityプロジェクトのパス>] [-Purge]
#   既定:   キット所有ファイルのみ削除。プロジェクト所有（e2e-config.json / driver\tests\ の自作テストと
#           conftest.py / config\local.json / Builds\）は残す＝installer 再実行で設定ごと復帰する
#   -Purge: uapp_e2e\ を丸ごと削除（ジャーニー記録・更新バックアップ含む）。installer -RootAgentsMd が
#           作成したルート AGENTS.md も、生成時から未編集の場合に限り削除する
# ProjectSettings の UAPP_E2E_BRIDGE define と Packages\manifest.json の追加パッケージは自動では戻さない
# （他機能が使っている可能性があるため。最後に残手順として表示する）。詳細: docs/05-install-to-project.md
param(
    [string]$ProjectPath,
    [switch]$Purge
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "uapp-platform.ps1")   # OS 差分の吸収（Windows / macOS。mac は暫定・未検証）

# --- 対象の解決: 引数 > 自身の配置場所（<プロジェクト>\uapp_e2e\scripts\ に配布される前提） ---
if ($ProjectPath) {
    $target = (Resolve-Path -LiteralPath $ProjectPath).Path
} else {
    $target = (Resolve-Path -LiteralPath (Join-UappPath $PSScriptRoot "..\..")).Path
}
if (-not ((Test-Path -LiteralPath (Join-UappPath $target "Assets")) -and (Test-Path -LiteralPath (Join-UappPath $target "ProjectSettings")))) {
    throw "Unity プロジェクトではありません（Assets/ProjectSettings が見つからない）: $target"
}
$kit = Join-UappPath $target "uapp_e2e"
if (-not ((Test-Path -LiteralPath $kit) -or (Test-Path -LiteralPath (Join-UappPath $target "Assets\uapp_e2e")))) {
    throw "キットが導入されていません（uapp_e2e\ も Assets\uapp_e2e\ も無い）: $target"
}

Write-Host "アンインストール対象: $target"
Write-Host ("モード: " + $(if ($Purge) { "-Purge（uapp_e2e\ 全体と未編集のルート AGENTS.md も削除）" }
                           else { "既定（キット所有のみ。設定・自作テスト・記録は残す）" }))

# **ディレクトリの削除と空判定は Remove-UappTree / Test-UappDirEmpty で行う**。
# `Remove-Item -Recurse` と `Get-ChildItem` は**大小文字だけ違う別ディレクトリ**を掴むことが
# あり（PowerShell の既知不具合。詳細と一次情報は helper のヘルプ）、ここは
# **導入先のツリーを消す経路**なので取り違えの影響が大きい
function Remove-Reported($path, $label) {
    if (Test-Path -LiteralPath $path) {
        Remove-UappTree $path
        Write-Host "  [削除] $label"
    }
}
function Remove-IfEmpty($path) {
    if (Test-UappDirEmpty $path) { Remove-UappTree $path }
}

# --- 1. 計装SDK（キット所有は E2EBridge のみ。Assets\uapp_e2e\ 直下のユーザー独自アセットは消さない） ---
Remove-Reported (Join-UappPath $target "Assets\uapp_e2e\E2EBridge") "Assets\uapp_e2e\E2EBridge\（計装SDK）"
Remove-Reported (Join-UappPath $target "Assets\uapp_e2e\E2EBridge.meta") "Assets\uapp_e2e\E2EBridge.meta"
Remove-IfEmpty (Join-UappPath $target "Assets\uapp_e2e")
if (-not (Test-Path -LiteralPath (Join-UappPath $target "Assets\uapp_e2e"))) {
    Remove-Reported (Join-UappPath $target "Assets\uapp_e2e.meta") "Assets\uapp_e2e.meta"
}

# --- 2. AIスキル・ルール（キットの e2e-* のみ。他のスキル・ルールには触らない） ---
foreach ($skillsRoot in @(".claude\skills", ".agents\skills")) {
    foreach ($name in @("e2e-setup", "e2e-run", "e2e-write-test", "e2e-dump")) {
        Remove-Reported (Join-UappPath $target "$skillsRoot\$name") "$skillsRoot\$name\"
    }
    Remove-IfEmpty (Join-UappPath $target $skillsRoot)
}
Remove-Reported (Join-UappPath $target ".claude\rules\uapp-e2e.md") ".claude\rules\uapp-e2e.md"
foreach ($d in @(".claude\rules", ".claude", ".agents")) { Remove-IfEmpty (Join-UappPath $target $d) }

# --- 3. uapp_e2e\ ---
if ($Purge) {
    # ルート AGENTS.md を installer が作成した記録（kit-manifest.json のメタ記録）を、削除前に読んでおく
    $rootAgentsByInstaller = $false
    $manifestPath = Join-UappPath $kit "kit-manifest.json"
    if (Test-Path -LiteralPath $manifestPath) {
        try { $rootAgentsByInstaller = [bool]((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)."__rootAgentsMdByInstaller") } catch {}
    }
    Remove-Reported $kit "uapp_e2e\（全体。ジャーニー記録・更新バックアップ含む）"
} else {
    # キット所有のみ削除。プロジェクト所有（e2e-config.json / driver\tests\ の自作テストと conftest.py /
    # config\local.json / Builds\）は残す。**列挙は install-to-project.ps1 の Get-KitOwnedFiles とは別実装**
    # （同期していない）。あちらは issue #40 で「キットが配ったファイルだけ」を manifest へ
    # 記録する形になったが、**こちらはディレクトリごと消す**ので、導入先がここへ置いた
    # 自作ファイルも一緒に消える。installer は実行時にそれを [情報] として並べ、
    # scripts-local\ への移動を促す（#40 で改変警告が消えたぶんの導線）
    # oslayer はキット所有（0.1.9 で同梱）だが、中の DerivedData は導入先でビルドした
    # 生成物＝プロジェクト所有（installer の manifest も除外している）。既定ではキット所有分だけ
    # 消し、DerivedData が無ければディレクトリごと消える（-Purge は uapp_e2e\ 全体を消すので対象外）
    $oslayerDir = Join-UappPath $kit "oslayer"
    if (Test-Path -LiteralPath $oslayerDir) {
        $hasDerived = @(Get-UappTreeDirectory $oslayerDir |
                        Where-Object { (Split-Path $_ -Leaf) -eq "DerivedData" }).Count -gt 0
        if ($hasDerived) {
            # 判定は oslayer からの**相対パスのセグメント一致**で行う（フルパスへの部分一致だと、
            # 祖先ディレクトリ名に DerivedData を含む環境で全ファイルが除外され、削除が空振りする）
            $inDerived = {
                param($fullName)
                (($fullName.Substring($oslayerDir.Length).TrimStart('\', '/')) -split '[\\/]') -contains 'DerivedData'
            }
            Get-UappTreeFile $oslayerDir |
                Where-Object { -not (& $inDerived $_) } |
                ForEach-Object { Remove-UappTree $_ }
            Get-UappTreeDirectory $oslayerDir | Sort-Object -Descending |
                Where-Object { -not (& $inDerived $_) -and (Split-Path $_ -Leaf) -ne 'DerivedData' } |
                ForEach-Object { Remove-IfEmpty $_ }
            Write-Host "  [削除] uapp_e2e\oslayer（キット所有分。DerivedData=ビルドキャッシュは保持）"
        } else {
            Remove-Reported $oslayerDir "uapp_e2e\oslayer"
        }
    }
    foreach ($rel in @("scripts", "driver\e2e_driver", "docs",
                       "CLAUDE.md", "AGENTS.md", "SETUP.md", "VERSION", "kit-manifest.json",
                       "driver\pytest.ini", "driver\requirements.txt",
                       "driver\tests\test_journey_unit.py", "driver\tests\test_adb_ui.py",
                       "driver\tests\test_client_unit.py", "driver\tests\test_bridge_smoke.py",
                       "driver\tests\test_metrics_unit.py",
                       "config\local.sample.json", "config\e2e-config.sample.json",
                       # scripts-local は README だけキット所有。**ディレクトリは消さない**
                       # （中身は導入先の自作スクリプト＝プロジェクト所有。上の一覧に
                       # ディレクトリを入れず、下の Remove-IfEmpty で空のときだけ消す）
                       "scripts-local\README.md")) {
        Remove-Reported (Join-UappPath $kit $rel) "uapp_e2e\$rel"
    }
    foreach ($rel in @("driver\tests\__pycache__", "driver\.pytest_cache")) {
        Remove-UappTree (Join-UappPath $kit $rel)
    }
    foreach ($d in @("driver\tests", "driver", "config", "scripts-local")) { Remove-IfEmpty (Join-UappPath $kit $d) }
    Remove-IfEmpty $kit
    if (Test-Path -LiteralPath $kit) {
        Write-Host "  [保持] uapp_e2e\（e2e-config.json・自作テスト・local.json・Builds\ 等のプロジェクト所有物。"
        Write-Host "         installer 再実行で設定ごと復帰できる。すべて消す場合は -Purge で再実行）"
    }
}

# --- 4. ルート AGENTS.md（-Purge 時のみ・「installer が作成した記録あり」かつ「生成時から未編集」の場合に限り削除） ---
if ($Purge) {
    $rootAgentsPath = Join-UappPath $target "AGENTS.md"
    if ((Test-Path -LiteralPath $rootAgentsPath) -and -not $rootAgentsByInstaller) {
        Write-Host "  [保持] AGENTS.md（installer が作成した記録が無いため触らない。不要なら手動で削除）"
    } elseif (Test-Path -LiteralPath $rootAgentsPath) {
        # install-to-project.ps1 の 2.8 が生成する内容（変更したら両方を同期すること）
        $rootAgentsSnippet = @"
## uapp_e2e（E2Eテスト基盤・導入済み）

E2Eテストの作成・実行・デバッグ、計装SDK（``Assets/uapp_e2e/E2EBridge/``）、
エミュレーター/エディタ再生への接続に関わる作業を始める前に、必ず
``uapp_e2e/CLAUDE.md``（エージェント共通の規約・コマンド・失敗解析手順）を読むこと。
セットアップ・修復の入口は ``uapp_e2e/SETUP.md``。
定型作業は ``.agents/skills/e2e-*`` スキル（setup / run / write-test / dump）にある。
"@
        # 比較は改行コードを LF に正規化して行う（このスクリプトと installer のファイル改行が
        # 異なっても、また git の改行変換を経ても、内容が同じなら「未編集」と判定できるように）
        $expected = ("# AGENTS.md`n`n" + ($rootAgentsSnippet -replace "`r`n", "`n") + "`n")
        $actual = [System.IO.File]::ReadAllText($rootAgentsPath) -replace "`r`n", "`n"  # BOM は読込時に除去される
        if ($actual -eq $expected) {
            Remove-Item -LiteralPath $rootAgentsPath -Force
            Write-Host "  [削除] AGENTS.md（installer が生成したまま未編集のため）"
        } else {
            Write-Host "  [保持] AGENTS.md（installer 生成時から変更されているため触らない。不要なら手動で削除）"
        }
    }
}

# --- 5. 自動では戻さない項目の案内 ---
Write-Host ""
Write-Host "=== 残りの手動手順（自動では変更しない） ==="
$projSettings = Join-UappPath $target "ProjectSettings\ProjectSettings.asset"
$defineFound = (Test-Path -LiteralPath $projSettings) -and
    (Select-String -Path $projSettings -Pattern '(^|[^A-Za-z0-9_])UAPP_E2E_BRIDGE($|[^A-Za-z0-9_])' -Quiet)
if ($defineFound) {
    Write-Host "1. [残] Scripting Define Symbols から UAPP_E2E_BRIDGE を除去（Player Settings。自前ビルドスクリプトに組み込んだ場合はそちらも）"
} else {
    Write-Host "1. [済] UAPP_E2E_BRIDGE define は ProjectSettings に見つからない"
}
Write-Host "2. com.unity.inputsystem / com.unity.nuget.newtonsoft-json が他で不要なら Packages\manifest.json から削除"
Write-Host "3. .gitignore の uapp_e2e/ 関連行は残っていても無害（気になるなら手動で削除）"
exit 0
