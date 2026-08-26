# キットを**一時的に**別プロジェクトへ貸し出す（注入 / 撤去）。issue #34。
#
# 使い方:
#   .\scripts\inject-to-project.ps1 -TargetProject <Unityプロジェクト>            # 注入
#   .\scripts\inject-to-project.ps1 -TargetProject <Unityプロジェクト> -Eject     # 撤去
#   .\scripts\inject-to-project.ps1 -List                                          # 台帳を見る
#
# **フル導入（install-to-project.ps1）との違い**: 対象へ置くのは
# 計装 SDK・define・パッケージ参照・ポート設定だけで、**テスト・ドライバ・スクリプトは置かない**
# （それらはハブ＝このキットの側にあり、対象は「計装が入った実行対象」に徹する）。
# 同一プロダクトの clone が多数あり、E2E を回す対象が日替わりで変わる運用のためのもの。
#
# **撤去は記録ベース**。注入時に「自分が入れたもの」を対象の uapp_e2e-inject.json へ逐次
# 記録し、撤去はそれだけを戻す。推測で消す実装にすると、対象の既存差分を壊す事故が起きる
# （途中で失敗しても、記録が残っているので撤去をやり直せる）。
param(
    [string]$TargetProject,
    [switch]$Eject,
    [switch]$List,
    # 台帳のスロット番号（省略時は自動割り当て）。
    # ポートは editorBridgePort = 13343 + slot / devicePort = 13333 + slot
    [int]$Slot = -1,
    # 事前チェック（対象のエディタが開いている等）を警告に落として続行する
    [switch]$Force,
    # 生成する e2e-config.json の値（対象の UI 実装に合わせる）
    [ValidateSet("ugui-nis", "ugui-legacy", "ngui-nis", "ngui-legacy")][string]$UiType = "ugui-nis",
    [ValidateSet("portrait", "landscape")][string]$Orientation = "portrait"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "uapp-platform.ps1")   # OS 差分の吸収（Windows / macOS）

$root = (Resolve-Path -LiteralPath (Join-UappPath $PSScriptRoot "..")).Path

# --- 実行元レイアウトの自動判定 ---
# **このスクリプトは配布キットでも `scripts\` の中に置かれる**（installer だけが zip 直下）。
# だから計装マスターは「自分の親」から探す:
#   配布キット   … <kit>\scripts\inject-to-project.ps1 / 計装は <kit>\bridge\E2EBridge
#   開発リポジトリ … <root>\scripts\inject-to-project.ps1 / 計装は <root>\unity-nis\Assets\...
# `$PSScriptRoot\bridge` を見る形にしていて配布キットで必ず落ちる、という誤りを
# レビューで指摘された（installer のコードをそのまま持ってきたのが原因）
# 候補は 3 つ。**導入済みレイアウトを落とすと、配った先で起動すらできない**
# （キットは <project>\uapp_e2e\scripts\ へ配られ、計装は <project>\Assets\uapp_e2e\E2EBridge。
# この 3 番目を見ていなかったため、導入先で「展開が不完全」と誤報していた ― レビュー指摘）
$bridgeCandidates = @(
    (Join-UappPath $root "bridge\E2EBridge"),                          # 展開した配布 zip
    (Join-UappPath $root "unity-nis\Assets\uapp_e2e\E2EBridge"),       # 開発リポジトリ
    (Join-UappPath $root "..\Assets\uapp_e2e\E2EBridge")               # 導入済み（uapp_e2e\ の親）
)
$srcBridge = $bridgeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $srcBridge) {
    throw ("計装マスターが見つかりません（探した場所: " + ($bridgeCandidates -join " / ") +
           "）。キットの展開が不完全です")
}
$srcBridge = (Resolve-Path -LiteralPath $srcBridge).Path
$srcBridgeMeta = "$srcBridge.meta"
$hubRoot = $root

$RECORD_NAME = "uapp_e2e-inject.json"
$LEDGER = Join-UappPath $hubRoot "config\targets.json"
$PIPELINE_PKG = "com.unity.pipeline"
$DEFINE = "UAPP_E2E_BRIDGE"

