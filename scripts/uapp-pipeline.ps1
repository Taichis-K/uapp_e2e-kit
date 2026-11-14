# uapp-pipeline.ps1 — com.unity.pipeline を扱う層（配布物。uapp-platform.ps1 のあとに . で読む）
# 設計: docs/design/pipeline-1.0.md。**基準はキットの形（いまは 1.0.0 の返事と同じ。1.0.0 のコードは 1.0.0-pre.1 と同一）**で、
# 0.10 と 0.9.1 の返事はここで 1.0 の形へ直す。呼び手は「送る引数を決める」「返事を読む」をここに任せ、
# 待つループ（タイムアウトの再試行・生存確認・証跡）は呼び手に残す（run-e2e と run-unity-tests で待ち方が意図して違う＝#38）。
# **新しい版はこの表に 1.0 との差を足し、採取した返事を scripts/fixtures/pipeline/<版>/ に足す**（check-platform-helpers が全版を試験する）。

# 版ごとの表（プロファイル）。**送り方**の違いだけを持つ: EvalFileArgs = eval をファイルで送るときの名前 / Legacy = グループの無い名前で送る（0.8）。
# **返事の読み方は版でなく形で決める**（包み・NDJSON・scenes / Results の配列。版が分からないときに古い版の返事を取り違えないため）
$script:UappPipelineProfiles = @{
    "1.0"  = @{ EvalFileArgs = @("script", "eval") }
    "0.10" = @{ EvalFileArgs = @("script", "eval") }
    "0.9"  = @{ EvalFileArgs = @("script", "eval_file") }
    # 0.8 はグループの無い古い名前で送る（返事の包みは 0.9 と同じ）。**0.1.32 も以前の呼び方を扱う**（2026-11-11 ユーザー指示「それ以前の呼び方との互換性を維持して」）
    "0.8"  = @{ EvalFileArgs = @("eval_file"); Legacy = $true }
}

function Get-UappPipelineProfileName {
    <#
      .SYNOPSIS
      版の文字列からプロファイル名（"1.0" / "0.10" / "0.9" / "0.8"）を返す。**分からない（$null・版の形でない）は "1.0"**（基準）。0.8 より前も "0.8"（古い名前で送る）
    #>
    param([AllowNull()][string]$Version)
    if (-not $Version -or $Version -notmatch '^\s*(\d+)\.(\d+)\.') { return "1.0" }
    $major = [int]$Matches[1]; $minor = [int]$Matches[2]
    if ($major -ge 1) { return "1.0" }
    if ($minor -ge 10) { return "0.10" }
    if ($minor -eq 9) { return "0.9" }
    return "0.8"
}

function Get-UappPipelineSendArgs {
    <#
      .SYNOPSIS
      したいこと（Op）と版から、`unity cmd --project-path <p>` のあとに付ける引数の配列を返す。
      Op: editor_status / eval（-Code か -File）/ list_open_scenes / open_scene（-ScenePath）/ editor_play / editor_stop /
          recompile / recompile_status / run_tests（-Filter -TimeoutSeconds）
    #>
    param([Parameter(Mandatory)][string]$Op, [AllowNull()][string]$Version,
          [string]$Code, [string]$File, [string]$ScenePath, [string]$Filter, [int]$TimeoutSeconds = 0)
    $prof = Get-UappPipelineProfileName $Version
    $p = $script:UappPipelineProfiles[$prof]
    if ($p.Legacy) {
        # 0.8 の古い名前（グループなし）。引数の形は同じ
        switch -CaseSensitive ($Op) {
            "editor_status"    { return @("editor_status") }
            "eval"             { if ($File) { return @("eval_file", "--file", $File) } else { return @("eval", "--code", $Code) } }
            "list_open_scenes" { return @("list_open_scenes") }
            "open_scene"       { return @("open_scene", "--path", $ScenePath) }
            "editor_play"      { return @("editor_play") }
            "editor_stop"      { return @("editor_stop") }
            "recompile"        { return @("recompile") }
            "recompile_status" { return @("recompile_status") }
            "run_tests"        { $a = @("run_tests", "--mode", "editor"); if ($TimeoutSeconds -gt 0) { $a += @("--timeout", "$TimeoutSeconds") }; if ($Filter) { $a += @("--filter", $Filter) }; return $a }
            default            { throw "uapp-pipeline: 知らない Op '$Op'" }
        }
    }
    switch -CaseSensitive ($Op) {
        "editor_status"    { return @("editor", "status") }
        "eval"             { if ($File) { return @($p.EvalFileArgs) + @("--file", $File) } else { return @("script", "eval", "--code", $Code) } }   # code は名前付きで（位置引数は 0.4 で 400 になった）
        "list_open_scenes" { return @("scene", "list_open") }
        "open_scene"       { return @("scene", "open", "--path", $ScenePath) }
        "editor_play"      { return @("editor.playmode", "start") }
        "editor_stop"      { return @("editor.playmode", "stop") }
        "recompile"        { return @("script", "recompile") }
        "recompile_status" { return @("script", "recompile_status") }
        "run_tests"        { $a = @("test", "run", "--mode", "editor"); if ($TimeoutSeconds -gt 0) { $a += @("--timeout", "$TimeoutSeconds") }; if ($Filter) { $a += @("--filter", $Filter) }; return $a }
        default            { throw "uapp-pipeline: 知らない Op '$Op'" }
    }
}

