#!/usr/bin/env python3
"""doc-mcp: markitdown MCP 的透明替代实现（stdio / FastMCP）。

对外契约与原 markitdown-mcp 完全一致：
    工具名 : convert_to_markdown
    入参   : uri: str
    返回   : Markdown 文本（字符串）

新增能力：对 .doc/.xls/.rtf/.wps 等老版格式，先用隔离配置的 LibreOffice 无头转换，
再交给 MarkItDown 提取文本；直接转换失败时自动兜底一次 LibreOffice 转换。

安全约束：
    - 只允许 /workspace 之内的真实路径（os.path.realpath 解析后比对），越界一律拒绝；
    - 临时目录与 LibreOffice profile 用完即删；
    - 只读源文件，绝不修改或删除 /workspace 内的文件。
"""

import logging
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path

from docx import Document
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Pt, RGBColor
from markitdown import MarkItDown
from mcp.server.fastmcp import FastMCP

WORKSPACE = Path("/workspace").resolve()

# 老格式 -> LibreOffice 目标格式
LEGACY_TARGET = {
    ".doc": "docx",
    ".dot": "docx",
    ".rtf": "docx",
    ".wps": "docx",
    ".odt": "docx",
    ".xls": "xlsx",
    ".xlt": "xlsx",
    ".ods": "xlsx",
    ".ppt": "pptx",
    ".pps": "pptx",
    ".odp": "pptx",
}

# 直接交给 MarkItDown 的格式；失败时按 FALLBACK_TARGET 再走一次 LibreOffice
DIRECT_SUFFIXES = {
    ".docx", ".pdf", ".xlsx", ".pptx", ".txt", ".md", ".markdown",
    ".html", ".htm", ".csv", ".json", ".xml", ".epub",
}
FALLBACK_TARGET = {
    ".docx": "docx",
    ".xlsx": "xlsx",
    ".pptx": "pptx",
    ".html": "docx",
    ".htm": "docx",
    ".txt": "docx",
    ".md": "docx",
    ".csv": "xlsx",
    ".json": "docx",
    ".xml": "docx",
}

EMPTY_HINT = "[提示] 未提取到有效文本内容（可能为纯图片扫描件），请勿猜测原文"
CONVERT_TIMEOUT = 90

logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("doc-mcp")

mcp = FastMCP("doc-mcp")
_markitdown = MarkItDown()


def _denied(original):
    return ValueError(
        "Access denied - path outside allowed directories: %s not in /workspace" % original
    )


def resolve_uri(uri):
    """把 file:///... 或裸路径解析为 /workspace 内的真实文件路径。"""
    if not isinstance(uri, str) or not uri.strip():
        raise ValueError("uri is required")

    raw = uri.strip()
    if raw.lower().startswith("file:"):
        parsed = urllib.parse.urlparse(raw)
        if parsed.netloc not in ("", "localhost"):
            raise _denied(raw)
        candidate = urllib.parse.unquote(parsed.path or "")
    else:
        candidate = raw
        # 少数客户端会把裸路径也做百分号编码；仅在原样不存在时尝试解码
        if ("%" in raw) and (not os.path.exists(candidate)):
            candidate = urllib.parse.unquote(raw)

    if not candidate:
        raise ValueError("uri is required")

    real = Path(os.path.realpath(candidate))
    try:
        real.relative_to(WORKSPACE)
    except ValueError:
        raise _denied(raw)

    if not real.exists():
        raise FileNotFoundError("File not found: %s" % raw)
    if not real.is_file():
        raise ValueError("Not a regular file: %s" % raw)
    return real


def _soffice_env(workdir):
    env = dict(os.environ)
    env["HOME"] = str(workdir)
    env["SAL_USE_VCLPLUGIN"] = "svp"
    return env


def _libreoffice_convert(src, target_ext, workdir):
    """在隔离 profile 下把 src 转成 target_ext，返回输出文件路径。"""
    profile = workdir / "lo_profile"
    profile.mkdir(parents=True, exist_ok=True)

    executable = "soffice"
    if not any(
        (Path(p) / executable).exists()
        for p in os.environ.get("PATH", "/usr/bin:/bin").split(os.pathsep)
        if p
    ):
        raise RuntimeError("soffice not found in PATH")

    cmd = [
        executable,
        "--headless",
        "--nologo",
        "--nodefault",
        "--nofirststartwizard",
        "-env:UserInstallation=" + profile.as_uri(),
        "--convert-to", target_ext,
        "--outdir", str(workdir),
        str(src),
    ]
    log.info("libreoffice convert: %s -> %s", src.name, target_ext)

    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=CONVERT_TIMEOUT,
            env=_soffice_env(workdir),
        )
    except subprocess.TimeoutExpired:
        raise TimeoutError(
            "LibreOffice 转换超时（>%d 秒）：%s" % (CONVERT_TIMEOUT, src.name)
        )

    out = workdir / (src.stem + "." + target_ext)
    if not out.exists():
        raise RuntimeError(
            "LibreOffice 转换失败（rc=%s）：stdout=%s stderr=%s"
            % (
                proc.returncode,
                (proc.stdout or "")[-400:].strip(),
                (proc.stderr or "")[-400:].strip(),
            )
        )
    return out


