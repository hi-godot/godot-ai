"""Real Godot AI backend: only its private PID file changes during status replies."""

import json
import os
import signal
import sys
import threading
from functools import wraps
from pathlib import Path

from godot_ai import main
from godot_ai.server import GodotAIFastMCP


def serve() -> None:
    work = Path(os.environ["PROOF_WORK"])
    original = GodotAIFastMCP.custom_route
    requests: dict[str, int] = {}

    def custom_route(self, path, *args, **kwargs):
        register = original(self, path, *args, **kwargs)
        if path != "/godot-ai/status":
            return register

        def decorate(handler):
            @wraps(handler)
            async def controlled(request):
                response = await handler(request)
                control_path = work / "control.json"
                if response.status_code == 200 and control_path.exists():
                    control = json.loads(control_path.read_text(encoding="utf-8"))
                    case = control["case"]
                    requests[case] = requests.get(case, 0) + 1
                    if requests[case] == control["change_on_request"]:
                        (work / "worker.pid").write_text(str(control["replacement_pid"]))
                    (work / "route-receipt.json").write_text(json.dumps({
                        "case": case, "authenticated_requests": requests[case],
                    }))
                return response

            return register(controlled)

        return decorate

    GodotAIFastMCP.custom_route = custom_route
    # Bound a surviving actual backend even if its test parent disappears.
    timer = threading.Timer(240, lambda: os.kill(os.getpid(), signal.SIGTERM))
    timer.daemon = True
    timer.start()
    (work / "backend-process.json").write_text(json.dumps({"pid": os.getpid()}))
    main(sys.argv[1:])


if __name__ == "__main__":
    serve()
