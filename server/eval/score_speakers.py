"""Word-level speaker accuracy of a Minutes transcript against a reference RTTM.

    python3 score_speakers.py meeting.json reference.rttm

`meeting.json` is what `minutes-check --json` writes (on-device or with `--server`), so the
words have been through the app's own SpeakerAligner. For each word, the reference speaker is
the RTTM speaker whose segments overlap the word the most; words no reference segment overlaps
are skipped. Hypothesis speakers are mapped one-to-one onto reference speakers to maximise
matches, and the score is matched / scored words. That is how the README's 95.6% (on device,
AMI ES2004a) was measured.
"""
import itertools
import json
import re
import sys


def load_rttm(path):
    segments = []
    for line in open(path):
        fields = line.split()
        if fields and fields[0] == "SPEAKER":
            start, duration = float(fields[3]), float(fields[4])
            segments.append((start, start + duration, fields[7]))
    return segments


def word_speakers(words, utterances):
    """Each utterance is a contiguous run of words whose concatenated text is its text, so walk
    the words consuming one utterance at a time. Matched by text, not time, because word times
    from different engines aren't guaranteed to be monotonic."""
    normalize = lambda text: re.sub(r"\s+", " ", text).strip()
    labels = [None] * len(words)
    i = 0
    for utterance in utterances:
        start, text = i, ""
        while i < len(words) and len(normalize(text)) < len(utterance["text"]):
            text += words[i]["text"]
            i += 1
        if normalize(text) != utterance["text"]:
            raise SystemExit(f"couldn't match utterance {utterance['id']} to words {start}..{i}")
        labels[start:i] = [utterance["speaker"]] * (i - start)
    return labels


def reference_speaker(word, segments):
    best, best_overlap = None, 0.0
    for start, end, speaker in segments:
        overlap = min(word["end"], end) - max(word["start"], start)
        if overlap > best_overlap:
            best, best_overlap = speaker, overlap
    return best


def main(meeting_path, rttm_path):
    meeting = json.load(open(meeting_path))
    segments = load_rttm(rttm_path)
    words = meeting["words"]
    labels = word_speakers(words, meeting["utterances"])
    pairs = []
    for word, label in zip(words, labels):
        reference = reference_speaker(word, segments)
        if label is not None and reference is not None:
            pairs.append((label, reference))

    hypotheses = sorted({h for h, _ in pairs})
    references = sorted({s for _, _, s in segments})
    padded = references + [None] * max(0, len(hypotheses) - len(references))
    best, mapping = -1, {}
    for assignment in itertools.permutations(padded, len(hypotheses)):
        candidate = dict(zip(hypotheses, assignment))
        matched = sum(1 for h, r in pairs if candidate[h] == r)
        if matched > best:
            best, mapping = matched, candidate

    print(f"words: {len(words)}, scored: {len(pairs)} (no reference speaker: {len(words) - len(pairs)})")
    print(f"speakers: {len(hypotheses)} found, {len(references)} in reference")
    print("mapping: " + ", ".join(f"{h}→{mapping[h]}" for h in hypotheses))
    print(f"word-speaker accuracy: {best}/{len(pairs)} = {best / len(pairs):.1%}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
