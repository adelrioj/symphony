#!/bin/sh
# Provisions a throwaway sshd so claude_real_ssh_test.exs can drive a remote turn
# over a real ssh client instead of a shell shim, then runs that test.
#
#   docker run --rm -v "$PWD":/app -w /app -e MIX_ENV=test \
#     -e HEX_HOME=/app/.hexcache -e MIX_HOME=/app/.mixcache \
#     elixir:1.19.5-otp-28 sh test/support/real_ssh_harness.sh
set -eu

PORT=${SYMPHONY_REAL_SSH_PORT:-2222}
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

if ! command -v sshd >/dev/null 2>&1; then
  apt-get update -qq >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server openssh-client >/dev/null
fi
mkdir -p /run/sshd

ssh-keygen -q -t ed25519 -N '' -f "$DIR/host" </dev/null
ssh-keygen -q -t ed25519 -N '' -f "$DIR/client" </dev/null
mkdir -p /root/.ssh && chmod 700 /root/.ssh
cat "$DIR/client.pub" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys "$DIR/client"

# Keyed by HostKeyAlias, matching how the managed path pins the guest's key.
printf 'symphony-realssh %s\n' "$(cut -d' ' -f1,2 < "$DIR/host.pub")" > "$DIR/known_hosts"

# The stub stands in for claude: it proves the prompt arrived intact on stdin and
# emits the two stream-json lines the adapter folds into a Result.
cat > "$DIR/stub-claude" <<'STUB'
#!/bin/sh
cat > ./stub-stdin.txt
printf '%s\n' '{"type":"system","subtype":"init","session_id":"real-ssh-run"}'
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":10,"usage":{"input_tokens":2,"output_tokens":3,"total_tokens":5},"result":"real ssh ok"}'
STUB
chmod 755 "$DIR/stub-claude"
chmod 755 "$DIR"

/usr/sbin/sshd -f /dev/null \
  -o "Port=$PORT" -o "HostKey=$DIR/host" -o "PidFile=$DIR/sshd.pid" \
  -o "PermitRootLogin=prohibit-password" -o "PasswordAuthentication=no" \
  -o "UsePAM=no" -o "AuthorizedKeysFile=/root/.ssh/authorized_keys" \
  -o "StrictModes=no" -o "LogLevel=ERROR"

SYMPHONY_REAL_SSH_HOST=127.0.0.1 \
SYMPHONY_REAL_SSH_PORT="$PORT" \
SYMPHONY_REAL_SSH_USER=root \
SYMPHONY_REAL_SSH_KEY="$DIR/client" \
SYMPHONY_REAL_SSH_KNOWN_HOSTS="$DIR/known_hosts" \
SYMPHONY_REAL_SSH_STUB="$DIR/stub-claude" \
  mix test --include real_ssh test/symphony_elixir/agent/claude_real_ssh_test.exs
