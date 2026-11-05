---
name: wetype-voice-notes
description: Decrypt and incrementally export the WeType (微信输入法) AI voice-recorder notes — per-record transcripts and AI recaps — from the local VoiceSummary store into readable files (txt / html / docx). Use when the user says 拉取新的AI笔记, 录音笔笔记, 微信输入法录音笔有新内容吗, 同步 WeType 语音记录, or otherwise asks to pull new voice notes. Pull-and-export only; it does not summarise, rewrite, or translate the notes.
---

<p align="right"><a href="SKILL.zh_CN.md">简体中文</a> · <strong>English</strong></p>

# Pull WeType AI voice notes

WeType (微信输入法) keeps every AI-recorder session in a local, encrypted store.
This skill decrypts that store and exports each session as a readable folder.

**Scope: pull and export only.** Do not summarise, polish, translate, merge, or
"clean up" the transcripts. If the user wants analysis, do it as a separate task
after the export, and keep the exported files verbatim.

**On this machine the export already runs by itself.** A resident hook watches
the store and archives new notes ~20 s after the client finishes writing — see
§6. Running the command below by hand is still safe and idempotent.

## 1. Pre-check

1. The data directory exists:
   `C:\Users\SHiNe\AppData\Local\Tencent\WeType\VoiceSummary`
   It must contain `index.json.enc`, `key.dpapi`, and one `vs-<32 hex>` folder per
   session. If it is missing, the client was never used for a recording, or the
   user is on another machine — say so and stop.
2. **You must be the same Windows user that recorded the notes**
   (`pc-20240916lmsv\shine`). The key file is sealed with DPAPI in CurrentUser
   scope; another account gets a hard failure, not a partial result.
3. Note the client version (`WetypeCore_x.y.z` under `C:\Program Files\Tencent\WeType`).
   The format below is verified on **3.0.0.38 / WetypeCore 3.0.0.38**. A client
   upgrade can change it — see §7.

## 2. Run

```powershell
py -3 C:\Users\SHiNe\.dsh\skills\wetype-voice-notes\scripts\wetype_notes.py
```

That is the normal path: incremental, quiet, and safe to repeat. It writes only
what changed.

| Flag | Meaning |
|---|---|
| `--out <dir>` | Export root. Default `C:\Users\SHiNe\Desktop\微信输入法录音笔导出` |
| `--list` | Print the record list (time, duration, chars, exported?) and exit. No writes. |
| `--force` | Rewrite every record even if nothing changed. Changes mtimes — do not use it as a "refresh". |
| `--json` | Machine-readable summary on stdout (counts, char totals, new items, orphans). |
| `--open` | Open the export folder in Explorer when done. |
| `--src <dir>` | Advanced: point at a copied data directory (testing / moved install). |
| `--selftest` | Verify AES + DPAPI + index decrypt without touching the export folder. |

Exit codes: `0` ok, `2` data directory / key / index missing, `3` decryption
failed (DPAPI, bad magic, corrupt index).

## 3. Output layout

```
<out>\
  index.md                       full record list (regenerated, safe to open)
  NOTES.md                       method notes; only the "最近一次同步" block is maintained
  .wetype-export-state.json      per-record sha256 of transcript / recap / meta
  .wetype-watcher.log            hook log (only when the hook is installed)
  最近一次同步.txt                snapshot of the last archived change (hook)
  <NN>_<YYYY-MM-DD>_<title>\
      transcript.txt             verbatim transcript, UTF-8
      recap.html                 original AI recap, opens in a browser
      recap.docx                 Word version (needs python-docx; skipped silently if absent)
      meta.json                  id, title, timestamps, duration, char count
```

Folder numbers follow `created_at` ascending. The tool reuses an existing folder
for a known `summary_id` (matched via `meta.json`), so a new recording appends
`NN+1` instead of renumbering the whole set.

## 4. Reading the run summary

```
新增 N 条 / 更新 M 条 / 跳过 K 条 / 空壳 J 条（索引共 T 条）
总字数 ...（本次新增 ...）· 耗时 ...
```

- **新增 (N)** — new sessions written this run. List them to the user with titles.
- **更新 (M)** — an existing session whose transcript or recap changed in place.
- **跳过 (K)** — unchanged; those files were not touched.
- **空壳 (J)** — sessions the phone/app synced as empty (both `.enc` files are
  36 bytes: header only, no plaintext). They have no transcript and no recap;
  no folder is created. Report them as "空" if the user asks about one by name.
- `0 新增 / 0 更新` means nothing new. Say that plainly instead of padding.
- A `注意：N 个目录在磁盘上但不在索引里` line means the store has `vs-*` folders
  the index does not list (interrupted sync / deleted from the app). Report it;
  do not hand-edit the index.

## 5. Verifying health

```powershell
py -3 ...\wetype_notes.py --selftest   # AES KAT + DPAPI + index parse
py -3 ...\wetype_notes.py --list       # 4-ish lines, no writes
```

