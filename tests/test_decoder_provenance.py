import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts'))
from rebuild_ollama import digest
from vendor_sndfile import validate_frozen_record

class DecoderProvenanceTests(unittest.TestCase):
    def test_stale_decoder_record_is_rejected_even_with_matching_worker_hashes(self):
        current = json.loads((ROOT/'runtime/libsndfile/build.json').read_text())
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder); (base/'runtime/libsndfile').mkdir(parents=True)
            (base/'runtime/libsndfile/build.json').write_text(json.dumps(current))
            workers={name:base/name for name in ('asr_server','offline_diarizer')}
            for path in workers.values():path.write_bytes(b'test worker')
            record={'library_image_sha256':'verified-image', 'decoder':current,'workers':{name:digest(path) for name,path in workers.items()},
                'embedded_decoders':{name:{'_soundfile_data/libsndfile_arm64.dylib':'verified-image'}for name in workers}}
            with patch('vendor_sndfile.ROOT',base), patch('vendor_sndfile.verified_library'), patch('vendor_sndfile.unsigned_image_digest',return_value='verified-image'):
                validate_frozen_record(record,workers)
                unverified=copy.deepcopy(record);unverified.pop('embedded_decoders')
                with self.assertRaises(ValueError):validate_frozen_record(unverified,workers)
                stale=copy.deepcopy(record); stale['decoder']['patches']['cue-label.patch']='0'*64
                with self.assertRaises(ValueError):validate_frozen_record(stale,workers)
                incomplete=copy.deepcopy(record);incomplete['workers'].pop('offline_diarizer')
                with self.assertRaises(ValueError):validate_frozen_record(incomplete,workers)
                workers['asr_server'].write_bytes(b'changed worker')
                with self.assertRaises(ValueError):validate_frozen_record(record,workers)

    def test_actual_frozen_decoder_rejects_a_different_source_image(self):
        from vendor_sndfile import unsigned_image_digest, verify_embedded_decoder, verified_library
        worker=ROOT/'asr_server/dist/offline_diarizer'
        if not worker.is_file():self.skipTest('Frozen worker is not built yet')
        expected=unsigned_image_digest(verified_library())
        image=verify_embedded_decoder(worker,expected)
        self.assertEqual(set(image),{'_soundfile_data/libsndfile_arm64.dylib'})
        with self.assertRaises(ValueError):verify_embedded_decoder(worker,'0'*64)
