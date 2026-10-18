#!/usr/bin/env python3
"""Bind both frozen workers to the verified patched decoder."""
import json
from pathlib import Path
from vendor_sndfile import verified_library, unsigned_image_digest, verify_embedded_decoder
from rebuild_ollama import digest
ROOT=Path(__file__).resolve().parents[1]
if __name__=='__main__':
    library = verified_library()
    expected_image = unsigned_image_digest(library)
    record=dict(library_image_sha256=expected_image, decoder=json.loads((ROOT/'runtime/libsndfile/build.json').read_text()),
        workers={name:digest(ROOT/'asr_server/dist'/name) for name in ('asr_server','offline_diarizer')},
        embedded_decoders={name:verify_embedded_decoder(ROOT/'asr_server/dist'/name, expected_image)
            for name in ('asr_server','offline_diarizer')})
    (ROOT/'runtime/libsndfile/frozen.json').write_text(json.dumps(record,indent=2)+'\n')