def _to_markdown(path):
    result = _markitdown.convert(str(path))
    text = getattr(result, "text_content", None)
    if text is None:
        text = str(result)
    return text


def extract(path):
    suffix = path.suffix.lower()

    # 1) 老格式：先 LibreOffice 转换，再提取
    if suffix in LEGACY_TARGET:
        target = LEGACY_TARGET[suffix]
        with tempfile.TemporaryDirectory(prefix="docmcp-") as tmpdir:
            converted = _libreoffice_convert(path, target, Path(tmpdir))
            return _to_markdown(converted)

    # 2) 常规格式：直接提取
    try:
        return _to_markdown(path)
    except Exception as exc:  # noqa: BLE001 - 需要兜底而非中断
        log.warning("direct convert failed for %s: %s", path.name, exc)
        target = FALLBACK_TARGET.get(suffix)
        if not target:
            raise
        with tempfile.TemporaryDirectory(prefix="docmcp-") as tmpdir:
            converted = _libreoffice_convert(path, target, Path(tmpdir))
            return _to_markdown(converted)


@mcp.tool()
def convert_to_markdown(uri: str) -> str:
    """Convert a document to Markdown text.

    Args:
        uri: Either file:///workspace/... (URL-encoded allowed) or /workspace/...
    """
    path = resolve_uri(uri)
    try:
        text = extract(path)
    except TimeoutError as exc:
        return "[错误] %s" % exc
    except RuntimeError as exc:
        return "[错误] %s" % exc

    if text is None or not str(text).strip():
        return EMPTY_HINT
    return text


# ---------------------------------------------------------------- Markdown -> Word
# 面向"老板直接用 Word 阅读"的排版：微软雅黑（含 eastAsia）、1.5 倍行距、
# 标题/加粗/列表/分割线/链接/表格（实线网格 + 表头灰底 + 自动换行）。

CJK_FONT = "微软雅黑"
BODY_FONT_SIZE = Pt(10.5)
LINE_SPACING = 1.5
HEADING_SIZES = {1: Pt(18), 2: Pt(15), 3: Pt(13)}
HEADING_COLOR = RGBColor(0x1F, 0x3A, 0x5F)
LINK_COLOR = RGBColor(0x1F, 0x4E, 0x79)
MUTED_COLOR = RGBColor(0x59, 0x59, 0x59)
TABLE_HEAD_FILL = "D9D9D9"

INLINE_RE = re.compile(r"(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)\s]+\))")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")
BULLET_RE = re.compile(r"^(\s*)[-*+]\s+(.*)$")
ORDERED_RE = re.compile(r"^(\s*)\d+[.)]\s+(.*)$")
CJK_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]")


def _set_cjk_font(run, name=CJK_FONT, size=None, bold=None, color=None):
    """同时设置西文与 eastAsia 字体，避免中文回退成宋体/乱字体。"""
    run.font.name = name
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.append(rfonts)
    for attr in ("w:ascii", "w:hAnsi", "w:eastAsia", "w:cs"):
        rfonts.set(qn(attr), name)
    if size is not None:
        run.font.size = size
    if bold is not None:
        run.bold = bold
    if color is not None:
        run.font.color.rgb = color


def _add_runs(paragraph, text, size=None, bold=False, color=None):
    """渲染 **粗体**、`代码`、[文字](URL)；链接保留可读文字与完整 URL。"""
    if not text:
        return
    pos = 0
    for m in INLINE_RE.finditer(text):
        if m.start() > pos:
            _set_cjk_font(paragraph.add_run(text[pos:m.start()]), size=size, bold=bold, color=color)
        token = m.group(0)
        if token.startswith("**"):
            _set_cjk_font(paragraph.add_run(token[2:-2]), size=size, bold=True, color=color)
        elif token.startswith("`"):
            _set_cjk_font(paragraph.add_run(token[1:-1]), name="Consolas", size=Pt(9.5), bold=bold)
        else:
            label, url = token[1:-1].split("](", 1)
            _set_cjk_font(paragraph.add_run(label), size=size, bold=bold, color=color)
            _set_cjk_font(paragraph.add_run(" (" + url + ")"), size=Pt(9), color=LINK_COLOR)
        pos = m.end()
    if pos < len(text):
        _set_cjk_font(paragraph.add_run(text[pos:]), size=size, bold=bold, color=color)


