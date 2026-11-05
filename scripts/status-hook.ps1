#requires -Version 7.0
<#
.SYNOPSIS
    查看「微信输入法录音笔自动归档」钩子状态。

.DESCRIPTION
    打印：两个计划任务的状态/上次运行/结果/下次运行、watcher 进程、最近 5 条日志、
    最近一次同步时间。退出码 0=已安装且 watcher 在跑，2=已安装但进程没跑，1=未安装。

.EXAMPLE
    pwsh -File status-hook.ps1
#>
[CmdletBinding()]
param(
    [string]$Out = 'C:\Users\SHiNe\Desktop\微信输入法录音笔导出'
)

$ErrorActionPreference = 'Continue'
$TaskName = 'WeTypeVoiceNotesHook'
$BackupTaskName = 'WeTypeVoiceNotesHookBackup'
$LogPath = Join-Path $Out '.wetype-watcher.log'
$SyncPath = Join-Path $Out '最近一次同步.txt'
$StatePath = Join-Path $Out '.wetype-export-state.json'

function Format-Result($code) {
    if ($null -eq $code) { return '-' }
    try { return ('0x{0:X8}（{1}）' -f [int]$code, [int]$code) } catch { return [string]$code }
}

function Show-Task([string]$Name, [string]$Label) {
    $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Host ("  {0,-28} 未注册" -f $Label) -ForegroundColor Yellow
        return $false
    }
    $info = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction SilentlyContinue
    $lastRun = '-'
    if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $lastRun = $info.LastRunTime.ToString('MM-dd HH:mm:ss') }
    $trig = @($task.Triggers | ForEach-Object {
            if ($_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger') {
                '登录时' + $(if ($_.Delay) { '（延迟 ' + $_.Delay + '）' } else { '' })
            }
            elseif ($_.Repetition.Interval) { '每 ' + $_.Repetition.Interval }
            else { $_.CimClass.CimClassName -replace 'MSFT_Task', '' -replace 'Trigger', '' }
        }) -join ' + '
    Write-Host ("  {0,-28} {1}  上次 {2} 结果 {3} 下次 {4}" -f $Label, $task.State, $lastRun,
        (Format-Result $info.LastTaskResult),
        $(if ($info.NextRunTime -and $info.NextRunTime.Year -gt 2000) { $info.NextRunTime.ToString('MM-dd HH:mm') } else { '-' }))
    Write-Host ("  {0,-28} 触发器：{1}" -f '', $trig)
    return $true
}

Write-Host ''
Write-Host '== 计划任务 ==' -ForegroundColor Cyan
$hasMain = Show-Task -Name $TaskName -Label $TaskName
$hasBackup = Show-Task -Name $BackupTaskName -Label $BackupTaskName

Write-Host ''
Write-Host '== watcher 进程 ==' -ForegroundColor Cyan
$all = @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*-File*watcher.ps1*' -and $_.CommandLine -notlike '*-Command*' })
$daemon = @($all | Where-Object { $_.CommandLine -notlike '*-Once*' })
$backup = @($all | Where-Object { $_.CommandLine -like '*-Once*' })
if ($daemon.Count -eq 0) {
    Write-Host '  常驻 watcher：未运行' -ForegroundColor Yellow
}
else {
    foreach ($p in $daemon) {
        $started = '-'
        try {
            if ($p.CreationDate -is [datetime]) { $started = $p.CreationDate.ToString('MM-dd HH:mm:ss') }
            elseif ($p.CreationDate) { $started = ([Management.ManagementDateTimeConverter]::ToDateTime([string]$p.CreationDate)).ToString('MM-dd HH:mm:ss') }
        }
        catch { }
        $cpu = ''
        try { $cpu = ' CPU ' + [math]::Round((Get-Process -Id $p.ProcessId).CPU, 1) + 's' } catch { }
        Write-Host ("  常驻 watcher：PID {0}  启动 {1}{2}" -f $p.ProcessId, $started, $cpu) -ForegroundColor Green
    }
}
if ($backup.Count -gt 0) {
    Write-Host ("  后备扫描进程：{0}" -f (($backup | ForEach-Object { $_.ProcessId }) -join ', '))
}

Write-Host ''
Write-Host '== 最近 5 条日志 ==' -ForegroundColor Cyan
if (Test-Path -LiteralPath $LogPath) {
    Get-Content -LiteralPath $LogPath -Encoding utf8 -Tail 5 | ForEach-Object { '  ' + $_ }
}
else {
    Write-Host '  （还没有日志）'
}

Write-Host ''
Write-Host '== 导出目录 ==' -ForegroundColor Cyan
Write-Host ("  {0}" -f $Out)
if (Test-Path -LiteralPath $StatePath) {
    try {
        $state = Get-Content -LiteralPath $StatePath -Raw -Encoding utf8 | ConvertFrom-Json
        Write-Host ("  已导出记录：{0} 条（状态文件 updated_at={1}）" -f @($state.records.PSObject.Properties).Count, $state.updated_at)
    }
    catch { Write-Host '  状态文件读取失败' -ForegroundColor Yellow }
}
if (Test-Path -LiteralPath $SyncPath) {
    Write-Host ("  最近一次同步.txt：{0}" -f (Get-Item -LiteralPath $SyncPath).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
}
else {
    Write-Host '  最近一次同步.txt：还没有（尚未归档过新纪要）'
}

Write-Host ''
if (-not $hasMain) {
    Write-Host '结论：钩子未安装。安装：pwsh -File install-hook.ps1' -ForegroundColor Yellow
    exit 1
}
if ($daemon.Count -eq 0) {
    Write-Host '结论：任务已注册，但 watcher 进程没在跑。可 Start-ScheduledTask -TaskName WeTypeVoiceNotesHook，或看日志排查。' -ForegroundColor Yellow
    exit 2
}
Write-Host '结论：钩子已安装，watcher 正常运行。' -ForegroundColor Green
exit 0
