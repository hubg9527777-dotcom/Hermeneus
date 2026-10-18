import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from check_release_security import check, reviewed_components
from vendor_ollama import VERSION, SHA256
from rebuild_ollama import REVISION

class ReleasePolicyTests(unittest.TestCase):
    def test_release_requires_explicit_review(self):
        with self.assertRaises(ValueError): check({'release_approved': False})
    def test_qa_only_still_blocks_an_approval_flag(self):
        with self.assertRaises(ValueError): check({'qa_only': True, 'release_approved': True})
    def test_approval_is_bound_to_exact_runtime(self):
        policy = dict(release_approved=True, **reviewed_components())
        check(policy)
        policy['reviewed_ollama_sha256'] = '0' * 64
        with self.assertRaises(ValueError): check(policy)

    def test_review_rejects_changed_source_decoder_and_ffmpeg(self):
        for key in ('reviewed_source_sha256', 'reviewed_decoder_revision', 'reviewed_decoder_recipe_sha256', 'reviewed_ffmpeg_source_sha256'):
            policy = dict(release_approved=True, **reviewed_components())
            policy[key] = 'changed'
            with self.subTest(key=key), self.assertRaises(ValueError): check(policy)

    def test_unresolved_findings_cannot_be_bypassed_by_approval(self):
        with self.assertRaises(ValueError):
            check(dict(release_approved=True, blockers=['Unresolved finding'], **reviewed_components()))
