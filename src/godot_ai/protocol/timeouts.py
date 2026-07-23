"""Shared protocol timeout budgets.

Values used by more than one transport layer live here so the editor command
budget and any client-facing transport policy cannot silently drift.
"""

TEST_RUN_TIMEOUT_SEC = 300.0
