"""python3 test_shaping.py — checks the WhisperX → MinutesCore shapes without WhisperX."""
import math
import unittest

from shaping import speaker_turns, timed_words


class TimedWordsTests(unittest.TestCase):
    def test_leading_spaces_reproduce_the_sentence(self):
        segments = [
            {"text": "Hello there.", "words": [
                {"word": "Hello", "start": 0.0, "end": 0.4, "score": 0.91},
                {"word": "there.", "start": 0.5, "end": 0.9, "score": 0.8},
            ]},
            {"text": "Next one", "words": [
                {"word": "Next", "start": 2.0, "end": 2.2, "score": 0.7},
                {"word": "one", "start": 2.3, "end": 2.5, "score": 0.6},
            ]},
        ]
        words = timed_words(segments, "en")
        self.assertEqual("".join(w["text"] for w in words), "Hello there. Next one")
        self.assertEqual(words[0]["confidence"], 0.91)

    def test_unaligned_words_keep_their_text_and_get_times(self):
        segments = [{"text": "It costs 25 euros", "words": [
            {"word": "It", "start": 1.0, "end": 1.1, "score": 0.9},
            {"word": "costs", "start": 1.2, "end": 1.5, "score": 0.9},
            {"word": "25"},
            {"word": "euros", "start": 2.0, "end": 2.4, "score": float("nan")},
        ]}]
        words = timed_words(segments, "en")
        self.assertEqual([w["text"] for w in words], ["It", " costs", " 25", " euros"])
        self.assertEqual((words[2]["start"], words[2]["end"]), (1.5, 2.0))
        self.assertIsNone(words[2]["confidence"])
        self.assertIsNone(words[3]["confidence"])

    def test_rejected_segment_is_spread_over_its_span(self):
        segments = [
            {"text": "OK", "words": [{"word": "OK", "start": 0.0, "end": 0.3, "score": 0.9}]},
            {"text": "₂ ₃", "start": 4.0, "end": 5.0, "words": []},
        ]
        words = timed_words(segments, "en")
        self.assertEqual([w["text"] for w in words], ["OK", " ₂", " ₃"])
        self.assertEqual((words[1]["start"], words[1]["end"]), (4.0, 4.5))

    def test_times_never_run_backwards_or_go_missing(self):
        segments = [{"text": "a b c", "words": [{"word": "a"}, {"word": "b", "start": 3.0, "end": 2.0}, {"word": "c"}]}]
        words = timed_words(segments, "en")
        for w in words:
            self.assertFalse(math.isnan(w["start"]) or math.isnan(w["end"]))
            self.assertLessEqual(w["start"], w["end"])

    def test_languages_without_spaces(self):
        segments = [{"text": "你好", "words": [{"word": "你", "start": 0, "end": 0.2}, {"word": "好", "start": 0.2, "end": 0.4}]}]
        self.assertEqual("".join(w["text"] for w in timed_words(segments, "zh")), "你好")


class SpeakerTurnsTests(unittest.TestCase):
    def test_sorted_and_empty_turns_dropped(self):
        turns = speaker_turns([("SPEAKER_01", 5.0, 6.0), ("SPEAKER_00", 1.0, 2.5), ("SPEAKER_00", 3.0, 3.0)])
        self.assertEqual(turns, [
            {"speaker": "SPEAKER_00", "start": 1.0, "end": 2.5},
            {"speaker": "SPEAKER_01", "start": 5.0, "end": 6.0},
        ])


if __name__ == "__main__":
    unittest.main()
