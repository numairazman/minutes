"""Turns WhisperX output into the shapes MinutesCore decodes (`TimedWord`, `SpeakerTurn` in
Packages/MinutesCore/Sources/MinutesCore/Meeting.swift), so the app's own aligner, summarizer
and exporter run on the result unchanged.

No third-party imports, so it can be tested without WhisperX: python3 test_shaping.py
"""

# WhisperX aligns these per character and joins words without spaces.
LANGUAGES_WITHOUT_SPACES = {"ja", "zh"}


def timed_words(segments, language):
    """Aligned segments → [{text, start, end, confidence}] in spoken order.

    `text` carries its own leading space, as `TimedWord.text` does on device, so concatenating
    words reproduces the sentence. Nothing is dropped: words the aligner couldn't place
    (numbers, symbols, a whole segment of them) keep their text and get interpolated times.
    """
    words = []
    for segment in segments:
        aligned = [w for w in segment.get("words") or [] if str(w.get("word", "")).strip()]
        if not aligned and str(segment.get("text", "")).strip():
            aligned = _spread(segment)
        for w in aligned:
            score = w.get("score")
            words.append({
                "text": str(w["word"]).strip(),
                "start": _number(w.get("start")),
                "end": _number(w.get("end")),
                "confidence": round(float(score), 3) if _number(score) is not None else None,
            })
    _fill_times(words)
    separator = "" if language in LANGUAGES_WITHOUT_SPACES else " "
    for i, w in enumerate(words):
        if i > 0:
            w["text"] = separator + w["text"]
    return words


def speaker_turns(rows):
    """(speaker, start, end) rows from the diarizer → [{speaker, start, end}] sorted by start."""
    turns = [
        {"speaker": str(speaker), "start": round(float(start), 3), "end": round(float(end), 3)}
        for speaker, start, end in rows
        if end > start
    ]
    turns.sort(key=lambda t: (t["start"], t["end"]))
    return turns


def _spread(segment):
    """A segment the aligner rejected outright: spread its words evenly over its time span."""
    tokens = segment["text"].split()
    start = _number(segment.get("start"))
    end = _number(segment.get("end"))
    if start is None or end is None or end <= start:
        return [{"word": t} for t in tokens]
    step = (end - start) / len(tokens)
    return [
        {"word": t, "start": round(start + i * step, 3), "end": round(start + (i + 1) * step, 3)}
        for i, t in enumerate(tokens)
    ]


def _fill_times(words):
    """Missing starts take the previous word's end (or the next known start); missing ends take
    the next known start (or their own start). Times never run backwards."""
    previous_end = 0.0
    for i, w in enumerate(words):
        if w["start"] is None:
            w["start"] = previous_end if i > 0 else _next_known(words, i, "start", 0.0)
        if w["end"] is None:
            w["end"] = max(w["start"], _next_known(words, i + 1, "start", w["start"]))
        w["start"] = max(w["start"], 0.0)
        w["end"] = max(w["end"], w["start"])
        previous_end = w["end"]


def _next_known(words, index, key, default):
    for w in words[index:]:
        if w[key] is not None:
            return w[key]
    return default


def _number(value):
    try:
        value = float(value)
    except (TypeError, ValueError):
        return None
    return None if value != value else value  # NaN
