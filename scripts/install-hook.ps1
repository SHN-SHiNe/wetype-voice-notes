#requires -Version 7.0
<#
.SYNOPSIS
    安装「微信输入法录音笔自动归档」钩子（登录自启 + 30 分钟后备扫描）。

.DESCRIPTION
    注册两个当前用户级计划任务：
      WeTypeVoiceNotesHook        登录后延迟 30 秒启动 watcher（隐藏窗口），失败自动重启
      WeTypeVoiceNotesHookBackup  每 N 分钟跑一次 watcher -Once（后备触发，防 FileSystemWatcher 漏事件）

    两者都通过生成的 .vbs（wscript 隐藏窗口）启动 pwsh，避免黑框一闪。
    不需要管理员权限；不需要常驻 DSH 会话。

.EXAMPLE
    pwsh -File install-hook.ps1
    pwsh -File install-hook.ps1 -Start        # 装完立刻启动一次
    pwsh -File install-hook.ps1 -Out D:\notes -BackupMinutes 15
#>
[CmdletBinding()]
param(
    [string]$Source = 'C:\Users\SHiNe\AppData\Local\Tencent\WeType\VoiceSummary',
    [string]$Out = 'C:\Users\SHiNe\Desktop\微信输入法录音笔导出',
    [ValidateRange(1, 600)][int]$QuietSeconds = 20,
    [ValidateRange(5, 1440)][int]$BackupMinutes = 30,
    [switch]$NoNotify,
    [switch]$Start
)

$ErrorActionPreference = 'Stop'

$TaskName = 'WeTypeVoiceNotesHook'
$BackupTaskName = 'WeTypeVoiceNotesHookBackup'
$WatcherScript = Join-Path $PSScriptRoot 'watcher.ps1'
$PyScript = Join-Path $PSScriptRoot 'wetype_notes.py'
$WatcherVbs = Join-Path $PSScriptRoot 'watcher-hidden.vbs'
$BackupVbs = Join-Path $PSScriptRoot 'backup-hidden.vbs'

function Fail([string]$Message) {
    Write-Host "[install-hook] 失败：$Message" -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------ 前置检查
if (-not (Test-Path -LiteralPath $WatcherScript)) { Fail "找不到 watcher.ps1：$WatcherScript" }
if (-not (Test-Path -LiteralPath $PyScript)) { Fail "找不到 wetype_notes.py：$PyScript" }
if (-not (Test-Path -LiteralPath $Source -PathType Container)) { Fail "数据目录不存在：$Source" }

$pwshPath = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshPath)) {
    $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
}
if (-not $pwshPath) { Fail '找不到 pwsh.exe；请从 PowerShell 7 运行本脚本。' }

$wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$useVbs = Test-Path -LiteralPath $wscriptPath

if (-not (Test-Path -LiteralPath $Out)) {
    New-Item -ItemType Directory -Force -Path $Out | Out-Null
    Write-Host "[install-hook] 已创建导出目录：$Out"
}

$user = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME

# ------------------------------------------------------- 生成隐藏窗口启动器
function Write-Launcher {
    param([string]$Path, [string[]]$ExtraArgs)
    $cmd = @(
        ('"{0}"' -f $script:pwshPath),
        '-NoProfile',
        '-ExecutionPolicy Bypass',
        '-WindowStyle Hidden',
        '-File',
        ('"{0}"' -f $script:WatcherScript)
    ) -join ' '
    if ($ExtraArgs.Count -gt 0) { $cmd += ' ' + ($ExtraArgs -join ' ') }

    $vbs = @(
        "' 由 install-hook.ps1 生成：以隐藏窗口启动 wetype-voice-notes watcher。删除本文件不影响已导出内容。",
        'Option Explicit',
        'Dim sh',
        'Set sh = CreateObject("WScript.Shell")',
        ('sh.Run "{0}", 0, False' -f $cmd.Replace('"', '""')),
        'Set sh = Nothing'
    ) -join "`r`n"
    $unicode = New-Object System.Text.UnicodeEncoding($false, $true)
    [IO.File]::WriteAllText($Path, $vbs + "`r`n", $unicode)
}

$watchArgs = @('-Source', ('"{0}"' -f $Source), '-Out', ('"{0}"' -f $Out),
    '-QuietSeconds', [string]$QuietSeconds)
$backupArgs = $watchArgs + @('-Once')
if ($NoNotify) { $watchArgs += '-NoNotify'; $backupArgs += '-NoNotify' }

