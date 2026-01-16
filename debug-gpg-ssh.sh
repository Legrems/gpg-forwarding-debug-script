#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-}"
if [[ -z "$HOST" ]]; then
  echo "Usage: $0 <ssh-host-alias>"
  exit 1
fi

SOCKET_DIR="/run/user/$UID/gnupg"

hr() { printf '\n%s\n' "================================================="; }
sec() { printf '\n---- %s ----\n' "$1"; }
ok() { echo "✔ $*"; }
warn() { echo "⚠ $*"; }
fail() { echo "✗ $*"; }

hr
echo "GPG AGENT FORWARDING — VERBOSE DEBUG"
echo "SSH host alias: $HOST"
hr

sec "SSH CONFIG (effective, post-merge)"

ssh -G "$HOST" | sed 's/^/  /'

sec "SSH CONFIG — relevant options"

ssh -G "$HOST" | grep -Ei \
'hostname|user|port|remoteforward|localforward|dynamicforward|streamlocal|exitonforwardfailure|forwardagent' \
|| warn "No relevant options found"

sec "LOCAL: gpg + agent versions"

command -v gpg >/dev/null && gpg --version | head -n 3 || fail "gpg not installed"
command -v gpg-agent >/dev/null && gpg-agent --version | head -n 2 || warn "gpg-agent binary not found"

sec "LOCAL: gpg-agent runtime directories"

gpgconf --list-dirs | sed 's/^/  /'

sec "LOCAL: expected socket directory"

echo "Path: $SOCKET_DIR"
if [[ -d "$SOCKET_DIR" ]]; then
  ok "Directory exists"
else
  fail "Directory missing"
fi

sec "LOCAL: socket presence + permissions"

ls -l "$SOCKET_DIR" || fail "Cannot list socket dir"

for s in S.gpg-agent S.gpg-agent.extra S.gpg-agent.scd S.scdaemon; do
  if [[ -S "$SOCKET_DIR/$s" ]]; then
    ok "$s exists (socket)"
  else
    warn "$s missing"
  fi
done

sec "LOCAL: gpg-agent processes"

pgrep -a gpg-agent || warn "No gpg-agent process found"

sec "LOCAL: agent sanity check"

gpg-connect-agent /bye && ok "Local gpg-agent responds" || fail "Local gpg-agent not responding"

sec "SSH: testing control connection (no shell)"

ssh -O check "$HOST" 2>/dev/null && ok "Existing SSH control connection" || warn "No existing control connection"

sec "SSH: connecting with full TTY"

ssh -tt "$HOST" bash <<EOF
set -euo pipefail

hr() { printf '\n%s\n' "================================================="; }
sec() { printf '\n---- %s ----\n' "\$1"; }
ok() { echo "✔ \$*"; }
warn() { echo "⚠ \$*"; }
fail() { echo "✗ \$*"; }

SOCKET_DIR="/run/user/\$UID/gnupg"

hr
echo "REMOTE SESSION"
hostname
whoami
hr

sec "REMOTE: environment (GPG / SSH)"

env | grep -E 'GPG|SSH' || echo "<none>"

sec "REMOTE: GPG_TTY"

echo "tty: \$(tty)"
if [[ -n "\${GPG_TTY:-}" ]]; then
  ok "GPG_TTY=\$GPG_TTY"
else
  warn "GPG_TTY is NOT set (pinentry will fail)"
fi

sec "REMOTE: socket directory"

if [[ -d "\$SOCKET_DIR" ]]; then
  ok "Socket dir exists"
else
  fail "Socket dir missing"
fi

ls -l "\$SOCKET_DIR" || true

sec "REMOTE: forwarded socket verification"

for s in S.gpg-agent S.gpg-agent.extra S.gpg-agent.scd S.scdaemon; do
  if [[ -S "\$SOCKET_DIR/\$s" ]]; then
    ok "\$s present (forwarded)"
  else
    warn "\$s missing"
  fi
done

sec "REMOTE: listening UNIX sockets (ssh)"

ss -lx | grep gpg-agent || warn "No gpg-agent sockets visible via ss"

sec "REMOTE: gpg-agent processes (should be NONE)"

pgrep -a gpg-agent && warn "Remote gpg-agent RUNNING (conflict)" || ok "No remote gpg-agent"

sec "REMOTE: gpgconf socket paths"

gpgconf --list-dirs | sed 's/^/  /'

sec "REMOTE: gpg-connect-agent (verbose)"

GPG_AGENT_INFO= gpg-connect-agent -v /bye && ok "gpg-connect-agent succeeded" || fail "gpg-connect-agent failed"

sec "REMOTE: test signing (very verbose)"

echo test | gpg \
  --verbose \
  --debug-level guru \
  --clearsign >/tmp/gpg-test.out 2>/tmp/gpg-test.err && ok "Signing succeeded" || warn "Signing failed"

echo
echo "--- gpg stdout ---"
sed 's/^/  /' /tmp/gpg-test.out || true

echo
echo "--- gpg stderr ---"
sed 's/^/  /' /tmp/gpg-test.err || true

hr
echo "REMOTE TEST COMPLETE"
hr
EOF

sec "FINAL INTERPRETATION GUIDE"

cat <<'EOF'
✔ All sockets present + signing works:
  → Forwarding is correct

⚠ Sockets missing remotely:
  → SSH RemoteForward not applied
  → Wrong host alias
  → StreamLocalBindUnlink missing

⚠ gpg-connect-agent fails:
  → Remote gpg-agent running
  → Socket path mismatch
  → Local agent not running

⚠ Signing hangs:
  → Missing GPG_TTY
  → pinentry blocked
  → Wayland/X11 forwarding issue

⚠ Signing fails with 'No secret key':
  → You forwarded wrong socket (need S.gpg-agent, not extra only)
EOF

hr
echo "DEBUG FINISHED"
hr
