# OS 差分の吸収（Windows / macOS）。他のスクリプトから dot-source して使う:
#   . (Join-Path $PSScriptRoot "uapp-platform.ps1")
#
# **mac は Intel Mac（x86_64）と Apple Silicon（arm64）の両方の実機で検証済み
# （2026-08-03。どちらもデバイス経路の E2E まで全パス）**。「OS で分かれる判断」をこの 1 ファイルに集約しているのは、
# mac で動かないときにまずここを読んで直せばよい状態にしておくためで、各スクリプトへ分岐を散らさない。
#
# 分かっている前提（Intel / Apple Silicon の両方で実測済み）:
#   - Unity エディタ実体: <root>/<version>/Unity.app/Contents/MacOS/Unity（Hub 既定は /Applications/Unity/Hub/Editor）
#   - Android SDK 既定: ~/Library/Android/sdk（adb / emulator に .exe は付かない）
#   - Unity CLI（`unity`）: PATH → OS 既定（Windows=%LOCALAPPDATA%\Unity\bin / mac=~/.unity/bin）の順に解決
#   - `Get-CimInstance Win32_Process` は Windows 専用。mac では `ps` からコマンドラインを読む
#   - `robocopy` は Windows 専用。Copy-UappTree で代替する

function Test-UappWindows {
    <#
      .SYNOPSIS
      Windows で動いているか。**PowerShell 5.1 には $IsWindows が無い**ので、無ければ Windows と見なす。
    #>
    if ($null -eq $IsWindows) { return $true }
    return [bool]$IsWindows
}

function Get-UappPathSeparator {
    return [string][System.IO.Path]::DirectorySeparatorChar
}

