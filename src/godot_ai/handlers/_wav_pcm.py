"""Cut and fade RIFF PCM16 WAV frames using bounded binary I/O."""

from __future__ import annotations

import math
import struct
import sys
from array import array
from dataclasses import dataclass
from fractions import Fraction
from io import SEEK_END
from typing import BinaryIO
from uuid import UUID

MAX_OUTPUT_PCM_BYTES = 64 * 1024 * 1024
_CHUNK_BYTES = 64 * 1024
_MAX_RIFF_CHUNKS = 4096
_RIFF_HEADER = struct.Struct("<4sI4s")
_CHUNK_HEADER = struct.Struct("<4sI")
_PCM_FORMAT = struct.Struct("<HHIIHH")
_EXTENSIBLE_FORMAT = struct.Struct("<HHI16s")
_PCM_SUBTYPE = UUID("00000001-0000-0010-8000-00aa00389b71").bytes_le
_PCM = 1
_EXTENSIBLE = 0xFFFE


class WavEditError(ValueError):
    """A validation failure the tool can report without exposing local paths."""

    def __init__(self, reason: str, message: str) -> None:
        super().__init__(message)
        self.reason = reason


@dataclass(frozen=True, slots=True)
class _PcmLayout:
    sample_rate: int
    channels: int
    data_offset: int
    data_size: int

    @property
    def frame_size(self) -> int:
        return 2 * self.channels

    @property
    def frame_count(self) -> int:
        return self.data_size // self.frame_size


def _read_exact(source: BinaryIO, size: int) -> bytes:
    data = source.read(size)
    if len(data) == size:
        return data
    parts = bytearray(data)
    while len(parts) < size:
        part = source.read(size - len(parts))
        if not part:
            raise WavEditError("malformed_wav", "The WAV ended before its declared data.")
        parts.extend(part)
    return bytes(parts)


def _write_all(output: BinaryIO, data: bytes) -> None:
    remaining = memoryview(data)
    while remaining:
        written = output.write(remaining)
        if not written:
            raise OSError("Could not finish writing WAV data")
        remaining = remaining[written:]


def _read_pcm_format(source: BinaryIO, size: int) -> tuple[int, int]:
    if size < _PCM_FORMAT.size:
        raise WavEditError("malformed_wav", "The WAV format chunk is incomplete.")
    encoding, channels, rate, byte_rate, alignment, bits = _PCM_FORMAT.unpack(
        _read_exact(source, _PCM_FORMAT.size)
    )
    if encoding not in (_PCM, _EXTENSIBLE) or channels not in (1, 2) or bits != 16:
        raise WavEditError(
            "unsupported_wav",
            "Use an uncompressed 16-bit PCM WAV with one or two channels.",
        )
    if encoding == _EXTENSIBLE:
        _check_extensible_format(source, size, channels)
    elif size != _PCM_FORMAT.size:
        # PCM commonly uses the 16-byte format. Also accept WAVEFORMATEX
        # with a zero-byte extension.
        if size != _PCM_FORMAT.size + 2 or _read_exact(source, 2) != b"\0\0":
            raise WavEditError("malformed_wav", "The WAV PCM format extension is invalid.")
    if rate == 0 or alignment != 2 * channels or byte_rate != rate * alignment:
        raise WavEditError("malformed_wav", "The WAV frame size or byte rate is inconsistent.")
    return rate, channels


def _check_extensible_format(source: BinaryIO, size: int, channels: int) -> None:
    if size < _PCM_FORMAT.size + _EXTENSIBLE_FORMAT.size:
        raise WavEditError("malformed_wav", "The WAV extensible format chunk is incomplete.")
    ext_size, valid_bits, speaker_mask, subtype = _EXTENSIBLE_FORMAT.unpack(
        _read_exact(source, _EXTENSIBLE_FORMAT.size)
    )
    if ext_size != size - _PCM_FORMAT.size - 2:
        raise WavEditError("malformed_wav", "The WAV extensible format size is inconsistent.")
    if subtype != _PCM_SUBTYPE or valid_bits != 16:
        raise WavEditError("unsupported_wav", "Use an extensible WAV with 16 valid PCM bits.")
    standard_mask = 0x04 if channels == 1 else 0x03  # Front center, or front left and right.
    if speaker_mask not in (0, standard_mask):
        raise WavEditError("unsupported_wav", "Use a conventional mono or stereo WAV layout.")