function ConvertTo-UappPipelineRecord {
    # 0.10 以前の PascalCase のテスト結果を 1.0 の名前へ（fullName / status / duration / message / stackTrace）
    param($r)
    [pscustomobject]@{ fullName = "$($r.fullName)"; status = "$($r.status)"; duration = $r.duration
                       message = $r.message; stackTrace = $r.stackTrace }
}

function ConvertFrom-UappPipelineResponse {
    <#
      .SYNOPSIS
      `unity cmd … --format json` の標準出力・標準エラー・終了コードを、**キットの形**に直す。
      @{ Ok; Value; Error = @{ Class; Code; Message }; Parsed } を返す。
      Value は Op ごとに 1.0 の形（eval=値・list_open_scenes=シーンのレコードの配列・run_tests=@{ records; total; passed; failed; skipped; inconclusive; duration }・
      editor_status / recompile_status=オブジェクト・play / stop / open / recompile=$null）。
      Parsed は 0.9.1 の包みの形の失敗（既存の Get-UappUnityCliErrorClass・Test-UappPipelineRenamedResponse に渡せる）。

      .NOTES
      Class: ok / transient（待てば直る＝既存の分類か 1.0 の rc 17）/ modal（rc 18。待っても直らない）/ timeout（rc 14。実行されたかを保証しない）/
      cancelled（rc 130）/ command-not-found（rc 13・`No command named`）/ invalid-args（rc 2）/ unparsable（読めない）/ failed（そのほか）。
      1.0 の rc 6 は「コマンドは動いたが結果が失敗」（テストの失敗）で、run_tests はレコードを読んで成功として返す（失敗したテストは records に入る）。
      rc 2 で標準エラーが `No EditMode tests matched` で始まるのは「一致 0 件」＝空の結果（それ以外の rc 2 は invalid-args）。
    #>
    param([Parameter(Mandatory)][string]$Op, [AllowNull()][string]$Version,
          [AllowNull()][AllowEmptyString()][string]$Stdout, [AllowNull()][AllowEmptyString()][string]$Stderr, $ExitCode)
    $prof = Get-UappPipelineProfileName $Version
    $p = $script:UappPipelineProfiles[$prof]
    $out = "$Stdout".TrimStart([char]0xFEFF).Trim()
    $err = "$Stderr".Trim()
    $exit = $null; if ($null -ne $ExitCode -and "$ExitCode" -match '^-?\d+$') { $exit = [int]"$ExitCode" }
    $mkFail = {
        param([string]$class, [string]$code, [string]$message)
        $parsedFail = [pscustomobject]@{ success = $false; command = "command"; data = $null
                                         errors = @([pscustomobject]@{ code = $code; message = $message }); warnings = @() }
        if ($class -eq "failed") {   # 既存の文言の分類（Network error・No Pipeline instance found など）を活かす
            $c = (Get-UappUnityCliErrorClass -Parsed $parsedFail).Class
            if ($c -eq "transient") { $class = "transient" }
        }
        @{ Ok = $false; Value = $null; Error = @{ Class = $class; Code = $code; Message = $message }; Parsed = $parsedFail }
    }
    $mkOk = { param($v) @{ Ok = $true; Value = $v; Error = $null; Parsed = $null } }

    # --- 1.0 の終了コード（標準出力が無くても判定できるもの） ---
    # rc 6 は「コマンドは動いたが結果が失敗」（1.0）。run_tests（失敗したテストの行）と recompile（{status:"failed"}）だけは中身を読む
    if ($null -ne $exit -and $exit -ne 0 -and -not ($exit -eq 6 -and $Op -in @("run_tests", "recompile"))) {
        $msg = if ($err) { $err } elseif ($out) { $out } else { "（終了コード $exit・出力なし）" }
        if ($exit -eq 2 -and $Op -ceq "run_tests" -and $err -match '(?m)^\s*(error:\s*)?Invalid Command Arguments:\s*No EditMode tests (matched|found)') {
            return (& $mkOk @{ records = @(); total = 0; passed = 0; failed = 0; skipped = 0; inconclusive = 0; duration = 0 })
        }
        $class = switch ($exit) { 2 { "invalid-args" } 13 { "command-not-found" } 14 { "timeout" } 17 { "transient" } 18 { "modal" } 102 { "transient" } 130 { "cancelled" } default { "failed" } }
        $code = switch ($exit) { 2 { "INVALID_COMMAND_ARGS" } 13 { "REMOTE_COMMAND_NOT_FOUND" } 14 { "TIMEOUT" } 17 { "EDITOR_BUSY" } 18 { "EDITOR_BLOCKED_BY_DIALOG" } 102 { "EDITOR_BUSY" } 130 { "CANCELLED" } default { "COMMAND_FAILED" } }
        # **標準出力の JSON を先に読む**（標準エラーにはプラグインの案内などが混ざる）: 0.9.1 は包みの errors（code もそのまま使う＝送り直しの判定のため）、
        # 0.10 は本体の error / errorDetails / errorCode
        $origWrap = $null
        if ($out) {
            try {
                $j = ConvertFrom-Json -InputObject $out -NoEnumerate -ErrorAction Stop
                if ($j -is [System.Management.Automation.PSCustomObject]) {
                    if ($j.errors) { $msg = (@($j.errors | ForEach-Object { "$($_.message)" }) -join " / "); if ("$(@($j.errors)[0].code)") { $code = "$(@($j.errors)[0].code)" }; $origWrap = $j }
                    elseif ("$($j.error)".Trim()) {
                        $msg = (@(foreach ($k in @("error", "errorDetails", "message")) { if ("$($j.$k)".Trim()) { "$($j.$k)" } }) -join "`n ")
                        if ("$($j.errorCode)".Trim()) { $code = "$($j.errorCode)" }
                    }
                }
            } catch { }
        }
        if ($msg -match 'No command named') { $class = "command-not-found" }
        $f = & $mkFail $class $code $msg
        if ($origWrap) { $f.Parsed = $origWrap }
        return $f
    }
    if ($null -eq $exit) {
        # 0.9.1 の包みつきの成功だけは、終了コードが取れなくても読む（前の ConvertFrom-UappCliCommandResponse と同じ。中身で成否が分かる）
        $wrapOk = $false
        try { $w = ConvertFrom-Json -InputObject $out -NoEnumerate -ErrorAction Stop; $wrapOk = ($w -is [System.Management.Automation.PSCustomObject] -and "$($w.command)" -ceq "command" -and $w.success -eq $true -and $null -ne $w.PSObject.Properties["data"]) } catch { }
        if (-not $wrapOk) { return (& $mkFail "unparsable" "NO_EXIT_CODE" "終了コードが分からない（成功とみなさない）: $out $err") }
    }

    # --- 本体を取り出す ---
    $body = $null; $records = $null
    if (-not $out) {
        if ($exit -eq 6) { return (& $mkFail "failed" "COMMAND_FAILED" $(if ($err) { $err } else { "（終了コード 6・出力なし。$Op）" })) }   # 結果が無いのに失敗＝理由は標準エラー（空の成功より先に見る）
        # 1.0 の Play / Stop / open などは標準出力が空で成功
        if ($Op -in @("editor_play", "editor_stop", "open_scene", "recompile")) { return (& $mkOk $null) }   # recompile も空なら $null（呼び手は「不明」として後段に任せる）
        if ($Op -ceq "list_open_scenes" -and $prof -eq "1.0") { return (& $mkOk @()) }
        if ($Op -ceq "run_tests" -and $prof -eq "1.0") { return (& $mkOk @{ records = @(); total = 0; passed = 0; failed = 0; skipped = 0; inconclusive = 0; duration = 0 }) }
        return (& $mkFail "unparsable" "EMPTY" "標準出力が空（$Op）: $err")
    }
    $single = $null; $singleOk = $false
    try { $single = ConvertFrom-Json -InputObject $out -NoEnumerate -ErrorAction Stop; $singleOk = $true } catch { }
    if (-not $singleOk) {
        # 1 行 1 件（NDJSON）。1 行でも読めなければ読めない扱い（黙って一部だけ読まない）
        $lines = @($out -split "`r?`n" | Where-Object { $_.Trim() })
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($l in $lines) {
            try { $list.Add((ConvertFrom-Json -InputObject $l -ErrorAction Stop)) } catch { return (& $mkFail "unparsable" "NDJSON" "1 行 1 件の返事の行が読めない（$Op）: $l") }
        }
        $records = $list.ToArray()
    } else {
        $body = $single
        # 0.9.1 の包み（success / command / data / errors。command が "command"）
        if ($body -is [System.Management.Automation.PSCustomObject]) {
            $names = @($body.PSObject.Properties.Name)
            if (($names -ccontains "success") -and ($names -ccontains "data") -and ($names -ccontains "errors") -and ("$($body.command)" -ceq "command")) {
                if ($body.success -ne $true) {
                    $msg = (@($body.errors | ForEach-Object { "$($_.message)" }) -join " / ")
                    $f = & $mkFail "failed" "$(@($body.errors)[0].code)" $msg
                    if ($msg -match 'No command named|renamed') { $f.Error.Class = "command-not-found" }
                    $f.Parsed = $body
                    return $f
                }
                $body = $body.data.result
            }
            # 包みの無い失敗の本体（0.10: success:false か error）
            elseif ($Op -cne "eval" -and ((($names -ccontains "success") -and $body.success -eq $false) -or (($names -ccontains "error") -and "$($body.error)".Trim()))) {
                $msg = (@(foreach ($k in @("error", "errorDetails", "message")) { if (($names -ccontains $k) -and "$($body.$k)".Trim()) { "$($body.$k)" } }) -join " / ")
                if (-not $msg) { $msg = $out }
                return (& $mkFail "failed" "COMMAND_FAILED" $msg)
            }
        }
        # 一覧は**版でなく形で読む**（下の switch）。版が分からないまま 1.0 として古い版の本体を「1 件」と数えると、偽の緑・未保存の変更の消失になる（mac のレビュー 高 1）
    }

    switch -CaseSensitive ($Op) {
        "eval" {
            if ($null -ne $records) { return (& $mkFail "unparsable" "NDJSON" "eval の返事が 1 行 1 件になっている: $out") }
            $isEvalBody = ($body -is [System.Management.Automation.PSCustomObject] -and $null -ne $body.PSObject.Properties["diagnostics"] -and $null -ne $body.PSObject.Properties["result"])
            if ($isEvalBody) {   # 0.10 以前の eval の本体（diagnostics と result）は .result を値にする。1.0 は値そのもの
                if ($body.success -eq $false) {
                    $diag = @($body.diagnostics | ForEach-Object { if ($_ -is [string]) { $_ } else { "$($_.message)" } }) -join " / "
                    return (& $mkFail "failed" "EVAL_FAILED" $(if ($diag) { $diag } else { $out }))
                }
                return (& $mkOk $body.result)
            }
            return (& $mkOk $body)
        }
        "list_open_scenes" {
            # 形で決める: NDJSON の行 / scenes の配列（0.10 以前）/ path を持つ単体（1.0 の 1 行）。それ以外は読めない
            $scenes = if ($null -ne $records) { @($records) }
                      elseif ($body -is [System.Management.Automation.PSCustomObject] -and $null -ne $body.PSObject.Properties["scenes"]) { @($body.scenes) }
                      elseif ($body -is [System.Management.Automation.PSCustomObject] -and $null -ne $body.PSObject.Properties["path"]) { @($body) }
                      else { return (& $mkFail "unparsable" "SHAPE" "list_open_scenes の返事の形が分からない: $out") }
            foreach ($s in $scenes) { if ($null -eq $s -or -not ($s -is [System.Management.Automation.PSCustomObject]) -or $null -eq $s.PSObject.Properties["path"]) { return (& $mkFail "unparsable" "SHAPE" "シーンのレコードに path が無い: $out") } }
            return (& $mkOk @($scenes))
        }
        "run_tests" {
            # 形で決める: NDJSON の行 / Results（0.10 以前）/ fullName を持つ単体（1.0 の 1 行）。それ以外は読めない
            $raw = if ($null -ne $records) { @($records) }
                   elseif ($body -is [System.Management.Automation.PSCustomObject] -and $null -ne $body.PSObject.Properties["Results"]) { @($body.Results) }
                   elseif ($body -is [System.Management.Automation.PSCustomObject] -and $null -ne $body.PSObject.Properties["fullName"]) { @($body) }
                   else { return (& $mkFail "unparsable" "SHAPE" "run_tests の返事の形が分からない: $out") }
            if (@($raw | Where-Object { $null -eq $_ }).Count -gt 0) { return (& $mkFail "unparsable" "SHAPE" "テストのレコードに null がある: $out") }   # 欠けたレコードを黙って捨てない
            $recs = @($raw | ForEach-Object { ConvertTo-UappPipelineRecord $_ })
            foreach ($r in $recs) { if (-not $r.fullName -or -not $r.status) { return (& $mkFail "unparsable" "SHAPE" "テストのレコードに fullName か status が無い: $out") } }
            $count = { param($s) @($recs | Where-Object { $_.status -eq $s }).Count }
            $dur = 0.0
            if ($null -eq $records -and $null -ne $body.Duration) { $dur = [double]$body.Duration }
            else { foreach ($r in $recs) { if ($null -ne $r.duration) { $dur += [double]$r.duration } } }
            # 1.0 の rc 6 は「失敗したテストがある」ときだけ結果として読む（途中で異常終了した rc 6 を成功にしない。mac のレビュー 中 3）
            if ($exit -eq 6 -and (& $count "Failed") -lt 1) { return (& $mkFail "failed" "COMMAND_FAILED" $(if ($err) { $err } else { "終了コード 6 なのに失敗したテストが無い: $out" })) }
            return (& $mkOk @{ records = [object[]]$recs; total = $recs.Count; passed = (& $count "Passed"); failed = (& $count "Failed")
                               skipped = (& $count "Skipped"); inconclusive = (& $count "Inconclusive"); duration = $dur })
        }
        { $_ -in @("editor_play", "editor_stop", "open_scene") } { return (& $mkOk $null) }   # 0.10 以前の「Entered play mode」などは捨てる
        "recompile" {
            # 1.0 はエラーが残っていて再コンパイルが要らないとき {status:"failed"} と rc 6（公式文書）。状態として返す（呼び手が原因を取り直す）
            if ($exit -eq 6 -and -not ($body -is [System.Management.Automation.PSCustomObject] -and "$($body.status)" -eq "failed")) { return (& $mkFail "failed" "COMMAND_FAILED" $(if ($err) { $err } else { $out })) }
            return (& $mkOk $body)
        }
        default { return (& $mkOk $body) }
    }
}