function Get-UappHostMutexName {
    <#
      .SYNOPSIS
      「ホスト全体で 1 つ」を意味する名前付き Mutex の名前へ変換する。

      .NOTES
      **素の名前はホスト全体ではない**。**接頭辞を付けないと `Local\`（セッション単位）**に
      なる、というのが .NET の仕様で、OS 固有の設定やマシン固有の事情ではない。
      用途が「全セッション横断の多重起動検知」である以上、`Global\` が正解になる。
      **OS で分岐しない**（issue #24 で Windows 側と合意。2026-08-04）。

      - Unix（.NET）: `Local\` は `/tmp/.dotnet/shm/session<セッションID>/` 配下に、
        `Global\` は `/tmp/.dotnet/shm/global/` に置かれる。セッション ID は `getsid()` 由来なので、
        **素の名前だと別ターミナルから起動した 2 本が別々のロックを取り、排他が黙って無効になる**。
        mac（arm64・pwsh 7.6.4 / .NET 10.0.10）で `setsid` を明示した A/B を実測:
        素の名前は別セッションから取得できてしまい、`Global\` 付きだけが `false` を返す（2026-08-03）。
      - Windows: 仕様は同じ。対話ユーザーの端末同士は同一セッションに入るため素の名前でも
        「たまたま」機能するが、RDP・ユーザーの簡易切り替え・**セッション 0（タスクスケジューラ／
        サービス）**をまたぐと同じ狭窄になる。AI 自律運用ではスケジューラから回す構成があり得るので
        そこは実害になる。**Windows 11・非昇格で実測済み**（issue #24）:
        `Global\` 付きの Mutex 作成は例外なし、保持中に別プロセスから `WaitOne(0)` が `False`。
        **mutex の作成に SeCreateGlobalPrivilege は要らない**（特権が要るのは file-mapping と
        symbolic link の作成のみ）。Store アプリでは global 名前空間が使えないが、
        このキットはターミナルの pwsh 7 前提なので該当しない。仮に拒否されても
        **例外でガードの手前で止まる＝fail-closed** なので方針と整合する。
        RDP／別ユーザー越しの排他だけは未実測で、Microsoft の文書保証に依拠している

      なお `-Editor` の排他はこの Mutex だけではない。**実運用の二重実行は
      `playMode ≠ stopped` の判定（run-e2e.ps1）が止める**（エディタ自身に問い合わせるので
      OS のセッション概念と無関係）。**この Mutex はその判定の TOCTOU
      （2 本が同時に `stopped` を読む窓）を塞ぐ補助層**という位置づけ。
    #>
    param([Parameter(Mandatory)][string]$Name)
    return "Global\$Name"
}

function Test-UappIosSupported {
    <#
      .SYNOPSIS
      iOS 経路（build-ios.ps1 / run-ios-e2e.ps1）が使える OS か。

      .NOTES
      判断基準は「xcodebuild / simctl が存在しうる OS か」＝ macOS。
      呼び出し側に OS 分岐を書かせないための意味ベースの解決関数
      （check-portability の「OS 分岐は uapp-platform.ps1 に集約」規則と整合させる）。
    #>
    return -not (Test-UappWindows)
}

function Get-UappEditorPlayMutexName {
    <#
      .SYNOPSIS
      「このプロジェクトのエディタ Play を操作する」排他 Mutex の名前を返す。

      .NOTES
      run-e2e.ps1 の -Editor と restart-editor-play.ps1 が**同じ名前を共有する**ためのヘルパ。
      名前の組み立てが片方にだけあると、もう片方が別名の Mutex を取って排他が素通りする
      （restart-editor-play が別ターミナルの E2E 実行中に editor_stop してしまう）。
    #>
    param([Parameter(Mandatory)][string]$ProjectDir)
    return Get-UappHostMutexName ("uapp_e2e-editor-" + (($ProjectDir.ToLowerInvariant() -replace "[^a-z0-9]", "-")))
}

function Join-UappPath {
    <#
      .SYNOPSIS
      パスを連結する。**子要素に含まれる `\` と `/` はどちらも区切りとして扱う**。

      .NOTES
      `Join-Path $dir "Library\EditorInstance.json"` は Windows では動くが、
      **mac では `\` が区切りではない**ためファイル名の一部になり、存在しないパスになる
      （エラーにならず「見つからない」として現れるので原因が分かりにくい）。
      既存の記述をそのまま活かせるよう、区切りの解釈だけを差し替える形にしている。

      **絶対パスが子要素に来たら、そこから組み立て直す**（.NET の Path.Combine と同じ）。
      素朴に連結すると `C:\base\D:\root\x` のような**別の有効な場所**が出来てしまい、
      「見つからない」ではなく「違う場所を見ている」形で遅れて発覚する。
      `e2e-config.json` の値のように利用者が書いた文字列が子要素へ来る経路が実在する。
    #>
    param(
        [Parameter(Mandatory, Position = 0)][string]$Base,
        [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$Parts
    )
    $result = $Base
    foreach ($part in $Parts) {
        if ([string]::IsNullOrEmpty($part)) { continue }
        $native = ConvertTo-UappNativePath $part
        if ([System.IO.Path]::IsPathRooted($native)) { $result = $native; continue }
        foreach ($segment in ($part -split '[\\/]+')) {
            if ($segment -eq "") { continue }
            $result = Join-Path $result $segment
        }
    }
    return $result
}

function ConvertTo-UappNativePath {
    <#
      .SYNOPSIS
      区切りを実行中 OS のものへ揃える（設定値やマニフェストに書かれた相対パス用）。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    # 置換文字列側で特別扱いされるのは `$` だけ（`\` はそのまま入る）
    return ($Path -replace '[\\/]', (Get-UappPathSeparator))
}

function ConvertTo-UappPathKey {
    <#
      .SYNOPSIS
      比較用に区切りを `/` へ正規化する。**OS をまたいで作られた記録の照合に使う**
      （kit-manifest.json のキーは記録した OS の区切りで入る）。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    return ($Path -replace '\\', '/')
}

function Get-UappNormalizedDir {
    <#
      .SYNOPSIS
      ディレクトリパスの末尾区切りを落とす（Windows のドライブ直下 `C:\` だけは残す）。

      .NOTES
      末尾に区切りが付いたまま引用すると、Windows では閉じ引用符が `\"` と解釈されて
      **後続の引数までパスに飲み込まれる**。`C:` はドライブ相対を指す別物なので落とせない。
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (Test-UappWindows) {
        # **区切りが複数付いていても落とし切らない**（`C:\\` を素の TrimEnd に通すと `C:` に
        # なり、ドライブ相対という別物に化ける）
        # **`+` にする**（`*` だと区切りゼロの `C:`＝ドライブ相対にも一致し、
        # 別の場所（ドライブルート）へ静かに変えてしまう）
        if ($Path -match '^([A-Za-z]:)[\\/]+$') { return ($Matches[1] + '\') }
        return $Path.TrimEnd('\', '/')
    }
    if ($Path -match '^/+$') { return '/' }   # `//` を空文字にしない
    if ($Path -eq '/') { return $Path }
    return $Path.TrimEnd('/')
}

function Get-UappDefaultEditorRoots {
    <#
      .SYNOPSIS
      Unity Hub がエディタを置く既定の場所（config\local.json の editorRoots が無いときの候補）。
    #>
    if (Test-UappWindows) {
        return @("C:\Program Files\Unity\Hub\Editor", "D:\Unity\Hub\Editor")
    }
    return @("/Applications/Unity/Hub/Editor", (Join-UappPath $HOME "Applications/Unity/Hub/Editor"))
}

function Get-UappEditorExecutable {
    <#
      .SYNOPSIS
      エディタルートとバージョンから実行ファイルのパスを組み立てる（存在確認はしない）。

      .NOTES
      **mac は .app バンドルの中の実行ファイルを直接指す**（Windows の Unity.exe に相当）:
        Windows … <root>\<version>\Editor\Unity.exe
        macOS  … <root>/<version>/Unity.app/Contents/MacOS/Unity
    #>
    param(
        [Parameter(Mandatory)][string]$EditorRoot,
        [Parameter(Mandatory)][string]$Version
    )
    if (Test-UappWindows) { return (Join-UappPath $EditorRoot $Version "Editor" "Unity.exe") }
    return (Join-UappPath $EditorRoot $Version "Unity.app/Contents/MacOS/Unity")
}

function Resolve-UappEditor {
    <#
      .SYNOPSIS
      指定バージョンのエディタ実体を探す。見つからなければ $null。
    #>
    param(
        [Parameter(Mandatory)][string]$Version,
        [string[]]$Roots
    )
    if (-not $Roots -or $Roots.Count -eq 0) { $Roots = Get-UappDefaultEditorRoots }
    foreach ($root in $Roots) {
        if (-not $root) { continue }
        $candidate = Get-UappEditorExecutable -EditorRoot $root -Version $Version
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Get-UappUnityCli {
    <#
      .SYNOPSIS
      Unity CLI（`unity`）の実体。PATH → OS 既定インストール先の順。無ければ $null。

      .NOTES
      既定インストール先は Windows が `%LOCALAPPDATA%\Unity\bin`、mac が `~/.unity/bin`
      （公式 install.sh の配置先）。**インストーラが PATH を足すのは対話シェルの rc だけ**なので、
      AI エージェント等の非対話シェルでは PATH に乗らない。既定位置のフォールバックが無いと
      「インストール済みなのに `-Editor` 系だけ使えない」という分かりにくい欠け方になる。
    #>
    $cli = Get-UappCommandPath "unity"
    if ($cli) { return $cli }
    $candidate = if (Test-UappWindows) { Join-UappPath $env:LOCALAPPDATA "Unity\bin\unity.exe" }
                 else { Join-UappPath $HOME ".unity/bin/unity" }
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    return $null
}

function Get-UappUnityCliGlobalArgs {
    <#
      .SYNOPSIS
      Unity CLI へ毎回渡す**グローバル引数**（サブコマンドより前に置く）を組み立てる。
      有効化されていなければ空配列を返す。

      .NOTES
      **プロキシ配下では `-Editor` 系が一切動かないこと**がある。CLI が localhost 宛ての
      Pipeline 通信までプロキシへ流し、プロキシが 503 を返すため `unity status` が
      `unreachable` になる（ブリッジ側は健全で、`curl` に Bearer トークンを付ければ 200 が返る）。
      **CLI が受け付けるバイパス指定はどれも効かない** — `NO_PROXY` / `no_proxy` /
      `UNITY_NOPROXY` / `unity config proxy --bypass`（保存設定は環境変数に負ける。
      優先順位はコマンドライン引数 > 環境変数 > 保存設定 > OS 設定）。
      **効くのは CLI 公式の `--proxy-disable` だけ**（0.1.0-beta.6 で追加。
      「1 回の呼び出しについてプロキシ設定をバイパスする」オプション）。
      いずれも mac（1.0.0-beta.3）で陽性対照つきに実測（2026-08-03）。

      **既定では何も足さない。** プロキシを黙って無効化すると、認証やダウンロードが
      通らない環境で原因の分からない失敗になるため、使う側が明示的に有効化する。
    #>
    param([switch]$ProxyDisable)
    $cliArgs = @()
    if ($ProxyDisable) { $cliArgs += "--proxy-disable" }
    return ,$cliArgs   # 空配列がスカラーへ潰れないようにカンマ演算子で包む
}

function Resolve-UappUnityCliProxyDisable {
    <#
      .SYNOPSIS
      `--proxy-disable` を付けるかを、スイッチと環境変数から決める。

      .NOTES
      スクリプトは 1 回の作業で複数本（run-e2e → run-unity-tests 等）呼ばれるので、
      **環境変数 `UAPP_E2E_UNITY_CLI_PROXY_DISABLE=1` で一度に効かせられる**ようにしてある。
      スイッチが指定されていればそちらが優先。
    #>
    param([switch]$Switch)
    if ($Switch) { return $true }
    return ($env:UAPP_E2E_UNITY_CLI_PROXY_DISABLE -eq "1")
}

function Get-UappCommandPath {
    <#
      .SYNOPSIS
      PATH 上の**実行ファイル**の絶対パス（無ければ $null）。

      .NOTES
      **`-CommandType Application` に限定する**。素の `Get-Command` は関数・エイリアス・
      モジュールのコマンドも拾い、`.Source` が実行ファイルではなくモジュール名になる
      （それを `Start-Process -FilePath` に渡すと即失敗する）。`adb` を関数やエイリアスで
      包んでいる利用者は珍しくないので、存在判定にも同じ限定を使うこと。
    #>
    param([Parameter(Mandatory)][string]$Name)
    $cmd = @(Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-UappPython {
    <#
      .SYNOPSIS
      Python の実行ファイル（`python` → `python3` の順）。見つからなければ $null。

      .NOTES
      **mac は `python` が無い構成が普通**（Homebrew は `python3` だけを入れる）。
      裸で `python` を呼ぶと「見つからない」で止まるので、必ずここで解決してから呼ぶ。
    #>
    foreach ($name in @("python", "python3")) {
        $path = Get-UappCommandPath $name
        if ($path) { return $path }
    }
    return $null
}

function Get-UappAndroidSdkRoot {
    <#
      .SYNOPSIS
      Android SDK の場所（最初に見つかった候補）。無ければ $null。
      **ツールを探すときは Get-UappAndroidTool を使う**（候補を順に見るため）。
    #>
    $roots = @(Get-UappAndroidSdkRoots)
    if ($roots.Count -gt 0) { return $roots[0] }
    return $null
}

function Get-UappAndroidSdkRoots {
    <#
      .SYNOPSIS
      Android SDK の候補を優先順に列挙する（実在するものだけ）。
      ANDROID_HOME → ANDROID_SDK_ROOT → OS 既定。

      .NOTES
      **存在確認で例外を出さない**（呼び出し元は $ErrorActionPreference = "Stop"）。
      切断されたドライブや権限の無いディレクトリが先頭候補にあると、
      そこで列挙全体が止まり、後ろにある使える SDK に辿り着けなくなる。
    #>
    $roots = @()
    foreach ($v in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)) {
        if ($v -and (Test-Path -LiteralPath $v -ErrorAction SilentlyContinue) -and ($roots -notcontains $v)) { $roots += $v }
    }
    $default = if (Test-UappWindows) { Join-UappPath $env:LOCALAPPDATA "Android/Sdk" }
               else { Join-UappPath $HOME "Library/Android/sdk" }
    if ($default -and (Test-Path -LiteralPath $default -ErrorAction SilentlyContinue) -and ($roots -notcontains $default)) { $roots += $default }
    return $roots
}

function Get-UappAndroidTool {
    <#
      .SYNOPSIS
      SDK 同梱ツールの実体パス（emulator / adb）。見つからなければ $null。

      .NOTES
      **候補ルートを順に見る**。「ANDROID_HOME は古い SDK で platform-tools が無い／
      ANDROID_SDK_ROOT に現行 SDK がある」という環境で、使える adb があるのに
      「見つからない」で止めないため（最初の候補で確定すると実際に止まる）。
    #>
    param([Parameter(Mandatory)][ValidateSet("emulator", "adb")][string]$Name)
    $sub = if ($Name -eq "adb") { "platform-tools" } else { "emulator" }
    $exe = if (Test-UappWindows) { "$Name.exe" } else { $Name }
    foreach ($sdk in (Get-UappAndroidSdkRoots)) {
        $candidate = Join-UappPath $sdk $sub $exe
        if (Test-Path -LiteralPath $candidate -ErrorAction SilentlyContinue) { return $candidate }
    }
    return $null
}

function Get-UappEditorLogPath {
    <#
      .SYNOPSIS
      Unity エディタのログの置き場（表示用の文字列）。**案内先を間違えると探しようがない**。
    #>
    if (Test-UappWindows) { return "%LOCALAPPDATA%\Unity\Editor\Editor.log" }
    return "~/Library/Logs/Unity/Editor.log"
}

function Initialize-UappAndroidPath {
    <#
      .SYNOPSIS
      `adb` が PATH に無ければ、SDK の platform-tools をこのプロセスの PATH へ前置する。
      追加したディレクトリを返す（何もしなければ $null）。

      .NOTES
      **狙いは子プロセスにも効かせること**。pytest（Python ドライバ）も裸の `adb` を呼ぶので、
      PowerShell 側だけ実体を解決しても Python 側は直らない。環境変数は子へ継承されるため、
      ここで PATH を補えば両方が同じ adb を使う。
      **既に PATH にあるときは何もしない**（利用者が選んだ adb を横取りしない）。
      mac は SDK を入れても platform-tools が PATH に入らないことが多く、ここが無いと
      デバイス経路の最初の adb 呼び出しで止まる。
    #>
    # **実行ファイルに限定して見る**。`adb` という関数やエイリアスが定義されているだけで
    # 「PATH にある」と誤認すると、SDK を足さないまま先へ進んで結局失敗する
    if (Get-UappCommandPath "adb") { return $null }
    $adb = Get-UappAndroidTool -Name adb
    if (-not $adb) { return $null }
    $dir = Split-Path $adb -Parent
    $env:PATH = $dir + [System.IO.Path]::PathSeparator + $env:PATH
    return $dir
}

function Get-UappUnityProcess {
    <#
      .SYNOPSIS
      マシン上の Unity エディタプロセスを列挙する（Id / CommandLine / MainWindowTitle）。

      .NOTES
      **コマンドラインの `-projectPath` が「どのプロジェクトか」を知る唯一の確実な信号**。
      取得方法が OS で違う:
        Windows … Get-CimInstance Win32_Process（Get-Process にコマンドラインは無い）
        macOS  … `ps -axo pid=,command=`（Win32_Process 相当は存在しない）
      **MainWindowTitle は Windows でしか埋まらない**（mac では常に空。ウィンドウタイトルを
      根拠にした推定は mac では効かないが、mac では ps から全プロセスの引数が取れるので
      -projectPath 側の信号で足りる想定）。
    #>
    $result = @()
    if (Test-UappWindows) {
        # **CIM を母集合にする**（pid とコマンドラインを一度に得られる）。
        # Get-Process を先に撮って後から CIM で突き合わせると、2 つのスナップショットの間に
        # **起動したプロセスを取りこぼし、終了したプロセスを「取得不可」として過剰に占有扱い**にする、
        # という非対称が出る。
        # **コマンドラインが取れなかったことは黙って捨てない**（どのプロジェクトのものか
        # 分からないまま無関係扱いにすると見落とし＝fail-open になる）。ウィンドウタイトル由来の
        # 推定は残したいので例外にはせず、`CommandLineAvailable = $false` を立てて
        # 呼び出し側が安全側へ倒せるようにする
        $cimProcs = $null
        try {
            $cimProcs = @(Get-CimInstance Win32_Process -Filter "Name='Unity.exe'" -ErrorAction Stop)
        } catch {
            Write-Warning ("Unity プロセスのコマンドラインを取得できませんでした（$($_.Exception.Message)）。" +
                           "どのプロジェクトのものか判定できません")
        }
        if ($null -ne $cimProcs) {
            foreach ($p in $cimProcs) {
                $procId = [int]$p.ProcessId
                # タイトルは best-effort（取れなくても判定は -projectPath 側で行う）
                $title = (Get-Process -Id $procId -ErrorAction SilentlyContinue).MainWindowTitle
                $result += [pscustomobject]@{
                    Id                   = $procId
                    CommandLine          = $p.CommandLine
                    MainWindowTitle      = $title
                    CommandLineAvailable = [bool]$p.CommandLine
                }
            }
            return $result
        }
        # CIM が丸ごと使えないときだけ Get-Process へ落ちる（全件「コマンドライン不明」）
        foreach ($p in @(Get-Process Unity -ErrorAction SilentlyContinue)) {
            $result += [pscustomobject]@{
                Id                   = [int]$p.Id
                CommandLine          = $null
                MainWindowTitle      = $p.MainWindowTitle
                CommandLineAvailable = $false
            }
        }
        return $result
    }
    # macOS / Linux: ps の出力からエディタ本体だけを拾う。
    # Unity Hub・パッケージマネージャ・自作ラッパーを巻き込まないよう、
    # 実行ファイルが Unity.app の中の Unity 本体であることを条件にする
    # **`ps` は実行ファイルとして解決してから呼ぶ**。PowerShell には `ps` という
    # `Get-Process` の別名があり（Unix では定義されない想定だが、環境によっては profile 等で
    # 定義されうる）、裸で呼ぶと `Get-Process` に `-axww` が渡って例外になる。
    # その例外を下の catch が握り潰すと、**「取得できなかった」が「0 件」に化ける**のが最悪で、
    # 起動途中のエディタを見落として二重起動ガードをすり抜ける
    # **列挙できないときは例外にする**（空配列を返すと呼び出し側が「Unity は動いていない」と
    # 解釈し、排他ガードが fail-open になる。mac はウィンドウタイトル信号が無く lockfile も
    # 弱いので、この経路が落ちると起動途中のエディタを丸ごと見落とす）
    $psExe = Get-UappCommandPath "ps"
    if (-not $psExe) {
        throw [System.InvalidOperationException]::new(
            "ps コマンドが見つからないため Unity プロセスを列挙できません")
    }
    try {
        # **`-ww` を必ず付ける**（幅制限を外す）。macOS の ps は既定でウィンドウ幅に切り詰め、
        # パイプ出力時の挙動は man に書かれていない。切られると **`-projectPath` が消えて**
        # 「どのプロジェクトのエディタか」が分からなくなり、検出漏れ（起動中を closed と誤報・
        # 二重起動ガードのすり抜け）になる。付けて困ることは無いので必ず付ける
        # **終了コードを見る**。ネイティブコマンドの失敗は例外にならないので、
        # catch では拾えず「0 件」に化ける（それがこの関数で一番危ない壊れ方）
        $psLines = @(& $psExe -axww -o "pid=,command=" 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                "ps が失敗しました（終了コード $LASTEXITCODE）。Unity プロセスを列挙できていません")
        }
        foreach ($line in $psLines) {
            if ($line -notmatch '^\s*(\d+)\s+(.+)$') { continue }
            $procId = [int]$Matches[1]
            $cmd = $Matches[2]
            if ($cmd -notmatch 'Unity\.app/Contents/MacOS/Unity(\s|$)') { continue }
            $result += [pscustomobject]@{
                Id                   = $procId
                CommandLine          = $cmd
                MainWindowTitle      = $null   # mac では取得できない
                CommandLineAvailable = $true   # ps から取れている（取れないときは上で例外）
            }
        }
    } catch [System.InvalidOperationException] {
        throw   # 上で作った「列挙できない」はそのまま呼び出し側へ渡す
    } catch {
        # **握り潰したまま 0 件を返さない**（「取れなかった」と「居なかった」は別物）
        throw [System.InvalidOperationException]::new(
            "Unity プロセスの列挙に失敗しました（$($_.Exception.Message)）")
    }
    return $result
}

function Save-UappNativeOutput {
    <#
      .SYNOPSIS
      ネイティブコマンドの標準出力を**バイト列のまま**ファイルへ保存する。終了コードを返す。

      .NOTES
      **`>` でバイナリをリダイレクトしない**。PowerShell の版によっては、ネイティブコマンドの
      標準出力がテキストとして解釈され、**PNG が静かに壊れる**（失敗証跡は壊れて初めて困る）。
      ここでは標準出力ストリームを直接ファイルへコピーするので、版にも OS にも依存しない。
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$OutFile
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $fs = [System.IO.File]::Create($OutFile)
    try {
        $proc.StandardOutput.BaseStream.CopyTo($fs)
    } finally {
        $fs.Dispose()
        $proc.WaitForExit()
    }
    return $proc.ExitCode
}

function Stop-UappProcessTree {
    <#
      .SYNOPSIS
      プロセスを**子孫ごと**強制終了する（ウォッチドッグの回収用）。

      .NOTES
      `Stop-Process` は子孫へ再帰しない。ラッパー（pwsh）だけ殺すと、その下で動く実処理
      （xcodebuild / pytest / Unity 等）が孤児化してポートやビルド出力を握り続ける（レビュー指摘）。
        Windows … taskkill /T /F（プロセスツリー終了の標準手段）
        Unix    … ps の親子表（pid,ppid）を辿って子孫を列挙し、子孫から順に SIGKILL
      列挙とキルの間に生まれた孫は取り逃す可能性があるが、ウォッチドッグの回収では
      「実処理の大半を確実に止める」ことが目的で、残骸は次回実行のガードが検出する。
    #>
    param([Parameter(Mandatory)][int]$ProcessId)
    if (Test-UappWindows) {
        # **実体を解決して呼ぶ**（裸で呼ぶと同名の関数・エイリアスへ入りうる。ps で踏んだ型と同じ）。
        # 失敗を黙って正常終了にしない — ツリーが残ると、直したい孤児化がそのまま再発する
        $taskkill = Get-UappCommandPath "taskkill"
        if ($taskkill) {
            & $taskkill /PID $ProcessId /T /F 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { return }
            Write-Warning "taskkill /T が失敗しました（exit=$LASTEXITCODE）。単体 kill にフォールバックします（子孫が残る可能性）"
        } else {
            Write-Warning "taskkill が見つかりません。単体 kill にフォールバックします（子孫が残る可能性）"
        }
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
        return
    }
    $psExe = Get-UappCommandPath "ps"
    if (-not $psExe) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
        return
    }
    $childrenOf = @{}
    foreach ($line in @(& $psExe -axo "pid=,ppid=" 2>$null)) {
        if ($line -match '^\s*(\d+)\s+(\d+)') {
            $parent = [int]$Matches[2]
            # `@($childrenOf[$parent]) + ...` は初回に `@($null)` を作って null 要素が混入する
            if (-not $childrenOf.ContainsKey($parent)) { $childrenOf[$parent] = @() }
            $childrenOf[$parent] += [int]$Matches[1]
        }
    }
    $all = @()
    $queue = @([int]$ProcessId)
    while ($queue.Count -gt 0) {
        $current = $queue[0]
        $queue = @($queue | Select-Object -Skip 1)
        $all += $current
        if ($childrenOf.ContainsKey($current)) { $queue += $childrenOf[$current] }
    }
    [array]::Reverse($all)   # 子孫から先に止める
    foreach ($procId in $all) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
}

function Test-UappPathEqual {
    <#
      .SYNOPSIS
      2 つのパス文字列が同じ場所を指すか（大小文字を区別する。「一致したら殺す」系の判定用）。

      .NOTES
      **全 OS で大小文字を区別する（Ordinal）**。大小文字だけ違う別ディレクトリは
      Unix の case-sensitive ボリュームだけでなく、**Windows でも NTFS のディレクトリ単位
      case-sensitivity（Microsoft 公式仕様。WSL 連携で有効化できる）で共存できる**ため、
      無視して比較するとどの OS でも巻き添えの余地が残る。
      殺す判定は under-match（一致を逃して殺し損ねる）が安全側 — 逃した場合は
      呼び出し側の可視化（UNITY_ORPHAN 等）が拾う。大小文字違いで同じ場所を指す文字列は
      「両辺を同じ構成で組み立てる」呼び出し方をしている限り発生しない。
      逆に**排他ガードの「見つけたら止まる」系は over-match が安全側**なので、
      この関数へ寄せずに従来の -ieq のままでよい（性質が逆）。
    #>
    param(
        [Parameter(Mandatory)][string]$A,
        [Parameter(Mandatory)][string]$B
    )
    return [string]::Equals($A, $B, [System.StringComparison]::Ordinal)
}

function Get-UappDevOnlyScript {
    <#
      .SYNOPSIS
      導入先へ配らない「開発専用スクリプト」の一覧を返す。

      .NOTES
      **配布経路が 2 つあるので、この一覧は 1 か所に置く**:
        package-kit.ps1 …… zip を作るとき
        install-to-project.ps1 … 開発リポジトリから直接導入するとき
      片方だけに書くと、**もう片方の経路でだけ未配布のはずのものが導入先へ届く**。
      実際に build-ios.ps1 / run-ios-e2e.ps1 が installer 側の列挙から漏れており、
      「iOS はキットに含まれていない」という文書の断定が開発リポジトリ経由では嘘になっていた
      （2026-08-06 のレビューで発覚）。**しかも docs/06 のリリース前検証は展開した zip から
      実行すると定めているため、この向きの漏れは検証では原理的に捕まらない**。

      **配るスクリプトの側は列挙しない**（v0.1.6 で unity-editor-status.ps1 が
      配布リストから漏れ、キットの文書が案内するコマンドが導入先に存在しない状態になった）。
      除外だけを列挙すれば、配布対象が増えたときは何もしなくても届く。
    #>
    return @(
        # iOS 経路（build-ios.ps1 / run-ios-e2e.ps1）は kit 0.1.9 で統合済み＝配布する
        # （SETUP の iOS 節・スキルの導線・E2EBridge.Editor.BuildEntry の iOS エントリ・
        # oslayer/ の同梱と揃えて解除した。issue #27）
        "install-to-project.ps1", "package-kit.ps1", "publish-kit.ps1", "verify-all.ps1",
        "check-portability.ps1"
    )
}

function Start-UappBackgroundProcess {
    <#
      .SYNOPSIS
      呼び出し元のコンソールを汚さずにプロセスをバックグラウンド起動し、Process オブジェクトを返す。

      .NOTES
      `Start-Process -WindowStyle Hidden` は **Windows 専用**で、mac / Linux では
      「このエディションではサポートされない」例外で落ちる（pwsh 7.6 で実測）。
      かといって単に外すと、Unix では子プロセスの標準出力が呼び出し元の端末へ混ざる。
      OS ごとに実績のある形へ寄せる:
        Windows … 従来どおり隠しウィンドウ（出力は捨てる。既存の検証済み挙動を変えない）
        Unix    … 標準出力を LogPath へ、標準エラーを LogPath + ".err" へリダイレクト
                  （同じファイルには向けられない仕様のため 2 本になる）
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$LogPath
    )
    # **`Start-Process -ArgumentList` は配列を空白で結合するだけ**（引用しない）ので、
    # 空白を含む引数は割れる。ここで 1 個ずつ引用してから渡す（Format-CliArg と同じ規則:
    # `"` の直前の `\` は連続ぶんだけ倍にして `\"` で退避、末尾の `\` も倍にする。
    # .NET の引数文字列の解釈規則は Unix でも同じ）
    $quoted = foreach ($a in $ArgumentList) {
        $escaped = [regex]::Replace($a, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
        $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
        '"' + $escaped + '"'
    }
    if (Test-UappWindows) {
        return Start-Process -FilePath $FilePath -ArgumentList $quoted -PassThru -WindowStyle Hidden
    }
    return Start-Process -FilePath $FilePath -ArgumentList $quoted -PassThru `
        -RedirectStandardOutput $LogPath -RedirectStandardError ($LogPath + ".err")
}

function Copy-UappTree {
    <#
      .SYNOPSIS
      ディレクトリを再帰コピーする（robocopy /E の代替。**robocopy は Windows 専用**）。

      .NOTES
      robocopy と同じく「宛先にある余分なファイルは消さない」追加型。
      失敗したら例外を投げる（呼び出し元は $ErrorActionPreference = "Stop" 前提）。

      **robocopy /E に合わせるために要るもの**（外すと静かに欠ける）:
      - `-Force` … 隠し項目も列挙する。**Unix では `.` で始まる名前が隠し扱い**なので、
        これが無いと mac でドットファイルが無言で配布から落ちる
      - `-FollowSymlink` … ディレクトリのシンボリックリンクの先も辿る（robocopy は
        `/SL` を付けない限り辿る）。付けないとリンク配下が丸ごと欠落する
      - 空ディレクトリも作る … `/E` は空ディレクトリを含める契約
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExcludeDirectory = @()
    )
    if (-not (Test-Path -LiteralPath $Source)) { throw "コピー元がありません: $Source" }
    $srcRoot = (Resolve-Path -LiteralPath $Source).Path
    New-Item -ItemType Directory -Force $Destination | Out-Null

    # 空ディレクトリを含めて構造を先に作る（除外ディレクトリ自身とその配下は作らない）
    foreach ($dir in (Get-ChildItem -LiteralPath $srcRoot -Recurse -Directory -Force -FollowSymlink -ErrorAction SilentlyContinue)) {
        $relDir = $dir.FullName.Substring($srcRoot.Length).TrimStart('\', '/')
        if ($ExcludeDirectory.Count -gt 0) {
            $segments = @($relDir -split '[\\/]+')
            if (@($segments | Where-Object { $ExcludeDirectory -contains $_ }).Count -gt 0) { continue }
        }
        $destDir = Join-UappPath $Destination $relDir
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force $destDir | Out-Null }
    }

    foreach ($file in (Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Force -FollowSymlink)) {
        $rel = $file.FullName.Substring($srcRoot.Length).TrimStart('\', '/')
        if ($ExcludeDirectory.Count -gt 0) {
            # 除外はディレクトリ名の一致で見る（相対パスの最後の要素＝ファイル名は対象外）
            $dirSegments = @($rel -split '[\\/]+')
            if ($dirSegments.Count -gt 1) {
                $dirSegments = $dirSegments[0..($dirSegments.Count - 2)]
                if (@($dirSegments | Where-Object { $ExcludeDirectory -contains $_ }).Count -gt 0) { continue }
            }
        }
        $dest = Join-UappPath $Destination $rel
        $destDir = Split-Path $dest -Parent
        if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Force $destDir | Out-Null
        }
        Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
    }
}