# --- 台帳（対象 → スロット） -------------------------------------------------
# **ポートの重複は「別プロジェクトのエディタを操作する」事故に直結する**ので、割り当ては
# 1 か所で記録し、読み書きはホスト全体で排他する（並行注入で同じスロットを取り合わない）。
# ドライバ側の接続先検査（UAPP_E2E_EDITOR=1 の platform + project 照合）と**二重の網**にする
# ― 台帳だけでも検査だけでも足りない。
function Use-Ledger([scriptblock]$Body) {
    $mutex = New-Object System.Threading.Mutex($false, (Get-UappHostMutexName "uapp_e2e-inject-ledger"))
    $acquired = $false
    try { $acquired = $mutex.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw "台帳のロックを取得できません（別の注入処理が進行中）" }
    try {
        # **キーの比較は大小文字を区別する（Ordinal）**。`[ordered]@{}` の既定比較子は
        # **OS に関係なく case-insensitive**（PowerShell の型の性質。mac でも同じ ―
        # 別セッションが実測して私の理解の誤りを訂正した）。既定のままだと、
        # 大小文字だけ違う**別物の 2 つの clone が 1 エントリへ潰れて同じ slot を共有**し、
        # **同じ editorBridgePort で別プロジェクトのエディタへ繋ぐ**事故になる。
        # 逆向き（同一物が違う表記で 2 エントリになる）は slot を余分に消費するだけで害が薄い。
        # `Test-UappPathEqual` が全 OS で Ordinal なのと同じ判断（大小文字違いの別ディレクトリは
        # Windows でも NTFS のディレクトリ単位 case-sensitivity で共存しうる）
        $data = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        if (Test-Path -LiteralPath $LEDGER) {
            # **必ず -AsHashtable で読む**。素の ConvertFrom-Json は「大小文字だけ違うキーが
            # 2 つある JSON」を PSCustomObject へ変換できず例外になる（`keys with different
            # casing`）。台帳のキーは上の理由で Ordinal＝大小文字を区別するので、
            # **そういう組み合わせが書けてしまう**。書けるのに読めない、という非対称のまま
            # にすると -List も inject も eject も全部ここで落ち、**手で targets.json を
            # 直すまで復旧できない**（2026-08-23 に mac で実測。case-sensitive ボリュームは
            # 不要で、同じプロジェクトを表記違いで指すだけで 3 手で到達した）。
            # -AsHashtable は OrderedHashtable を返し、2 キーとも保持して参照も大小文字を区別する
            # **読み込みの失敗と I/O の失敗を混ぜない**（ファイルを掴まれているだけのときに
            # 「手で直せ」と案内すると、直す必要のないものを触らせる）
            $rawLedger = Get-Content -LiteralPath $LEDGER -Raw
            $ledgerHelp = ("手で開いて直してください（形式は " +
                           "{`"<対象の絶対パス>`": {`"slot`": 1, `"editorBridgePort`": 13344, " +
                           "`"devicePort`": 13334}}。**キーはすべて小文字**）。" +
                           "中身を捨ててよければ {} と書けば空の台帳になります" +
                           "（対象側の $RECORD_NAME が残っていれば -Eject はそれだけで動きます）")
            # **大小文字を区別して読めるかを、版番号ではなく実行時の能力で確かめる**。
            # `-AsHashtable` が `OrderedHashtable`（大小文字を区別）を返すのは
            # **PowerShell 7.3 以降**で、7.0〜7.2 は素の `Hashtable`（区別しない）を返す。
            # 区別しないと**大小文字だけ違うキーが黙って 1 つへ潰れ**、消えたエントリの slot が
            # 再利用されて**別プロジェクトと同じ editorBridgePort を共有する**（この修正が
            # 防ごうとしている事故そのもの）。7.3 未満は手元に用意できず挙動を実測できないので、
            # **版で分岐せず「今の版で本当に区別できるか」を測る**
            $keepsCase = $false
            try { $keepsCase = ((('{"a":1,"A":2}' | ConvertFrom-Json -AsHashtable).Count) -eq 2) } catch { }
            if (-not $keepsCase) {
                # **潰れるかどうかは台帳の中身しだい**なので、区別できない版でも
                # 大小文字違いのキーが無ければそのまま使える。素のパースがその判定に使える
                # （大小文字違いのキーがあるときだけ例外になる＝この不具合の入口そのもの）
                try { $null = $rawLedger | ConvertFrom-Json }
                catch {
                    throw ("この PowerShell では台帳を正しく読めません" +
                           "（$($PSVersionTable.PSVersion)。7.3 未満は大小文字を区別しません）。" +
                           "台帳に大小文字だけ違うキーがあり、**そのまま読むと 1 つへ潰れて" +
                           "slot が再利用され、別プロジェクトと同じ editorBridgePort を共有します**。" +
                           "pwsh 7.3 以降で実行してください。$ledgerHelp")
                }
            }
            try {
                $json = $rawLedger | ConvertFrom-Json -AsHashtable
            } catch { throw "台帳を読めません: $LEDGER（$_）。$ledgerHelp" }
            # **JSON として読めても辞書とは限らない**（0 バイト・`null`・配列。実測で
            # 案内にならない生のエラーになった ― レビュー指摘）
            if ($json -isnot [System.Collections.IDictionary]) {
                throw "台帳の形式が正しくありません（オブジェクトではありません）: $LEDGER。$ledgerHelp"
            }
            foreach ($p in $json.GetEnumerator()) {
                # **値のキー参照も大小文字を区別する**（-AsHashtable の性質。素の
                # ConvertFrom-Json は区別しなかったので、手編集で `Slot` と書くと
                # `[int]$null` = 0 に潰れ、**ポートが 13343/13333 になり slot も空きと
                # 判定されて別 clone へ再割り当てされる** ― レビューが実測）。
                # 黙って 0 に落とさず、読んだ時点で弾く
                $v = $p.Value
                if ($v -isnot [System.Collections.IDictionary] -or
                    -not ($v.Contains("slot")) -or ([int]$v["slot"]) -lt 0) {
                    throw "台帳のエントリが壊れています（slot を読めません）: $($p.Key)。$ledgerHelp"
                }
                $data[$p.Key] = $v
            }
        }
        $result = & $Body $data
        New-Item -ItemType Directory -Force (Split-Path $LEDGER -Parent) | Out-Null
        $data | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $LEDGER -Encoding utf8
        return $result
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-HostForwardPort {
    # config\local.json の bridgePort（デバイス経路の adb forward が握るホスト側ポート）。
    # 無ければ $null
    $localJson = Join-UappPath $hubRoot "config\local.json"
    if (-not (Test-Path -LiteralPath $localJson)) { return $null }
    try { return [int]((Get-Content -LiteralPath $localJson -Raw | ConvertFrom-Json).bridgePort) }
    catch { return $null }
}

function Get-SlotPorts([int]$SlotNumber) {
    # **ホスト側 forward ポートと別番号にする**（devicePort と分けるだけでは足りない ―
    # デバイス実行が残した adb forward が editorBridgePort を握ると、エディタのつもりで
    # 端末のアプリを検証してしまう。docs/02 の制約）
    return @{ editorBridgePort = 13343 + $SlotNumber; devicePort = 13333 + $SlotNumber }
}

# --- 記録（対象側に置く。撤去の唯一の根拠） ----------------------------------
function Get-RecordPath([string]$Target) { Join-UappPath $Target $RECORD_NAME }

function Read-Record([string]$Target) {
    $path = Get-RecordPath $Target
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch {
        # **壊れた記録は「無い」と扱わない**（no-op で流すと、計装・define・pipeline が
        # 対象へ残ったまま「撤去するものはありません」と言うことになる）。
        # 手で回収できる導線を示して止める
        throw ("注入の記録が壊れています: $path（$_）。" +
               "対象に残っているもの（Assets\uapp_e2e\E2EBridge・$DEFINE define・" +
               "$PIPELINE_PKG・e2e-config.json）を手で戻し、この記録ファイルを削除してください。" +
               "台帳の割り当ては -List で確認できます")
    }
}

function Write-Record([string]$Target, $Record) {
    # **各ステップの直後に書く**（途中で失敗しても、そこまでの分は撤去できる）。
    # **書き込みは原子的に**（一時ファイル→置換）。記録は撤去の唯一の根拠なので、
    # 中断で半端に書かれると inject も eject もできない手詰まりになる ― レビューが実測で再現
    $path = Get-RecordPath $Target
    $tmp = "$path.tmp"
    $Record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# 対象のテキストファイルを**バイトの性質を保ったまま**書き戻す。
# `Set-Content -Encoding utf8` は PowerShell 7 では BOM なしで書くため、**BOM 付きの
# ファイルから BOM が落ちる**（注入前後でハッシュが変わる＝「撤去後は完全一致」の前提が
# 崩れる ― レビューが実測）。元の BOM の有無をそのまま再現する。
function Set-TargetText([string]$Path, [string]$Text) {
    $hadBom = $false
    if (Test-Path -LiteralPath $Path) {
        $head = [System.IO.File]::ReadAllBytes($Path)
        $hadBom = ($head.Length -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)
    }
    $enc = New-Object System.Text.UTF8Encoding($hadBom)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# --- define の付与・除去（ProjectSettings.asset の YAML を行単位で編集） ------
# **ファイル全体のバックアップで書き戻さない**。注入中に人が別の設定を変えることがあり、
# 全体を戻すとその変更を捨てる。シンボルだけを足し引きする。
# 読み取り側（install-to-project.ps1 の検出）と同じブロック走査を使う。
function Edit-DefineSymbols([string]$Target, [switch]$Remove, [string[]]$OnlyTargets, [switch]$DryRun) {
    $path = Join-UappPath $Target "ProjectSettings\ProjectSettings.asset"
    if (-not (Test-Path -LiteralPath $path)) { throw "ProjectSettings.asset がありません: $path" }
    $raw = Get-Content -LiteralPath $path -Raw
    $nl = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
    $keyIndent = $null
    $touched = @()
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($raw -split "`r?`n")) {
        $emit = $line
        if ($null -eq $keyIndent) {
            if ($line -match '^([ \t]*)scriptingDefineSymbols:\s*(\S.*)?$') {
                $rest = $Matches[2]
                if ($rest) {
                    # `scriptingDefineSymbols: {}` のような**インライン値**は、行単位の
                    # 足し引きでは安全に扱えない。**黙って素通りさせない**（変更 0 件のまま
                    # 「付与しました」と言うと、計装が入らないまま E2E が走る ― レビュー指摘）
                    throw ("ProjectSettings.asset の scriptingDefineSymbols がインライン値です" +
                           "（$rest）。このスクリプトはブロック形式のみ編集できます。" +
                           "Unity で一度 define を設定してブロック形式にするか、手で付与してください")
                }
                $keyIndent = $Matches[1].Length
            }
        }
        elseif ($keyIndent -ge 0 -and $line -match '^([ \t]*)\S') {
            if ($Matches[1].Length -le $keyIndent) {
                $keyIndent = -1        # ブロック終端（以後は触らない）
            }
            elseif ($line -match '^(\s*)([A-Za-z0-9_]+):(.*)$') {
                $indent = $Matches[1]
                $targetKey = $Matches[2]
                $value = $Matches[3]
                # 撤去では**記録したターゲットだけ**を対象にする（他は触らない）
                # **空配列は falsy** なので `if ($OnlyTargets -and …)` だと絞り込みが丸ごと
                # 無効になり、記録が空のときに**全ターゲットから消す**（対象が元から持っていた
                # 同名 define を破壊する ― レビューが実測で再現）。null かどうかで判定する
                if ($null -ne $OnlyTargets -and ($OnlyTargets -notcontains $targetKey)) {
                    $out.Add($emit); continue
                }
                # **安全に編集できない値は触らずに止める**。引用符付き scalar や
                # インラインコメントがあると、素朴な足し引きで壊す（`#` の後ろへ付与する等）
                if ($value -match '#' -or $value -match '"' -or $value -match "'") {
                    throw ("ProjectSettings.asset の $targetKey の define 値を安全に編集できません" +
                           "（引用符またはコメントを含む: $($value.Trim())）。手で付与・除去してください")
                }
                $has = $value -match "(^|[^A-Za-z0-9_])$DEFINE($|[^A-Za-z0-9_])"
                # **コロンの後の空白は元のまま残す**（Unity は `Key: ` と書くので、
                # 空値へ戻すときに空白を落とすと**対象の git に無意味な 1 行差分**が出る。
                # 「人のリポジトリを荒らさない」という注入の前提に反する ― 実測で発覚）
                $lead = if ($value -match '^(\s*)') { $Matches[1] } else { "" }
                if ($Remove -and $has) {
                    # 自分が足したシンボルだけを取り除き、区切りの ; を整える
                    $parts = @($value.Trim() -split ';' | Where-Object { $_ -ne "" -and $_ -ne $DEFINE })
                    $emit = if ($parts.Count -gt 0) { "$indent${targetKey}:$lead$($parts -join ';')" }
                            else { "$indent${targetKey}:$lead" }
                    $touched += $targetKey
                }
                elseif (-not $Remove -and -not $has) {
                    $body = $value.Trim()
                    $sep = if ($lead) { $lead } else { " " }
                    $emit = if ($body) { "$indent${targetKey}:$sep$body;$DEFINE" }
                            else { "$indent${targetKey}:$sep$DEFINE" }
                    $touched += $targetKey
                }
            }
        }
        $out.Add($emit)
    }
    if ($touched.Count -gt 0 -and -not $DryRun) {
        # 改行は元ファイルに合わせる（不要な全行差分を作らない）
        Set-TargetText $path ($out -join $nl)
    }
    elseif (-not $Remove) {
        # **付与で 1 件も触れなかったのは異常**（ブロックが見つからない・既に全ターゲットに
        # 付いている、のどちらか）。前者を黙って成功にすると計装なしで E2E が走る
        if ($null -eq $keyIndent) {
            throw ("ProjectSettings.asset に scriptingDefineSymbols のブロックが見つかりません。" +
                   "Unity で一度 define を設定してから注入してください")
        }
    }
    return $touched
}

