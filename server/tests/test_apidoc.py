from bdzbridge.tools import apidoc


def test_api_reference_is_up_to_date():
    """docs/api.md and docs/openapi.json are generated; regenerate with `uv run python -m bdzbridge.tools.apidoc`."""
    stale = [p.name for p, text in apidoc.files().items() if not p.exists() or p.read_text() != text]
    assert not stale, f"stale: {stale} - run `uv run python -m bdzbridge.tools.apidoc`"


def test_api_reference_covers_every_route():
    sp = apidoc.spec()
    md = apidoc.render(sp)
    for path, methods in sp["paths"].items():
        for method in methods:
            assert f"### {method.upper()} {path.removeprefix('/api/v1')}" in md
    assert "## モデル" in md and "### Reservation" in md and "### Job" in md