def _shade(cell, fill):
    tc_pr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), fill)
    tc_pr.append(shd)


def _repeat_header(row):
    tr_pr = row._tr.get_or_add_trPr()
    el = OxmlElement("w:tblHeader")
    el.set(qn("w:val"), "true")
    tr_pr.append(el)


def _add_hr(doc):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(6)
    p.paragraph_format.space_after = Pt(6)
    p_pr = p._p.get_or_add_pPr()
    borders = OxmlElement("w:pBdr")
    bottom = OxmlElement("w:bottom")
    bottom.set(qn("w:val"), "single")
    bottom.set(qn("w:sz"), "6")
    bottom.set(qn("w:space"), "1")
    bottom.set(qn("w:color"), "BFBFBF")
    borders.append(bottom)
    p_pr.append(borders)


def _add_code_block(doc, text):
    for line in (text.splitlines() or [""]):
        p = doc.add_paragraph()
        p.paragraph_format.space_after = Pt(0)
        p.paragraph_format.line_spacing = 1.0
        _set_cjk_font(p.add_run(line if line else " "), name="Consolas", size=Pt(9))


def _add_heading(doc, text, level):
    p = doc.add_paragraph(style="Heading %d" % level)
    p.paragraph_format.space_before = Pt(12 if level == 1 else 10)
    p.paragraph_format.space_after = Pt(6)
    p.paragraph_format.line_spacing = 1.25
    _add_runs(p, text, size=HEADING_SIZES.get(level, Pt(12)), bold=True, color=HEADING_COLOR)


def _split_row(line):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    return [c.strip() for c in s.split("|")]


def _is_sep(line):
    s = line.strip().strip("|")
    if not s:
        return False
    cells = [c.strip() for c in s.split("|")]
    return bool(cells) and all(re.fullmatch(r":?-{3,}:?", c) for c in cells)


def _add_table(doc, header, rows):
    cols = max([len(header)] + [len(r) for r in rows]) if rows else len(header)
    table = doc.add_table(rows=1, cols=cols)
    table.style = "Table Grid"
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = True

    head_row = table.rows[0]
    _repeat_header(head_row)
    for idx in range(cols):
        cell = head_row.cells[idx]
        cell.text = ""
        p = cell.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_after = Pt(0)
        _add_runs(p, header[idx] if idx < len(header) else "", size=Pt(10), bold=True)
        _shade(cell, TABLE_HEAD_FILL)

    for values in rows:
        cells = table.add_row().cells
        for idx in range(cols):
            cells[idx].text = ""
            p = cells[idx].paragraphs[0]
            p.paragraph_format.space_after = Pt(0)
            p.paragraph_format.line_spacing = 1.15
            _add_runs(p, values[idx] if idx < len(values) else "", size=Pt(10))

    doc.add_paragraph().paragraph_format.space_after = Pt(2)


def _join_lines(parts):
    out = ""
    for part in parts:
        if not out:
            out = part
        elif CJK_RE.search(out[-1:]) or CJK_RE.search(part[:1]):
            out += part
        else:
            out += " " + part
    return out