# --- Packages/manifest.json（pipeline の追加・除去） -------------------------
function Get-PipelineVersion {
    # ハブ（このキット）が使っている版に合わせる。分からなければ既定
    $candidate = Join-UappPath $root "unity-nis\Packages\manifest.json"
    if (Test-Path -LiteralPath $candidate) {
        try {
            $v = (Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json).dependencies.$PIPELINE_PKG
            if ($v) { return $v }
        } catch { }
    }
    # 配布キットのハブには unity-nis が無いので、ここへ落ちるのが通常経路。
    # **キットが検証した版を既定にする**（docs/05 の記載と揃える）
    return "0.4.0-exp.1"
}

function Test-PipelinePackagePresent([string]$Target) {
    $path = Join-UappPath $Target "Packages\manifest.json"
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try {
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return [bool]($json.dependencies -and
                      ($json.dependencies.PSObject.Properties.Name -contains $PIPELINE_PKG))
    } catch { return $false }
}

function Add-PipelinePackage([string]$Target) {
    $path = Join-UappPath $Target "Packages\manifest.json"
    if (-not (Test-Path -LiteralPath $path)) { throw "Packages\manifest.json がありません: $path" }
    $raw = Get-Content -LiteralPath $path -Raw
    $json = $raw | ConvertFrom-Json
    if ($json.dependencies -and
        ($json.dependencies.PSObject.Properties.Name -contains $PIPELINE_PKG)) { return $null }
    $version = Get-PipelineVersion
    # **JSON を組み直さずテキストへ 1 行挿す**（ConvertTo-Json は順序・書式・エスケープを
    # 変えるため、対象の manifest 全体が差分になる。人のリポジトリを荒らさない）
    $needle = '"dependencies"'
    $idx = $raw.IndexOf($needle)
    if ($idx -lt 0) { throw "manifest.json に dependencies がありません: $path" }
    $brace = $raw.IndexOf("{", $idx)
    if ($brace -lt 0) { throw "manifest.json の dependencies を解釈できません: $path" }
    $nl = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
    # **既存要素が無ければカンマを付けない**（`"dependencies": {}` へカンマ付きで挿すと
    # 末尾カンマの不正 JSON になる。PowerShell は寛容に読むが、厳格なパーサーは拒否する
    # ― レビュー指摘。Unity 自身が読めなくなる可能性がある）
    $hasExisting = ($json.dependencies -and
                    @($json.dependencies.PSObject.Properties).Count -gt 0)
    $comma = if ($hasExisting) { "," } else { "" }
    $entry = $nl + '    "' + $PIPELINE_PKG + '": "' + $version + '"' + $comma
    Set-TargetText $path ($raw.Insert($brace + 1, $entry))
    return $version
}

