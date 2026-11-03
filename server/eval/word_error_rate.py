"""Word error rate of a Minutes transcript against a reference transcript.

    python3 word_error_rate.py meeting.json reference.txt [more meeting.json …]

`meeting.json` is what `minutes-check --json` writes. `reference.txt` is the reference text in
spoken order. Both sides are lowercased, stripped of punctuation and of fillers ("um",
"mm-hmm") that transcribers keep or drop as they please, and numbers are spelled out, so the
score counts real word mistakes: substitutions + deletions + insertions over reference words.
Speaker labels are ignored here; score_speakers.py scores those.
"""
import json
import re
import sys

FILLERS = {
    "ah", "eh", "er", "erm", "hm", "hmm", "huh", "mhm", "mm", "mmm", "oh", "uh", "uhm", "um",
    "mm-hmm", "hmm-hmm", "uh-huh", "uh-hu", "um-hmm",
}
ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def spell(number):
    if number < 20:
        return [ONES[number]]
    if number < 100:
        return [TENS[number // 10]] + (spell(number % 10) if number % 10 else [])
    if number < 1000:
        return spell(number // 100) + ["hundred"] + (spell(number % 100) if number % 100 else [])
    if number < 1_000_000:
        return spell(number // 1000) + ["thousand"] + (spell(number % 1000) if number % 1000 else [])
    return [str(number)]


def normalize(text):
    text = text.lower().replace("’", "'").replace("%", " percent ").replace("&", " and ")
    words = []
    for token in re.findall(r"[a-z0-9]+(?:['-][a-z0-9]+)*", text):
        if token in FILLERS:
            continue
        if token.isdigit():
            words += spell(int(token))
            continue
        # "remote-control" and "remote control" are the same words.
        words += [part for part in token.split("-") if part and part not in FILLERS]
    return words


def errors(reference, hypothesis):
    """Levenshtein distance over words, one row at a time."""
    previous = list(range(len(hypothesis) + 1))
    for i, ref in enumerate(reference, 1):
        current = [i] + [0] * len(hypothesis)
        for j, hyp in enumerate(hypothesis, 1):
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ref != hyp))
        previous = current
    return previous[-1]


def main(reference_path, meeting_paths):
    reference = normalize(open(reference_path).read())
    for path in meeting_paths:
        meeting = json.load(open(path))
        hypothesis = normalize("".join(word["text"] for word in meeting["words"]))
        count = errors(reference, hypothesis)
        print(f"{path}: WER {count / len(reference):.1%} ({count} errors / {len(reference)} reference words, {len(hypothesis)} transcribed)")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    main(sys.argv[2], [sys.argv[1]] + sys.argv[3:])
