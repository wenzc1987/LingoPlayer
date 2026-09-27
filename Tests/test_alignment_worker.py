import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import tempfile
import subprocess
import json
import wave
import sys

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


class WorkerFailureTests(unittest.TestCase):
    def job(self):
        return {"video": "fixture.mp4", "stream": 1, "ffmpeg": "ffmpeg", "mfa": "mfa", "modelRoot": "/tmp/models", "acousticModel": "english", "pronunciationDictionary": "english", "cues": [
            {"id": "empty", "start": 0, "end": 0, "tokens": []},
            {"id": "good", "start": 1, "end": 2, "tokens": [{"id": 0, "text": "hello", "isWord": True}]}]}

    def runner(self, audio_frames=48000, mfa_status=0):
        def run(command, **kwargs):
            if command[0] == "ffmpeg":
                with wave.open(command[-1], "wb") as audio:
                    audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(16000); audio.writeframes(b"\0\0" * audio_frames)
            else:
                kwargs["stdout"].write("fixture MFA failure: full diagnostics" if mfa_status else "aligned")
                if mfa_status == 0:
                    Path(command[5], "cue_00001.json").write_text(json.dumps({"tiers": {"words": {"entries": [[0.2, 0.6, "hello"]]}}}))
            return subprocess.CompletedProcess(command, mfa_status if command[0] == "mfa" else 0)
        return run

    def test_empty_cue_does_not_abort_valid_cue(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(worker.subprocess, "run", side_effect=self.runner()), patch.object(worker, "prepare_dictionary", return_value=Path("subset.dict")):
            result = worker.run_job(self.job(), Path(directory))
            self.assertIn("empty", result["failures"])
            self.assertEqual(result["words"][0]["cueID"], "good")
            self.assertEqual(len(result["completed"]), 2)

    def test_empty_audio_is_content_failure_without_mfa(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(worker.subprocess, "run", side_effect=self.runner(0)) as mocked:
            result = worker.run_job(self.job(), Path(directory))
            self.assertEqual(len(result["failures"]), 2)
            self.assertEqual(mocked.call_count, 1)

    def test_mfa_nonzero_preserves_stage_and_reason(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(worker.subprocess, "run", side_effect=self.runner(mfa_status=2)), patch.object(worker, "prepare_dictionary", return_value=Path("subset.dict")):
            with self.assertRaisesRegex(RuntimeError, "full diagnostics"):
                worker.run_job(self.job(), Path(directory))
            self.assertEqual(worker.STAGE, "mfa")

    def test_ffmpeg_failure_writes_diagnostic_before_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); job = self.job(); job["ffmpeg"] = "/usr/bin/false"
            request, output = folder / "request.json", folder / "result.json"
            request.write_text(json.dumps(job))
            process = subprocess.run([sys.executable, str(module_path), "--request", str(request), "--output", str(output)], capture_output=True)
            self.assertEqual(process.returncode, 1)
            self.assertEqual(json.loads(output.with_suffix(".error.json").read_text())["stage"], "ffmpeg")
            self.assertTrue(output.with_suffix(".error.log").exists())
            self.assertEqual(list(folder.glob("alignment-*")), [])


if __name__ == "__main__":
    unittest.main()
