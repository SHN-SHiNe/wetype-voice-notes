#requires -Version 7.0
<#
.SYNOPSIS
    微信输入法 AI 录音笔 · 自动归档钩子（常驻监视器）。

.DESCRIPTION
    递归监视 VoiceSummary（只读），在最后一次写盘后静默 QuietSeconds 秒，
    再调用 wetype_notes.py --json 做增量导出。
    有新增/更新时：写 <Out>\.wetype-watcher.log、弹 Windows 通知、
    刷新 <Out>\最近一次同步.txt。异常只记日志，不退出监视。

.PARAMETER Source
    数据目录，默认 %LOCALAPPDATA%\Tencent\WeType\VoiceSummary。只读，绝不写入。

.PARAMETER Out
    导出目录，默认 C:\Users\SHiNe\Desktop\微信输入法录音笔导出。

.PARAMETER QuietSeconds
    去抖静默秒数，默认 20。最后一次写盘后静默满这么久才触发。

.PARAMETER NoNotify
    不弹通知（测试/静默运行用）。

.PARAMETER Once
    只跑一次增量导出（供 30 分钟后备任务调用），不进监视循环。

.PARAMETER LogAllRuns
    每次导出都写日志（含"无新增"），用于自测去抖次数。

.PARAMETER NoStartupSync
    启动时不做首次补同步（自测去抖时用）。

.PARAMETER PythonExe
    覆盖 py 启动器路径，默认用 `py -3`。

.EXAMPLE
    pwsh -File watcher.ps1
    pwsh -File watcher.ps1 -Source "$env:TEMP\vs-copy" -Out "$env:TEMP\vs-out" -NoNotify -LogAllRuns
#>
[CmdletBinding()]
param(
    [string]$Source = 'C:\Users\SHiNe\AppData\Local\Tencent\WeType\VoiceSummary',
    [string]$Out = 'C:\Users\SHiNe\Desktop\微信输入法录音笔导出',
    [ValidateRange(1, 600)][int]$QuietSeconds = 20,
    [switch]$NoNotify,
    [switch]$Once,
    [switch]$LogAllRuns,
    [switch]$NoStartupSync,
    [string]$PythonExe = ''
)

$ErrorActionPreference = 'Continue'

$script:Source = [IO.Path]::GetFullPath($Source)
$script:Out = [IO.Path]::GetFullPath($Out)
$script:PyScript = Join-Path $PSScriptRoot 'wetype_notes.py'
$script:LogPath = Join-Path $script:Out '.wetype-watcher.log'
$script:SyncPath = Join-Path $script:Out '最近一次同步.txt'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Notify = -not $NoNotify
$script:RetrySeconds = 15
$script:WatcherPrefix = 'WeTypeHook'
$script:SubIds = New-Object System.Collections.Generic.List[string]

# ------------------------------------------------------------------ 基础工具
function Write-Utf8File {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}

function Add-Log {
    param([string]$Level, [string]$Message)
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if ((Test-Path -LiteralPath $script:LogPath) -and
            (Get-Item -LiteralPath $script:LogPath).Length -gt 512KB) {
            $keep = @(Get-Content -LiteralPath $script:LogPath -Encoding utf8 -Tail 400)
            Write-Utf8File -Path $script:LogPath -Text (($keep -join "`r`n") + "`r`n")
        }
        [IO.File]::AppendAllText($script:LogPath, $line + "`r`n", $script:Utf8)
    }
    catch { }
    try { Write-Host $line } catch { }
}

function Resolve-PythonCommand {
    if ($PythonExe) {
        $cmd = @($PythonExe)
    }
    else {
        $cmd = @('py', '-3')
    }
    if (-not (Get-Command $cmd[0] -ErrorAction SilentlyContinue)) {
        foreach ($alt in @(@('python'), @('python3'), @('py'))) {
            if (Get-Command $alt[0] -ErrorAction SilentlyContinue) { $cmd = $alt; break }
        }
    }
    if (-not (Get-Command $cmd[0] -ErrorAction SilentlyContinue)) {
        throw '找不到 Python 解释器（py -3 / python 都不可用）'
    }
    return $cmd
}

