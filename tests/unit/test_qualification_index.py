"""Exercise the real, token-scoped local index used by artifact installs."""

import hashlib
import urllib.error
import urllib.parse
import urllib.request

import pytest

from script import release_support as support
from script.qualification_index import retained_index


def wheel_fixture(tmp_path, version="1.0"):
    payload = b"retained qualification bytes"
    name = f"example-{version}-py3-none-any.whl"
    (tmp_path / name).write_bytes(payload)
    return payload, [
        {
            "name": "example",
            "version": version,
            "filename": name,
            "size": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }
    ]


@pytest.mark.parametrize("version", ["1.0", "1.0+cpu"])
def test_index_serves_only_hashed_retained_bytes_and_does_not_log_capability(
    tmp_path, capsys, version
):
    payload, rows = wheel_fixture(tmp_path, version)
    with retained_index(tmp_path, rows) as (index, requested):
        with urllib.request.urlopen(index + "example/") as response:
            listing = response.read().decode()
        assert "#sha256=" + rows[0]["sha256"] in listing
        assert urllib.parse.quote(rows[0]["filename"]) in listing
        # Follow the generated PEP 503 link, including escaped local versions.
        href = listing.split('href="', 1)[1].split('"', 1)[0]
        artifact = urllib.parse.urljoin(index + "example/", href)
        for url in (index + "example/", artifact):
            with urllib.request.urlopen(urllib.request.Request(url, method="HEAD")) as response:
                assert int(response.headers["Content-Length"]) > 0
                assert response.read() == b""
        assert requested == []
        with urllib.request.urlopen(artifact) as response:
            assert response.read() == payload
        assert requested == [rows[0]["filename"]]
        for url in (
            index.replace(index.split("/")[3], "wrong"),
            index + "missing/",
            urllib.parse.urljoin(index, "../files/unknown.whl"),
        ):
            with pytest.raises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(url)
            assert error.value.code == 404
    with pytest.raises(urllib.error.URLError):
        urllib.request.urlopen(index, timeout=1)
    assert capsys.readouterr() == ("", "")


@pytest.mark.parametrize("method", ["GET", "HEAD"])
def test_index_rejects_encoded_path_escape_and_double_decoding(tmp_path, method):
    _payload, rows = wheel_fixture(tmp_path, "1.0+cpu")
    filename = rows[0]["filename"]
    with retained_index(tmp_path, rows) as (index, requested):
        for name in (
            "nested%2f" + filename,
            "..%2f" + filename,
            "..%5c" + filename,
            filename.replace("+", "%252B"),
            filename + "%00",
        ):
            artifact = urllib.parse.urljoin(index, "../files/" + name)
            with pytest.raises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(urllib.request.Request(artifact, method=method))
            assert error.value.code == 404
        assert requested == []


def test_index_rejects_changed_files_before_and_after_startup(tmp_path):
    _payload, rows = wheel_fixture(tmp_path)
    with retained_index(tmp_path, rows) as (index, requested):
        (tmp_path / rows[0]["filename"]).write_bytes(b"replaced")
        artifact = urllib.parse.urljoin(index, "../files/" + rows[0]["filename"])
        with pytest.raises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(artifact)
        assert error.value.code == 409
        assert requested == []
    with pytest.raises(support.ReleaseError, match="differs"):
        with retained_index(tmp_path, rows):
            pytest.fail("mutated index started")


def test_index_rejects_duplicate_filenames(tmp_path):
    _payload, rows = wheel_fixture(tmp_path)
    with pytest.raises(support.ReleaseError, match="duplicate"):
        with retained_index(tmp_path, rows + rows):
            pytest.fail("ambiguous index started")


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("filename", "../escape.whl"),
        ("filename", "nested/escape.whl"),
        ("filename", "encoded%2fescape.whl"),
        ("name", "../escape"),
        ("name", "Not_Normalized"),
        ("size", True),
        ("size", support.MAX_FILE_BYTES + 1),
        ("sha256", "A" * 64),
    ],
)
def test_index_rejects_malformed_artifact_identity(tmp_path, field, value):
    _payload, rows = wheel_fixture(tmp_path)
    rows[0][field] = value
    with pytest.raises(support.ReleaseError, match="identity"):
        with retained_index(tmp_path, rows):
            pytest.fail("malformed index started")


@pytest.mark.parametrize("mutation", ["deleted", "oversized", "same_size", "directory"])
@pytest.mark.parametrize("method", ["GET", "HEAD"])
def test_index_rechecks_bounded_regular_file_for_every_request(tmp_path, mutation, method):
    payload, rows = wheel_fixture(tmp_path)
    target = tmp_path / rows[0]["filename"]
    with retained_index(tmp_path, rows) as (index, requested):
        if mutation in ("deleted", "directory"):
            target.unlink()
            if mutation == "directory":
                target.mkdir()
        else:
            target.write_bytes(b"x" * (len(payload) + (1 if mutation == "oversized" else 0)))
        artifact = urllib.parse.urljoin(index, "../files/" + rows[0]["filename"])
        with pytest.raises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(urllib.request.Request(artifact, method=method))
        assert error.value.code == 409
        assert requested == []


def test_empty_index_is_refused(tmp_path):
    with pytest.raises(support.ReleaseError, match="empty"):
        with retained_index(tmp_path, []):
            pytest.fail("empty index started")
