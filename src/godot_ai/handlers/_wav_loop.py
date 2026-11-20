"""Validate PCM WAV data and rank candidate loop boundaries by waveform continuity."""

from __future__ import annotations

import heapq
import math
import struct
import sys
from array import array
from dataclasses import dataclass
from fractions import Fraction
from io import SEEK_END
from typing import BinaryIO
from uuid import UUID

MAX_SELECTED_PCM_BYTES = 64 * 1024 * 1024
MAX_CANDIDATES = 10
_READ_BYTES = 64 * 1024
_MAX_RIFF_CHUNKS = 4096
_COARSE_POINTS = 128
_REFINEMENT_SEEDS = 32
_RIFF_HEADER = struct.Struct("<4sI4s")
_CHUNK_HEADER = struct.Struct("<4sI")
_PCM_FORMAT = struct.Struct("<HHIIHH")
_EXTENSIBLE_FORMAT = struct.Struct("<HHI16s")
_PCM_SUBTYPE = UUID("00000001-0000-0010-8000-00aa00389b71").bytes_le


class WavLoopError(ValueError):
    """A file or parameter error the tool can report to callers."""

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
            raise WavLoopError("malformed_wav", "The WAV ended before its declared data.")
        parts.extend(part)
    return bytes(parts)


def _read_format(source: BinaryIO, size: int) -> tuple[int, int]:
    if size < _PCM_FORMAT.size:
        raise WavLoopError("malformed_wav", "The WAV format chunk is incomplete.")
    encoding, channels, rate, byte_rate, block_align, bits = _PCM_FORMAT.unpack(
        _read_exact(source, _PCM_FORMAT.size)
    )
    if encoding not in (1, 0xFFFE) or channels not in (1, 2) or bits != 16:
        raise WavLoopError("unsupported_wav", "Use a 16-bit PCM WAV with one or two channels.")
    if encoding == 0xFFFE:
        if size < _PCM_FORMAT.size + _EXTENSIBLE_FORMAT.size:
            raise WavLoopError("malformed_wav", "The WAV extensible format chunk is incomplete.")
        extension_size, valid_bits, mask, subtype = _EXTENSIBLE_FORMAT.unpack(
            _read_exact(source, _EXTENSIBLE_FORMAT.size)
        )
        if extension_size != size - _PCM_FORMAT.size - 2:
            raise WavLoopError("malformed_wav", "The WAV extensible format size is inconsistent.")
        if (
            subtype != _PCM_SUBTYPE
            or valid_bits != 16
            or mask not in (0, 4 if channels == 1 else 3)
        ):
            raise WavLoopError(
                "unsupported_wav",
                "Use a conventional mono or stereo layout with 16 valid PCM bits.",
            )
    elif size != _PCM_FORMAT.size:
        if size != _PCM_FORMAT.size + 2 or _read_exact(source, 2) != b"\0\0":
            raise WavLoopError("malformed_wav", "The WAV PCM format extension is invalid.")
    if rate == 0 or block_align != 2 * channels or byte_rate != rate * block_align:
        raise WavLoopError("malformed_wav", "The WAV frame size or byte rate is inconsistent.")
    return rate, channels


def _read_layout(source: BinaryIO) -> _PcmLayout:
    source.seek(0, SEEK_END)
    file_size = source.tell()
    source.seek(0)
    container, riff_size, form = _RIFF_HEADER.unpack(_read_exact(source, _RIFF_HEADER.size))
    if container != b"RIFF" or form != b"WAVE":
        raise WavLoopError("unsupported_wav", "Use a little-endian RIFF WAV file.")
    riff_end = riff_size + 8
    if riff_end < _RIFF_HEADER.size or riff_end != file_size:
        raise WavLoopError("malformed_wav", "The RIFF size does not match the WAV file size.")

    pcm_format = None
    data = None
    for _ in range(_MAX_RIFF_CHUNKS):
        if source.tell() == riff_end:
            break
        if riff_end - source.tell() < _CHUNK_HEADER.size:
            raise WavLoopError("malformed_wav", "The WAV has an incomplete chunk header.")
        kind, size = _CHUNK_HEADER.unpack(_read_exact(source, _CHUNK_HEADER.size))
        offset = source.tell()
        next_chunk = offset + size + size % 2
        if next_chunk > riff_end:
            raise WavLoopError("malformed_wav", "A WAV chunk runs past the end of the RIFF data.")
        if kind == b"fmt ":
            if pcm_format is not None:
                raise WavLoopError("malformed_wav", "The WAV contains multiple format chunks.")
            pcm_format = _read_format(source, size)
        elif kind == b"data":
            if pcm_format is None or data is not None:
                raise WavLoopError(
                    "malformed_wav", "The WAV needs one data chunk after its format."
                )
            data = offset, size
        source.seek(next_chunk)

    if source.tell() != riff_end:
        raise WavLoopError("edit_too_large", "The WAV contains more than 4096 RIFF chunks.")
    if pcm_format is None or data is None:
        raise WavLoopError("malformed_wav", "The WAV is missing its format or data chunk.")
    layout = _PcmLayout(*pcm_format, *data)
    if layout.data_size % layout.frame_size:
        raise WavLoopError("malformed_wav", "The WAV data ends in a partial PCM frame.")
    return layout


