---
name: wetype-voice-notes
description: 解密并增量导出微信输入法（WeType）AI 录音笔的本地加密记录——每条录音的逐字稿与 AI 纪要——成可直接阅读的 txt / html / docx。用户说「拉取新的 AI 笔记」「录音笔笔记」「微信输入法录音笔有新内容吗」「同步 WeType 语音记录」或要求拉取语音记录时使用。只做拉取导出，不做二次加工、总结、改写或翻译。
---

<p align="right"><strong>简体中文</strong> · <a href="SKILL.md">English</a></p>

# 拉取微信输入法 AI 录音笔笔记

微信输入法把每次 AI 录音笔会话都存在本地加密目录里。本技能负责解密，并把每条会话
导出成一个可阅读的文件夹。

**范围：只拉取和导出。** 不要总结、润色、翻译、合并或"整理"逐字稿。用户若需要分析，
在导出之后另起任务做，导出的文件保持原样。

**本机默认已经在自动归档。** 常驻钩子只读监视数据目录，客户端写完后约 20 秒自动增量导出，
见 §6；手动再跑一次是安全的、幂等的。

## 1. 前置检查

1. 数据目录存在：`C:\Users\SHiNe\AppData\Local\Tencent\WeType\VoiceSummary`
   里面应有 `index.json.enc`、`key.dpapi`，以及每条会话一个 `vs-<32 位 hex>` 目录。
   目录不存在 = 没录过音，或者换机器了，直接说明并停止。
2. **必须是录制这些笔记的同一个 Windows 用户**（`pc-20240916lmsv\shine`）。
   密钥用 DPAPI 的 CurrentUser 作用域封装，换账户只会硬失败，不会给部分结果。
3. 记下客户端版本（`C:\Program Files\Tencent\WeType` 下的 `WetypeCore_x.y.z`）。
   下面这套格式在 **3.0.0.38 / WetypeCore 3.0.0.38** 上验证过，客户端升级可能改变它，见 §7。

## 2. 怎么跑

```powershell
py -3 C:\Users\SHiNe\.dsh\skills\wetype-voice-notes\scripts\wetype_notes.py
```

这就是正常路径：增量、安静、可反复跑，只写有变化的东西。

| 参数 | 含义 |
|---|---|
| `--out <目录>` | 导出根目录，默认 `C:\Users\SHiNe\Desktop\微信输入法录音笔导出` |
| `--list` | 只列记录清单（时间、时长、字数、是否已导出），不写任何文件 |
| `--force` | 忽略比较、全部重写。会改 mtime，别拿它当"刷新"用 |
| `--json` | stdout 输出 JSON 摘要（计数、字数、新增项、孤儿目录） |
| `--open` | 完成后在资源管理器打开导出目录 |
| `--src <目录>` | 进阶：指向复制出来的数据目录（测试/迁移用） |
| `--selftest` | 自检 AES + DPAPI + 索引解密，不碰导出目录 |

退出码：`0` 正常，`2` 数据目录/密钥/索引缺失，`3` 解密失败（DPAPI、魔数不对、索引损坏）。

## 3. 输出结构

```
<out>\
  index.md                       全量记录清单（每次重新生成，可直接看）
  NOTES.md                       方法说明；只维护末尾「最近一次同步」区块
  .wetype-export-state.json      每条记录的 transcript / recap / meta sha256
  .wetype-watcher.log            钩子日志（装了钩子才有；每次归档/报错一行）
  最近一次同步.txt                钩子最近一次归档的快照（有新增/更新才写）
  <序号>_<YYYY-MM-DD>_<标题>\
      transcript.txt             逐字稿，UTF-8，原文
      recap.html                 原始 AI 纪要，浏览器直接打开
      recap.docx                 Word 版（需要 python-docx；缺失时静默跳过）
      meta.json                  记录 ID、标题、时间、时长、字数
```

目录序号按 `created_at` 升序。已存在的 `summary_id` 会通过 `meta.json` 匹配并复用原目录，
所以新录音只会追加 `NN+1`，不会把整套目录重编号。

## 4. 怎么读运行摘要

```
新增 N 条 / 更新 M 条 / 跳过 K 条 / 空壳 J 条（索引共 T 条）
总字数 ...（本次新增 ...）· 耗时 ...
```

- **新增 N** —— 这次新写出的记录，把标题列给用户。
- **更新 M** —— 已导出的记录，正文/纪要在源端变了。
- **跳过 K** —— 内容没变，文件一个字节都没动。
- **空壳 J** —— App 同步过来就是空的（两个 `.enc` 各 36 字节，只有头没有正文），
  没有逐字稿也没有纪要，不会建目录。用户若点名问某一条，如实说"这条是空的"。
- `0 新增 / 0 更新` 就是没有新内容，直接说没有，不要凑内容。
- 出现 `注意：N 个目录在磁盘上但不在索引里`，说明存储里有索引没登记的 `vs-*` 目录
  （同步中断或在 App 里删过）。报给用户，不要手动改索引。

## 5. 健康检查

```powershell
py -3 ...\wetype_notes.py --selftest   # AES 已知答案 + DPAPI + 索引解析
py -3 ...\wetype_notes.py --list       # 4 行左右的清单，不写文件
```