function Remove-PipelinePackage([string]$Target) {
    $path = Join-UappPath $Target "Packages\manifest.json"
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $raw = Get-Content -LiteralPath $path -Raw
    $pattern = '\s*"' + [regex]::Escape($PIPELINE_PKG) + '"\s*:\s*"[^"]*"\s*,?'
    $cleaned = [regex]::Replace($raw, $pattern, "")
    if ($cleaned -eq $raw) { return $false }
    # 直前の要素の末尾カンマが余ることがある（最後の要素を消した場合）
    $cleaned = [regex]::Replace($cleaned, ',(\s*\})', '$1')
    Set-TargetText $path $cleaned
    return $true
}

# --- 事前チェック ------------------------------------------------------------
function Test-TargetReady([string]$Target) {
    $problems = @()
    if (-not ((Test-Path -LiteralPath (Join-UappPath $Target "Assets")) -and
              (Test-Path -LiteralPath (Join-UappPath $Target "ProjectSettings")))) {
        throw "Unity プロジェクトではありません（Assets / ProjectSettings が無い）: $Target"
    }
    # **フル導入済みへは注入しない**（所有権が二重になり、撤去でどちらの物か分からなくなる）
    if (Test-Path -LiteralPath (Join-UappPath $Target "uapp_e2e\kit-manifest.json")) {
        throw ("この対象は install-to-project.ps1 でフル導入済みです（uapp_e2e\kit-manifest.json がある）。" +
               "注入は未導入の clone に対して使ってください")
    }
    # **既に計装がある対象へは注入しない**（上書きすると撤去時にどちらの物か分からない）。
    # **スロット確保より前に見る** ― 後段で落とすと、台帳と記録だけが残るゴミになる（実測）
    if (Test-Path -LiteralPath (Join-UappPath $Target "Assets\uapp_e2e\E2EBridge")) {
        throw ("対象に Assets\uapp_e2e\E2EBridge が既にあります。" +
               "注入で上書きすると撤去時にどちらの物か分からなくなるため中断します")
    }
    # **既存の e2e-config.json も事前に見る**（他の拒否条件と同じ場所で判断する。
    # 手順 4 で初めて中断すると、計装コピー・define・pipeline を入れた後の半端な状態になる
    # ― レビュー指摘。回収はできるが、無人実行では放置される）
    if ((Test-Path -LiteralPath (Join-UappPath $Target "e2e-config.json")) -and -not $Force) {
        $problems += "対象に e2e-config.json が既にある（-Force で退避できる。撤去時に戻す）"
    }
    # **対象のエディタが開いていると設定書き換えで再インポートが走り、作業者を妨げる**
    $statusScript = Join-UappPath $PSScriptRoot "unity-editor-status.ps1"
    if (Test-Path -LiteralPath $statusScript) {
        # **プローブが失敗したことを「開いている」と言わない**。空出力は PS7 では例外に
        # ならず $state=$null になり、`-ne "closed"` が真＝「開いています（state=）」という
        # 誤った診断になっていた（レビューが実測で再現）。状態は 4 値で、判定できない場合は
        # そう言う ― 誤診が続くと「常に -Force を付ける」癖がついて検査自体が死ぬ
        $state = $null
        try {
            $pwshExe = (Get-Process -Id $PID).Path
            $json = & $pwshExe -NoProfile -File $statusScript -ProjectPath $Target -Json 2>$null | Out-String
            if ("$json".Trim()) { $state = ($json | ConvertFrom-Json).state }
        } catch { $state = $null }
        if (-not $state) {
            $problems += "対象のエディタ状態を確認できませんでした（判定不能）"
        } elseif ($state -ne "closed") {
            $problems += "対象の Unity エディタが開いています（state=$state）"
        }
    }
    return $problems
}