if ($useVbs) {
    Write-Launcher -Path $WatcherVbs -ExtraArgs $watchArgs
    Write-Launcher -Path $BackupVbs -ExtraArgs $backupArgs
    $action = New-ScheduledTaskAction -Execute $wscriptPath `
        -Argument ('//nologo "{0}"' -f $WatcherVbs) -WorkingDirectory $PSScriptRoot
    $backupAction = New-ScheduledTaskAction -Execute $wscriptPath `
        -Argument ('//nologo "{0}"' -f $BackupVbs) -WorkingDirectory $PSScriptRoot
}
else {
    Write-Host '[install-hook] 警告：没有 wscript.exe，改用 pwsh -WindowStyle Hidden（登录时可能闪一下窗口）。' -ForegroundColor Yellow
    $baseArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $WatcherScript
    $action = New-ScheduledTaskAction -Execute $pwshPath `
        -Argument ($baseArgs + ' ' + ($watchArgs -join ' ')) -WorkingDirectory $PSScriptRoot
    $backupAction = New-ScheduledTaskAction -Execute $pwshPath `
        -Argument ($baseArgs + ' ' + ($backupArgs -join ' ')) -WorkingDirectory $PSScriptRoot
}

$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

# ------------------------------------------------------------------ 触发器
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $user
try { $logonTrigger.Delay = 'PT30S' }
catch { Write-Host '[install-hook] 警告：无法设置 30 秒延迟，将立即启动。' -ForegroundColor Yellow }

# 每日触发 + 1 天重复区间 = 每 N 分钟一直跑（Task Scheduler 的"重复任务"没有无限时长选项）
$startAt = (Get-Date).AddMinutes(2)
$daily = New-ScheduledTaskTrigger -Daily -At $startAt
$repeat = New-ScheduledTaskTrigger -Once -At $startAt `
    -RepetitionInterval (New-TimeSpan -Minutes $BackupMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 1)
$daily.Repetition = $repeat.Repetition

# ------------------------------------------------------------------ 注册
$watchSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
$watchSettings.DisallowStartIfOnBatteries = $false
$watchSettings.StopIfGoingOnBatteries = $false

$backupSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5)

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $logonTrigger `
        -Settings $watchSettings -Principal $principal -Force `
        -Description '微信输入法 AI 录音笔：登录后常驻监视 VoiceSummary，新纪要自动增量归档并弹通知（隐藏窗口）。' | Out-Null

    Register-ScheduledTask -TaskName $BackupTaskName -Action $backupAction -Trigger $daily `
        -Settings $backupSettings -Principal $principal -Force `
        -Description ('微信输入法 AI 录音笔：每 {0} 分钟后备增量归档，防实时监视漏事件。' -f $BackupMinutes) | Out-Null
}
catch {
    Fail ("注册计划任务失败：{0}`n  常见原因：Group Policy 禁止普通用户建任务、或需要管理员运行。" -f $_.Exception.Message)
}

Write-Host ''
Write-Host '[install-hook] 已安装' -ForegroundColor Green
Write-Host ("  任务 1：{0}（登录后延迟 30 秒启动 watcher，失败每分钟重启）" -f $TaskName)
Write-Host ("  任务 2：{0}（每 {1} 分钟跑一次 watcher -Once 后备）" -f $BackupTaskName, $BackupMinutes)
Write-Host ("  数据目录：{0}（只读）" -f $Source)
Write-Host ("  导出目录：{0}" -f $Out)
Write-Host ("  日志：{0}" -f (Join-Path $Out '.wetype-watcher.log'))
Write-Host ("  启动器：{0}" -f $(if ($useVbs) { $WatcherVbs } else { 'pwsh -WindowStyle Hidden（无 wscript）' }))
Write-Host ''
Write-Host '  查看状态：pwsh -File status-hook.ps1'
Write-Host '  停止卸载：pwsh -File uninstall-hook.ps1'

if ($Start) {
    Write-Host ''
    Write-Host '[install-hook] 立即启动 watcher ...'
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 4
    $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*-File*watcher.ps1*' -and $_.CommandLine -notlike '*-Command*' -and $_.CommandLine -notlike '*-Once*' })
    if ($procs.Count -gt 0) {
        Write-Host ("  已在运行，PID {0}" -f (($procs | ForEach-Object { $_.ProcessId }) -join ', ')) -ForegroundColor Green
    }
    else {
        Write-Host '  启动信号已发出，但暂时没看到 watcher 进程；稍等几秒再跑 status-hook.ps1。' -ForegroundColor Yellow
    }
}

exit 0
