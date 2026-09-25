import importlib.util
from pathlib import Path
import unittest

module_path = Path(__file__).resolve().parents[1] / "Sources/LingoPlayer/Resources/alignment_worker.py"
spec = importlib.util.spec_from_file_location("alignment_worker", module_path)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class AlignmentMappingTests(unittest.TestCase):
    def cue(self, words):
        return {"id": "cue-1", "start": 10, "end": 15, "tokens": [{"id": i * 2, "text": word, "isWord": True} for i, word in enumerate(words)]}

    def test_real_spans_are_shifted_to_media_time(self):
        result = worker.map_words(self.cue(["Hello", "world"]), [[0.2, 0.6, "hello"], [0.9, 1.2, "world"]], 10)
        self.assertEqual(result[0]["start"], 10.2)
        self.assertEqual(result[1]["tokenIndex"], 2)
        self.assertEqual(result[1]["end"], 11.2)

    def test_contraction_can_merge_model_spans(self):
        result = worker.map_words(self.cue(["can't"]), [[0, 0.2, "ca"], [0.2, 0.4, "n't"]], 10)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["end"], 10.4)

    def test_mismatch_does_not_fabricate_timing(self):
        with self.assertRaises(ValueError):
            worker.map_words(self.cue(["hello", "world"]), [[0, 0.4, "hello"], [0.4, 0.8, "there"]], 10)

    def test_unknown_word_does_not_become_a_highlight(self):
        with self.assertRaises(ValueError):
            worker.map_words(self.cue(["hello"]), [[0, 0.4, "<unk>"]], 10)

    def test_zero_duration_is_rejected(self):
        with self.assertRaises(ValueError):
            worker.map_words(self.cue(["hello"]), [[0, 0, "hello"]], 10)

    def test_extra_model_word_is_rejected(self):
        with self.assertRaises(ValueError):
            worker.map_words(self.cue(["hello"]), [[0, 0.4, "hello"], [0.4, 0.8, "world"]], 10)


if __name__ == "__main__":
    unittest.main()