def _read_layout(source: BinaryIO) -> _PcmLayout:
    source.seek(0, SEEK_END)
    file_size = source.tell()
    source.seek(0)
    container, riff_size, form = _RIFF_HEADER.unpack(_read_exact(source, _RIFF_HEADER.size))
    if container != b"RIFF" or form != b"WAVE":
        raise WavEditError("unsupported_wav", "Use a little-endian RIFF WAV file.")
    riff_end = riff_size + 8
    if riff_end < _RIFF_HEADER.size or riff_end != file_size:
        raise WavEditError("malformed_wav", "The RIFF size does not match the WAV file size.")

    pcm_format = None
    data = None
    # Seek over data and optional metadata, while checking the bounds of
    # every chunk, even when the selected frames end before a truncated tail.
    for _ in range(_MAX_RIFF_CHUNKS):
        if source.tell() == riff_end:
            break
        if riff_end - source.tell() < _CHUNK_HEADER.size:
            raise WavEditError("malformed_wav", "The WAV has an incomplete chunk header.")
        kind, size = _CHUNK_HEADER.unpack(_read_exact(source, _CHUNK_HEADER.size))
        offset = source.tell()
        next_chunk = offset + size + (size % 2)
        if next_chunk > riff_end:
            raise WavEditError("malformed_wav", "A WAV chunk runs past the end of the RIFF data.")
        if kind == b"fmt ":
            if pcm_format is not None:
                raise WavEditError("malformed_wav", "The WAV contains multiple format chunks.")
            pcm_format = _read_pcm_format(source, size)
        elif kind == b"data":
            if pcm_format is None or data is not None:
                raise WavEditError(
                    "malformed_wav", "The WAV needs one data chunk after its format."
                )
            data = (offset, size)
        source.seek(next_chunk)

    if source.tell() != riff_end:
        raise WavEditError("edit_too_large", "The WAV contains more than 4096 RIFF chunks.")
    if pcm_format is None or data is None:
        raise WavEditError("malformed_wav", "The WAV is missing its format or data chunk.")
    layout = _PcmLayout(*pcm_format, *data)
    if layout.data_size % layout.frame_size:
        raise WavEditError("malformed_wav", "The WAV data ends in a partial PCM frame.")
    return layout


def _seconds(value: float, field: str) -> Fraction:
    if type(value) is int and value >= 0:
        return Fraction(value)
    if type(value) is float and math.isfinite(value) and value >= 0:
        # Use the float's shortest round-trip decimal spelling so a decimal
        # half-frame value is rounded up even when its binary float is below it.
        return Fraction(str(value))
    raise WavEditError("invalid_time", f"{field} must be a finite nonnegative number.")


def _nearest_frame(seconds: Fraction, sample_rate: int) -> int:
    frames = seconds * sample_rate
    return (2 * frames.numerator + frames.denominator) // (2 * frames.denominator)


