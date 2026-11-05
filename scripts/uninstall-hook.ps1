#requires -Version 7.0
<#
.SYNOPSIS
    卸载「微信输入法录音笔自动归档」钩子。

.DESCRIPTION
    停掉并删除两个计划任务、结束常驻 watcher 进程、清理生成的隐藏启动器。
    **不动导出目录里的任何内容**（txt / html / docx / 日志 / 状态文件都保留）。

.EXAMPLE
    pwsh -File uninstall-hook.ps1
#>
[CmdletBinding()]
param(
    [string]$Out = 'C:\Users\SHiNe\Desktop\微信输入法录音笔导出'
)

$ErrorActionPreference = 'Continue'
$TaskName = 'WeTypeVoiceNotesHook'
$BackupTaskName = 'WeTypeVoiceNotesHookBackup'
$VbsFiles = @(
    (Join-Path $PSScriptRoot 'watcher-hidden.vbs'),
    (Join-Path $PSScriptRoot 'backup-hidden.vbs')
)

Write-Host ''
Write-Host '== 停止并删除计划任务 ==' -ForegroundColor Cyan
foreach ($name in @($TaskName, $BackupTaskName)) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Host ("  {0}：未注册（跳过）" -f $name)
        continue
    }
    try { Stop-ScheduledTask -TaskName $name -ErrorAction Stop } catch { }
    try {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        Write-Host ("  {0}：已删除" -f $name) -ForegroundColor Green
    }
    catch {
        Write-Host ("  {0}：删除失败 —— {1}" -f $name, $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '== 结束 watcher 进程 ==' -ForegroundColor Cyan
$procs = @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*-File*watcher.ps1*' -and $_.CommandLine -notlike '*-Command*' -and $_.CommandLine -notlike '*-Once*' })
if ($procs.Count -eq 0) {
    Write-Host '  没有常驻 watcher 在跑'
}
else {
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Write-Host ("  已结束 PID {0}" -f $p.ProcessId) -ForegroundColor Green }
        catch { Write-Host ("  结束 PID {0} 失败：{1}" -f $p.ProcessId, $_.Exception.Message) -ForegroundColor Yellow }
    }
}

Write-Host ''
Write-Host '== 清理隐藏启动器 ==' -ForegroundColor Cyan
foreach ($f in $VbsFiles) {
    if (Test-Path -LiteralPath $f) {
        try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop; Write-Host ("  已删除 {0}" -f (Split-Path -Leaf $f)) }
        catch { Write-Host ("  删除 {0} 失败：{1}" -f (Split-Path -Leaf $f), $_.Exception.Message) -ForegroundColor Yellow }
    }
}

Write-Host ''
Write-Host '== 复核 ==' -ForegroundColor Cyan
Start-Sleep -Milliseconds 500
$left = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -in @($TaskName, $BackupTaskName) })
$leftProc = @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*-File*watcher.ps1*' -and $_.CommandLine -notlike '*-Command*' -and $_.CommandLine -notlike '*-Once*' })
Write-Host ("  计划任务剩余：{0} 个" -f $left.Count)
Write-Host ("  watcher 进程剩余：{0} 个" -f $leftProc.Count)
Write-Host ''
Write-Host ("  导出目录保持原样：{0}" -f $Out) -ForegroundColor Green
Write-Host ("  日志仍在：{0}" -f (Join-Path $Out '.wetype-watcher.log'))

if ($left.Count -gt 0 -or $leftProc.Count -gt 0) { exit 1 }
exit 0
