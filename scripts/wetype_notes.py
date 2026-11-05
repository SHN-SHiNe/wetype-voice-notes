#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""WeType (微信输入法) AI 录音笔笔记导出工具.

纯标准库实现：
  * DPAPI 解封 —— ctypes 调用 crypt32!CryptUnprotectData
  * AES-256-CTR —— 自带 AES 实现（不依赖 cryptography / pycryptodome）
  * recap.html -> recap.docx —— 仅在 python-docx 可用时启用

数据目录（只读）：%LOCALAPPDATA%\\Tencent\\WeType\\VoiceSummary
  index.json.enc   记录索引 JSON
  key.dpapi        270 B，"WTVSKEY1" + 原始 CryptProtectData blob
  vs-<32hex>/      transcript.txt.enc / recap.html.enc

格式：
  key.dpapi      = b"WTVSKEY1" + blob[8:]  → CryptUnprotectData（CurrentUser、无 entropy）
  *.enc          = b"WTVSAES1"(8) + nonce(12) + 16 B 未用字段 + ciphertext
  计数器块       = nonce(12) || BE32(块号)，块号从 2 开始
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import re
import struct
import sys
import time
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser

APP_VERSION = "1.0"
DEFAULT_SRC = r"C:\Users\SHiNe\AppData\Local\Tencent\WeType\VoiceSummary"
DEFAULT_OUT = r"C:\Users\SHiNe\Desktop\微信输入法录音笔导出"
STATE_NAME = ".wetype-export-state.json"
TZ = timezone(timedelta(hours=8))

MAGIC_ENC = b"WTVSAES1"
MAGIC_KEY = b"WTVSKEY1"
HEADER_LEN = 36          # magic 8 + nonce 12 + 16
COUNTER_START = 2

SYNC_BEGIN = "<!-- WETYPE-SYNC:BEGIN -->"
SYNC_END = "<!-- WETYPE-SYNC:END -->"


class DataDirError(Exception):
    """数据目录/密钥文件缺失，退出码 2。"""


class DecryptError(Exception):
    """DPAPI 或文件解密失败，退出码 3。"""


# --------------------------------------------------------------------------- AES
def _xtime(a: int) -> int:
    a <<= 1
    return (a ^ 0x11B) & 0xFF if a & 0x100 else a


def _rotl8(x: int, n: int) -> int:
    return ((x << n) | (x >> (8 - n))) & 0xFF


def _gen_sbox() -> list:
    sbox = [0] * 256
    p = q = 1
    while True:
        p = (p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)) & 0xFF
        q ^= (q << 1) & 0xFF
        q ^= (q << 2) & 0xFF
        q ^= (q << 4) & 0xFF
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ _rotl8(q, 1) ^ _rotl8(q, 2) ^ _rotl8(q, 3) ^ _rotl8(q, 4)
        sbox[p] = x ^ 0x63
        if p == 1:
            break
    sbox[0] = 0x63
    return sbox


SBOX = _gen_sbox()
_RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36, 0x6C]


class AES256:
    """AES-256 分组加密（只做加密方向，够 CTR 用）。"""

    __slots__ = ("rk",)

    def __init__(self, key: bytes):
        if len(key) != 32:
            raise ValueError("AES-256 needs a 32-byte key")
        self.rk = self._expand(key)

    @staticmethod
    def _expand(key: bytes) -> list:
        nk, nr = 8, 14
        w = [list(key[4 * i:4 * i + 4]) for i in range(nk)]
        rcon = 1
        for i in range(nk, 4 * (nr + 1)):
            temp = list(w[i - 1])
            if i % nk == 0:
                temp = temp[1:] + temp[:1]
                temp = [SBOX[b] for b in temp]
                temp[0] ^= rcon
                rcon = _xtime(rcon)
            elif nk > 6 and i % nk == 4:
                temp = [SBOX[b] for b in temp]
            w.append([w[i - nk][j] ^ temp[j] for j in range(4)])
        return [sum(w[4 * r:4 * r + 4], []) for r in range(nr + 1)]

    def encrypt_block(self, block: bytes) -> bytes:
        s = list(block)
        rk = self.rk
        s = [a ^ b for a, b in zip(s, rk[0])]
        for r in range(1, 14):
            s = [SBOX[b] for b in s]
            # ShiftRows（state[r + 4c]）
            s = [
                s[0], s[5], s[10], s[15],
                s[4], s[9], s[14], s[3],
                s[8], s[13], s[2], s[7],
                s[12], s[1], s[6], s[11],
            ]
            # MixColumns
            m = [0] * 16
            for c in range(0, 16, 4):
                a0, a1, a2, a3 = s[c], s[c + 1], s[c + 2], s[c + 3]
                m[c] = _xtime(a0) ^ (_xtime(a1) ^ a1) ^ a2 ^ a3
                m[c + 1] = a0 ^ _xtime(a1) ^ (_xtime(a2) ^ a2) ^ a3
                m[c + 2] = a0 ^ a1 ^ _xtime(a2) ^ (_xtime(a3) ^ a3)
                m[c + 3] = (_xtime(a0) ^ a0) ^ a1 ^ a2 ^ _xtime(a3)
            s = [a ^ b for a, b in zip(m, rk[r])]
        s = [SBOX[b] for b in s]
        s = [
            s[0], s[5], s[10], s[15],
            s[4], s[9], s[14], s[3],
            s[8], s[13], s[2], s[7],
            s[12], s[1], s[6], s[11],
        ]
        return bytes(a ^ b for a, b in zip(s, rk[14]))