def _scale_frame(samples: array, first_sample: int, channels: int, gain: int, span: int) -> None:
    for index in range(first_sample, first_sample + channels):
        value = samples[index] * gain
        # Round sample magnitudes to nearest, with half-integer ties away
        # from zero, and restore the sign to keep quantization symmetric.
        rounded = (abs(value) + span // 2) // span
        samples[index] = -rounded if value < 0 else rounded


def _fade_chunk(
    data: bytes,
    first: int,
    count: int,
    channels: int,
    frame_count: int,
    fade_in: int,
    fade_out: int,
) -> bytes:
    end = first + count
    fade_out_start = frame_count - fade_out
    if first >= fade_in and end <= fade_out_start:
        return data

    samples = array("h")
    samples.frombytes(data)
    if sys.byteorder != "little":
        samples.byteswap()
    # The first/last fades include both gain endpoints. A one-frame fade
    # uses the silent endpoint.
    fade_in_span = max(1, fade_in - 1)
    fade_out_span = max(1, fade_out - 1)
    for frame in range(first, min(end, fade_in)):
        _scale_frame(samples, (frame - first) * channels, channels, frame, fade_in_span)
    for frame in range(max(first, fade_out_start), end):
        gain = frame_count - frame - 1
        _scale_frame(samples, (frame - first) * channels, channels, gain, fade_out_span)
    if sys.byteorder != "little":
        samples.byteswap()
    return samples.tobytes()


def edit_pcm_wav(
    source_binary_stream: BinaryIO,
    output_binary_stream: BinaryIO,
    *,
    start_seconds: float,
    end_seconds: float,
    fade_in_seconds: float = 0.0,
    fade_out_seconds: float = 0.0,
) -> dict[str, int]:
    """Write a frame-aligned selection to a fresh output stream."""
    start = _seconds(start_seconds, "start_seconds")
    end = _seconds(end_seconds, "end_seconds")
    fade_in = _seconds(fade_in_seconds, "fade_in_seconds")
    fade_out = _seconds(fade_out_seconds, "fade_out_seconds")

    source = source_binary_stream
    output = output_binary_stream
    layout = _read_layout(source)
    duration = Fraction(layout.frame_count, layout.sample_rate)
    # Accept the usual float spelling of the exact duration, which can be
    # just above the rational boundary for nonterminating frame periods.
    if start >= end or (end > duration and end_seconds != float(duration)):
        raise WavEditError(
            "invalid_range", f"Choose 0 <= start_seconds < end_seconds <= {float(duration):.17g}."
        )
    start_frame = _nearest_frame(start, layout.sample_rate)
    end_frame = _nearest_frame(end, layout.sample_rate)
    frame_count = end_frame - start_frame
    if frame_count <= 0:
        raise WavEditError("invalid_range", "The selection must span at least one sample frame.")

    fade_in_frames = _nearest_frame(fade_in, layout.sample_rate)
    fade_out_frames = _nearest_frame(fade_out, layout.sample_rate)
    if fade_in + fade_out > end - start or fade_in_frames + fade_out_frames > frame_count:
        raise WavEditError(
            "invalid_fades", "The fades must fit inside the selection without overlap."
        )

    data_size = frame_count * layout.frame_size
    if data_size > MAX_OUTPUT_PCM_BYTES:
        raise WavEditError("edit_too_large", "Select at most 64 MiB of PCM audio per edit.")
    _write_all(output, _RIFF_HEADER.pack(b"RIFF", 36 + data_size, b"WAVE"))
    _write_all(output, _CHUNK_HEADER.pack(b"fmt ", _PCM_FORMAT.size))
    _write_all(
        output,
        _PCM_FORMAT.pack(
            _PCM,
            layout.channels,
            layout.sample_rate,
            layout.sample_rate * layout.frame_size,
            layout.frame_size,
            16,
        ),
    )
    _write_all(output, _CHUNK_HEADER.pack(b"data", data_size))

    source.seek(layout.data_offset + start_frame * layout.frame_size)
    frames_per_chunk = _CHUNK_BYTES // layout.frame_size
    for first in range(0, frame_count, frames_per_chunk):
        count = min(frames_per_chunk, frame_count - first)
        data = _read_exact(source, count * layout.frame_size)
        data = _fade_chunk(
            data, first, count, layout.channels, frame_count, fade_in_frames, fade_out_frames
        )
        _write_all(output, data)

    return {
        "sample_rate": layout.sample_rate,
        "channels": layout.channels,
        "start_frame": start_frame,
        "end_frame": end_frame,
        "frame_count": frame_count,
        "fade_in_frames": fade_in_frames,
        "fade_out_frames": fade_out_frames,
    }
