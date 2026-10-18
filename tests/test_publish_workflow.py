"""Exercise real local Git commits/tags/pushes; mock only the GitHub boundary."""
import contextlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import publish_v1 as publisher
from verify_release import digest

class PublishWorkflowTests(unittest.TestCase):
    def exercise(self, corrupt=False, resume=False):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory);root=base/'repo';root.mkdir();remote=base/'origin.git';out=base/'attachments';out.mkdir()
            def git(*args):
                return subprocess.check_output(['git',*args],cwd=root,stderr=subprocess.DEVNULL,text=True).strip()
            git('init','-b','main');git('config','user.name','Release Test');git('config','user.email','test@example.invalid')
            subprocess.run(['git','init','--bare',str(remote)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            git('remote','add','origin',str(remote));(root/'README.md').write_text('old')
            git('add','README.md');git('commit','-m','old');old=git('rev-parse','HEAD');git('tag','v1.0.0');git('push','origin','main')
            (root/'README.md').write_text('reviewed security reissue');(root/'VERSION').write_text('1.0.0\n');(root/'BUILD_NUMBER').write_text('2\n')
            names={'Hermeneus-v1.0.0-Full.dmg','Hermeneus-v1.0.0-Source.zip','SECURITY_AUDIT.md','DEPENDENCIES.md','dependency-sbom.json','RELEASE_NOTES.md'}
            for name in names|{'release-manifest.json','SHA256SUMS'}:(out/name).write_text('reviewed fixture')
            manifest={'artifacts':{n:digest(out/n)for n in names}};state={'release':{'draft':True,'assets':[]} if resume else None}
            real_output=publisher.output;real_run=publisher.run
            def output(args):
                if args==['git','remote','get-url','origin']:return 'https://github.com/secure-artifacts/Hermeneus.git'
                return real_output(args)
            def run(args,**kwargs):
                if args[0]!='gh':return real_run(args,**kwargs)
                if args[1:3] in (['release','create'], ['release','upload']):
                    state['release']={'draft':True,'assets':[{'name':n,'digest':'sha256:'+('0'*64 if corrupt else digest(out/n))}for n in names|{'release-manifest.json','SHA256SUMS'}]}
                if args[1:3]==['release','edit'] and '--draft=false' in args:state['release']['draft']=False
                return subprocess.CompletedProcess(args,0)
            with contextlib.ExitStack() as stack:
                for target,value in [('ROOT',root),('output',output),('run',run),('release',lambda:state['release']),
                                     ('source_files',lambda:['README.md','VERSION','BUILD_NUMBER']),('verify',lambda _:manifest)]:
                    stack.enter_context(patch.object(publisher,target,value))
                if corrupt:
                    with self.assertRaisesRegex(ValueError,'digest mismatch'):publisher.publish(out,manifest)
                    self.assertTrue(state['release']['draft'])
                else:
                    publisher.publish(out,manifest);self.assertFalse(state['release']['draft'])
                head=git('rev-parse','HEAD');self.assertNotEqual(head,old)
                self.assertEqual(git('rev-parse','v1.0.0^{}'),head)
                self.assertEqual(git('ls-remote','--heads','origin','main').split()[0],head)
                backups=[x for x in git('tag','--list','v1.0.0-local-backup-*').splitlines() if x]
                self.assertEqual(len(backups),1);self.assertEqual(git('rev-parse',backups[0]),old)
    def test_reissue_tags_new_commit_and_preserves_old_local_tag(self):self.exercise()
    def test_bad_uploaded_digest_keeps_release_private_as_draft(self):self.exercise(corrupt=True)

    def test_retry_completes_a_partial_draft(self):self.exercise(resume=True)