def aes_ctr(key: bytes, nonce: bytes, data: bytes) -> bytes:
    """AES-256-CTR；计数器块 = nonce(12) || BE32(块号)，块号从 2 开始。"""
    if not data:
        return b""
    if len(nonce) != 12:
        raise DecryptError("nonce 长度异常：%d" % len(nonce))
    aes = AES256(key)
    out = bytearray(len(data))
    for i in range((len(data) + 15) // 16):
        ctr = nonce + struct.pack(">I", (COUNTER_START + i) & 0xFFFFFFFF)
        ks = aes.encrypt_block(ctr)
        chunk = data[i * 16:(i + 1) * 16]
        base = i * 16
        for j, b in enumerate(chunk):
            out[base + j] = b ^ ks[j]
    return bytes(out)


# ------------------------------------------------------------------------- DPAPI
class _DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", ctypes.c_uint32),
                ("pbData", ctypes.POINTER(ctypes.c_ubyte))]


def _crypt32():
    dll = ctypes.WinDLL("crypt32", use_last_error=True)
    dll.CryptUnprotectData.restype = ctypes.c_bool
    dll.CryptUnprotectData.argtypes = [
        ctypes.POINTER(_DATA_BLOB), ctypes.POINTER(ctypes.c_wchar_p),
        ctypes.POINTER(_DATA_BLOB), ctypes.c_void_p, ctypes.c_void_p,
        ctypes.c_uint32, ctypes.POINTER(_DATA_BLOB),
    ]
    return dll


def dpapi_unprotect(data: bytes) -> bytes:
    if not data:
        raise DecryptError("DPAPI 输入为空")
    buf = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
    blob_in = _DATA_BLOB(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_ubyte)))
    blob_out = _DATA_BLOB()
    ok = _crypt32().CryptUnprotectData(
        ctypes.byref(blob_in), None, None, None, None, 0, ctypes.byref(blob_out))
    if not ok:
        err = ctypes.get_last_error()
        raise DecryptError(
            "CryptUnprotectData 失败（Win32 错误 %d）。"
            "该密钥绑定当前 Windows 用户（pc-20240916lmsv\\shine），"
            "换账户/换机器后无法解封。" % err)
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        ctypes.WinDLL("kernel32").LocalFree(blob_out.pbData)


# -------------------------------------------------------------------- decrypt
def load_key(src: str) -> bytes:
    path = os.path.join(src, "key.dpapi")
    if not os.path.isfile(path):
        raise DataDirError("缺少 key.dpapi：%s" % path)
    with open(path, "rb") as f:
        raw = f.read()
    if not raw.startswith(MAGIC_KEY):
        raise DecryptError(
            "key.dpapi 魔数不是 WTVSKEY1（实际 %r）。客户端可能升级并更换了密钥封装格式。"
            % raw[:8])
    key = dpapi_unprotect(raw[8:])
    if len(key) != 32:
        raise DecryptError("解出的密钥长度异常：%d 字节（期望 32）" % len(key))
    return key


def decrypt_blob(raw: bytes, key: bytes, what: str = "") -> bytes:
    if len(raw) < HEADER_LEN:
        raise DecryptError("%s 长度不足（%d B，至少 36 B）" % (what or "文件", len(raw)))
    if not raw.startswith(MAGIC_ENC):
        raise DecryptError(
            "%s 魔数不是 WTVSAES1（实际 %r）。客户端升级后格式可能变了，需要重新逆向。"
            % (what or "文件", raw[:8]))
    return aes_ctr(key, raw[8:20], raw[HEADER_LEN:])


def decrypt_file(path: str, key: bytes) -> bytes:
    with open(path, "rb") as f:
        return decrypt_blob(f.read(), key, os.path.basename(path))