function Get-UappPipelineVersionForSend {
    <#
      .SYNOPSIS
      このプロジェクトの pipeline の版（送り方を決める版）を返す。分からなければ $null（＝基準の 1.0 として送る）。
      **分からない結果は覚えない**（エディタの起動・pipeline install のあとで変わる）。分かった結果はプロジェクトごとに覚える
    #>
    param([Parameter(Mandatory)][string]$ProjectDir)
    if (-not $script:UappPipelineVersionCache) { $script:UappPipelineVersionCache = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal) }
    if ($script:UappPipelineVersionCache.ContainsKey($ProjectDir)) { return $script:UappPipelineVersionCache[$ProjectDir] }
    $st = Get-UappPipelineCommandStyle -ProjectDir $ProjectDir
    if ($st.Version) { $script:UappPipelineVersionCache[$ProjectDir] = $st.Version }
    return $st.Version
}

function Invoke-UappPipelineOnce {
    <#
      .SYNOPSIS
      したいこと（Op）を **1 回だけ**送り、キットの形で返す（待たない・再試行しない。待つのは呼び手）。
      名前が古いと言われたら（0.9 の版が読めずに 1.0 の形で送った等）は送り直さない（呼び手が版を直して呼び直す）。
      期限 -TimeoutSeconds を過ぎたら子孫ごと止めて Class = "timeout" を返す
    #>
    param([Parameter(Mandatory)][string]$ProjectDir, [Parameter(Mandatory)][string]$Op,
          [string]$Code, [string]$File, [string]$ScenePath, [string]$Filter, [int]$TestTimeoutSeconds = 0,
          [int]$TimeoutSeconds = 60, [string[]]$CliGlobalArgs = @(), [string]$UnityCli)
    $ver = Get-UappPipelineVersionForSend -ProjectDir $ProjectDir
    $send = @(Get-UappPipelineSendArgs -Op $Op -Version $ver -Code $Code -File $File -ScenePath $ScenePath -Filter $Filter -TimeoutSeconds $TestTimeoutSeconds)
    $cli = if ($UnityCli) { $UnityCli } else { Get-UappUnityCli }
    if (-not $cli) { return @{ Ok = $false; Value = $null; Error = @{ Class = "failed"; Code = "NO_CLI"; Message = "Unity CLI が見つかりません" }; Parsed = $null } }
    $argv = @($CliGlobalArgs) + @("cmd", "--project-path", $ProjectDir) + $send + @("--format", "json", "--no-banner")
    $r = Invoke-UappPipelineCli -UnityCli $cli -ArgumentList $argv -TimeoutSeconds $TimeoutSeconds
    if ($r.TimedOut) { return @{ Ok = $false; Value = $null; Error = @{ Class = "timeout"; Code = "CLIENT_TIMEOUT"; Message = "Unity CLI が $TimeoutSeconds 秒で返らなかった（$Op）" }; Parsed = $null } }
    $res = ConvertFrom-UappPipelineResponse -Op $Op -Version $ver -Stdout $r.Stdout -Stderr $r.Stderr -ExitCode $r.ExitCode
    $res.Stdout = $r.Stdout; $res.Stderr = $r.Stderr; $res.ExitCode = $r.ExitCode
    return $res
}

