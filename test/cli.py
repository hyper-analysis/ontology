"""Public CLI behavior, documented SQL and Unicode source handling."""
import os
import pathlib
import subprocess
import tempfile

binary = str(pathlib.Path('build/ontology').resolve())

def run(*args, ok=True, env=None):
    result = subprocess.run([binary, *args], encoding='utf-8', capture_output=True, env=env)
    assert (result.returncode == 0) == ok, (args, result.returncode, result.stderr)
    if not ok:
        assert result.stderr.strip(), args
        assert not result.stdout, (args, result.stdout)
    return result

assert run('--version').stdout.strip() == 'ontology 0.1.0'
assert 'Usage:' in run('--help').stdout
run('check', '--root', 'School', 'examples/school.ontology')
run('inspect', 'examples/school.ontology', '--root', 'School')
sql = run('compile', 'examples/school.ontology', '--root', 'School')
assert 'CREATE TABLE' in sql.stdout and 'FOREIGN KEY' in sql.stdout
assert not sql.stderr
assert pathlib.Path('examples/school.sql').read_text().strip() == sql.stdout.strip()
query = run('query', 'examples/school.ontology', 'examples/school.osql', '--root', 'School', '--namespace', 'school_demo')
assert 'CREATE FUNCTION' in query.stdout and 'SELECT' in query.stdout
assert 'Result:' in query.stderr
for args in [
    ('compile', 'examples/school.ontology'),
    ('compile', 'examples/school.ontology', '--root', 'Missing'),
    ('compile', 'missing.ontology', '--root', 'School'),
    ('check', 'examples/school.ontology', '--root'),
    ('check', 'examples/school.ontology', '--root', 'School', '--root', 'School'),
    ('check', 'examples/school.ontology', '--root', 'School', '--namespace', 'foo'),
    ('compile', '--unknown'),
    ('query', 'examples/school.ontology', 'examples/school.osql', '--root', 'School', '--namespace', 'bad-name'),
]:
    run(*args, ok=False)
with tempfile.TemporaryDirectory() as directory:
    model = pathlib.Path(directory) / 'unicode.ontology'
    model.write_text('type Élève = { key nom: string; }; type École = { élèves: Élève[]; };', encoding='utf-8')
    environment = {**os.environ, 'LC_ALL': 'C', 'LANG': 'C'}
    assert 'Élève' in run('check', str(model), '--root', 'École', env=environment).stdout
    bad_query = pathlib.Path(directory) / 'bad.osql'
    bad_query.write_text('select p.missing from root.people as p')
    assert 'missing' in run('query', 'examples/school.ontology', str(bad_query), '--root', 'School', ok=False).stderr
    model.write_text('type Broken = {')
    assert 'unicode.ontology' in run('check', str(model), '--root', 'Broken', ok=False).stderr
print('Verified CLI commands, SQL snapshot, Unicode in a C locale, option errors and diagnostics.')
