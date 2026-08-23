# エージェント開発ダッシュボード（別リポジトリ unity-agent-dash）への薄いエミッタ。
#
# 設計方針:
#   - **ダッシュボードを必須依存にしない**。プロトコルがファイルベースなので、ここでは
#     `.agent-status\units\<unitId>.ndjson` へ JSON を1行追記するだけで済む（Python もパッケージも不要）
#   - `.agent-status` が無ければ**完全に何もしない**（ダッシュボード未導入の環境で挙動が変わらないこと）
#   - 失敗しても**呼び出し元の終了コードとログを汚さない**（握りつぶす）
#
# 使い方（他のスクリプトから dot-source する）:
#   . (Join-Path $PSScriptRoot "emit-status.ps1")
#   Send-DashEvent -Kind "evidence.test" -Data @{ suite = "unity-editmode"; passed = 12; failed = 0; exitCode = 0 }

function Get-DashStatusDir {
    <#
      .SYNOPSIS
      監視対象の `.agent-status` を探す。環境変数 > 起点とその親の2階層。見つからなければ $null。

      .NOTES
      **2階層より上は見ない**。開発リポジトリでは起点自身、導入先では親（uapp_e2e の親＝
      Unity プロジェクトルート）で必要十分であり、それ以上遡ると複数リポジトリを束ねた
      親ディレクトリの .agent-status を掴んで、導入していない別プロジェクトのジャーナルを汚す。
    #>
    param([string]$StartPath)

    # ディレクトリであることまで確認する（同名のファイルを掴むと以降の書き込みが必ず失敗する）
    try {
        if ($env:UAPP_E2E_STATUS_DIR) {
            return $(if (Test-Path -LiteralPath $env:UAPP_E2E_STATUS_DIR -PathType Container) {
                $env:UAPP_E2E_STATUS_DIR
            } else { $null })
        }
        if (-not $StartPath) { $StartPath = $PSScriptRoot }
        $current = $StartPath
        for ($i = 0; $i -lt 2 -and $current; $i++) {
            $candidate = Join-Path $current ".agent-status"
            if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }
            $parent = Split-Path $current -Parent
            if ($parent -eq $current) { break }
            $current = $parent
        }
    } catch {
        # 判定自体が失敗しても呼び出し元を巻き込まない（連携は補助機能）
    }
    return $null
}

function Send-DashEvent {
    <#
      .SYNOPSIS
      客観エビデンス（evidence.*）を1行追記する。ダッシュボードが無ければ何もしない。
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [hashtable]$Data,
        [string]$StartPath
    )

    try {
        $statusDir = Get-DashStatusDir -StartPath $StartPath
        if (-not $statusDir) { return }

        $unitsDir = Join-Path $statusDir "units"
        New-Item -ItemType Directory -Force $unitsDir | Out-Null

        # 作業単位の解決: 環境変数 → **進行中の単位がちょうど1件ならそれ** → ambient。
        # ラッパー（このスクリプトを呼ぶ run-e2e.ps1 等）は AI から別プロセスで起動されるので
        # 環境変数も unitId も届かない。そのため申告中の作業でもエビデンスだけが ambient に落ち、
        # 「申告では成功だが、この単位で実際に走ったテストは？」に答えられなかった。
        # 2件以上ならどちらの作業か決められないので ambient のまま（推測で結びつけない）
        $data = if ($Data) { @{} + $Data } else { @{} }   # 呼び出し元の hashtable を書き換えない
        # **ホスト名は Dns.GetHostName() を使う**。$env:COMPUTERNAME は NetBIOS 名で 15 文字に
        # 切られるため（例: MY-LONG-HOSTNAME-R5 → MY-LONG-HOSTNAM）、Python 側（socket.gethostname）と
        # 食い違い、同じマシンなのに「別ホストの単位」と誤判定したり ambient が2つに割れたりする
        $thisHost = try { [System.Net.Dns]::GetHostName() } catch { $env:COMPUTERNAME }
        $unitId = $null
        if ($env:UAPP_E2E_UNIT_ID) { $unitId = $env:UAPP_E2E_UNIT_ID }
        elseif ($env:UAPP_DASH_UNIT_ID) { $unitId = $env:UAPP_DASH_UNIT_ID }
        else {
            # 候補は「このホストが所有し」「ハートビートが切れていない」進行中の単位だけ。
            # 別マシンの作業や放置された単位に実測値を付けると、突き合わせの信頼性が壊れる
            $active = @()
            foreach ($f in (Get-ChildItem -LiteralPath $unitsDir -Filter *.json -File -ErrorAction SilentlyContinue)) {
                try {
                    $u = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
                    if (-not $u.unitId -or $u.state -in @("done", "failed", "aborted")) { continue }
                    if ($u.owner -and $u.owner.host -and $u.owner.host -ne $thisHost) { continue }
                    $beat = if ($u.lastHeartbeat) { $u.lastHeartbeat } else { $u.startedAt }
                    if ($beat) {
                        $ttl = if ($u.ttlSec) { [int]$u.ttlSec } else { 300 }
                        # 集約側と同じ猶予（60 秒）を足して「停滞」を判定する
                        if (((Get-Date) - [datetime]::Parse($beat)).TotalSeconds -gt ($ttl + 60)) { continue }
                    }
                    $active += $u.unitId
                    if ($active.Count -gt 1) { break }   # 2 件見つかれば決められない（走査も打ち切る）
                } catch { }   # 壊れた行/ファイルは黙って飛ばす（記録は補助機能）
            }
            if ($active.Count -eq 1) {
                $unitId = $active[0]
                $data["unitIdSource"] = "active-unit"   # 自動で結びつけた根拠を残す
            }
        }
        if (-not $unitId) { $unitId = "ambient-$thisHost" }
        $unitId = $unitId -replace '[^A-Za-z0-9._-]', '_'

        $event = [ordered]@{
            schema   = "uapp-dash/event/0"
            at       = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")   # オフセット付き必須
            unitId   = $unitId
            seq      = 0                                             # 追記のみのため採番しない
            producer = "tool"                                        # AI の自己申告と混ぜない
            kind     = $Kind
            data     = $data
        }
        $line = ConvertTo-Json $event -Compress -Depth 6
        $path = Join-Path $unitsDir "$unitId.ndjson"
        # 追記は UTF-8（BOM なし）。1行が短いので追記の原子性は実用上問題にならない
        [System.IO.File]::AppendAllText($path, $line + "`n", (New-Object System.Text.UTF8Encoding $false))
    } catch {
        # ダッシュボード連携は補助機能。ここでの失敗を呼び出し元に波及させない
    }
}