`--selftest` 会打印 AES 已知答案结果、密钥长度（永远不打印密钥本身）和记录条数。
导出结果看着不对时先跑它，别急着怀疑文件。

## 6. 自动归档（钩子）

本机默认不需要任何人开口：常驻钩子只读监视 `VoiceSummary`，客户端写完后自动跑同一条增量
导出。它是一对当前用户级计划任务，**不依赖 DSH 会话**——关掉所有聊天窗口也照跑。

```
<out>\.wetype-watcher.log        每次归档 / 报错一行
<out>\最近一次同步.txt            最近一次同步的可读快照
```

| 命令 | 作用 |
|---|---|
| `pwsh -File C:\Users\SHiNe\.dsh\skills\wetype-voice-notes\scripts\install-hook.ps1` | 注册 `WeTypeVoiceNotesHook`（登录后延迟 30 秒、隐藏窗口、失败自动重启）和 `WeTypeVoiceNotesHookBackup`（每 30 分钟后备触发）。加 `-Start` 装完立刻启动 |
| `pwsh -File ...\status-hook.ps1` | 任务状态、上次运行结果、watcher 进程是否在跑、最近 5 条日志 |
| `pwsh -File ...\uninstall-hook.ps1` | 删掉两个任务、停掉进程；导出文件一个都不动 |

行为：

- **去抖**：客户端是分片写盘的，钩子等最后一次写盘后静默 `-QuietSeconds`（默认 20）秒才动作。
  一条录音不管分几片，只导出一次。
- 只有新增/更新才写日志、弹 Windows 通知、刷新「最近一次同步.txt」；
  `0 新增 / 0 更新` 的运行不打扰（手动加 `-LogAllRuns` 才会记录）。
- 失败隔离：导出报错 15 秒后重试一次，仍失败就记日志并继续监视；关机或钩子没跑期间漏掉的
  事件由 30 分钟的后备任务补上。
- 单实例互斥（同一时刻只有一个 watcher）；Ctrl+C 优雅退出并释放互斥量。
- 测试开关：`-Source` / `-Out` / `-QuietSeconds` / `-NoNotify` / `-LogAllRuns` / `-Once`。
  测试时 `-Source` 必须指向**副本目录**，绝不要对着真实数据目录造数据。

排查：

| 现象 | 原因 | 处理 |
|---|---|---|
| `注册计划任务失败`（拒绝访问） | 组策略禁止普通用户创建计划任务 | 用管理员权限的 pwsh 跑一次安装；或让管理员放开当前用户的计划任务权限 |
| status 显示已注册但没进程 | PowerShell 7 升级/卸载导致 `pwsh` 路径变了，或 `wscript.exe` 被拦 | 重跑 `install-hook.ps1`（会用当前 `$PSHOME\pwsh.exe` 重新生成启动器），再看日志 |
| 登录后一直没动静 | 任务只在**本用户**登录时运行（交互式） | `Start-ScheduledTask -TaskName WeTypeVoiceNotesHook`，或跑 `status-hook.ps1` |
| `导出失败（…）` / 文件占用 | 客户端正写到一半 | 钩子 15 秒后自动重试；持续报错就等录音结束。别用 `--force` 去"修" |
| 日志出现 `watcher 异常退出` | 未预期异常（下一行带堆栈） | 后备任务仍会补归档；把这两行日志报出来 |

## 7. 常见故障

| 现象 | 原因 | 处理 |
|---|---|---|
| `CryptUnprotectData 失败（Win32 错误 5/13）` | 换了 Windows 账户，或该用户主密钥变了 | 用 `whoami` 确认身份；换账户无法导出，不要试图绕过 DPAPI |
| `key.dpapi 魔数不是 WTVSKEY1` / `... 不是 WTVSAES1` | 客户端升级改了容器格式 | 停止，先重新逆向新格式再导出；把看到的版本号报给用户 |
| `index.json 解密后不是合法 JSON` | 索引被截断/存储损坏 | 让用户打开一次微信输入法（会重写索引），再重试；不要手搓索引 |
| 两个 `.enc` 正好 36 字节 | 空会话 | 正常，计入空壳，没有可导出内容 |
| `未安装 python-docx` | 可选依赖缺失 | 跳过 `.docx`，`transcript.txt` / `recap.html` 不受影响 |
| `数据目录不存在`（退出码 2） | 换机器或没录过音 | 确认路径和用户后停止 |

## 8. 绝对不要

- **改动、移动或删除 `VoiceSummary` 下任何东西。** 一律只读打开；不"修复"、不重加密、不改索引。
- **把 AES 密钥打印、写进日志或复制出去**（它在运行时从 `key.dpapi` 解出）。不要写进报告、
  笔记或命令行。
- 手改 `index.md`、`meta.json`、`.wetype-export-state.json`——它们是工具维护的。
  `NOTES.md` 可以手写，只有 `<!-- WETYPE-SYNC:BEGIN -->` 区块会被覆盖。
- 未经用户明确指示，不要把解出来的逐字稿传到本机之外；那是私人会议录音。
- 用 `--force` 去"修"一次全跳过的运行：没有变化时跳过才是正确结果。