# ------------------------------------------------------------------ 导出调用
function Invoke-WeTypeExport {
    <# 调用 wetype_notes.py --out <Out> --json，返回 JSON 摘要对象。失败抛异常。 #>
    $locked = $script:ExportMutex.WaitOne([TimeSpan]::FromSeconds(300))
    if (-not $locked) { throw '等待导出互斥量超时（另一个导出正在进行）' }

    $stamp = [guid]::NewGuid().ToString('N')
    $outTmp = Join-Path $env:TEMP "wetype-hook-out-$stamp.txt"
    $errTmp = Join-Path $env:TEMP "wetype-hook-err-$stamp.txt"
    try {
        $exe = $script:PyCmd[0]
        $prefix = ''
        if ($script:PyCmd.Count -gt 1) {
            $prefix = (($script:PyCmd[1..($script:PyCmd.Count - 1)]) -join ' ') + ' '
        }
        $argLine = '{0}"{1}" --src "{2}" --out "{3}" --json' -f $prefix, $script:PyScript, $script:Source, $script:Out

        $proc = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru `
            -WindowStyle Hidden -RedirectStandardOutput $outTmp -RedirectStandardError $errTmp
        if (-not $proc.WaitForExit(300000)) {
            try { $proc.Kill($true) } catch { }
            throw 'wetype_notes.py 超时（>300 秒）'
        }
        $code = $proc.ExitCode
        $stdout = ''
        $stderr = ''
        if (Test-Path -LiteralPath $outTmp) { $stdout = [IO.File]::ReadAllText($outTmp, $script:Utf8) }
        if (Test-Path -LiteralPath $errTmp) { $stderr = ([IO.File]::ReadAllText($errTmp, $script:Utf8)).Trim() }

        if ($code -ne 0) {
            $why = if ($stderr) { ($stderr -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' ' }
                   else { "退出码 $code" }
            throw "wetype_notes.py 退出码 $code：$why"
        }

        $text = $stdout.Trim()
        $i = $text.IndexOf('{')
        $j = $text.LastIndexOf('}')
        if ($i -lt 0 -or $j -le $i) {
            throw ('wetype_notes.py 没有输出 JSON：{0}' -f ($text.Substring(0, [Math]::Min(180, $text.Length))))
        }
        return ($text.Substring($i, $j - $i + 1) | ConvertFrom-Json)
    }
    finally {
        try { $script:ExportMutex.ReleaseMutex() } catch { }
        Remove-Item -LiteralPath $outTmp, $errTmp -Force -ErrorAction SilentlyContinue
    }
}

function Show-BalloonTip {
    <# Windows 气泡通知；任何失败静默降级，绝不中断监视。 #>
    param([string]$Title, [string]$Text)
    if (-not $script:Notify) { return }
    $icon = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $icon = New-Object System.Windows.Forms.NotifyIcon
        $icon.Icon = [System.Drawing.SystemIcons]::Information
        $icon.Text = '微信输入法录音笔'
        $icon.Visible = $true
        $icon.ShowBalloonTip(6000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::Info)
        # 气泡要进程存活才显示得出来；占用 6 秒期间事件会排队，不会丢。
        Start-Sleep -Seconds 6
    }
    catch { }
    finally {
        if ($icon) { try { $icon.Visible = $false; $icon.Dispose() } catch { } }
    }
}

function Write-SyncSnapshot {
    param($Summary)
    $newItems = @($Summary.new_items | Where-Object { $_ })
    $updItems = @($Summary.updated_items | Where-Object { $_ })
    $orphans = @($Summary.orphans | Where-Object { $_ })
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('微信输入法录音笔 · 最近一次同步')
    $lines.Add('')
    $lines.Add('时间：{0}' -f $Summary.finished_at)
    $lines.Add('数据目录：{0}' -f $Summary.src)
    $lines.Add('导出目录：{0}' -f $Summary.out)
    $lines.Add(('结果：新增 {0} 条 / 更新 {1} 条 / 跳过 {2} 条 / 空壳 {3} 条（索引共 {4} 条）' -f `
            $Summary.new, $Summary.updated, $Summary.skipped, $Summary.shell, $Summary.total))
    $lines.Add(('总字数：{0}（本次新增 {1}）' -f $Summary.chars_total, $Summary.chars_new))
    $lines.Add('耗时：{0}' -f $Summary.elapsed_text)
    if ($newItems.Count -gt 0) {
        $lines.Add('')
        $lines.Add('新增：')
        foreach ($it in $newItems) { $lines.Add(('  - {0}（{1} 字）' -f $it.folder, $it.chars)) }
    }
    if ($updItems.Count -gt 0) {
        $lines.Add('')
        $lines.Add('更新：')
        foreach ($it in $updItems) { $lines.Add(('  - {0}（{1} 字）' -f $it.folder, $it.chars)) }
    }
    if ($orphans.Count -gt 0) {
        $lines.Add('')
        $lines.Add(('注意：{0} 个目录在磁盘上但不在索引里：{1}' -f $orphans.Count, ($orphans -join '、')))
    }
    $lines.Add('')
    $lines.Add('日志：{0}' -f $script:LogPath)
    try { Write-Utf8File -Path $script:SyncPath -Text (($lines -join "`r`n") + "`r`n") }
    catch { Add-Log 'WARN' ("写「最近一次同步.txt」失败：{0}" -f $_.Exception.Message) }
}

