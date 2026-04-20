"""Tests for protocol envelope types."""

import json

from godot_ai.protocol.envelope import (
    CommandRequest,
    CommandResponse,
    ErrorDetail,
    HandshakeMessage,
)


class TestCommandRequest:
    def test_defaults(self):
        req = CommandRequest(command="get_scene_tree")
        assert req.command == "get_scene_tree"
        assert req.params == {}
        assert len(req.request_id) > 0

    def test_with_params(self):
        req = CommandRequest(command="get_scene_tree", params={"depth": 5})
        assert req.params == {"depth": 5}

    def test_roundtrip_json(self):
        req = CommandRequest(command="test", params={"key": "value"})
        raw = req.model_dump_json()
        parsed = CommandRequest.model_validate_json(raw)
        assert parsed.command == req.command
        assert parsed.request_id == req.request_id
        assert parsed.params == req.params


class TestCommandResponse:
    def test_ok_response(self):
        resp = CommandResponse(
            request_id="abc123",
            status="ok",
            data={"nodes": []},
        )
        assert resp.status == "ok"
        assert resp.error is None

    def test_error_response(self):
        resp = CommandResponse(
            request_id="abc123",
            status="error",
            error=ErrorDetail(code="NODE_NOT_FOUND", message="Not found"),
        )
        assert resp.status == "error"
        assert resp.error.code == "NODE_NOT_FOUND"

    def test_roundtrip_json(self):
        resp = CommandResponse(
            request_id="abc123",
            status="ok",
            data={"version": "4.4"},
        )
        raw = resp.model_dump_json()
        parsed = CommandResponse.model_validate_json(raw)
        assert parsed.request_id == "abc123"
        assert parsed.data == {"version": "4.4"}


class TestHandshakeMessage:
    def test_defaults(self):
        msg = HandshakeMessage(
            session_id="sess-001",
            godot_version="4.4.1",
            project_path="/tmp/project",
            plugin_version="0.0.1",
        )
        assert msg.type == "handshake"
        assert msg.protocol_version == 1

    def test_from_dict(self):
        raw = {
            "type": "handshake",
            "session_id": "sess-001",
            "godot_version": "4.4.1",
            "project_path": "/tmp/project",
            "plugin_version": "0.0.1",
            "protocol_version": 1,
        }
        msg = HandshakeMessage.model_validate(raw)
        assert msg.session_id == "sess-001"

    def test_roundtrip_json(self):
        msg = HandshakeMessage(
            session_id="sess-001",
            godot_version="4.4.1",
            project_path="/tmp/project",
            plugin_version="0.0.1",
        )
        raw = msg.model_dump_json()
        parsed = json.loads(raw)
        assert parsed["type"] == "handshake"
        assert parsed["session_id"] == "sess-001"

    def test_server_launch_mode_defaults_to_unknown(self):
        ## Older plugins omit server_launch_mode; server should parse the
        ## handshake cleanly rather than reject it, and default to "unknown"
        ## so agents can distinguish "old plugin" from "mode could not be
        ## determined" via plugin_version.
        msg = HandshakeMessage(
            session_id="sess-001",
            godot_version="4.4.1",
            project_path="/tmp/project",
            plugin_version="0.0.1",
        )
        assert msg.server_launch_mode == "unknown"

    def test_server_launch_mode_parsed_when_supplied(self):
        msg = HandshakeMessage.model_validate(
            {
                "session_id": "sess-001",
                "godot_version": "4.4.1",
                "project_path": "/tmp/project",
                "plugin_version": "0.0.1",
                "server_launch_mode": "dev_venv",
            }
        )
        assert msg.server_launch_mode == "dev_venv"