# --- 注入 --------------------------------------------------------------------
function Invoke-Inject([string]$Target) {
    $problems = Test-TargetReady $Target
    if ($problems.Count -gt 0) {
        $text = ($problems -join " / ")
        if (-not $Force) {
            throw ("事前チェックで中断しました: $text。" +
                   "エディタを閉じてから実行してください（close-editor.ps1）。" +
                   "承知のうえで進めるなら -Force")
        }
        Write-Warning "事前チェックの指摘を無視して続行します: $text"
    }
    if (Read-Record $Target) {
        throw ("既に注入済みです（$RECORD_NAME がある）。撤去してから注入し直してください: " +
               ".\scripts\inject-to-project.ps1 -TargetProject '$Target' -Eject")
    }

    # スロット確定（台帳）
    $assigned = Use-Ledger {
        param($data)
        $key = (Get-UappNormalizedDir $Target)
        if ($data.Contains($key)) { return [int]$data[$key].slot }
        $used = @($data.Keys | ForEach-Object { [int]$data[$_].slot })
        $n = if ($Slot -ge 0) { $Slot } else {
            $candidate = 1
            while ($used -contains $candidate) { $candidate++ }
            $candidate
        }
        if ($Slot -ge 0 -and ($used -contains $n)) {
            throw "スロット $n は既に使われています（-Slot を変えるか省略して自動割り当てにする）"
        }
        # ポートは 1〜65535。範囲外のスロットは**注入前に**弾く（ドライバ側で後から
        # 弾かれるのでは、対象を書き換えた後になる ― レビュー指摘）
        $probe = Get-SlotPorts $n
        foreach ($pv in @($probe.editorBridgePort, $probe.devicePort)) {
            if ($pv -lt 1 -or $pv -gt 65535) {
                throw "スロット $n ではポートが範囲外になります（$pv）。0〜22000 程度の値を使ってください"
            }
        }
        $ports = Get-SlotPorts $n
        $data[$key] = [ordered]@{ slot = $n; editorBridgePort = $ports.editorBridgePort
                                  devicePort = $ports.devicePort; injectedAt = (Get-Date -Format o) }
        return $n
    }
    $ports = Get-SlotPorts $assigned
    # **ホスト側 forward ポートと衝突していないか**（issue #25 と同じ事故: デバイス実行が
    # 残した adb forward が editorBridgePort を握ると、エディタのつもりで端末のアプリを
    # 検証してしまう。installer は同じ検査をしているのに注入側に無かった ― レビュー指摘）
    $forwardPort = Get-HostForwardPort
    if ($forwardPort -and $forwardPort -eq $ports.editorBridgePort) {
        Write-Warning ("割り当てた editorBridgePort=$($ports.editorBridgePort) が" +
                       "ホスト側 forward ポート（config\local.json の bridgePort）と同じです。" +
                       "デバイス実行の残り forward がエディタ直結の接続先を奪う事故になりえます" +
                       "（-Slot で別番号にするか local.json を変える。" +
                       "ドライバの接続先検査が第 2 の網として働きます）")
    }
    Write-Host "[inject] 対象: $Target"
    Write-Host "[inject] スロット $assigned（editorBridgePort=$($ports.editorBridgePort) / devicePort=$($ports.devicePort)）"

    # **何も入れないまま失敗したら、台帳と記録を残さない**（残すと「注入済み」に見えて
    # 次の注入が拒否され、撤去しようにも戻すものが無い、という手詰まりになる）
    $anyStep = $false
    try {
    $record = [ordered]@{
        schema = "uapp_e2e-inject/1"
        target = $Target
        hub = $hubRoot
        slot = $assigned
        injectedAt = (Get-Date -Format o)
        steps = @()
    }
    Write-Record $Target $record

    # 1. 計装 SDK（存在チェックは Test-TargetReady で済ませている）
    $bridgeDest = Join-UappPath $Target "Assets\uapp_e2e\E2EBridge"
    # **記録を先に書いてからコピーする**（後だと、コピー途中の失敗で「記録なしの残留物」が
    # でき、再注入も撤去もできない手詰まりになる ― レビュー指摘。記録が先なら、
    # 実物が無くても eject は「無ければ飛ばす」で回収できる）
    $metaDest = Join-UappPath $Target "Assets\uapp_e2e\E2EBridge.meta"
    $ownMeta = (Test-Path -LiteralPath $srcBridgeMeta) -and -not (Test-Path -LiteralPath $metaDest)
    $anyStep = $true
    $record.steps += [ordered]@{ kind = "bridge"; path = "Assets\uapp_e2e\E2EBridge"
                                 ownMeta = $ownMeta }
    Write-Record $Target $record
    Copy-UappTree -Source $srcBridge -Destination $bridgeDest
    if ($ownMeta) { Copy-Item -LiteralPath $srcBridgeMeta $metaDest -Force }
    Write-Host "  [OK] 計装 SDK を配置"

    # 2. define
    # **どのターゲットを触るかを先に確定して記録する**（変更してから記録すると、
    # その間の中断で「変更したのに記録が無い」＝撤去できない状態になる ― 最終レビュー指摘）。
    # -WhatIf 相当の予行で対象を求め、記録してから本番を打つ
    $willTouch = @(Edit-DefineSymbols $Target -DryRun)
    if ($willTouch.Count -gt 0) {
        $record.steps += [ordered]@{ kind = "define"; symbol = $DEFINE; targets = $willTouch }
        Write-Record $Target $record
        $touched = @(Edit-DefineSymbols $Target)
        Write-Host "  [OK] $DEFINE define を付与（$($touched.Count) ターゲット）"
    } else {
        $touched = @()
        # **1 つも足していないなら撤去対象にもしない**（記録すると、撤去時に
        # 「対象が元から持っていた define」を自分の物として消してしまう）
        Write-Host "  [--] $DEFINE define は既に全ターゲットに付いている（対象の所有物として触らない）"
    }

    # 3. pipeline パッケージ
    # 追加が要るかを先に判定して記録し、それから書く（define と同じ理由）
    $needPackage = -not (Test-PipelinePackagePresent $Target)
    if ($needPackage) {
        $record.steps += [ordered]@{ kind = "package"; name = $PIPELINE_PKG; version = (Get-PipelineVersion) }
        Write-Record $Target $record
        $added = Add-PipelinePackage $Target
        Write-Host "  [OK] $PIPELINE_PKG $added を追加"
    } else {
        Write-Host "  [--] $PIPELINE_PKG は既にある（撤去時も触らない）"
    }

    # 4. e2e-config.json（対象専用ポート）
    $configPath = Join-UappPath $Target "e2e-config.json"
    if (Test-Path -LiteralPath $configPath) {
        # **温存すると台帳の割り当てが効かない**（run-e2e は対象の設定からポートを読むので、
        # 台帳は新しい slot を指しているのにブリッジは従来ポート、という食い違いになる
        # ― レビュー指摘）。既定は中断し、-Force なら退避して自前のを置く（eject で戻す）
        if (-not $Force) {
            throw ("対象に e2e-config.json が既にあります。台帳が割り当てたポート" +
                   "（editorBridgePort=$($ports.editorBridgePort)）が使われず、" +
                   "別プロジェクトのエディタへ繋ぐ事故になりえます。" +
                   "退避してよければ -Force を付けてください（撤去時に戻します）")
        }
        $backup = Join-UappPath $Target "e2e-config.json.uapp-inject-backup"
        $record.steps += [ordered]@{ kind = "config-backup"; path = "e2e-config.json"
                                     backup = "e2e-config.json.uapp-inject-backup" }
        Write-Record $Target $record
        Move-Item -LiteralPath $configPath -Destination $backup -Force
        Write-Host "  [OK] 既存 e2e-config.json を退避（撤去時に戻す）"
    }
    if ($true) {
        # uiType / orientation は対象の実装で変わる（NGUI なら ngui-* が正しい）。
        # **既定のまま嘘の値を置かない**よう引数で上書きできるようにする
        $config = [ordered]@{
            package = ""
            tests = "tests"
            uiType = $UiType
            orientation = $Orientation
            devicePort = $ports.devicePort
            editorBridgePort = $ports.editorBridgePort
        }
        $record.steps += [ordered]@{ kind = "config"; path = "e2e-config.json" }
        Write-Record $Target $record
        $config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding utf8
        Write-Host "  [OK] e2e-config.json（editorBridgePort=$($ports.editorBridgePort)）"
    }

    } catch {
        if (-not $anyStep) {
            Remove-Item -LiteralPath (Get-RecordPath $Target) -Force -ErrorAction SilentlyContinue
            Use-Ledger { param($data)
                $key = (Get-UappNormalizedDir $Target)
                if ($data.Contains($key)) { $data.Remove($key) }
            } | Out-Null
            Write-Warning "何も配置していないため、台帳の割り当てと記録を取り消しました"
        } else {
            Write-Warning ("途中まで配置した状態です。記録は残してあるので撤去できます: " +
                           ".\scripts\inject-to-project.ps1 -TargetProject '$Target' -Eject")
        }
        throw
    }

    Write-Host ""
    Write-Host "注入しました。次の手順:"
    # **絶対パスで出す**（相対だと cwd 次第で解決しない ― ハブが「導入済みの uapp_e2e」の
    # 場合、cwd をプロジェクト直下に置くのが自然で、そこからは `.\scripts\...` が外れる。mac の指摘）
    Write-Host "  1. E2E 実行:  $(Join-UappPath $root 'scripts\run-e2e.ps1') -Editor -ProjectPath '$Target' -NoProjectTests"
    Write-Host "     （テストはハブ側にあるので -NoProjectTests を付ける。テスト指定は -PytestArgs）"
    Write-Host "  2. 終わったらエディタを閉じる: $(Join-UappPath $root 'scripts\close-editor.ps1') -ProjectPath '$Target'"
    Write-Host "  3. 撤去: $(Join-UappPath $root 'scripts\inject-to-project.ps1') -TargetProject '$Target' -Eject"
}