function Invoke-SyncCycle {
    param([string]$Reason)
    $summary = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try { $summary = Invoke-WeTypeExport; break }
        catch {
            $msg = $_.Exception.Message
            if ($attempt -eq 1) {
                Add-Log 'WARN' ('导出失败（{0}），{1} 秒后重试：{2}' -f $Reason, $script:RetrySeconds, $msg)
                Start-Sleep -Seconds $script:RetrySeconds
            }
            else {
                Add-Log 'ERROR' ('导出失败（{0}）：{1}' -f $Reason, $msg)
                return
            }
        }
    }
    if ($null -eq $summary) { return }

    $newItems = @($summary.new_items | Where-Object { $_ })
    $updItems = @($summary.updated_items | Where-Object { $_ })
    $newCount = [int]$summary.new
    $updCount = [int]$summary.updated
    $changed = ($newCount + $updCount) -gt 0
    $head = '新增 {0} 条 / 更新 {1} 条 / 跳过 {2} 条 / 空壳 {3} 条（共 {4} 条）' -f `
        $newCount, $updCount, $summary.skipped, $summary.shell, $summary.total

    if (-not $changed) {
        if ($LogAllRuns) { Add-Log 'SYNC' ('{0} | 触发：{1} | 无变化' -f $head, $Reason) }
        return
    }

    $titles = @()
    foreach ($it in $newItems) { $titles += [string]$it.title }
    foreach ($it in $updItems) { $titles += ('[更新] ' + [string]$it.title) }
    $titleText = ($titles -join '、')
    Add-Log 'SYNC' ('{0} | 触发：{1} | {2} | 新增/更新：{3}' -f $head, $Reason,
        [string]$summary.finished_at, $titleText)

    # 归档已成功；后面的快照/通知即使出错也只是降级，绝不能让监视器退出。
    try {
        Write-SyncSnapshot -Summary $summary
    }
    catch {
        Add-Log 'WARN' ('写「最近一次同步.txt」失败（已继续监视）：{0}' -f $_.Exception.Message)
    }

    try {
        $shown = ''
        if ($newCount -gt 0) {
            $shown = ($newItems | ForEach-Object { [string]$_.title } | Select-Object -First 3) -join '、'
            $tip = '已归档 {0} 条新纪要：{1}' -f $newCount, $shown
        }
        else {
            $shown = ($updItems | ForEach-Object { [string]$_.title } | Select-Object -First 3) -join '、'
            $tip = '{0} 条纪要已更新：{1}' -f $updCount, $shown
        }
        if ($tip.Length -gt 250) { $tip = $tip.Substring(0, 247) + '...' }
        Show-BalloonTip -Title '微信输入法 · 新纪要已归档' -Text $tip
    }
    catch {
        Add-Log 'WARN' ('弹通知失败（已降级，不影响归档）：{0}' -f $_.Exception.Message)
    }
}

# ------------------------------------------------------------------ 监视器
function Initialize-Watchers {
    $notifyFlags = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::LastWrite `
        -bor [IO.NotifyFilters]::Size -bor [IO.NotifyFilters]::CreationTime

    $specs = @(
        @{ Name = 'index'; Filter = 'index.json.enc'; Recursive = $false },
        @{ Name = 'blobs'; Filter = '*.enc'; Recursive = $true }
    )

    foreach ($spec in $specs) {
        $w = New-Object IO.FileSystemWatcher($script:Source, $spec.Filter)
        $w.NotifyFilter = $notifyFlags
        $w.IncludeSubdirectories = [bool]$spec.Recursive
        $w.InternalBufferSize = 65536
        foreach ($evtName in @('Changed', 'Created', 'Renamed', 'Error')) {
            $sid = '{0}.{1}.{2}' -f $script:WatcherPrefix, $spec.Name, $evtName
            Register-ObjectEvent -InputObject $w -EventName $evtName -SourceIdentifier $sid -ErrorAction Stop | Out-Null
            $script:SubIds.Add($sid)
        }
        $w.EnableRaisingEvents = $true
        $script:Watchers += $w
    }
}

function Receive-WatchEvents {
    <# 排空事件队列，返回事件条数与最新的文件名。 #>
    $names = New-Object System.Collections.Generic.List[string]
    $count = 0
    while ($true) {
        $evts = @(Get-Event -ErrorAction SilentlyContinue)
        if ($evts.Count -eq 0) { break }
        foreach ($e in $evts) {
            $count++
            try {
                $sea = $e.SourceEventArgs
                if ($sea -and $sea.PSObject.Properties['FullPath'] -and $sea.FullPath) {
                    $leaf = Split-Path -Leaf $sea.FullPath
                    if (-not $names.Contains($leaf)) { $names.Add($leaf) }
                }
            }
            catch { }
            Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
        }
    }
    return [pscustomobject]@{ Count = $count; Names = @($names) }
}

