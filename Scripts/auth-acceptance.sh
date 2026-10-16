#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_root="$PWD"
task_temp="$(mktemp -d /private/tmp/GitPier-auth-ui.XXXXXX)"
task_server_pid=""
cleanup() {
  if [[ -n "$task_server_pid" ]]; then kill "$task_server_pid" 2>/dev/null || true; wait "$task_server_pid" 2>/dev/null || true; fi
  rm -rf "$task_temp"
}
trap cleanup EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir "$task_temp/seed"
git -C "$task_temp/seed" init -q -b main
git -C "$task_temp/seed" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit --allow-empty -m fixture
git clone -q --bare "$task_temp/seed" "$task_temp/remote.git"
cat > "$task_temp/openssl.cnf" <<'CONFIG'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=localhost
[ext]
subjectAltName=IP:127.0.0.1,DNS:localhost
CONFIG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$task_temp/openssl.cnf" -keyout "$task_temp/key.pem" -out "$task_temp/cert.pem" >/dev/null 2>&1
/usr/bin/python3 Tests/Fixtures/authenticated-https.py "$task_temp" "$task_temp/cert.pem" "$task_temp/key.pem" "$task_temp/port" &
task_server_pid=$!
for task_attempt in {1..100}; do [[ -f "$task_temp/port" ]] && break; sleep 0.02; done
[[ -f "$task_temp/port" ]] || { echo 'TLS fixture failed to start' >&2; exit 1; }
export GITPIER_AUTH_ACCEPTANCE_URL="https://127.0.0.1:$(cat "$task_temp/port")/remote.git"
export GITPIER_AUTH_ACCEPTANCE_CERT="$task_temp/cert.pem"
export GIT_SSL_CAINFO="$task_temp/cert.pem"
export GITPIER_UI_ACCEPTANCE_LAUNCH_BUNDLE=1
python3 - "$task_temp" "$task_root/dist/GitPier.app/Contents/MacOS/GitPier" <<'PY'
import json, os, pathlib, subprocess, sys, uuid
folder, executable = pathlib.Path(sys.argv[1]), sys.argv[2]
identity = folder / 'ssh-identity'
subprocess.run(['/usr/bin/ssh-keygen','-q','-t','ed25519','-N','','-f',str(identity)], check=True)
ssh_config = folder / 'ssh-config'
ssh_config.write_text('Host fixture.invalid\n HostName 127.0.0.1\n Port 2222\n IdentityFile '+str(identity)+'\n')
identifier = str(uuid.uuid4())
configuration = folder / 'ssh-workspace.json'
profile = dict(id=identifier, name='Synthetic SSH', host='127.0.0.1:2222', username='git', kind='ssh', identityPath=str(identity))
def save():
    configuration.write_text(json.dumps(dict(version=2, repositories=[], credentials=[profile])))
save()
environment = dict(os.environ, GITPIER_CONFIGURATION=str(configuration), GITPIER_BACKGROUND='1')
arguments = [executable, '--ssh-profile', identifier, '-G', '-F', str(ssh_config), '-oBatchMode=yes', '-oStrictHostKeyChecking=yes', '-oNumberOfPasswordPrompts=0', '-oIgnoreUnknown=UseKeychain', '-oUseKeychain=no', 'fixture.invalid']
result = subprocess.run(arguments, env=environment, capture_output=True, timeout=10)
assert result.returncode == 0, 'Packaged SSH profile rejected its matching host/port'
values = dict(line.split(' ',1) for line in result.stdout.decode().splitlines() if ' ' in line)
assert values['hostname'] == '127.0.0.1' and values['port'] == '2222'
assert values['batchmode'] == 'yes' and values['stricthostkeychecking'] == 'true' and values['identitiesonly'] == 'yes'
assert values['identityfile'] == str(identity)
for host in ['other.invalid:2222', '127.0.0.1:2200']:
    profile['host'] = host; save()
    rejected = subprocess.run(arguments, env=environment, capture_output=True, timeout=10)
    assert rejected.returncode != 0, 'Packaged SSH helper accepted a mismatching profile'
print('Packaged SSH helper alias/identity/port/strict background options passed.')
PY
Scripts/workspace-acceptance.sh version144 "${1:-$task_root/.cache/v144-auth/native}"