def load_index(src: str, key: bytes) -> dict:
    path = os.path.join(src, "index.json.enc")
    if not os.path.isfile(path):
        raise DataDirError("缺少 index.json.enc：%s" % path)
    try:
        return json.loads(decrypt_file(path, key).decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise DecryptError("index.json 解密后不是合法 JSON：%s" % exc)


# ------------------------------------------------------------------ utilities
def clean_text(s: str) -> str:
    s = s.replace("\u200b", "").replace("\ufeff", "").replace("\u00a0", " ")
    return re.sub(r"[ \t]+", " ", s).strip()


def safe_name(s: str, limit: int = 60) -> str:
    s = clean_text(s)
    s = re.sub(r'[\\/:*?"<>|\r\n\t]', "_", s)
    s = s.replace("\uff1a", "-").replace("\uff0f", "-")
    return s[:limit].strip(" ._") or "untitled"


def fmt_duration(sec) -> str:
    try:
        sec = int(sec)
    except (TypeError, ValueError):
        return "-"
    if sec <= 0:
        return "-"
    return "%d 分 %d 秒" % (sec // 60, sec % 60)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_if_changed(path: str, data: bytes) -> bool:
    """内容相同则不落盘（保持 mtime），返回是否写入。"""
    data = data if isinstance(data, bytes) else data.encode("utf-8")
    try:
        with open(path, "rb") as f:
            if f.read() == data:
                return False
    except OSError:
        pass
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    return True


def now_local() -> datetime:
    return datetime.now(TZ)


# --------------------------------------------------------------- html -> docx
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"}
SKIP_TAGS = {"script", "style", "svg", "button", "head", "title", "meta", "link"}
BLOCK_TAGS = {"h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "figcaption",
              "blockquote", "pre", "dt", "dd", "caption"}
CONTAINER_TAGS = {"div", "section", "header", "footer", "aside", "nav", "main",
                  "article", "figure", "ul", "ol", "dl", "table", "tbody",
                  "thead", "tr", "body", "html"}


class _Node:
    __slots__ = ("tag", "attrs", "children")

    def __init__(self, tag, attrs=None):
        self.tag = tag
        self.attrs = attrs or {}
        self.children = []


class _TreeBuilder(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = _Node("#root")
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = _Node(tag, dict(attrs))
        self.stack[-1].children.append(node)
        if tag not in VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.stack[-1].children.append(_Node(tag, dict(attrs)))

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return

    def handle_data(self, data):
        self.stack[-1].children.append(data)


def _n_text(node) -> str:
    parts = []
    if isinstance(node, str):
        return node
    for ch in node.children:
        if isinstance(ch, str):
            parts.append(ch)
        else:
            parts.append(_n_text(ch))
    return "".join(parts)


def _find_body(node):
    if isinstance(node, str):
        return None
    if node.tag == "body":
        return node
    for ch in node.children:
        found = _find_body(ch)
        if found is not None:
            return found
    return None


def _is_leaf_container(node) -> bool:
    for ch in node.children:
        if not isinstance(ch, str) and (ch.tag in BLOCK_TAGS or ch.tag in CONTAINER_TAGS):
            return False
    return True


def _style_run(run, size=None, bold=None, italic=None, mono=False):
    from docx.oxml.ns import qn
    from docx.shared import Pt
    run.font.name = "Consolas" if mono else "微软雅黑"
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = rpr.makeelement(qn("w:rFonts"), {})
        rpr.append(rfonts)
    rfonts.set(qn("w:eastAsia"), "微软雅黑")
    if size:
        run.font.size = Pt(size)
    if bold is not None:
        run.bold = bold or None
    if italic is not None:
        run.italic = italic or None


def _join_text(prev: str, text: str) -> str:
    if prev and re.search(r"[A-Za-z0-9]$", prev) and re.match(r"[A-Za-z0-9]", text):
        return " " + text
    return text


def _emit_inline(par, node, bold=False, italic=False, mono=False):
    for ch in node.children:
        if isinstance(ch, str):
            t = clean_text(ch)
            if t:
                _style_run(par.add_run(_join_text(par.text, t)),
                           bold=bold, italic=italic, mono=mono)
            continue
        if ch.tag in SKIP_TAGS:
            continue
        _emit_inline(par, ch,
                     bold or ch.tag in ("b", "strong"),
                     italic or ch.tag in ("i", "em"),
                     mono or ch.tag in ("code", "kbd", "samp"))


def _add_table(doc, node):
    rows = []
    for tr in _iter(node, "tr"):
        cells = [c for c in tr.children if not isinstance(c, str) and c.tag in ("td", "th")]
        if cells:
            rows.append((tr, cells))
    if not rows:
        return
    ncol = max(len(c) for _, c in rows)
    table = doc.add_table(rows=0, cols=ncol)
    table.style = "Table Grid"
    for tr, cells in rows:
        row = table.add_row()
        for i, cell in enumerate(cells[:ncol]):
            p = row.cells[i].paragraphs[0]
            _emit_inline(p, cell, bold=cell.tag == "th")
            for run in p.runs:
                if run.font.size is None:
                    from docx.shared import Pt
                    run.font.size = Pt(9.5)
    doc.add_paragraph()


def _iter(node, tag):
    if isinstance(node, str):
        return
    for ch in node.children:
        if isinstance(ch, str):
            continue
        if ch.tag == tag:
            yield ch
        yield from _iter(ch, tag)


def html_to_docx(html_text: str, docx_path: str, title: str, meta_line: str,
                 empty_note: bool = False) -> None:
    from docx import Document
    from docx.shared import Cm, Pt, RGBColor
    from docx.oxml.ns import qn

    doc = Document()
    st = doc.styles["Normal"]
    st.font.name = "微软雅黑"
    st.font.size = Pt(10.5)
    st.element.rPr.rFonts.set(qn("w:eastAsia"), "微软雅黑")
    for sec in doc.sections:
        sec.left_margin = sec.right_margin = Cm(2.2)

    p = doc.add_paragraph()
    _style_run(p.add_run(meta_line), size=8.5)
    p.runs[0].font.color.rgb = RGBColor(0x60, 0x6C, 0x78)

    if empty_note:
        q = doc.add_paragraph()
        _style_run(q.add_run("（本条记录在客户端内为空，没有纪要内容）"), italic=True)
        doc.core_properties.title = title
        doc.save(docx_path)
        return

    builder = _TreeBuilder()
    builder.feed(html_text)
    body = _find_body(builder.root) or builder.root

    state = {"first_h1": True}

    def heading(node, tag):
        lvl = int(tag[1])
        level = 1 if (lvl == 1 and state["first_h1"]) else min(lvl, 4)
        state["first_h1"] = False
        h = doc.add_heading(level=level)
        _emit_inline(h, node)

    def walk(node):
        for ch in node.children:
            if isinstance(ch, str):
                t = clean_text(ch)
                if t:
                    par = doc.add_paragraph()
                    _style_run(par.add_run(t))
                continue
            tag = ch.tag
            if tag in SKIP_TAGS:
                continue
            txt = clean_text(_n_text(ch))
            if tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
                if txt:
                    heading(ch, tag)
                continue
            if tag == "table":
                _add_table(doc, ch)
                continue
            if tag == "li":
                style = "List Number" if node.tag == "ol" else "List Bullet"
                try:
                    par = doc.add_paragraph(style=style)
                except KeyError:
                    par = doc.add_paragraph(style="List Bullet")
                _emit_inline(par, ch)
                continue
            if tag in ("p", "dt", "dd", "caption"):
                if txt:
                    par = doc.add_paragraph()
                    _emit_inline(par, ch)
                continue
            if tag == "figcaption":
                if txt:
                    par = doc.add_paragraph()
                    _emit_inline(par, ch)
                    for run in par.runs:
                        run.font.size = Pt(8.5)
                        run.italic = True
                        run.font.color.rgb = RGBColor(0x70, 0x7A, 0x86)
                continue
            if tag == "blockquote":
                if txt:
                    par = doc.add_paragraph()
                    _emit_inline(par, ch)
                    par.paragraph_format.left_indent = Cm(0.6)
                continue
            if tag == "pre":
                if txt:
                    par = doc.add_paragraph()
                    _style_run(par.add_run(txt), size=9, mono=True)
                continue
            if tag in CONTAINER_TAGS:
                if _is_leaf_container(ch):
                    t = clean_text(_n_text(ch))
                    if not t or re.fullmatch(r"\d{1,2}", t):
                        continue
                    par = doc.add_paragraph()
                    _emit_inline(par, ch)
                    cls = ch.attrs.get("class", "")
                    if "kicker" in cls or "tag" in cls or "num" in cls:
                        for run in par.runs:
                            run.font.size = Pt(8.5)
                else:
                    walk(ch)
                continue
            if tag in ("span", "small", "b", "strong", "i", "em", "code"):
                if txt:
                    par = doc.add_paragraph()
                    _emit_inline(par, ch)

    walk(body)
    doc.core_properties.title = title
    os.makedirs(os.path.dirname(docx_path) or ".", exist_ok=True)
    doc.save(docx_path)


def docx_available() -> bool:
    try:
        import docx  # noqa: F401
        return True
    except Exception:
        return False


# ------------------------------------------------------------------- exporting
def load_state(out: str) -> dict:
    path = os.path.join(out, STATE_NAME)
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data.get("records"), dict):
            return data
    except (OSError, ValueError):
        pass
    return {"version": 1, "records": {}}


def save_state(out: str, state: dict) -> bool:
    """记录集合没变就不落盘（避免每次运行都改 mtime）。"""
    path = os.path.join(out, STATE_NAME)
    prev = load_state(out) if os.path.isfile(path) else {"records": {}}
    if prev.get("records") == state.get("records"):
        return False
    state["version"] = 1
    state["updated_at"] = now_local().strftime("%Y-%m-%d %H:%M:%S")
    text = json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    return write_if_changed(path, text.encode("utf-8"))


def scan_existing_folders(out: str) -> dict:
    """通过各目录 meta.json 里的 summary_id 找到已有导出目录（换名/换序号也能复用）。"""
    found = {}
    try:
        entries = os.listdir(out)
    except OSError:
        return found
    for name in entries:
        d = os.path.join(out, name)
        meta = os.path.join(d, "meta.json")
        if not os.path.isdir(d) or not os.path.isfile(meta):
            continue
        try:
            with open(meta, "r", encoding="utf-8") as f:
                vsid = json.load(f).get("summary_id")
            if vsid:
                found[vsid] = name
        except (OSError, ValueError):
            continue
    return found


def normalize_records(index: dict):
    items = index.get("items") or []
    out = []
    for it in items:
        vsid = (it.get("summary_id") or "").strip()
        if not vsid:
            continue
        ts = it.get("created_at") or 0
        try:
            ts = int(ts)
        except (TypeError, ValueError):
            ts = 0
        out.append({
            "id": vsid,
            "title": clean_text(it.get("title") or it.get("server_title") or vsid),
            "created_at": ts,
            "duration": it.get("duration") or 0,
            "chars": it.get("transcript_chars") or 0,
            "raw": it,
        })
    out.sort(key=lambda r: (r["created_at"], r["id"]))
    return out


def read_enc(path: str):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return None


def export_record(rec, ordinal, folder, key, src, out, state, force, make_docx):
    """导出单条记录；以磁盘上现有文件为准做增量比较。

    返回 (status, brief)。status: new | updated | skipped | shell。
    """
    vsid = rec["id"]
    enc_dir = os.path.join(src, "vs-" + vsid.replace("vs-", "", 1))
    t_raw = read_enc(os.path.join(enc_dir, "transcript.txt.enc"))
    r_raw = read_enc(os.path.join(enc_dir, "recap.html.enc"))

    brief = {
        "id": vsid,
        "title": rec["title"],
        "folder": folder,
        "chars": 0,
    }

    if (t_raw is None or len(t_raw) <= HEADER_LEN) and (r_raw is None or len(r_raw) <= HEADER_LEN):
        return "shell", brief

    t_pt = decrypt_blob(t_raw, key, "transcript.txt.enc") if t_raw else b""
    r_pt = decrypt_blob(r_raw, key, "recap.html.enc") if r_raw else b""
    brief["chars"] = len(t_pt.decode("utf-8", "replace"))

    fdir = os.path.join(out, folder)
    existed = os.path.isdir(fdir)
    wrote = False

    # 逐字稿
    if force or read_enc(os.path.join(fdir, "transcript.txt")) != t_pt:
        os.makedirs(fdir, exist_ok=True)
        write_if_changed(os.path.join(fdir, "transcript.txt"), t_pt)
        wrote = True
    # 纪要
    recap_changed = force or read_enc(os.path.join(fdir, "recap.html")) != r_pt
    if recap_changed:
        os.makedirs(fdir, exist_ok=True)
        write_if_changed(os.path.join(fdir, "recap.html"), r_pt)
        wrote = True

    meta = {
        "summary_id": vsid,
        "title": rec["title"],
        "created_at": rec["created_at"],
        "created_at_local": _fmt_ts(rec["created_at"]),
        "duration_seconds": rec["duration"],
        "transcript_chars": rec["chars"],
        "enc_dir": "vs-" + vsid.replace("vs-", "", 1),
        "exported_by": "wetype_notes.py %s" % APP_VERSION,
        "exported_at": now_local().strftime("%Y-%m-%d %H:%M:%S"),
    }
    meta_bytes = (json.dumps(meta, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    # meta.json 只在语义字段变化时重写，避免旧版导出（字段集合不同）被无谓改动
    if force or not _meta_matches(os.path.join(fdir, "meta.json"), meta):
        os.makedirs(fdir, exist_ok=True)
        write_if_changed(os.path.join(fdir, "meta.json"), meta_bytes)
        wrote = True

    # Word 版：仅当纪要变化、缺失或被强制时才重写（避免无谓改 mtime）
    if make_docx:
        docx_path = os.path.join(fdir, "recap.docx")
        if force or recap_changed or not os.path.isfile(docx_path):
            _write_docx(docx_path, r_pt, rec, empty=False)
            wrote = True

    # 状态里记录磁盘上实际内容的哈希（meta 未被改写时哈希才不会每轮漂移）
    meta_disk = read_enc(os.path.join(fdir, "meta.json")) or meta_bytes
    state["records"][vsid] = {
        "transcript": sha256(t_pt),
        "recap": sha256(r_pt),
        "meta": sha256(meta_disk),
        "folder": folder,
        "chars": brief["chars"],
    }

    if not existed:
        return "new", brief
    return ("updated" if wrote else "skipped"), brief


def _meta_matches(path, meta):
    """比较 meta.json 的语义字段；旧版导出多/少几个字段不算变化。"""
    try:
        with open(path, "r", encoding="utf-8") as f:
            cur = json.load(f)
    except (OSError, ValueError):
        return False
    if not isinstance(cur, dict):
        return False
    for k in ("summary_id", "title", "created_at", "duration_seconds", "transcript_chars"):
        if cur.get(k) != meta.get(k):
            return False
    return True


def _write_docx(path, recap_bytes, rec, empty=False):
    if empty or not recap_bytes:
        html_to_docx("", path, rec["title"],
                     _meta_line(rec), empty_note=True)
        return True
    html = recap_bytes.decode("utf-8", "replace")
    html_to_docx(html, path, rec["title"], _meta_line(rec))
    return True


def _fmt_ts(ts):
    if not ts:
        return "unknown-time"
    try:
        return datetime.fromtimestamp(int(ts), TZ).strftime("%Y-%m-%d %H:%M")
    except (OverflowError, OSError, ValueError):
        return "unknown-time"


def _meta_line(rec):
    return "微信输入法 AI 录音笔 · %s · 时长 %s · 记录ID %s" % (
        _fmt_ts(rec["created_at"]), fmt_duration(rec["duration"]), rec["id"])


# ------------------------------------------------------------------- documents
def build_index_md(records, rows, out, src):
    lines = [
        "# 微信输入法 AI 录音笔 · 解密导出索引",
        "",
        "源目录：`%s`　　工具：`wetype_notes.py %s`（本文件由工具维护，可重跑）" % (
            src, APP_VERSION),
        "",
        "共 %d 条记录，其中 %d 条有正文、%d 条为空壳。" % (
            len(rows), sum(1 for r in rows if r["chars"]), sum(1 for r in rows if r["shell"])),
        "",
        "| # | 标题 | 时间 | 时长 | 字数 | 记录 ID | 目录 |",
        "|---|---|---|---|---|---|---|",
    ]
    for i, r in enumerate(rows, 1):
        name = r["folder"] or "—"
        link = "[%s](<%s>)" % (name, name) if r["folder"] else "—"
        lines.append("| %d | %s | %s | %s | %s | `%s` | %s |" % (
            i, r["title"], r["time"], r["dur"], r["chars"], r["id"], link))
    lines += ["", "## 每条记录", ""]
    for i, r in enumerate(rows, 1):
        lines.append("### %d. %s" % (i, r["title"]))
        if r["shell"]:
            lines.append("- 空壳记录：客户端内没有逐字稿与纪要（两个 .enc 各 36 字节），未导出正文。")
            lines.append("")
            continue
        lines.append("- 目录：`%s`" % r["folder"])
        lines.append("- 时间：%s　时长：%s　逐字稿字数：%s" % (r["time"], r["dur"], r["chars"]))
        lines.append("- 源文件：`vs-%s\\transcript.txt.enc`、`vs-%s\\recap.html.enc`" % (
            r["id"].replace("vs-", "", 1), r["id"].replace("vs-", "", 1)))
        lines.append("- 导出：`transcript.txt`、`recap.html`、`recap.docx`、`meta.json`")
        lines.append("")
    return "\n".join(lines) + "\n"


def build_notes_body():
    return """# 微信输入法（WeType）AI 录音笔导出说明

由 `wetype-notes` 技能维护。本文件的手写内容不会被覆盖；只有末尾
「最近一次同步」区块会随每次运行更新。

## 解密方式（已验证）

- `key.dpapi`：`WTVSKEY1`(8 B) + 原始 DPAPI blob。**直接取 `raw[8:]`** 调
  `CryptUnprotectData`（当前用户作用域、无 entropy），得 32 字节 AES-256 密钥。
  之前"改写前 8 字节为 cbData/dwVersion"会破坏 DPAPI 的 HMAC，必然报"数据无效"。
- `*.enc`：`WTVSAES1`(8) + nonce(12) + 16 字节未用字段 + 密文。
  算法是 **AES-256-CTR**（不是 GCM），计数器块 = `nonce || BE32(块号)`，块号从 **2** 开始。
- 空壳记录的两个 .enc 都是 36 B（8 + 12 + 16 + 0），没有正文。

## 红线

- VoiceSummary 目录只读，绝不修改或删除其中任何文件。
- 不把解出的 AES 密钥写进任何文件、日志或对话。
"""


def update_notes(out: str, summary: dict, new_items, skipped_items):
    path = os.path.join(out, "NOTES.md")
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError:
        text = build_notes_body()

    block = [SYNC_BEGIN,
             "## 最近一次同步",
             "",
             "- 时间：%s" % summary["finished_at"],
             "- 数据目录：`%s`" % summary["src"],
             "- 结果：新增 %d 条 / 跳过 %d 条 / 空壳 %d 条 / 索引共 %d 条" % (
                 summary["new"], summary["skipped"], summary["shell"], summary["total"]),
             "- 总字数：%d（本次新增 %d）" % (summary["chars_total"], summary["chars_new"]),
             "- 耗时：%.1f s" % summary["elapsed"],
             ]
    if new_items:
        block += ["", "本次新增："]
        block += ["- %s（%s 字）" % (it["folder"], it["chars"]) for it in new_items]
    if summary.get("orphans"):
        block += ["", "另有 %d 个目录在磁盘上但不在索引里：%s" % (
            len(summary["orphans"]), "、".join("`%s`" % o for o in summary["orphans"]))]
    block.append(SYNC_END)
    new_block = "\n".join(block) + "\n"

    if SYNC_BEGIN in text and SYNC_END in text:
        head, rest = text.split(SYNC_BEGIN, 1)
        _, tail = rest.split(SYNC_END, 1)
        text = head + new_block + tail.lstrip("\n")
    else:
        text = text.rstrip("\n") + "\n\n" + new_block
    write_if_changed(path, text.encode("utf-8"))


# ----------------------------------------------------------------------- CLI
def print_records(records, existing, rows_by_id):
    print("微信输入法 AI 录音笔 · 记录清单")
    print("%-4s %-18s %-12s %-7s %-8s %s" % ("#", "时间", "时长", "字数", "状态", "标题"))
    for i, r in enumerate(records, 1):
        info = rows_by_id.get(r["id"], {})
        if info.get("shell"):
            status = "空壳"
        elif r["id"] in existing:
            status = "已导出"
        else:
            status = "待导出"
        print("%-4d %-18s %-12s %-7s %-8s %s" % (
            i, _fmt_ts(r["created_at"]), fmt_duration(r["duration"]),
            r["chars"], status, r["title"]))
    print("\n共 %d 条：已导出 %d / 待导出 %d / 空壳 %d" % (
        len(records),
        sum(1 for r in records if r["id"] in existing and not rows_by_id.get(r["id"], {}).get("shell")),
        sum(1 for r in records if r["id"] not in existing and not rows_by_id.get(r["id"], {}).get("shell")),
        sum(1 for r in records if rows_by_id.get(r["id"], {}).get("shell"))))


def main(argv=None) -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    ap = argparse.ArgumentParser(
        prog="wetype_notes.py",
        description="解密并增量导出微信输入法 AI 录音笔笔记。")
    ap.add_argument("--out", default=DEFAULT_OUT, help="导出目录（默认 %s）" % DEFAULT_OUT)
    ap.add_argument("--src", default=DEFAULT_SRC, help="数据目录（默认 VoiceSummary，测试时可覆盖）")
    ap.add_argument("--list", action="store_true", help="只列记录，不导出")
    ap.add_argument("--force", action="store_true", help="忽略状态，全部重写")
    ap.add_argument("--json", action="store_true", help="输出 JSON 摘要（便于程序消费）")
    ap.add_argument("--open", action="store_true", help="完成后打开导出目录")
    ap.add_argument("--selftest", action="store_true", help="自检 AES/DPAPI/索引，不写导出目录")
    args = ap.parse_args(argv)

    t0 = time.perf_counter()

    if args.selftest:
        return run_selftest(args)

    src = os.path.abspath(args.src)
    out = os.path.abspath(args.out)

    if not os.path.isdir(src):
        print("数据目录不存在：%s" % src, file=sys.stderr)
        print("确认微信输入法已安装并至少用过一次 AI 录音笔；或用 --src 指定实际目录。",
              file=sys.stderr)
        return 2

    try:
        key = load_key(src)
        index = load_index(src, key)
    except DataDirError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    except DecryptError as exc:
        print(str(exc), file=sys.stderr)
        return 3

    records = normalize_records(index)
    os.makedirs(out, exist_ok=True)
    state = load_state(out)
    existing = scan_existing_folders(out)
    make_docx = docx_available()

    # 索引与磁盘双向对齐
    on_disk = sorted(
        d for d in os.listdir(src)
        if d.startswith("vs-") and os.path.isdir(os.path.join(src, d)))
    known = {"vs-" + r["id"].replace("vs-", "", 1) for r in records}
    orphans = [d for d in on_disk if d not in known]

    rows_by_id = {}
    if args.list:
        # 轻量探测空壳（不落盘）
        for r in records:
            enc_dir = os.path.join(src, "vs-" + r["id"].replace("vs-", "", 1))
            t = read_enc(os.path.join(enc_dir, "transcript.txt.enc"))
            rr = read_enc(os.path.join(enc_dir, "recap.html.enc"))
            shell = (t is None or len(t) <= HEADER_LEN) and (rr is None or len(rr) <= HEADER_LEN)
            rows_by_id[r["id"]] = {"shell": shell}
        print_records(records, existing, rows_by_id)
        if orphans:
            print("\n注意：%d 个目录在磁盘上但不在索引里：%s" % (len(orphans), "、".join(orphans)))
        return 0

    rows = []
    new_items, updated_items, skipped_items = [], [], []
    shells = 0
    chars_total = 0
    chars_new = 0

    try:
        for i, rec in enumerate(records, 1):
            vsid = rec["id"]
            folder = existing.get(vsid)
            if not folder:
                folder = "%02d_%s_%s" % (
                    i, datetime.fromtimestamp(rec["created_at"], TZ).strftime("%Y-%m-%d")
                    if rec["created_at"] else "0000-00-00", safe_name(rec["title"]))
            status, brief = export_record(rec, i, folder, key, src, out, state,
                                          args.force, make_docx)
            row = {
                "id": vsid, "title": rec["title"], "folder": folder,
                "time": _fmt_ts(rec["created_at"]), "dur": fmt_duration(rec["duration"]),
                "chars": brief.get("chars", rec["chars"]),
                "shell": status == "shell",
            }
            if status == "shell":
                row["folder"] = ""
            rows.append(row)
            rows_by_id[vsid] = row

            if status == "shell":
                shells += 1
                existing.pop(vsid, None)
                continue
            chars_total += row["chars"]
            if status == "new":
                chars_new += row["chars"]
                new_items.append(brief)
            elif status == "updated":
                chars_new += row["chars"]
                updated_items.append(brief)
            else:
                skipped_items.append(brief)
            existing[vsid] = folder
    except DecryptError as exc:
        print(str(exc), file=sys.stderr)
        return 3

    save_state(out, state)
    write_if_changed(os.path.join(out, "index.md"),
                     build_index_md(records, rows, out, src).encode("utf-8"))

    elapsed = time.perf_counter() - t0
    summary = {
        "ok": True,
        "src": src,
        "out": out,
        "total": len(records),
        "new": len(new_items),
        "updated": len(updated_items),
        "skipped": len(skipped_items),
        "shell": shells,
        "chars_total": chars_total,
        "chars_new": chars_new,
        "elapsed": round(elapsed, 2),
        "elapsed_text": "%.1f s" % elapsed,
        "finished_at": now_local().strftime("%Y-%m-%d %H:%M:%S"),
        "docx": "yes" if make_docx else "skipped(python-docx missing)",
        "new_items": new_items,
        "updated_items": updated_items,
        "orphans": orphans,
    }

    notes_path = os.path.join(out, "NOTES.md")
    if new_items or updated_items or not os.path.isfile(notes_path):
        update_notes(out, summary, new_items + updated_items, skipped_items)

    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    else:
        print("微信输入法录音笔 · 同步完成")
        print("  数据目录：%s" % src)
        print("  导出目录：%s" % out)
        print("  新增 %d 条 / 更新 %d 条 / 跳过 %d 条 / 空壳 %d 条（索引共 %d 条）" % (
            summary["new"], summary["updated"], summary["skipped"], shells, len(records)))
        print("  总字数 %s（本次新增 %s）· 耗时 %s" % (
            format(chars_total, ","), format(chars_new, ","), summary["elapsed_text"]))
        if not make_docx:
            print("  提示：未安装 python-docx，已跳过 recap.docx 生成（html/txt 不受影响）。")
        for it in new_items:
            print("  + %s（%s 字）" % (it["folder"], it["chars"]))
        for it in updated_items:
            print("  ~ %s（内容有变化，已更新）" % it["folder"])
        if orphans:
            print("  注意：%d 个目录在磁盘上但不在索引里：%s" % (
                len(orphans), "、".join(orphans)))
        if not new_items and not updated_items:
            print("  没有新内容，所有已导出记录都未改动。")

    if args.open:
        try:
            os.startfile(out)  # noqa: S606 - Windows only
        except Exception as exc:
            print("打开目录失败：%s" % exc, file=sys.stderr)

    return 0


def run_selftest(args) -> int:
    ok = True
    # AES-256 已知答案（NIST FIPS-197 附录 C.3）
    key = bytes.fromhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    pt = bytes.fromhex("00112233445566778899aabbccddeeff")
    ct = AES256(key).encrypt_block(pt)
    expect = "8ea2b7ca516745bfeafc49904b496089"
    got = ct.hex()
    print("AES-256 KAT: %s" % ("OK" if got == expect else "FAIL (%s != %s)" % (got, expect)))
    ok = ok and got == expect

    # CTR 往返
    nonce = bytes(range(12))
    data = b"hello wetype" * 7
    rt = aes_ctr(key, nonce, aes_ctr(key, nonce, data))
    print("CTR round-trip: %s" % ("OK" if rt == data else "FAIL"))
    ok = ok and rt == data

    src = os.path.abspath(args.src)
    if not os.path.isdir(src):
        print("数据目录不存在：%s" % src)
        return 2 if not ok else 0
    try:
        k = load_key(src)
        print("DPAPI 解封: OK（%d 字节密钥）" % len(k))
        idx = load_index(src, k)
        print("index 解密: OK（%d 条记录）" % len(idx.get("items") or []))
    except (DataDirError, DecryptError) as exc:
        print("DPAPI/索引自检失败：%s" % exc)
        return 3
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