function Wait-QuietWindow {
    <# 静默 $QuietSeconds 秒；期间再来事件就重置计时。全程阻塞等待，不轮询、不耗 CPU。 #>
    $deadline = [datetime]::UtcNow.AddSeconds($QuietSeconds)
    while ($true) {
        $remain = ($deadline - [datetime]::UtcNow).TotalSeconds
        if ($remain -le 0) { return }
        $secs = [int][Math]::Ceiling($remain)
        if ($secs -lt 1) { $secs = 1 }
        $evt = Wait-Event -Timeout $secs
        if ($null -eq $evt) { return }              # 静默到期
        [void](Receive-WatchEvents)                 # 又来了新写入 → 重置计时
        $deadline = [datetime]::UtcNow.AddSeconds($QuietSeconds)
    }
}

function Wait-SourceReady {
    param([int]$TimeoutSeconds = 300)
    if (Test-Path -LiteralPath $script:Source -PathType Container) { return $true }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Add-Log 'WARN' ('数据目录暂时不存在，10 秒后重试：{0}' -f $script:Source)
        Start-Sleep -Seconds 10
        if (Test-Path -LiteralPath $script:Source -PathType Container) { return $true }
    }
    return $false
}

function Remove-Watchers {
    try {
        foreach ($sid in $script:SubIds) { Unregister-Event -SourceIdentifier $sid -ErrorAction SilentlyContinue }
        foreach ($w in $script:Watchers) {
            try { $w.EnableRaisingEvents = $false; $w.Dispose() } catch { }
        }
        Get-Event -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    }
    catch { }
}

# ---------------------------------------------------------------------- main
$script:Watchers = @()
$script:ExportMutex = New-Object System.Threading.Mutex($false, 'Local\WeTypeVoiceNotes.Export')
$script:WatcherMutex = New-Object System.Threading.Mutex($false, 'Local\WeTypeVoiceNotes.Watcher')
$owner = $false
$exitCode = 0

try {
    if (-not (Test-Path -LiteralPath $script:Out)) {
        New-Item -ItemType Directory -Force -Path $script:Out | Out-Null
    }
    $script:PyCmd = @(Resolve-PythonCommand)
    if (-not (Test-Path -LiteralPath $script:PyScript)) {
        throw "找不到导出脚本：$script:PyScript"
    }

    if ($Once) {
        Invoke-SyncCycle -Reason 'backup'
    }
    else {
        try { $owner = $script:WatcherMutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $owner = $true }
        if (-not $owner) {
            Write-Host '[WeTypeHook] 已有 watcher 在运行（单实例互斥），本次退出。'
            $exitCode = 0
        }
        else {
            if (-not (Wait-SourceReady)) { throw "数据目录不存在：$script:Source" }

            Initialize-Watchers
            Add-Log 'START' ('watcher 启动 pid={0} src={1} out={2} quiet={3}s notify={4}' -f `
                    $PID, $script:Source, $script:Out, $QuietSeconds, $script:Notify)

            if (-not $NoStartupSync) { Invoke-SyncCycle -Reason 'startup' }

            while ($true) {
                $null = Wait-Event                 # 阻塞到有文件事件为止（CPU 0）
                $batch = Receive-WatchEvents
                $reason = 'event'
                if ($batch.Names.Count -gt 0) {
                    $reason = 'event:' + (($batch.Names | Select-Object -First 3) -join ',')
                }
                Wait-QuietWindow
                try { Invoke-SyncCycle -Reason $reason }
                catch { Add-Log 'ERROR' ('同步周期异常（已继续监视）：{0}' -f $_.Exception.Message) }
            }
        }
    }
}
catch [System.Management.Automation.PipelineStoppedException] {
    # Ctrl+C：正常退出
}
catch {
    Add-Log 'ERROR' ('watcher 异常退出：{0}' -f $_.Exception.Message)
    Add-Log 'ERROR' ('  位置：{0}' -f $_.ScriptStackTrace)
    $exitCode = 1
}
finally {
    Remove-Watchers
    if ($owner) {
        try { $script:WatcherMutex.ReleaseMutex() } catch { }
    }
    # 备份任务每 30 分钟一次，成功且无变化时不写日志，避免把日志刷成心跳。
    if ($owner -or ($Once -and ($LogAllRuns -or $exitCode -ne 0))) {
        try { Add-Log 'STOP' ('watcher 退出 pid={0} code={1}' -f $PID, $exitCode) } catch { }
    }
    try { $script:ExportMutex.Dispose() } catch { }
    try { $script:WatcherMutex.Dispose() } catch { }
}

exit $exitCode
