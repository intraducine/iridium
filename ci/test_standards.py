from pathlib import Path
import tempfile
import unittest
from test_manual_build import load

standards = load('standards', 'check-standards.py')

class StandardsTests(unittest.TestCase):
    def test_release_contract_and_workflow_rejections(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / '0.2.0-beta.1.md'
            text = '# Iridium 0.2.0-beta.1\n'
            for heading in standards.HEADINGS:
                text += '\n## ' + heading + '\n\nFixture content.\n'
                if heading == 'Verification':
                    text += 'Source commit: ' + 'a' * 40 + '\nBuild run: https://github.com/intraducine/iridium/actions/runs/1\n'
            path.write_text(text)
            self.assertEqual(standards.release_errors(path), [])
            path.write_text(text.replace('Fixture content.', '[Required: fill in]', 1))
            self.assertTrue(standards.release_errors(path))
            path.write_text(text.replace('## Changes', '## Changes omitted'))
            self.assertTrue(standards.release_errors(path))
            path.write_text(text.replace('a' * 40, 'abcd'))
            self.assertTrue(standards.release_errors(path))
        self.assertTrue(standards.workflow_errors('- uses: actions/checkout@main'))
        self.assertTrue(standards.workflow_errors('on: pull_request_target'))
        self.assertTrue(standards.workflow_errors('token: ${{ secrets.TOKEN }}'))
        self.assertEqual(standards.workflow_errors('- uses: actions/checkout@' + 'a' * 40), [])

    def test_missing_wine_templates_fail_before_build(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for component in ('iridium-wine-ios', 'testrepos/Madeira/wine'):
                directory = root / component
                directory.mkdir(parents=True)
                (directory / 'configure').write_text('wine_fn_config_makefile dlls/example enable_example\n')
            self.assertEqual(len(standards.check(root)), 2)
            for component in ('iridium-wine-ios', 'testrepos/Madeira/wine'):
                target = root / component / 'dlls/example/Makefile.in'
                target.parent.mkdir(parents=True)
                target.write_text('MODULE = example.dll\n')
            self.assertEqual(standards.check(root), [])