# --- 撤去 --------------------------------------------------------------------
function Show-EjectGitStatus([string]$TargetDir) {
    <#
      .SYNOPSIS
      撤去した対象の git 状態を出す（issue #47）。**git 管理下でなければ黙って省く**。

      .NOTES
      導入先は自作の eject が最後に出す `git status --porcelain` を見て
      「完全に戻った」と確認していた。標準の eject へ移行してから、
      **確認手段が手順書側の「自分で git status を打つ」に退化していた**（実行者から報告）。

      **表示するだけ。何も変更しない。**（この issue のもう 1 件が
      「終了メッセージが破壊的な git 操作を促していた」なので、ここで操作を足さない）
    #>
    $git = Get-UappCommandPath "git"
    if (-not $git) { return }   # git が無い環境では黙って省く
    # **対象が git 管理下か**を先に見る（管理外で "not a git repository" を出さない）
    $inside = & $git -C $TargetDir rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0 -or "$inside".Trim() -ne "true") { return }

    $changes = @(& $git -C $TargetDir status --porcelain 2>$null)
    $statusExit = $LASTEXITCODE
    Write-Host ""
    # **失敗を「差分なし」と読ませない**（codex 指摘）。stderr を捨てているので、
    # 終了コードを見ないと **`git status` がこけても空配列＝差分なし**になる
    # （`rev-parse=0 / status=128 / changesCount=0` を実測で再現）。
    # 導入先はこの表示で「完全に戻った」を確認するので、
    # **確認できていないのに「戻りました」と言うのがいちばん悪い**
    if ($statusExit -ne 0) {
        Write-Warning ("git status が失敗したため、撤去後の差分を確認できませんでした" +
                       "（終了コード $statusExit）: $TargetDir。手で `git status` を確認してください")
    } elseif ($changes.Count -eq 0) {
        Write-Host "  [OK] git 差分なし（対象は撤去前の状態に戻っています）"
    } else {
        Write-Host "  対象の git 差分（$($changes.Count) 件）:"
        foreach ($line in ($changes | Select-Object -First 20)) { Write-Host "    $line" }
        if ($changes.Count -gt 20) { Write-Host "    …ほか $($changes.Count - 20) 件" }
        Write-Host "  （$PIPELINE_PKG の行が残るのは既知です。**手当ては不要**）"
    }
}

