"""Render the HTTP API reference (docs/api.md and docs/openapi.json) from the FastAPI app's OpenAPI description.

    uv run python -m bdzbridge.tools.apidoc          # rewrite the files
    uv run python -m bdzbridge.tools.apidoc --check  # exit 1 when the checked-in files are stale (used by the tests)
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from ..api.app import create_app
from ..config import Settings

DOCS = Path(__file__).resolve().parents[3] / "docs"
TAG_TITLES = {
    "recorder": "レコーダー", "guide": "番組表", "reservations": "予約", "rules": "自動予約・通知・監視",
    "titles": "録画", "jobs": "バックグラウンドジョブ",
}


def spec() -> dict:
    app = create_app(Settings(api_token="doc", db_path=":memory:", static_dir="/nonexistent"))
    return app.openapi()


def _typestr(s: dict, schemas: dict) -> str:
    if "$ref" in s:
        return s["$ref"].rsplit("/", 1)[-1]
    if "anyOf" in s:
        parts = [_typestr(x, schemas) for x in s["anyOf"]]
        return " | ".join(parts)
    if "enum" in s:
        return " | ".join(json.dumps(v, ensure_ascii=False) for v in s["enum"])
    if "const" in s:
        return json.dumps(s["const"], ensure_ascii=False)
    t = s.get("type")
    if t == "array":
        return f"list[{_typestr(s.get('items', {}), schemas)}]"
    if t == "object" and "additionalProperties" in s and isinstance(s["additionalProperties"], dict):
        return f"dict[str, {_typestr(s['additionalProperties'], schemas)}]"
    if t == "object" and s.get("additionalProperties") is True:
        return "dict"
    if s.get("format") == "date-time":
        return "datetime"
    return t or "any"


def _schema_lines(name: str, schemas: dict) -> list[str]:
    sch = schemas[name]
    out = [f"### {name}", ""]
    if sch.get("description"):
        out += [sch["description"], ""]
    required = set(sch.get("required", []))
    for prop, ps in sch.get("properties", {}).items():
        bits = [f"`{prop}`: {_typestr(ps, schemas)}"]
        if prop not in required:
            bits.append("（省略可" + (f"、既定 `{json.dumps(ps['default'], ensure_ascii=False)}`" if "default" in ps and ps["default"] is not None else "") + "）")
        if ps.get("description"):
            bits.append("— " + ps["description"])
        out.append("- " + " ".join(bits))
    return out + [""]


def render(sp: dict) -> str:
    schemas = sp.get("components", {}).get("schemas", {})
    by_tag: dict[str, list[tuple[str, str, dict]]] = {}
    for path, methods in sp["paths"].items():
        for method, op in methods.items():
            by_tag.setdefault((op.get("tags") or ["other"])[0], []).append((method.upper(), path, op))
    used: list[str] = []

    def note(name: str) -> None:
        if name in schemas and name not in used:
            used.append(name)
            for ps in schemas[name].get("properties", {}).values():
                for inner in _refs(ps):
                    note(inner)

    intro = ("bdzbridge のサーバーが提供する JSON API の一覧です。`bdzbridge/tools/apidoc.py` が OpenAPI 記述から生成します"
             "（手で編集しないでください。サーバーを起動すると `/docs` で同じ内容を対話的に試せます）。")
    out = ["# HTTP API", "", intro, "",
           "すべてのリクエストに `Authorization: Bearer <BDZBRIDGE_API_TOKEN>` が必要です。パスの先頭は `/api/v1` です。", ""]
    for tag in [t for t in TAG_TITLES if t in by_tag] + [t for t in by_tag if t not in TAG_TITLES]:
        out += [f"## {TAG_TITLES.get(tag, tag)}", ""]
        for method, path, op in by_tag[tag]:
            out.append(f"### {method} {path.removeprefix('/api/v1')}")
            out.append("")
            doc = (op.get("description") or op.get("summary") or "").strip()
            if doc:
                out += [doc, ""]
            params = [p for p in op.get("parameters", []) if p["in"] in ("query", "path")]
            if params:
                out.append("パラメータ:")
                for p in params:
                    sch = p.get("schema", {})
                    line = f"- `{p['name']}` ({p['in']}): {_typestr(sch, schemas)}"
                    if "default" in sch and sch["default"] is not None:
                        line += f"、既定 `{json.dumps(sch['default'], ensure_ascii=False)}`"
                    if p.get("description"):
                        line += " — " + p["description"]
                    out.append(line)
                out.append("")
            body = op.get("requestBody", {}).get("content", {}).get("application/json", {}).get("schema")
            if body:
                name = _typestr(body, schemas)
                out += [f"リクエスト本文: `{name}`", ""]
                for r in _refs(body):
                    note(r)
            resp_lines = []
            for code, r in sorted(op.get("responses", {}).items()):
                if code in ("422",):
                    continue
                sch = r.get("content", {}).get("application/json", {}).get("schema")
                desc = r.get("description", "")
                if sch:
                    name = _typestr(sch, schemas)
                    resp_lines.append(f"- {code}: `{name}`" + (f" — {desc}" if desc and desc != "Successful Response" else ""))
                    for x in _refs(sch):
                        note(x)
                else:
                    resp_lines.append(f"- {code}: 本文なし" + (f" — {desc}" if desc and desc != "Successful Response" else ""))
            if resp_lines:
                out += ["レスポンス:"] + resp_lines + [""]
    out += ["## モデル", ""]
    for name in used:
        out += _schema_lines(name, schemas)
    return "\n".join(out).rstrip("\n") + "\n"


def _refs(s: dict) -> list[str]:
    if "$ref" in s:
        return [s["$ref"].rsplit("/", 1)[-1]]
    found: list[str] = []
    for key in ("anyOf", "allOf", "oneOf"):
        for x in s.get(key, []):
            found += _refs(x)
    if "items" in s:
        found += _refs(s["items"])
    if isinstance(s.get("additionalProperties"), dict):
        found += _refs(s["additionalProperties"])
    return found


def files() -> dict[Path, str]:
    sp = spec()
    return {DOCS / "api.md": render(sp), DOCS / "openapi.json": json.dumps(sp, ensure_ascii=False, indent=1) + "\n"}


def main(argv: list[str]) -> int:
    wanted = files()
    if "--check" in argv:
        stale = [p.name for p, text in wanted.items() if not p.exists() or p.read_text() != text]
        if stale:
            print("stale:", ", ".join(stale), "- run `uv run python -m bdzbridge.tools.apidoc`")
            return 1
        print("docs/api.md and docs/openapi.json are up to date")
        return 0
    for p, text in wanted.items():
        p.write_text(text)
        print("wrote", p)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
