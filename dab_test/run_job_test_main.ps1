<#
  [dev matsushita_sho] job_test_main を実行し、終わるまで待ち、ノートブックの結果を表示する
  前提: databricks CLI で認証済み

  終了コード:
    0 = 正常終了（ノートブックの status = SUCCESS）
    1 = ノートブックが失敗を返した（status = FAILED）
    2 = ジョブ自体が失敗した（例外を受け止めきれなかった・キャンセルなど）
    3 = タイムアウト（ジョブはキャンセル済み）
    9 = スクリプトや CLI のエラー
#>
param(
    [string]   $JobName        = "[dev matsushita_sho] job_test_main",
    [hashtable]$JobParams      = @{},        # 例: @{ target_date = "2026-11-13"; mode = "full" }
    [string]   $CliProfile     = "",         # 認証プロファイルを指定したい場合のみ
    [int]      $PollSeconds    = 15,
    [int]      $TimeoutMinutes = 60
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8   # 日本語が文字化けしないようにする

# CLI を呼び出し、JSON の部分だけを受け取る共通関数
function Invoke-DbCli {
    param([string[]]$CliArgs)
    if ($CliProfile) { $CliArgs += @("--profile", $CliProfile) }
    $all    = & databricks @CliArgs -o json 2>&1
    $stdout = $all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
    if ($LASTEXITCODE -ne 0) { throw "databricks $($CliArgs -join ' ') failed:`n$($all | Out-String)" }
    if (-not $stdout) { return $null }
    return ($stdout | Out-String | ConvertFrom-Json)
}

# ノートブックの結果を表示し、status を返す
function Show-NotebookResult {
    param($TaskKey, $Output)
    Write-Host "---- task: $TaskKey ----"
    $raw = $Output.notebook_output.result
    if ($raw) {
        try {
            $nb = $raw | ConvertFrom-Json
            Write-Host "status : $($nb.status)"
            Write-Host "message: $($nb.message)"
            if ($nb.params)     { Write-Host "params : $($nb.params | ConvertTo-Json -Compress)" }
            if ($nb.error_type) { Write-Host "error  : $($nb.error_type)" }
            if ($nb.trace)      { Write-Host "trace  :`n$($nb.trace)" }
            if ($Output.notebook_output.truncated) { Write-Warning "結果が途中で切れています（5MB 上限）" }
            return $nb.status
        } catch {
            Write-Host "result (raw): $raw"     # JSON でなかった場合はそのまま表示する
            return "UNKNOWN"
        }
    }
    # exit() まで届かずに止まった場合は、Databricks 側のエラー情報を表示する
    if ($Output.error)       { Write-Host "error : $($Output.error)" }
    if ($Output.error_trace) { Write-Host "trace :`n$($Output.error_trace)" }
    return "NO_OUTPUT"
}

try {
    # 0. ジョブ名から job_id を調べる
    $jobs = @(Invoke-DbCli @("jobs", "list", "--name", $JobName))
    if ($jobs.Count -ne 1) { throw "Job '$JobName' が $($jobs.Count) 件見つかりました（1 件である必要があります）" }
    $jobId = $jobs[0].job_id
    Write-Host "Job: $JobName (job_id=$jobId)"

    # ① ジョブを開始（パラメータ付き・完了を待たない）
    #    Windows では JSON を直接渡すと引用符が崩れやすいので、一時ファイルに書いて @file で渡す
    $body    = @{ job_id = [int64]$jobId; job_parameters = $JobParams } | ConvertTo-Json -Depth 5 -Compress
    $tmpJson = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmpJson, $body, (New-Object System.Text.UTF8Encoding($false)))  # 先頭に BOM を付けない
    try   { $run = Invoke-DbCli @("jobs", "run-now", "--json", "@$tmpJson", "--no-wait") }
    finally { Remove-Item $tmpJson -ErrorAction SilentlyContinue }
    $runId = $run.run_id
    Write-Host "Started run_id=$runId  params=$($JobParams | ConvertTo-Json -Compress)"

    # ② 終わるまで定期的に状態を確認する
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds $PollSeconds
        $r  = Invoke-DbCli @("jobs", "get-run", "$runId")
        $lc = $r.state.life_cycle_state
        Write-Host "$(Get-Date -Format T)  $lc"
        if ((Get-Date) -gt $deadline) {
                        try { Invoke-DbCli @("jobs", "cancel-run", "$runId", "--no-wait") | Out-Null } catch { Write-Host ("Cancel failed: " + $_.Exception.Message) }
            Write-Host "Timeout: $TimeoutMinutes 分を超えたため run_id=$runId をキャンセルしました"
            exit 3
        }
    } while ($lc -notin @("TERMINATED", "SKIPPED", "INTERNAL_ERROR"))

    $jobResult = $r.state.result_state
    Write-Host "Job result_state: $jobResult  $($r.state.state_message)"

    # ③ タスクごとにノートブックの結果を取得する（成功・失敗のどちらでも取りに行く）
    $nbStatuses = @()
    foreach ($t in $r.tasks) {
        try {
            $out = Invoke-DbCli @("jobs", "get-run-output", "$($t.run_id)")
            $nbStatuses += Show-NotebookResult -TaskKey $t.task_key -Output $out
        } catch {
            Write-Host "---- task: $($t.task_key) ---- 結果を取得できませんでした: $($_.Exception.Message)"
            $nbStatuses += "NO_OUTPUT"
        }
    }

    # ④ 終了コードを決める
    if ($jobResult -ne "SUCCESS")      { exit 2 }
    if ($nbStatuses -contains "FAILED") { exit 1 }
    exit 0
}
catch {
    Write-Host "Script error: $($_.Exception.Message)"
    exit 9
}