function Invoke-Eject([string]$Target) {
    $record = Read-Record $Target
    if (-not $record) {
        # **記録が無ければ何もしないで正常終了する**（冪等）。後始末を無条件に呼ぶ
        # ラッパーが失敗しないように ― レビュー指摘。**推測で消すことはしない**
        Write-Host ("注入の記録（$RECORD_NAME）が無いので、撤去するものはありません: $Target")
        Write-Host "（記録が無いものを推測で消すと対象の既存ファイルを壊すため、何も触りません）"
        return
    }
    $statusScript = Join-UappPath $PSScriptRoot "unity-editor-status.ps1"
    if ((Test-Path -LiteralPath $statusScript) -and -not $Force) {
        $state = $null
        try {
            $pwshExe = (Get-Process -Id $PID).Path
            $json = & $pwshExe -NoProfile -File $statusScript -ProjectPath $Target -Json 2>$null | Out-String
            if ("$json".Trim()) { $state = ($json | ConvertFrom-Json).state }
        } catch { $state = $null }
        if (-not $state) {
            # **判定できないことを理由に撤去を拒まない**（掃除の手段まで奪うのが最悪。
            # 撤去は記録に基づく後始末なので、続行しても対象の所有物は壊さない）
            Write-Warning "エディタ状態を確認できません（続行します）"
        } elseif ($state -ne "closed") {
            throw ("対象の Unity エディタが開いています（state=$state）。" +
                   "開いたまま撤去するとエラーの嵐になるので、close-editor.ps1 で閉じてから実行してください（-Force で強行）")
        }
    }

    Write-Host "[eject] 対象: $Target"
    # **記録の逆順で戻す**（入れた順の逆。将来ステップが増えても依存関係を壊さない）
    $failed = @()
    foreach ($step in @($record.steps)[($record.steps.Count - 1)..0]) {
        if ($record.steps.Count -eq 0) { break }
        try {
            switch ($step.kind) {
                "bridge" {
                    $p = Join-UappPath $Target $step.path
                    # **ディレクトリの削除と空判定は Remove-UappTree / Test-UappDirEmpty で行う**。
                    # `Remove-Item -Recurse` と `Get-ChildItem` は**大小文字だけ違う別ディレクトリ**を
                    # 掴むことがある（PowerShell の FileSystem プロバイダの既知不具合。
                    # 理由と一次情報は uapp-platform.ps1 の該当コメント）。
                    # 同じプロダクトの clone が `Foo` と `foo` で並ぶ構成は**この注入モードが
                    # まさに想定している運用**なので、机上の話ではない ― 2026-08-23 に
                    # case-sensitive ボリュームで「隣の clone の計装が消える」ことを実測した
                    $existed = Test-Path -LiteralPath $p
                    Remove-UappTree $p
                    # **自分が置いた .meta だけ消す**（注入前からあったものは対象の所有物）。
                    # 記録に ownMeta が無い旧記録は、安全側に倒して触らない
                    if ($step.PSObject.Properties.Name -contains "ownMeta" -and $step.ownMeta) {
                        Remove-UappTree (Join-UappPath $Target "Assets\uapp_e2e\E2EBridge.meta")
                    }
                    # 空になった Assets\uapp_e2e\ も畳む（対象に空ディレクトリを残さない）
                    if (Test-UappDirEmpty (Join-UappPath $Target "Assets\uapp_e2e")) {
                        Remove-UappTree (Join-UappPath $Target "Assets\uapp_e2e")
                        Remove-UappTree (Join-UappPath $Target "Assets\uapp_e2e.meta")
                    }
                    # **「消した」と「元から無かった」を書き分ける**。無条件に「削除」と出すと、
                    # 上のような取り違えが起きても**表示では気づけない**（実際、この文面のせいで
                    # 「隣を消していた」ことに気づくのが遅れた）。
                    # **理由は書かない** ― 記録はコピーより先に書く設計なので「記録はあるが
                    # まだ置いていない」もありうるし、人が手で消しても同じ表示になる。
                    # 観測していないことを断定しない
                    Write-Host $(if ($existed) { "  [戻] 計装 SDK を削除" }
                                 else { "  [--] 計装 SDK が記録どおりの場所に無い（何も消していません）" })
                }
                "define"  {
                    # **記録したターゲットからだけ外す**（全ターゲットを対象にすると、
                    # 注入前から別ターゲットに付いていた同名 define まで消す ― レビュー指摘）
                    $only = @($step.targets)
                    if ($only.Count -eq 0) {
                        Write-Host "  [--] define の記録が空なので触らない"
                    } else {
                        $t = Edit-DefineSymbols $Target -Remove -OnlyTargets $only
                        Write-Host "  [戻] define を除去（$($t.Count) ターゲット）"
                    }
                }
                "package" { if (Remove-PipelinePackage $Target) { Write-Host "  [戻] $PIPELINE_PKG を除去" } }
                "config"  { $p = Join-UappPath $Target $step.path
                            if (Test-Path -LiteralPath $p) {
                                Remove-Item -LiteralPath $p -Force
                                Write-Host "  [戻] e2e-config.json を削除"
                            } else { Write-Host "  [--] e2e-config.json が無い（何も消していません）" } }
                "config-backup" {
                    $orig = Join-UappPath $Target $step.path
                    $bak = Join-UappPath $Target $step.backup
                    if (Test-Path -LiteralPath $bak) {
                        if (Test-Path -LiteralPath $orig) { Remove-Item -LiteralPath $orig -Force }
                        Move-Item -LiteralPath $bak $orig -Force
                        Write-Host "  [戻] 退避していた e2e-config.json を復元"
                    }
                }
                default   {
                    # **記録から落とさない**（消すと「実物は残るのに記録は無い」＝
                    # 二度と撤去できない状態になる。新しいハブが書いた記録を
                    # 古いキットが黙って壊さないための保険 ― レビュー指摘）
                    throw "未知のステップ種別です（このキットでは戻せません）: $($step.kind)"
                }
            }
        } catch {
            # **1 つ失敗しても他を戻す**（記録は消さないので、やり直せば残りを回収できる）
            Write-Warning "戻せなかったステップ: $($step.kind) ― $_"
            $failed += $step
        }
    }
    if ($failed.Count -gt 0) {
        # **記録は元の順序のまま残す**（失敗を遭遇順＝逆順で書き戻すと、次回の eject が
        # それをさらに逆順にして順序が反転し、`config-backup` の復元直後に `config` の削除が
        # 走って**対象の元ファイルが消える**。しかも「撤去しました」と表示される
        # ― レビューが実測で再現した。順序は記録の意味そのものなので触らない）
        # **記録は 1 件も削らずそのまま残す**。失敗した分だけを残すと、依存し合うステップの
        # ペアが崩れる ― 実際、`config`（自前設定の削除）が失敗して `config-backup`
        # （元ファイルの復元）が成功した後に `config` だけ残すと、再試行が**復元済みの
        # 元ファイルを削除して「撤去しました」と言う**（最終レビューが再現）。
        # 各ステップは「対象が無ければ何もしない」＝冪等なので、全体を再実行して問題ない
        $failedKinds = @($failed | ForEach-Object { $_.kind })
        Write-Record $Target $record
        throw ("一部のステップを戻せませんでした（$($failed.Count) 件: $($failedKinds -join ', ')）。" +
               "記録はそのまま残してあるので、原因を解消してから -Eject をやり直してください" +
               "（戻し終えたステップは再実行しても何もしません）")
    }
    Remove-Item -LiteralPath (Get-RecordPath $Target) -Force
    Use-Ledger { param($data)
        # **注入時に使われた表記でも引く**。台帳は Ordinal なので、注入を `…/Clone`、
        # 撤去を `…/clone`（**同じ実体を表記違いで指した**）で行うと、対象は正しく戻るのに
        # **台帳のエントリだけが残る**。残骸は -List に「**記録なし**」として出続け、
        # 再注入で別表記のキーが増えると台帳に大小文字違いの 2 キーが並ぶ（上の読み込みの
        # コメント参照）。記録には注入時の表記が入っているので、それを第 2 の鍵にする
        #
        # **ただし「まだ誰も使っていないキー」に限る**。記録ファイルごと clone をコピーする運用
        # （このモードがまさに想定している増やし方）では、コピー先の記録が**別プロジェクトを
        # 指したまま**になる。無条件に第 2 の鍵として使うと、その eject が
        # **まだ注入中の別プロジェクトの台帳エントリを消し**、解放された slot が次の注入へ
        # 再割り当てされて**同じ editorBridgePort が二重予約**される ― 台帳が存在する理由
        # そのものの事故（サブエージェントのレビューが実測で再現）。
        #
        # **判定を「大小文字だけが違うか」の文字列比較にしてはいけない**。
        # **大小文字を区別する FS では `/Proj` と `/proj` は別実体**なので、
        # `/Proj` の記録ごと `/proj` へコピーして `/proj` を eject すると、
        # まだ注入中の `/Proj` のエントリを消してしまう（codex の指摘）。
        # 代わりに**記録の有無**で見る ― ここへ来る時点で自分の記録は削除済みなので、
        # 同一実体（表記違い）なら記録は無く、別実体がまだ注入中なら記録が残っている。
        # `Show-Ledger` が「注入中 / **記録なし**」を出しているのと同じ判定軸
        $keys = @((Get-UappNormalizedDir $Target))
        if ($record.target) {
            $recKey = Get-UappNormalizedDir $record.target
            if ($recKey -cne $keys[0]) {
                if (Test-Path -LiteralPath (Join-UappPath $recKey $RECORD_NAME)) {
                    Write-Warning ("記録の target（$recKey）にはまだ注入の記録があります。" +
                                   "そちらの台帳エントリは残します（記録ごとコピーされた clone の可能性）")
                } else { $keys += $recKey }
            }
        }
        foreach ($k in $keys) { if ($data.Contains($k)) { $data.Remove($k) } }
    } | Out-Null
    Write-Host "  [OK] 記録と台帳の割り当てを削除"
    Write-Host ""
    Write-Host "撤去しました。**Packages/packages-lock.json に $PIPELINE_PKG の行が残ることがあります**"
    # **破壊的な git 操作を促さない**（issue #47）。「git で戻してください」は
    # **AI エージェントに `git checkout --` を実行させうる**（導入先は手順書側で
    # 「エージェントは破棄しない・報告だけする」と明示して打ち消していた）。
    # **手当てが不要**なら、そう言い切るほうが安全
    Write-Host "（Unity が次回起動時に整理するので、**手当ては不要です**。"
    Write-Host "  どうしても今戻したい場合は、**人が判断して** git で戻してください）"

    # **撤去後の git 状態を出す**（issue #47）。導入先は自作の eject が最後に出す
    # `git status --porcelain` を見て「完全に戻った」と確認していた。標準の eject へ
    # 移行してから、**確認手段が手順書側の「自分で git status を打つ」に退化していた**。
    # **対象が git 管理下でなければ黙って省く**（無関係な警告を増やさない）
    Show-EjectGitStatus -TargetDir $Target
}