def _seconds(value: float, field: str) -> Fraction:
    if type(value) is int and value >= 0:
        return Fraction(value)
    if type(value) is float and math.isfinite(value) and value >= 0:
        return Fraction(str(value))
    raise WavLoopError("invalid_time", f"{field} must be a finite nonnegative number.")


def _nearest_frame(seconds: Fraction, sample_rate: int) -> int:
    frames = seconds * sample_rate
    return (2 * frames.numerator + frames.denominator) // (2 * frames.denominator)


def _read_selected(
    source: BinaryIO, layout: _PcmLayout, start: int, count: int
) -> tuple[array, ...]:
    source.seek(layout.data_offset + start * layout.frame_size)
    channels = tuple(array("h") for _ in range(layout.channels))
    remaining = count * layout.frame_size
    while remaining:
        size = min(_READ_BYTES, remaining)
        data = _read_exact(source, size)
        if layout.channels == 1:
            channels[0].frombytes(data)
        else:
            block = array("h")
            block.frombytes(data)
            channels[0].extend(block[::2])
            channels[1].extend(block[1::2])
        remaining -= size
    if sys.byteorder != "little":
        for channel in channels:
            channel.byteswap()
    return channels


def _channel_span(channel: array) -> int:
    low, high = channel[0], channel[0]
    block_samples = _READ_BYTES // channel.itemsize
    view = memoryview(channel)
    # Keep each C-level extrema scan short so a worker thread does not
    # hold the interpreter lock across the entire selection.
    for offset in range(0, len(view), block_samples):
        block = view[offset : offset + block_samples]
        low = min(low, min(block))
        high = max(high, max(block))
    return high - low


# score, negative duration, start, end. Equal scores favor longer loops,
# then earlier boundaries, independent of discovery/refinement order.
_RankedPair = tuple[float, int, int, int]


