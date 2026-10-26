import subprocess
from pathlib import Path
app = subprocess.Popen(['dist/Anyseek.app/Contents/MacOS/Anyseek', '--ui-performance-test'])
try:
    code = app.wait(timeout=90)
    if code: raise SystemExit(code)
except subprocess.TimeoutExpired:
    report = Path('dist/hang-sample.txt')
    subprocess.run(['sample', str(app.pid), '3', '-file', str(report)], timeout=15)
    if report.exists(): print(report.read_text()[:45000], flush=True)
    app.kill()
    app.wait()
    raise SystemExit('Native interaction test timed out')