# --- 台帳の表示 --------------------------------------------------------------
function Show-Ledger {
    if (-not (Test-Path -LiteralPath $LEDGER)) { Write-Host "台帳はまだありません: $LEDGER"; return }
    Write-Host "台帳: $LEDGER"
    # **ロック越しに読む**（書き込み中の部分 JSON を読むと壊れた表示になる ― レビュー指摘）
    $data = Use-Ledger { param($d) $d }
    foreach ($p in $data.GetEnumerator()) {
        $v = $p.Value
        $alive = if (Test-Path -LiteralPath (Join-UappPath $p.Key $RECORD_NAME)) { "注入中" } else { "**記録なし**" }
        Write-Host ("  slot {0,-3} editor={1} device={2}  {3}  {4}" -f
                    $v.slot, $v.editorBridgePort, $v.devicePort, $alive, $p.Key)
    }
}

# --- エントリ ----------------------------------------------------------------
if ($List) { Show-Ledger; exit 0 }
if (-not $TargetProject) {
    throw "-TargetProject を指定してください（台帳を見るだけなら -List）"
}
# **-LiteralPath で解決する**（`[` `]` を含むパスはワイルドカードとして解釈され、
# 空を返して「引数が空」という無関係なエラーになる ― レビューが実測）
$target = Get-UappNormalizedDir (Resolve-Path -LiteralPath $TargetProject).Path

# **対象ごとの排他で処理全体を囲む**（台帳のロックだけでは足りない ― 事前チェックから
# コピー・記録・撤去までは無防備で、2 プロセスが同時に通過して同じ対象を並行更新できる。
# 一方の eject が他方の注入中に計装を消す、という壊れ方も起きる ― レビュー指摘）
$targetMutex = New-Object System.Threading.Mutex($false,
    (Get-UappHostMutexName ("uapp_e2e-inject-" + ($target.ToLowerInvariant() -replace '[^a-z0-9]', '-'))))
$targetLocked = $false
try { $targetLocked = $targetMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $targetLocked = $true }
if (-not $targetLocked) {
    throw "この対象への注入/撤去が別プロセスで進行中です: $target（完了を待って再実行）"
}
try {
    if ($Eject) { Invoke-Eject $target } else { Invoke-Inject $target }
} finally {
    $targetMutex.ReleaseMutex()
    $targetMutex.Dispose()
}
exit 0
