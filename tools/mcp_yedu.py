#!/usr/bin/env python3
r"""yedu 工具：本地预检 / 构建日志复盘 / ipa 体检，同时是 MCP stdio 服务。

CLI:
    python mcp_yedu.py preflight [--root DIR] [--json]
    python mcp_yedu.py postmortem <build-log.zip|build.log>
    python mcp_yedu.py ipa <ipa|zip>

MCP（DSH 会这样拉起）:
    python mcp_yedu.py
"""

from __future__ import annotations

import io
import json
import os
import plistlib
import re
import struct
import sys
import traceback
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

IOS16_PLUS = [
    (r"\bNavigationStack\b", "iOS 16+"),
    (r"\bpresentationDetents\b", "iOS 16+"),
    (r"@Observable\b", "iOS 17+"),
    (r"\bContentUnavailableView\b", "iOS 17+"),
    (r"\bChart\s*\(", "iOS 16+"),
    (r"\.toolbarBackground\(", "iOS 16+"),
    (r"onChange\(of:[^)]*\)\s*\{\s*\w+\s*,\s*\w+\s+in", "iOS 17+ 双参数 onChange"),
]

RISKY = [
    (r"(?<!UIApplication\.shared)\.isIdleTimerDisabled", "isIdleTimerDisabled 属于 UIApplication.shared"),
    (r"catch\s*\{[^}]*\berror\s*=[^=]", "catch 里 error 是隐式只读绑定，不能赋值"),
    (r"for\s+\w+\s+in\s+archive[^{\n]*\{[^}]*\.extract\(", "边迭代 Archive 边 extract 会移动读游标（先快照条目）"),
    (r"try!\s", "try! 在真机会崩"),
    (r"as!\s", "as! 强转失败即崩"),
    (r"webView\.evaluateJavaScript", "未判空调用 evaluateJavaScript 会 EXC_BAD_ACCESS"),
    (r"\bformatted\(", "formatted 系列在 iOS 15 受限"),
]


def scan_swift(src: str):
    """去注释/字符串的极简词法，用于配平与危险模式。"""
    out, problems = [], []
    i, n, line = 0, len(src), 1
    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("/*", j):
                    depth += 1
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    if src[j] == "\n":
                        line += 1
                    j += 1
            i = j
            continue
        m = re.match(r'(#+)(""")?(")', src[i:])
        if m:
            closer = ('"""' if m.group(2) else '"') + m.group(1)
            j = src.find(closer, i + len(m.group(0)))
            if j < 0:
                problems.append(f"第 {line} 行的原始字符串 {m.group(1)}\" 没有结束（内容里出现 \"{m.group(1)} 会提前收尾）")
                return out, problems
            line += src.count("\n", i, j)
            i = j + len(closer)
            continue
        if src.startswith('"""', i):
            j = src.find('"""', i + 3)
            if j < 0:
                problems.append(f"第 {line} 行的多行字符串没有结束")
                return out, problems
            line += src.count("\n", i, j)
            i = j + 3
            continue
        ch = src[i]
        if ch == '"':
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == '"':
                    j += 1
                    break
                if src[j] == "\n":
                    problems.append(f"第 {line} 行的字符串跨行未闭合")
                    break
                j += 1
            i = j
            continue
        if ch == "\n":
            line += 1
        out.append((ch, line))
        i += 1
    return out, problems


