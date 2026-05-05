from starlette.testclient import TestClient

from godot_ai import __version__
from godot_ai.server import create_server


def test_status_route_reports_live_server_version():
    server = create_server(ws_port=9555, exclude_domains={"audio", "theme"})
    app = server.http_app(transport="streamable-http")
    ## ``base_url`` overrides Starlette TestClient's default ``testserver``
    ## Host header. The DNS-rebinding guard (origin_guard.py) rejects any
    ## non-loopback Host, so without this the request 403s before
    ## reaching the status route. See audit-v2 finding #1 (#345).
    client = TestClient(app, base_url="http://127.0.0.1")

    response = client.get("/godot-ai/status")

    assert response.status_code == 200
    assert response.json() == {
        "name": "godot-ai",
        "server_version": __version__,
        "ws_port": 9555,
        "tool_surface": "rollup",
        "exclude_domains": ["audio", "theme"],
    }
