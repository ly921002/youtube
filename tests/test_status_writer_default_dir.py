import json
import os
import subprocess
from pathlib import Path


def test_status_writer_uses_project_web_status_dir_by_default(tmp_path):
    repo_root = Path('/config/Desktop/youtube')
    script = repo_root / 'status_writer.sh'
    target_dir = repo_root / 'web' / 'status'
    target_dir.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    env.pop('STATUS_DIR', None)
    subprocess.run(['bash', str(script)], check=True, env=env, cwd=str(repo_root))

    status_file = target_dir / 'current_status.json'
    assert status_file.exists(), 'expected status file in project web/status directory'
    data = json.loads(status_file.read_text(encoding='utf-8'))
    assert data['status'] == 'waiting'