class _SeamSearch:
    def __init__(self, channels: tuple[array, ...], sample_rate: int, min_frames: int) -> None:
        self.count = len(channels[0])
        self.min_frames = max(2, min_frames)
        active = [(channel, _channel_span(channel)) for channel in channels]
        self.active = [(channel, 1.0 / span) for channel, span in active if span]
        radius = max(2, min(128, sample_rate // 250))
        offsets = {1, 2, radius // 2, radius}
        self.offsets = tuple(sorted({0, *offsets, *(-offset for offset in offsets)}))
        self.exclusion_radius = max(1, sample_rate // 200)

    def _rank(self, start: int, end: int) -> _RankedPair:
        offsets = [
            offset for offset in self.offsets if start + offset >= 0 and end + offset < self.count
        ]
        worst_score = 0.0
        for channel, scale in self.active:
            jump = channel[start] - channel[end - 1]
            # Compare the actual wrap step with the original step at each
            # cut. Matching phases can curve sharply at a seamless join.
            step_error = 0.0
            if start > 0:
                step_error = abs(jump - (channel[start] - channel[start - 1]))
            if end < self.count:
                step_error = max(step_error, abs(jump - (channel[end] - channel[end - 1])))
            if start == 0 and end == self.count:
                # The full selection has no samples outside it. Estimate the
                # original step from the neighboring slopes on each side.
                before = channel[end - 1] - channel[end - 2]
                after = channel[start + 1] - channel[start]
                step_error = max(abs(2 * jump - before - after) * 0.25, abs(before - after) * 0.5)
            squared_distance = 0
            for offset in offsets:
                difference = channel[start + offset] - channel[end + offset]
                squared_distance += difference * difference
            # At file/range endpoints no samples may be available on the
            # same side of both cuts. The wrap step and slopes still score it.
            waveform_error = math.sqrt(squared_distance / len(offsets)) if offsets else 0.0
            worst_score = max(worst_score, max(step_error, waveform_error) * scale)
        return worst_score, start - end, start, end

    def _refine(self, pair: _RankedPair, step: int) -> _RankedPair:
        while step > 1:
            step = (step + 1) // 2
            _, _, start, end = pair
            for start_delta, end_delta in (
                (-step, -step),
                (-step, 0),
                (-step, step),
                (0, -step),
                (0, step),
                (step, -step),
                (step, 0),
                (step, step),
            ):
                left, right = start + start_delta, end + end_delta
                if left >= 0 and right <= self.count and right - left >= self.min_frames:
                    pair = min(pair, self._rank(left, right))
        return pair

    def candidates(self, limit: int) -> list[_RankedPair]:
        # A bounded all-pairs coarse search, even for a very long selected
        # range. Refinement uses a fixed number of seeds and log(grid_step)
        # neighborhoods, ending with adjacent one-frame boundaries.
        step = (self.count + _COARSE_POINTS - 2) // (_COARSE_POINTS - 1)
        edges = (*range(0, self.count, step), self.count)
        coarse = (
            self._rank(left, right)
            for left in edges
            for right in edges
            if right - left >= self.min_frames
        )
        seeds = heapq.nsmallest(_REFINEMENT_SEEDS, coarse)
        refined = sorted({self._refine(seed, step) for seed in seeds})
        chosen: list[_RankedPair] = []
        for pair in refined:
            _, _, start, end = pair
            if any(
                abs(start - previous[2]) <= self.exclusion_radius
                and abs(end - previous[3]) <= self.exclusion_radius
                for previous in chosen
            ):
                continue
            chosen.append(pair)
            if len(chosen) == limit:
                break
        return chosen


def find_pcm_wav_loops(
    source_binary_stream: BinaryIO,
    *,
    start_seconds: float | None = None,
    end_seconds: float | None = None,
    min_loop_seconds: float = 0.5,
    max_candidates: int = 3,
) -> dict:
    """Find bounded, deterministic loop suggestions with exclusive end frames."""
    if type(max_candidates) is not int or not 1 <= max_candidates <= MAX_CANDIDATES:
        raise WavLoopError(
            "invalid_max_candidates",
            f"max_candidates must be an integer from 1 to {MAX_CANDIDATES}.",
        )
    minimum = _seconds(min_loop_seconds, "min_loop_seconds")
    if minimum == 0:
        raise WavLoopError("invalid_time", "min_loop_seconds must be greater than zero.")
    start = _seconds(start_seconds, "start_seconds") if start_seconds is not None else Fraction(0)
    end = _seconds(end_seconds, "end_seconds") if end_seconds is not None else None

    layout = _read_layout(source_binary_stream)
    rate = layout.sample_rate
    duration = Fraction(layout.frame_count, rate)
    if end is None:
        end = duration
    # Allow the usual float representation of the exact final frame even
    # when the rational duration rounds up to that float.
    full_empty_range = layout.frame_count == 0 and start_seconds is None and end_seconds is None
    if not full_empty_range and (
        start >= end or (end > duration and end_seconds != float(duration))
    ):
        raise WavLoopError(
            "invalid_range", f"Choose 0 <= start_seconds < end_seconds <= {float(duration):.17g}."
        )
    first = _nearest_frame(start, rate)
    last = _nearest_frame(end, rate)
    frame_count = last - first
    min_frames = math.ceil(minimum * rate)
    if frame_count * layout.frame_size > MAX_SELECTED_PCM_BYTES:
        raise WavLoopError(
            "edit_too_large", "Select at most 64 MiB of PCM audio for loop analysis."
        )

    result = {
        "sample_rate": rate,
        "channels": layout.channels,
        "start_frame": first,
        "end_frame": last,
        "frame_count": frame_count,
        "min_loop_frames": min_frames,
        "candidates": [],
    }
    if frame_count < max(2, min_frames):
        return {**result, "reason": "range_too_short"}
    samples = _read_selected(source_binary_stream, layout, first, frame_count)
    search = _SeamSearch(samples, rate, min_frames)
    if not search.active:
        return {**result, "reason": "silence_or_constant"}

    for score, _, start_frame, end_frame in search.candidates(max_candidates):
        length = end_frame - start_frame
        result["candidates"].append(
            {
                "start_frame": first + start_frame,
                "end_frame": first + end_frame,
                "start_seconds": (first + start_frame) / rate,
                "end_seconds": (first + end_frame) / rate,
                "frame_count": length,
                "duration_seconds": length / rate,
                "seam_error": score,
            }
        )
    return result
