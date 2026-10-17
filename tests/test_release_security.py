import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from check_release_security import check
from vendor_ollama import VERSION, SHA256
from rebuild_ollama import REVISION

class ReleasePolicyTests(unittest.TestCase):
    def test_release_requires_explicit_review(self):
        with self.assertRaises(ValueError): check({'release_approved': False})
    def test_qa_only_still_blocks_an_approval_flag(self):
        with self.assertRaises(ValueError): check({'qa_only': True, 'release_approved': True})
    def test_approval_is_bound_to_exact_runtime(self):
        policy = dict(release_approved=True, reviewed_ollama_version=VERSION, reviewed_ollama_sha256=SHA256, reviewed_security_revision=REVISION)
        check(policy)
        policy['reviewed_ollama_sha256'] = '0' * 64
        with self.assertRaises(ValueError): check(policy)
