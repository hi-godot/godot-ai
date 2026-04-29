from starlette.testclient import TestClient

from godot_ai import __version__
from godot_ai.server import create_server


def test_status_route_reports_live_server_version():
    server = create_server(ws_port=9555, exclude_domains={"audio", "theme"})
    app = server.http_app(transport="streamable-http")
    client = TestClient(app)

    response = client.get("/godot-ai/status")

    assert response.status_code == 200
    assert response.json() == {
        "name": "godot-ai",
        "server_version": __version__,
        "ws_port": 9555,
        "tool_surface": "rollup",
        "exclude_domains": ["audio", "theme"],
    }