`--selftest` prints the AES known-answer result, the key length (never the key),
and the record count. Use it before blaming the export when something looks off.

## 6. Auto-archive hook (default behaviour)

On this machine new notes do not need a prompt: a resident hook watches
`VoiceSummary` (read-only) and runs the same incremental export when the client
finishes writing. It is a pair of per-user scheduled tasks, not a DSH session —
it survives closing every chat.

```
<out>\.wetype-watcher.log       one line per archived change / error
<out>\最近一次同步.txt            human-readable snapshot of the last sync
```

| Command | What it does |
|---|---|
| `pwsh -File C:\Users\SHiNe\.dsh\skills\wetype-voice-notes\scripts\install-hook.ps1` | Register `WeTypeVoiceNotesHook` (logon, +30 s delay, hidden window, auto-restart) and `WeTypeVoiceNotesHookBackup` (every 30 min safety net). Add `-Start` to launch it immediately. |
| `pwsh -File ...\scripts\status-hook.ps1` | Task state, last run result, whether the watcher process is alive, last 5 log lines. |
| `pwsh -File ...\scripts\uninstall-hook.ps1` | Remove both tasks, stop the watcher, keep every exported file. |

How it behaves:

- **Debounce.** The client writes in fragments, so the hook waits for
  `-QuietSeconds` (default 20) of silence after the last write. One recording
  produces exactly one export, however many fragments arrive.
- Only new/updated records produce a log line, a Windows balloon notification
  and a refresh of `最近一次同步.txt`. A run with `0 新增 / 0 更新` stays silent.
- Failure isolation: an export error is retried once after 15 s, then logged;
  the watcher keeps running. The 30-minute backup task is the safety net for
  events lost while the machine was asleep or the watcher was down.
- Single instance (mutex). Ctrl+C exits cleanly and releases the mutex.
- Test switches: `-Source` / `-Out` / `-QuietSeconds` / `-NoNotify` /
  `-LogAllRuns` / `-Once`. Always point `-Source` at a **copy** when testing.

Troubleshooting:

| Symptom | Cause | Action |
|---|---|---|
| `注册计划任务失败` (Access is denied) | Group Policy forbids per-user task creation | Run the installer once from an elevated pwsh; or ask the admin to allow Task Scheduler for this user. |
| status says installed but no process | `pwsh` moved (PowerShell 7 upgraded/uninstalled), or `wscript.exe` blocked | Re-run `install-hook.ps1` — it regenerates the launcher from the current `$PSHOME\pwsh.exe` — then check the log. |
| Nothing at logon | The task runs only while *this* user is logged on (Interactive) | `Start-ScheduledTask -TaskName WeTypeVoiceNotesHook`, or check `status-hook.ps1`. |
| `导出失败（…）` / sharing violation | The client still holds a `.enc` file mid-write | The hook retries once after 15 s; if it persists, let the recording finish. Never "fix" it with `--force`. |
| `watcher 异常退出` in the log | Unexpected error (the line after it carries the stack trace) | The backup task keeps archiving every 30 min; report the two log lines. |

## 7. Troubleshooting

| Symptom | Cause | Action |
|---|---|---|
| `CryptUnprotectData 失败（Win32 错误 5/13）` | Different Windows account, or the profile's master key changed | Confirm `whoami`; the export cannot be done from another account. Do not try to bypass DPAPI. |
| `key.dpapi 魔数不是 WTVSKEY1` / `... 不是 WTVSAES1` | WeType upgraded and changed the container | Stop. Re-reverse the new format before exporting; report the version you saw. |
| `index.json 解密后不是合法 JSON` | Index file truncated / store damaged | Ask the user to open WeType once (it rewrites the index); retry. Do not rebuild the index by hand. |
| Two `.enc` of exactly 36 bytes | Empty session | Normal; counted as 空壳, nothing to export. |
| `未安装 python-docx` | Optional dependency missing | `.docx` skipped; `transcript.txt` / `recap.html` are unaffected. |
| `数据目录不存在` (exit 2) | Wrong machine or never used | Confirm the path and the user; stop. |

## 8. Red lines

- **Never modify, move, or delete anything under `VoiceSummary`.** Open files
  read-only. No "repair", no re-encrypt, no index patching.
- **Never print, log, or copy the AES key** (it is recovered from `key.dpapi` at
  runtime). Do not put it in a report, a note, or a command line.
- Do not hand-edit `index.md`, `meta.json`, or `.wetype-export-state.json`; they
  are tool-managed. `NOTES.md` may be edited by hand — only the
  `<!-- WETYPE-SYNC:BEGIN -->` block is overwritten.
- Do not ship the decrypted transcripts outside this machine without the user's
  explicit instruction; they are personal meeting recordings.
- Do not "fix" a skipped run by running `--force`: skipping is the correct
  outcome when nothing changed.

Human-facing docs: [README.md](README.md) (Chinese onboarding, workflow, two export paths).
