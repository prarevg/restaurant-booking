#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# IAM tokens expire, so this also runs hourly from a root-owned cron entry.
python3 - <<'PY'
import base64
import json
import subprocess
import urllib.request

request = urllib.request.Request(
    'http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token',
    headers={'Metadata-Flavor': 'Google'},
)
with urllib.request.urlopen(request, timeout=10) as response:
    token = json.load(response)['access_token']
subprocess.run(['docker', 'login', '--username', 'iam', '--password-stdin', 'cr.yandex'],
               input=token.encode(), stdout=subprocess.DEVNULL, check=True)
config = {'auths': {'cr.yandex': {'auth': base64.b64encode(('iam:' + token).encode()).decode()}}}
secret = {
    'apiVersion': 'v1', 'kind': 'Secret',
    'metadata': {'name': 'registry-pull', 'namespace': 'booking'},
    'type': 'kubernetes.io/dockerconfigjson',
    'data': {'.dockerconfigjson': base64.b64encode(json.dumps(config).encode()).decode()},
}
subprocess.run(['kubectl', 'apply', '-f', '-'], input=json.dumps(secret).encode(), check=True)
PY
