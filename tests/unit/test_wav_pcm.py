"""Verify WAV validation and exact edits independently of tool and file routing."""

import io
import math
import struct
import wave
from uuid import UUID

import pytest

from godot_ai.handlers import _wav_pcm
from godot_ai.handlers._wav_pcm import WavEditError, edit_pcm_wav


def _chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack("<4sI", kind, len(data)) + data + (b"\0" if len(data) % 2 else b"")


def _riff(*chunks: bytes) -> bytes:
    payload = b"WAVE" + b"".join(chunks)
    return struct.pack("<4sI", b"RIFF", len(payload)) + payload


def _format(
    *,
    rate: int = 10,
    channels: int = 1,
    bits: int = 16,
    encoding: int = 1,
    alignment: int | None = None,
    extension: bytes = b"",
) -> bytes:
    frame_alignment = alignment if alignment is not None else channels * (bits // 8)
    fields = struct.pack(
        "<HHIIHH", encoding, channels, rate, rate * frame_alignment, frame_alignment, bits
    )
    return _chunk(b"fmt ", fields + extension)


def _pcm(samples: list[int], *, rate: int = 10, channels: int = 1) -> bytes:
    data = struct.pack(f"<{len(samples)}h", *samples)
    return _riff(_format(rate=rate, channels=channels), _chunk(b"data", data))


def _extensible(
    *, channels: int = 1, mask: int = 0, valid_bits: int = 16, subtype: int = 1, ext_size: int = 22
) -> bytes:
    guid = UUID(f"{subtype:08x}-0000-0010-8000-00aa00389b71").bytes_le
    return _format(
        channels=channels,
        encoding=0xFFFE,
        extension=struct.pack("<HHI16s", ext_size, valid_bits, mask, guid),
    )


def _samples(output: io.BytesIO) -> tuple[int, int, tuple[int, ...]]:
    output.seek(0)
    with wave.open(output, "rb") as decoded:
        assert decoded.getsampwidth() == 2
        channels = decoded.getnchannels()
        frames = decoded.getnframes()
        samples = struct.unpack(f"<{frames * channels}h", decoded.readframes(frames))
        return decoded.getframerate(), channels, samples


def test_cut_is_half_open_with_half_frame_ties_rounded_up() -> None:
    source = io.BytesIO(_pcm([-32768, 32767, 18, -9, 0, 99]))
    output = io.BytesIO()

    result = edit_pcm_wav(source, output, start_seconds=0.15, end_seconds=0.45)

    assert result == {
        "sample_rate": 10,
        "channels": 1,
        "start_frame": 2,
        "end_frame": 5,
        "frame_count": 3,
        "fade_in_frames": 0,
        "fade_out_frames": 0,
    }
    assert _samples(output) == (10, 1, (18, -9, 0))


def test_stereo_fades_use_shared_gain_with_exact_endpoints_and_signed_rounding() -> None:
    samples = [81, -22, 1, -1, -32768, 32767, 3, 7, 10, 20, 15, -25, -3, 5, 31, 100]
    source = io.BytesIO(_pcm(samples, rate=8, channels=2))
    output = io.BytesIO()

    result = edit_pcm_wav(
        source,
        output,
        start_seconds=0,
        end_seconds=1,
        fade_in_seconds=0.375,
        fade_out_seconds=0.375,
    )

    assert (result["fade_in_frames"], result["fade_out_frames"]) == (3, 3)
    assert _samples(output) == (
        8,
        2,
        (0, 0, 1, -1, -32768, 32767, 3, 7, 10, 20, 15, -25, -2, 3, 0, 0),
    )


def test_adjacent_one_frame_fades_mute_their_frames() -> None:
    source = io.BytesIO(_pcm([32767, -32768], rate=2))
    output = io.BytesIO()

    result = edit_pcm_wav(
        source, output, start_seconds=0, end_seconds=1, fade_in_seconds=0.5, fade_out_seconds=0.5
    )

    assert result["fade_in_frames"] == result["fade_out_frames"] == 1
    assert _samples(output) == (2, 1, (0, 0))


def test_keeps_fade_continuous_across_bounded_io_chunks() -> None:
    class BoundedReader(io.BytesIO):
        def read(self, size: int = -1) -> bytes:
            assert 0 < size <= 64 * 1024
            return super().read(size)

    class BoundedWriter(io.BytesIO):
        def write(self, data: bytes) -> int:
            assert 0 < len(data) <= 64 * 1024
            return super().write(data)

    output = BoundedWriter()
    source = BoundedReader(_pcm([10000, -10000] * 20_001, rate=20_001, channels=2))
    result = edit_pcm_wav(source, output, start_seconds=0, end_seconds=1, fade_in_seconds=1)

    assert result["frame_count"] == result["fade_in_frames"] == 20_001
    rate, channels, samples = _samples(output)
    assert (rate, channels) == (20_001, 2)
    assert samples[:2] == (0, 0)
    assert samples[32766:32770] == (8192, -8192, 8192, -8192)
    assert samples[-2:] == (10000, -10000)


def test_accepts_padded_metadata_and_full_duration_float() -> None:
    source = io.BytesIO(
        _riff(
            _chunk(b"JUNK", b"odd"),
            _format(rate=3, extension=b"\0\0"),
            _chunk(b"data", struct.pack("<5h", 1, 2, 3, 4, 5)),
            _chunk(b"JUNK", b"other metadata"),
        )
    )
    output = io.BytesIO()

    result = edit_pcm_wav(source, output, start_seconds=0, end_seconds=5 / 3)

    assert result["end_frame"] == 5
    assert _samples(output) == (3, 1, (1, 2, 3, 4, 5))


@pytest.mark.parametrize(("channels", "mask"), [(1, 0), (1, 4), (2, 0), (2, 3)])
def test_rewrites_extensible_pcm_as_canonical_pcm(channels: int, mask: int) -> None:
    samples = (-32768, 32767) * channels
    data = struct.pack(f"<{len(samples)}h", *samples)
    source = io.BytesIO(_riff(_extensible(channels=channels, mask=mask), _chunk(b"data", data)))
    output = io.BytesIO()

    result = edit_pcm_wav(source, output, start_seconds=0, end_seconds=0.2)

    assert result["frame_count"] == 2
    assert struct.unpack_from("<IH", output.getvalue(), 16) == (16, 1)
    assert _samples(output) == (10, channels, samples)


@pytest.mark.parametrize(
    ("content", "reason"),
    [
        (b"tiny", "malformed_wav"),
        (_pcm([1, 2, 3])[:-1], "malformed_wav"),
        (_pcm([1, 2, 3]) + b"tail", "malformed_wav"),
        (b"RIFX" + _pcm([1, 2, 3])[4:], "unsupported_wav"),
        (_riff(_format(encoding=3), _chunk(b"data", b"\0\0")), "unsupported_wav"),
        (_riff(_format(encoding=0xFFFE), _chunk(b"data", b"\0\0")), "malformed_wav"),
        (_riff(_extensible(ext_size=21), _chunk(b"data", b"\0\0")), "malformed_wav"),
        (_riff(_extensible(subtype=3), _chunk(b"data", b"\0\0")), "unsupported_wav"),
        (_riff(_extensible(valid_bits=15), _chunk(b"data", b"\0\0")), "unsupported_wav"),
        (_riff(_extensible(mask=2), _chunk(b"data", b"\0\0")), "unsupported_wav"),
        (_riff(_extensible(channels=2, mask=12), _chunk(b"data", bytes(4))), "unsupported_wav"),
        (_riff(_format(bits=24), _chunk(b"data", b"\0\0\0")), "unsupported_wav"),
        (_riff(_format(channels=3), _chunk(b"data", bytes(6))), "unsupported_wav"),
        (_riff(_format(rate=0), _chunk(b"data", b"\0\0")), "malformed_wav"),
        (_riff(_format(alignment=1), _chunk(b"data", b"\0\0")), "malformed_wav"),
        (_riff(_format(channels=2), _chunk(b"data", b"\0\0")), "malformed_wav"),
        (_riff(_format(), _chunk(b"data", b"\0\0"), b"JUNK\x01\0\0\0x"), "malformed_wav"),
        (_riff(_format(), _chunk(b"data", b"\0\0"), _chunk(b"data", b"\0\0")), "malformed_wav"),
        (_riff(_chunk(b"data", b"\0\0"), _format()), "malformed_wav"),
    ],
)
def test_rejects_unsupported_or_malformed_wavs_before_writing(content: bytes, reason: str) -> None:
    output = io.BytesIO()

    with pytest.raises(WavEditError) as caught:
        edit_pcm_wav(io.BytesIO(content), output, start_seconds=0, end_seconds=0.1)

    assert caught.value.reason == reason
    assert output.getvalue() == b""


@pytest.mark.parametrize(
    ("params", "reason"),
    [
        ({"start_seconds": -1}, "invalid_time"),
        ({"start_seconds": True}, "invalid_time"),
        ({"end_seconds": "0.2"}, "invalid_time"),
        ({"end_seconds": math.nan}, "invalid_time"),
        ({"fade_in_seconds": math.inf}, "invalid_time"),
        ({"fade_out_seconds": -0.01}, "invalid_time"),
        ({"start_seconds": 0.2}, "invalid_range"),
        ({"end_seconds": 1.001}, "invalid_range"),
        ({"end_seconds": 0.03}, "invalid_range"),
        ({"fade_in_seconds": 0.21}, "invalid_fades"),
        ({"fade_in_seconds": 0.12, "fade_out_seconds": 0.11}, "invalid_fades"),
        (
            {
                "start_seconds": 0.05,
                "end_seconds": 0.15,
                "fade_in_seconds": 0.05,
                "fade_out_seconds": 0.05,
            },
            "invalid_fades",
        ),
    ],
)
def test_rejects_invalid_time_and_fade_ranges(params: dict, reason: str) -> None:
    source = io.BytesIO(_pcm([0] * 10))
    output = io.BytesIO()
    arguments = {"start_seconds": 0, "end_seconds": 0.2, **params}

    with pytest.raises(WavEditError) as caught:
        edit_pcm_wav(source, output, **arguments)

    assert caught.value.reason == reason
    assert output.getvalue() == b""


def test_refuses_an_oversize_selection_before_writing(monkeypatch) -> None:
    monkeypatch.setattr(_wav_pcm, "MAX_OUTPUT_PCM_BYTES", 8)
    output = io.BytesIO()

    with pytest.raises(WavEditError) as caught:
        edit_pcm_wav(io.BytesIO(_pcm([1] * 5)), output, start_seconds=0, end_seconds=0.5)

    assert caught.value.reason == "edit_too_large"
    assert output.getvalue() == b""
