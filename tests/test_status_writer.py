import json
import os
import subprocess
import tempfile
from pathlib import Path


def test_status_writer_creates_json(tmp_path):
    status_dir = tmp_path / 'status'
    status_dir.mkdir()
    env = os.environ.copy()
    env['STATUS_DIR'] = str(status_dir)
    script = Path('/config/Desktop/youtube/status_writer.sh')
    subprocess.run(['bash', str(script)], check=True, env=env)
    status_file = status_dir / 'current_status.json'
    assert status_file.exists()
    data = json.loads(status_file.read_text())
    assert data['status'] == 'waiting'
    assert data['playlist_index'] == 0
