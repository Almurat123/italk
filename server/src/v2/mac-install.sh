#!/bin/sh
# iTalk agent for macOS: lets your iPhone work on this Mac.
# It downloads a small program (under 1 MB) from __GATEWAY__, checks its checksum, installs it for your user only, and starts it.
# No AI models are downloaded and there are no keys to enter: thinking is done by iTalk's cloud models through your iTalk account.
# Node.js 22.13 or newer is needed; if this Mac has none, the official build is downloaded from nodejs.org and checked against its checksums.
set -eu

GATEWAY="__GATEWAY__"
SUPPORT="${ITALK_AGENT_SUPPORT:-$HOME/Library/Application Support/iTalk Agent}"
APP="$SUPPORT/app"
NODE_HOME="$SUPPORT/node"
BIN="${ITALK_AGENT_BIN:-$HOME/.local/bin}"
say() { printf '%s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "The iTalk agent runs on macOS only."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 13 ] 2>/dev/null || fail "macOS 13 or newer is needed (this Mac has $(sw_vers -productVersion))."
command -v curl >/dev/null 2>&1 || fail "curl is missing."
command -v shasum >/dev/null 2>&1 || fail "shasum is missing."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 1. Node.js
node_ok() { "$1" -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=13)?0:1)' >/dev/null 2>&1; }
NODE=""
for candidate in "$NODE_HOME/bin/node" "$(command -v node 2>/dev/null || true)" /opt/homebrew/bin/node /usr/local/bin/node; do
  if [ -n "$candidate" ] && [ -x "$candidate" ] && node_ok "$candidate"; then NODE="$candidate"; break; fi
done
if [ -z "$NODE" ]; then
  say "1/4  Downloading Node.js (official build, checked against nodejs.org's checksums)…"
  if [ "$(uname -m)" = "arm64" ]; then arch="arm64"; else arch="x64"; fi
  base="${ITALK_NODE_MIRROR:-https://nodejs.org/dist}/latest-v22.x"
  curl -fsSL "$base/SHASUMS256.txt" -o "$tmp/SHASUMS256.txt" || fail "Cannot reach nodejs.org. Install Node 22 from https://nodejs.org and run this again."
  line="$(grep "darwin-$arch.tar.gz" "$tmp/SHASUMS256.txt" | head -1)"
  [ -n "$line" ] || fail "No Node.js build for this Mac was found."
  want="$(printf '%s' "$line" | awk '{print $1}')"; file="$(printf '%s' "$line" | awk '{print $2}')"
  curl -fL --progress-bar "$base/$file" -o "$tmp/node.tgz" || fail "The Node.js download failed."
  got="$(shasum -a 256 "$tmp/node.tgz" | awk '{print $1}')"
  [ "$got" = "$want" ] || fail "The Node.js download did not match its checksum; nothing was installed."
  mkdir -p "$NODE_HOME"
  tar -xzf "$tmp/node.tgz" -C "$NODE_HOME" --strip-components=1
  NODE="$NODE_HOME/bin/node"
else
  say "1/4  Using Node.js at $NODE"
fi

# 2. The program
say "2/4  Downloading the iTalk agent…"
curl -fsSL "$GATEWAY/mac/italk-agent.tgz" -o "$tmp/agent.tgz" || fail "Cannot download the agent from $GATEWAY."
want="$(curl -fsSL "$GATEWAY/mac/italk-agent.tgz.sha256" | awk '{print $1}')"
got="$(shasum -a 256 "$tmp/agent.tgz" | awk '{print $1}')"
[ -n "$want" ] && [ "$got" = "$want" ] || fail "The download did not match its checksum; nothing was installed."
mkdir -p "$SUPPORT"
chmod 700 "$SUPPORT"
rm -rf "$APP.new"
mkdir -p "$APP.new"
tar -xzf "$tmp/agent.tgz" -C "$APP.new"
rm -rf "$APP"
mv "$APP.new" "$APP"

# 3. The command
mkdir -p "$BIN"
cat > "$BIN/italk-agent" <<WRAPPER
#!/bin/sh
exec "$NODE" --disable-warning=ExperimentalWarning "$APP/bin/italk-agent.mjs" "\$@"
WRAPPER
chmod 755 "$BIN/italk-agent"
say "3/4  Installed the command: $BIN/italk-agent"
case ":$PATH:" in *":$BIN:"*) ;; *) say "     (add $BIN to your PATH to run it by name)";; esac

# 4. Start it in the background and show the code that pairs the iPhone
say "4/4  Starting the agent and showing the code to pair your iPhone…"
say ""
if [ "${ITALK_AGENT_NO_SETUP:-0}" = "1" ]; then say "Installed (setup skipped)."; exit 0; fi
# `curl … | sh` leaves nothing on stdin; the pairing question is answered on the keyboard.
if [ -r /dev/tty ]; then exec "$BIN/italk-agent" setup < /dev/tty; fi
exec "$BIN/italk-agent" setup
