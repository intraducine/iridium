import unittest
from test_manual_build import load

reuse = load('linux_reuse', 'verify-linux-reuse.py')

class LinuxReuseTests(unittest.TestCase):
    def test_only_verified_main_producer_is_accepted(self):
        revision = 'a' * 40
        run = {'event': 'workflow_dispatch', 'head_branch': 'main', 'head_sha': revision,
               'path': '.github/workflows/build-unsigned-ipa.yml',
               'head_repository': {'full_name': 'intraducine/iridium'}}
        jobs = [{'name': 'linux-userland', 'conclusion': 'success'}]
        reuse.validate_run(run, jobs, revision)
        for key, value in [('event', 'pull_request'), ('head_branch', 'untrusted'),
                           ('head_sha', 'b' * 40), ('path', 'other.yml'),
                           ('head_repository', {'full_name': 'other/iridium'})]:
            with self.assertRaises(ValueError):
                reuse.validate_run(dict(run, **{key: value}), jobs, revision)
        with self.assertRaises(ValueError):
            reuse.validate_run(run, [{'name': 'linux-userland', 'conclusion': 'failure'}], revision)