def _render_markdown(text, out_path):
    doc = Document()

    normal = doc.styles["Normal"]
    normal.font.name = CJK_FONT
    normal.font.size = BODY_FONT_SIZE
    rpr = normal.element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.append(rfonts)
    for attr in ("w:ascii", "w:hAnsi", "w:eastAsia", "w:cs"):
        rfonts.set(qn(attr), CJK_FONT)
    normal.paragraph_format.line_spacing = LINE_SPACING
    normal.paragraph_format.space_after = Pt(6)

    lines = text.splitlines()
    stats = {"heading": 0, "table": 0, "list": 0, "para": 0}
    i = 0
    while i < len(lines):
        raw = lines[i]
        s = raw.strip()
        if not s:
            i += 1
            continue

        if s.startswith("```"):
            i += 1
            buf = []
            while i < len(lines) and not lines[i].strip().startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            _add_code_block(doc, "\n".join(buf))
            continue

        m = HEADING_RE.match(s)
        if m:
            level = min(len(m.group(1)), 3)
            _add_heading(doc, m.group(2).strip(), level)
            stats["heading"] += 1
            i += 1
            continue

        if re.fullmatch(r"(-{3,}|\*{3,}|_{3,})", s):
            _add_hr(doc)
            i += 1
            continue

        if "|" in s and i + 1 < len(lines) and _is_sep(lines[i + 1]):
            header = _split_row(raw)
            i += 2
            rows = []
            while i < len(lines):
                nxt = lines[i].strip()
                if not nxt or "|" not in nxt:
                    break
                rows.append(_split_row(nxt))
                i += 1
            _add_table(doc, header, rows)
            stats["table"] += 1
            continue

        m = BULLET_RE.match(raw)
        if m:
            indent = len(m.group(1)) // 2
            p = doc.add_paragraph(style="List Bullet")
            p.paragraph_format.left_indent = Pt(18 * (indent + 1))
            p.paragraph_format.space_after = Pt(2)
            p.paragraph_format.line_spacing = LINE_SPACING
            _add_runs(p, m.group(2).strip())
            stats["list"] += 1
            i += 1
            continue

        m = ORDERED_RE.match(raw)
        if m:
            indent = len(m.group(1)) // 2
            p = doc.add_paragraph(style="List Number")
            p.paragraph_format.left_indent = Pt(18 * (indent + 1))
            p.paragraph_format.space_after = Pt(2)
            p.paragraph_format.line_spacing = LINE_SPACING
            _add_runs(p, m.group(2).strip())
            stats["list"] += 1
            i += 1
            continue

        if s.startswith(">"):
            p = doc.add_paragraph()
            p.paragraph_format.left_indent = Pt(12)
            _add_runs(p, s.lstrip("> ").strip(), color=MUTED_COLOR)
            i += 1
            continue

        parts = [s]
        i += 1
        while i < len(lines):
            nxt = lines[i].strip()
            if (not nxt
                    or nxt.startswith("#")
                    or nxt.startswith("```")
                    or nxt.startswith(">")
                    or BULLET_RE.match(lines[i])
                    or ORDERED_RE.match(lines[i])
                    or re.fullmatch(r"(-{3,}|\*{3,}|_{3,})", nxt)
                    or ("|" in nxt and i + 1 < len(lines) and _is_sep(lines[i + 1]))):
                break
            parts.append(nxt)
            i += 1
        p = doc.add_paragraph()
        _add_runs(p, _join_lines(parts))
        stats["para"] += 1

    doc.save(str(out_path))
    return stats


def _resolve_output_path(docx_path, src):
    """输出路径同样必须落在 /workspace 内；为空则与源文件同目录同名 .docx。"""
    if not docx_path or not str(docx_path).strip():
        raw = str(src.with_suffix(".docx"))
    else:
        raw = str(docx_path).strip()
        if raw.lower().startswith("file:"):
            parsed = urllib.parse.urlparse(raw)
            if parsed.netloc not in ("", "localhost"):
                raise _denied(raw)
            raw = urllib.parse.unquote(parsed.path or "")

    if not raw.lower().endswith(".docx"):
        raise ValueError("docx_path 必须以 .docx 结尾：%s" % raw)

    real = Path(os.path.realpath(raw))
    try:
        real.relative_to(WORKSPACE)
    except ValueError:
        raise _denied(raw)

    if real == src:
        raise ValueError("输出路径不能与源文件相同：%s" % raw)
    if real.exists() and real.is_dir():
        raise ValueError("输出路径是目录：%s" % raw)
    if not real.parent.exists():
        raise ValueError("输出目录不存在：%s" % real.parent)
    return real


@mcp.tool()
def markdown_to_docx(md_path: str, docx_path: str = "") -> str:
    """Convert a Markdown file under /workspace into a Word .docx.

    Args:
        md_path: /workspace/... or file:///workspace/... pointing to a .md file
        docx_path: optional output path under /workspace; default = same name with .docx
    """
    src = resolve_uri(md_path)
    if src.suffix.lower() not in (".md", ".markdown"):
        raise ValueError("md_path 必须是 .md/.markdown 文件：%s" % src)

    out = _resolve_output_path(docx_path, src)
    text = src.read_text(encoding="utf-8", errors="replace")

    fd, tmp_name = tempfile.mkstemp(dir=str(out.parent), prefix=".docmcp-", suffix=".docx")
    os.close(fd)
    try:
        stats = _render_markdown(text, Path(tmp_name))
        os.replace(tmp_name, str(out))
    except Exception:
        try:
            os.remove(tmp_name)
        except OSError:
            pass
        raise

    return "OK: %s | %d bytes | 标题 %d / 表格 %d / 列表 %d / 段落 %d" % (
        out, out.stat().st_size, stats["heading"], stats["table"], stats["list"], stats["para"]
    )


if __name__ == "__main__":
    mcp.run(transport="stdio")