def preflight(root: str = "") -> dict:
    root = root or ROOT
    src_dir = os.path.join(root, "Sources")
    files = sorted(os.path.join(src_dir, f) for f in os.listdir(src_dir) if f.endswith(".swift"))
    syntax, must, warn = [], [], []
    pairs = {"(": ")", "[": "]", "{": "}"}
    closers = {v: k for k, v in pairs.items()}

    for path in files:
        text = io.open(path, encoding="utf-8", errors="replace").read()
        chars, problems = scan_swift(text)
        name = os.path.basename(path)
        syntax += [f"{name}: {p}" for p in problems]

        stack = []
        for ch, line in chars:
            if ch in pairs:
                stack.append((ch, line))
            elif ch in closers:
                if not stack or stack[-1][0] != closers[ch]:
                    syntax.append(f"{name}:{line}: 多余的 {ch}")
                    if stack:
                        stack.pop()
                else:
                    stack.pop()
        for ch, line in stack:
            syntax.append(f"{name}:{line}: {ch} 未闭合")

        # 逐行危险模式
        body = "\n".join(c for c, _ in chars)
        for pattern, msg, level in [(p, m, "E") for p, m in IOS16_PLUS] + [(p, m, "W") for p, m in RISKY]:
            for m in re.finditer(pattern, text):
                ln = text.count("\n", 0, m.start()) + 1
                (must if level == "E" else warn).append(f"{name}:{ln}: {msg}")
        if "\ufffd" in body:
            warn.append(f"{name}: 含替换字符 U+FFFD（源文件可能被错误编码保存过）")

    cfg_path = os.path.join(root, "project.yml")
    cfg = io.open(cfg_path, encoding="utf-8").read() if os.path.exists(cfg_path) else ""
    config = []
    if "ASSETCATALOG_COMPILER_APPICON_NAME" not in cfg:
        config.append("project.yml 缺 ASSETCATALOG_COMPILER_APPICON_NAME → 桌面没有图标")
    if not re.search(r"deploymentTarget:\s*\n\s*[Ii][Oo][Ss]\s*:\s*[\"']?15\.0", cfg):
        config.append("deploymentTarget 不是 15.0")
    for rel in ("Sources/Assets.xcassets/AppIcon.appiconset/Contents.json",
                "Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"):
        if not os.path.exists(os.path.join(root, rel)):
            config.append(f"缺 {rel}")

    return {
        "ok": not syntax and not must and not config,
        "files": len(files),
        "syntax": syntax,
        "must_fix": sorted(set(must)),
        "warn": sorted(set(warn))[:40],
        "config": config,
    }


ERR_RE = re.compile(r"^([^:\n]+\.(?:swift|m|h|mm|c|cpp)):(\d+):(?:\d+:)?\s*error:\s*(.+)$")


def postmortem(path: str) -> dict:
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            text = ""
            for n in z.namelist():
                if n.lower().endswith((".log", ".txt")):
                    text = z.read(n).decode("utf-8", "replace")
                    break
    else:
        text = io.open(path, encoding="utf-8", errors="replace").read()
    if not text:
        return {"ok": False, "reason": "没找到日志文本"}

    m = re.search(r"=== ERRORS START ===(.*?)(?:=== ERRORS END ===|\Z)", text, re.S)
    block = m.group(1) if m else text
    items, seen = [], set()
    for line in block.splitlines():
        hit = ERR_RE.match(line.strip())
        if hit:
            key = (os.path.basename(hit.group(1)), int(hit.group(2)))
            if key in seen:
                continue
            seen.add(key)
            items.append({"file": key[0], "line": key[1], "msg": hit.group(3).strip()})

    joined = "\n".join(i["msg"] for i in items)
    guesses = []
    if "unterminated string" in joined or "expected ',' separator" in joined:
        guesses.append('多行/原始字符串被提前截断：改 ##"…"##')
    if "main actor-isolated" in joined:
        guesses.append("去掉类型级 @MainActor，或给调用方加 @MainActor")
    if "cannot find" in joined and "in scope" in joined:
        guesses.append("成员写在了另一个类型上，或漏 import UIKit/SwiftUI")
    if "cannot assign to value" in joined and "immutable" in joined:
        guesses.append("catch 的隐式 error 已被占用，局部变量改名")
    if "extra argument" in joined or "missing argument" in joined:
        guesses.append("View 成员列表与构造调用不一致")
    return {"ok": bool(items), "count": len(items), "errors": items[:80], "guesses": guesses}


