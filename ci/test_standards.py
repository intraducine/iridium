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
