import numpy as np

from conftest import speech
from verbalog import audio as au
from verbalog import dedup
from verbalog.live import TrackTail, next_utterance
from verbalog.model_types import Segment


def test_wav_roundtrip_and_crash_tolerant_header(tmp_path):
    path = tmp_path / "a.wav"
    data = speech(1.0)
    au.write_wav(path, data)
    assert len(au.read_wav(path)) == len(data)
    # A crash leaves the header claiming fewer bytes than the file holds.
    raw = path.read_bytes()
    path.write_bytes(au.wav_header(0) + raw[au.HEADER_SIZE:])
    assert len(au.read_wav(path)) == len(data)


def test_vad_finds_speech_and_ignores_padding_silence():
    audio = np.concatenate([np.zeros(16000 * 2, np.float32), speech(3.0), np.zeros(16000 * 3, np.float32), speech(1.0, seed=1)])
    regions = au.energy_vad(audio)
    assert len(regions) == 2
    assert abs(regions[0][0] - 2.0) < 0.3 and abs(regions[0][1] - 5.0) < 0.3
    assert au.energy_vad(np.zeros(16000, np.float32)) == []


def test_long_regions_are_split_under_window():
    pieces = au.split_long_region(speech(70.0), 0.0, 70.0)
    assert all(e - s <= 28.0 for s, e in pieces)
    assert pieces[0][0] == 0.0 and pieces[-1][1] == 70.0


def _scene():
    """System speech; the mic hears it through the room 200 ms later, then a local voice."""
    system = np.concatenate([speech(4.0, seed=1), np.zeros(16000 * 4, np.float32)])
    local = speech(3.0, freq=240, seed=2)
    rng = np.random.default_rng(9)
    mic = rng.standard_normal(len(system)).astype(np.float32) * 0.002
    delay = int(0.2 * 16000)
    mic[delay:delay + 16000 * 4] += system[:16000 * 4] * 0.4
    mic[16000 * 5:16000 * 8] += local
    return mic, system


def test_correlation_detects_delayed_echo_not_a_different_voice():
    mic, system = _scene()
    echo = au.slice_seconds(mic, 0.3, 3.5)
    other = au.slice_seconds(mic, 5.2, 7.8)
    assert dedup.max_normalized_correlation(echo, system[:16000 * 5]) > 0.6
    assert dedup.max_normalized_correlation(other, system) < 0.2


def test_remove_echoes_keeps_local_speech_and_silences_echo_for_diarization():
    mic, system = _scene()
    mic_segments = [
        Segment(0.3, 3.5, "the rollout depends on integration", "en"),
        Segment(5.1, 7.9, "d'accord on regarde ça", "fr"),
    ]
    system_segments = [Segment(0.0, 4.0, "the rollout depends on integration", "en")]
    kept, cleaned, removed = dedup.remove_echoes(mic_segments, mic, system_segments, system)
    assert [s.lang for s in kept] == ["fr"]
    assert len(removed) == 1
    assert au.rms_db(au.slice_seconds(cleaned, 0.5, 3.0)) < -100
    assert au.rms_db(au.slice_seconds(cleaned, 5.5, 7.5)) > -30


def test_text_alone_requires_enough_words():
    assert dedup.is_echo(0.0, 1.0, 5) is True
    assert dedup.is_echo(0.0, 1.0, 1) is False  # two people can both say "oui"
    assert dedup.is_echo(0.3, 0.7, 1) is True
    assert dedup.is_echo(0.1, 0.5, 8) is False


def test_live_tail_cuts_on_silence_and_handles_growing_file(tmp_path):
    path = tmp_path / "mic.wav"
    tail = TrackTail("mic", path)
    au.write_wav(path, np.concatenate([np.zeros(16000, np.float32), speech(2.0), np.zeros(16000, np.float32)]))
    tail.read_new()
    start, utterance = next_utterance(tail)
    assert 0.7 < start < 1.1
    assert 1.8 < len(utterance) / 16000 < 2.5
    assert next_utterance(tail) is None
    # New bytes appended to the same file are picked up from where it stopped.
    with open(path, "ab") as fh:
        fh.write((speech(2.0, seed=3) * 32767).astype("<i2").tobytes())
        fh.write(np.zeros(16000, "<i2").tobytes())
    tail.read_new()
    start, _ = next_utterance(tail)
    assert 3.5 < start < 4.1


def test_live_tail_waits_for_end_of_utterance_but_not_forever(tmp_path):
    path = tmp_path / "mic.wav"
    tail = TrackTail("mic", path)
    au.write_wav(path, speech(3.0))
    tail.read_new()
    assert next_utterance(tail) is None  # still talking
    au.write_wav(path, speech(16.0))
    tail.read_new()
    assert next_utterance(tail) is not None