def inspect_ipa(path: str) -> dict:
    if path.lower().endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            inner = [n for n in z.namelist() if n.lower().endswith(".ipa")]
            if not inner:
                return {"ok": False, "reason": "zip 里没有 .ipa"}
            zf = zipfile.ZipFile(io.BytesIO(z.read(inner[0])))
            label = inner[0]
    else:
        zf = zipfile.ZipFile(path)
        label = os.path.basename(path)

    names = zf.namelist()
    apps = sorted({n.split("/")[1] for n in names if n.startswith("Payload/") and n.count("/") >= 2})
    app = apps[0] if apps else ""
    info = {}
    pl = f"Payload/{app}/Info.plist"
    if pl in names:
        try:
            info = plistlib.loads(zf.read(pl))
        except Exception:  # noqa: BLE001
            info = {}
    exe = info.get("CFBundleExecutable", "")
    arch, size = None, 0
    bp = f"Payload/{app}/{exe}"
    if bp in names:
        size = zf.getinfo(bp).file_size
        with zf.open(bp) as fh:
            head = fh.read(8)
        if len(head) >= 8:
            magic, cputype = struct.unpack_from("<II", head, 0)
            if magic == 0xFEEDFACF:
                arch = {0x0100000C: "arm64", 0x01000007: "x86_64"}.get(cputype, hex(cputype))
    icons = info.get("CFBundleIcons") or {}
    return {
        "ok": bool(info),
        "ipa": label,
        "app": app,
        "bundle_id": info.get("CFBundleIdentifier"),
        "version": f"{info.get('CFBundleShortVersionString')}/{info.get('CFBundleVersion')}",
        "min_ios": info.get("MinimumOSVersion"),
        "sdk": info.get("DTSDKName"),
        "arch": arch,
        "binary_size": size,
        "icon_declared": bool(icons),
        "icon_png": [n.split("/")[-1] for n in names if re.search(r"AppIcon.*\.png$", n)][:4],
        "assets_car": any(n.endswith("Assets.car") for n in names),
        "file_sharing": info.get("UIFileSharingEnabled"),
        "verdict": "图标已声明 ✓" if icons else "没有 CFBundleIcons → 桌面空白",
    }


TOOLS = [
    {"name": "preflight", "description": "离线预检 Swift 语法/原始字符串/iOS15 兼容/崩溃雷区/工程图标配置",
     "inputSchema": {"type": "object", "properties": {"root": {"type": "string"}}}},
    {"name": "postmortem", "description": "解析 Actions 构建日志（build-log.zip/log），输出 file:line + 单根因",
     "inputSchema": {"type": "object", "properties": {"log_path": {"type": "string"}}, "required": ["log_path"]}},
    {"name": "inspect_ipa", "description": "体检 ipa：Bundle ID/架构/min iOS/CFBundleIcons/Assets.car/文件共享",
     "inputSchema": {"type": "object", "properties": {"ipa_path": {"type": "string"}}, "required": ["ipa_path"]}},
]


def call(name: str, args: dict) -> dict:
    if name == "preflight":
        return preflight(args.get("root", ""))
    if name == "postmortem":
        return postmortem(args["log_path"])
    if name == "inspect_ipa":
        return inspect_ipa(args["ipa_path"])
    raise KeyError(name)


def serve() -> int:
    def reply(mid, result=None, error=None):
        payload = {"jsonrpc": "2.0", "id": mid}
        if error:
            payload["error"] = error
        else:
            payload["result"] = result
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
        sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:  # noqa: BLE001
            continue
        method, mid = msg.get("method"), msg.get("id")
        if method == "initialize":
            reply(mid, {"protocolVersion": "2024-11-05",
                        "capabilities": {"tools": {"listChanged": False}},
                        "serverInfo": {"name": "yedu", "version": "1.1.0"}})
        elif method in ("notifications/initialized", "notifications/cancelled"):
            continue
        elif method == "tools/list":
            reply(mid, {"tools": TOOLS})
        elif method == "ping":
            reply(mid, {})
        elif method == "tools/call":
            p = msg.get("params") or {}
            try:
                res = call(p.get("name", ""), p.get("arguments") or {})
                reply(mid, {"content": [{"type": "text", "text": json.dumps(res, ensure_ascii=False, indent=2)}],
                            "isError": not res.get("ok", True)})
            except Exception as exc:  # noqa: BLE001
                reply(mid, {"content": [{"type": "text", "text": f"{type(exc).__name__}: {exc}"}],
                            "isError": True})
        elif mid is not None:
            reply(mid, error={"code": -32601, "message": f"unknown method {method}"})
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 1:
        return serve()
    cmd, rest = argv[1], argv[2:]
    probe = {"preflight": lambda: preflight(rest[0] if rest else ROOT),
             "postmortem": lambda: postmortem(rest[0]),
             "ipa": lambda: inspect_ipa(rest[0])}[cmd]()
    text = json.dumps(probe, ensure_ascii=False, indent=2)
    if "--json" in argv:
        print(text)
    else:
        print(text)
    return 0 if probe.get("ok") else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except KeyError:
        print("用法: preflight|postmortem <path>|ipa <path>")
        raise SystemExit(2)