function Invoke-UappPipelineCli {
    <#
      .SYNOPSIS
      Unity CLI を 1 回起動し、@{ Stdout; Stderr; ExitCode; TimedOut } を返す。UTF-8 で読み、期限で子孫ごと止める
    #>
    param([Parameter(Mandatory)][string]$UnityCli, [string[]]$ArgumentList, [int]$TimeoutSeconds = 60)
    $psi = [System.Diagnostics.ProcessStartInfo]::new($UnityCli)
    foreach ($a in $ArgumentList) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false); $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $proc.StandardInput.Close()
        $o = $proc.StandardOutput.ReadToEndAsync(); $e = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)) {
            try { Stop-UappProcessTree -ProcessId $proc.Id } catch { try { $proc.Kill($true) } catch { } }
            return @{ Stdout = ""; Stderr = ""; ExitCode = $null; TimedOut = $true }
        }
        $proc.WaitForExit()
        return @{ Stdout = $o.Result; Stderr = $e.Result; ExitCode = $proc.ExitCode; TimedOut = $false }
    } finally { $proc.Dispose() }
}

function ConvertTo-UappPipelineOp {
    # 呼び手が使っている 0.8 の名前（editor_status・eval_file など）を Op にする。知らない名前はそのまま（default の読み方＝本体を返す）
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -ceq "eval_file") { return "eval" }
    return $Name
}

function ConvertTo-UappPipelineCompat {
    <#
      .SYNOPSIS
      ConvertFrom-UappPipelineResponse の結果を、呼び手の既存の判定がそのまま使える形にする:
      @{ success; Value（キットの形）; Error; errors（Get-UappUnityCliErrorClass・Test-UappPipelineRenamedResponse 用）; data = $null }。
      **中身は .Value で読む**（.data.result は使わない＝版で形が変わる）
    #>
    param([Parameter(Mandatory)]$Result)
    [pscustomobject]@{
        success = [bool]$Result.Ok
        Value   = $Result.Value
        Error   = $Result.Error
        errors  = $(if ($Result.Parsed) { @($Result.Parsed.errors) } else { @() })
        warnings = @()
        data    = $null
    }
}