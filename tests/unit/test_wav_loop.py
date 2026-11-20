"""PCM loop finder format, search, and input limits."""

from __future__ import annotations

import io
import math
import random
import struct
import wave

import pytest

from godot_ai.handlers import _wav_loop
from godot_ai.handlers._wav_loop import WavLoopError, find_pcm_wav_loops


def _pcm_wav(samples, *, rate=100, channels=1):
    source = io.BytesIO()
    with wave.open(source, "wb") as writer:
        writer.setparams((channels, 2, rate, 0, "NONE", ""))
        writer.writeframes(struct.pack(f"<{len(samples)}h", *samples))
    return source


def _riff(*chunks):
    body = b"WAVE"
    for tag, data in chunks:
        body += struct.pack("<4sI", tag, len(data)) + data + b"\0" * (len(data) % 2)
    return io.BytesIO(struct.pack("<4sI", b"RIFF", len(body)) + body)


def _format(*, tag=1, rate=100, channels=1, bits=16, byte_rate=None):
    align = channels * (bits // 8)
    return struct.pack(
        "<HHIIHH",
        tag,
        channels,
        rate,
        rate * align if byte_rate is None else byte_rate,
        align,
        bits,
    )


def _assert_error(source, reason, **kwargs):
    with pytest.raises(WavLoopError) as error:
        find_pcm_wav_loops(source, **kwargs)
    assert error.value.reason == reason


def _tone(period, count, amplitude):
    cycle = [round(amplitude * math.sin(math.tau * index / period)) for index in range(period)]
    return [cycle[index % period] for index in range(count)]


def test_quiet_periodic_audio_has_repeatable_ranked_loops():
    source = _pcm_wav([0, 1, 0, -1] * 37)
    result = find_pcm_wav_loops(source, min_loop_seconds=0.2, max_candidates=10)
    assert result == find_pcm_wav_loops(source, min_loop_seconds=0.2, max_candidates=10)
    assert "reason" not in result

    candidates = result["candidates"]
    assert len(candidates) == 10
    assert candidates[0] == {
        "start_frame": 0,
        "end_frame": 144,
        "frame_count": 144,
        "start_seconds": 0.0,
        "end_seconds": 1.44,
        "duration_seconds": 1.44,
        "seam_error": 0.0,
    }
    assert [c["seam_error"] for c in candidates] == sorted(c["seam_error"] for c in candidates)
    for index, candidate in enumerate(candidates):
        assert candidate["frame_count"] % 4 == 0
        assert all(
            abs(candidate["start_frame"] - previous["start_frame"]) > 1
            or abs(candidate["end_frame"] - previous["end_frame"]) > 1
            for previous in candidates[:index]
        )


def test_quiet_stereo_channel_changes_ranking():
    left = _tone(20, 185, 28000)
    right = _tone(40, 185, 3)
    interleaved = [sample for frame in zip(left, right, strict=True) for sample in frame]
    stereo = find_pcm_wav_loops(_pcm_wav(interleaved, channels=2), min_loop_seconds=0.2)
    mono = find_pcm_wav_loops(_pcm_wav(left), min_loop_seconds=0.2)

    assert stereo["channels"] == 2
    assert stereo["frame_count"] == mono["frame_count"] == 185
    assert mono["candidates"][0]["frame_count"] == 180
    assert stereo["candidates"][0]["frame_count"] == 160
    assert all(
        (candidate["end_frame"] - candidate["start_frame"]) % 40 == 0
        and candidate["seam_error"] == 0.0
        for candidate in stereo["candidates"]
    )


def test_search_refines_off_grid_boundaries_at_single_frames():
    tone = _tone(149, 5327, 12000)
    result = find_pcm_wav_loops(_pcm_wav(tone), min_loop_seconds=4)
    step = math.ceil(result["frame_count"] / (_wav_loop._COARSE_POINTS - 1))
    coarse_boundaries = (*range(0, result["frame_count"], step), result["frame_count"])
    candidate = result["candidates"][0]
    assert candidate["frame_count"] % 149 == 0
    assert candidate["seam_error"] == 0.0
    assert (
        candidate["start_frame"] not in coarse_boundaries
        or candidate["end_frame"] not in coarse_boundaries
    )


def test_noise_still_returns_the_best_available_score():
    rng = random.Random(7)
    source = _pcm_wav([rng.randrange(-32768, 32768) for _ in range(100)])
    result = find_pcm_wav_loops(source, min_loop_seconds=1)
    (candidate,) = result["candidates"]
    assert (candidate["start_frame"], candidate["end_frame"]) == (0, 100)
    assert 0.0 < candidate["seam_error"] <= 1.0


def test_selection_rounds_ties_up_and_minimum_rounds_up():
    source = _pcm_wav([0, 100, 0, -100] * 20, rate=8)
    result = find_pcm_wav_loops(
        source, start_seconds=0.3125, end_seconds=1.0625, min_loop_seconds=0.51
    )
    assert (result["start_frame"], result["end_frame"], result["min_loop_frames"]) == (3, 9, 5)
    assert result["frame_count"] == 6
    for candidate in result["candidates"]:
        start, end = candidate["start_frame"], candidate["end_frame"]
        assert 3 <= start < end <= 9
        assert 5 <= candidate["frame_count"] == end - start
        assert candidate["duration_seconds"] == (end - start) / 8


def test_round_trips_float_for_exact_eof():
    source = _pcm_wav([0, 100, 0, -100, 0], rate=3)
    result = find_pcm_wav_loops(source, end_seconds=5 / 3)
    assert result["end_frame"] == 5


@pytest.mark.parametrize(
    ("source", "reason"),
    [
        (_pcm_wav([]), "range_too_short"),
        (_pcm_wav([1]), "range_too_short"),
        (_pcm_wav([0, 1] * 24), "range_too_short"),
        (_pcm_wav([0] * 50), "silence_or_constant"),
        (_pcm_wav([-4000, 1400] * 50, channels=2), "silence_or_constant"),
    ],
)
def test_empty_results_explain_why(source, reason):
    result = find_pcm_wav_loops(source)
    assert result["candidates"] == []
    assert result["reason"] == reason


@pytest.mark.parametrize(
    ("params", "reason"),
    [
        ({"start_seconds": True}, "invalid_time"),
        ({"start_seconds": "0"}, "invalid_time"),
        ({"start_seconds": -0.01}, "invalid_time"),
        ({"end_seconds": float("inf")}, "invalid_time"),
        ({"end_seconds": float("nan")}, "invalid_time"),
        ({"min_loop_seconds": 0}, "invalid_time"),
        ({"min_loop_seconds": None}, "invalid_time"),
        ({"start_seconds": 0.1, "end_seconds": 0.1}, "invalid_range"),
        ({"start_seconds": 0.2, "end_seconds": 0.1}, "invalid_range"),
        ({"end_seconds": 1.001}, "invalid_range"),
        ({"max_candidates": False}, "invalid_max_candidates"),
        ({"max_candidates": 3.0}, "invalid_max_candidates"),
        ({"max_candidates": 0}, "invalid_max_candidates"),
        ({"max_candidates": 11}, "invalid_max_candidates"),
    ],
)
def test_invalid_arguments_fail_cleanly(params, reason):
    _assert_error(_pcm_wav([0, 100, 0, -100] * 25), reason, **params)


@pytest.mark.parametrize(
    ("fmt", "payload", "reason"),
    [
        (_format(tag=3), b"\0\0", "unsupported_wav"),
        (_format(channels=3), b"\0" * 6, "unsupported_wav"),
        (_format(bits=24), b"\0" * 3, "unsupported_wav"),
        (_format(rate=0), b"\0\0", "malformed_wav"),
        (_format(byte_rate=90), b"\0\0", "malformed_wav"),
        (_format(channels=2), b"\0\0", "malformed_wav"),
        (_format()[:10], b"\0\0", "malformed_wav"),
    ],
)
def test_invalid_format_or_frame_layout(fmt, payload, reason):
    _assert_error(_riff((b"fmt ", fmt), (b"data", payload)), reason)


@pytest.mark.parametrize(
    ("valid_bits", "mask", "encoding", "error"),
    [
        (16, 3, 1, None),
        (16, 0, 1, None),
        (15, 3, 1, "unsupported_wav"),
        (16, 4, 1, "unsupported_wav"),
        (16, 3, 3, "unsupported_wav"),
    ],
)
def test_extensible_pcm_stereo(valid_bits, mask, encoding, error):
    subtype = bytes.fromhex("0000000000001000800000aa00389b71")
    fmt = (
        _format(tag=0xFFFE, channels=2)
        + struct.pack("<HHII", 22, valid_bits, mask, encoding)
        + subtype[4:]
    )
    wave = _riff(
        (b"JUNK", b"odd"),
        (b"fmt ", fmt),
        (b"data", struct.pack("<8h", 0, 0, 1, -1, 0, 0, -1, 1) * 15),
    )
    if error:
        _assert_error(wave, error)
    else:
        result = find_pcm_wav_loops(wave)
        assert result["channels"] == 2
        assert result["frame_count"] == 60
        assert result["candidates"]


def test_riff_truncation_and_missing_format_are_rejected():
    valid = _pcm_wav([0, 1, 0, -1] * 20).getvalue()
    _assert_error(io.BytesIO(valid[:-1]), "malformed_wav")
    _assert_error(io.BytesIO(b"RIFX" + valid[4:]), "unsupported_wav")
    _assert_error(_riff((b"data", b"abc")), "malformed_wav")
    _assert_error(_riff((b"fmt ", _format())), "malformed_wav")
    _assert_error(_riff((b"fmt ", _format()), (b"data", b""), (b"data", b"")), "malformed_wav")


def test_chunk_count_and_selected_pcm_byte_limits(monkeypatch):
    monkeypatch.setattr(_wav_loop, "_MAX_RIFF_CHUNKS", 2)
    _assert_error(_riff((b"fmt ", _format()), (b"data", b""), (b"JUNK", b"")), "edit_too_large")

    monkeypatch.setattr(_wav_loop, "MAX_SELECTED_PCM_BYTES", 64)
    source = _pcm_wav([0, 0, 1, -1] * 20, rate=10, channels=2)
    _assert_error(source, "edit_too_large")
    _assert_error(source, "edit_too_large", end_seconds=1.7)
    assert find_pcm_wav_loops(source, end_seconds=1.6)["frame_count"] == 16


def test_reads_only_the_selected_pcm_in_bounded_blocks():
    class ObservedSource(io.BytesIO):
        def __init__(self, data):
            super().__init__(data)
            self.pcm_reads = []

        def read(self, size=-1):
            assert 0 <= size <= 65536
            if self.tell() >= 44:
                self.pcm_reads.append((self.tell(), size))
            return super().read(size)

    source = ObservedSource(_pcm_wav([0, 0, 1, -1] * 20000, rate=10000, channels=2).getvalue())
    result = find_pcm_wav_loops(source, start_seconds=1, end_seconds=3)
    assert result["frame_count"] == 20000
    assert source.pcm_reads == [(40044, 65536), (105580, 14464)]
