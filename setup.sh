#!/usr/bin/env bash
set -euo pipefail

# Metadata
PROGRAM="bits"
VERSION="0.1.0"
REPO="https://github.com/amwolff/bits"
REPO_RAW="https://raw.githubusercontent.com/amwolff/bits"

BEGIN_MARKER="# >>> bits begin >>>"
END_MARKER="# <<< bits end <<<"

MODULES=(ssh git shell packages awscli claude playwright)

# Defaults. Precedence is flag > BITS_* environment variable > default.
NAME="${BITS_NAME:-}"
EMAIL="${BITS_EMAIL:-}"
SIGNING_KEY="${BITS_SIGNING_KEY:-}"
KEY_NAME="${BITS_KEY_NAME:-bits}"
PACKAGES="${BITS_PACKAGES:-}"
ONLY="${BITS_MODULES:-}"
SKIP=""

AUTH_KEYS=()
if [[ -n "${BITS_AUTH_KEY:-}" ]]; then
  AUTH_KEYS+=("$BITS_AUTH_KEY")
fi

# Collected separately so flags replace BITS_AUTH_KEY rather than add to it.
AUTH_KEYS_FLAG=()

MODE="host"
TARGET="."
REF="main"
IMAGE="mcr.microsoft.com/devcontainers/go:2-1.26-trixie"
REMOTE_USER="vscode"
VOLUME=""

DRY_RUN=0
UPGRADE=0
PLAYWRIGHT_BROWSERS=0

CHANGES=0

# One work directory for the run: per-file cleanup would not survive a subshell.
WORKDIR="$(mktemp -d)"

# Set while a file is staged, so a failed write leaves no litter in ~/.ssh.
STAGED=""

cleanup() {
  rm -rf "$WORKDIR"
  if [[ -n "$STAGED" ]]; then
    rm -f "$STAGED"
  fi
}
trap cleanup EXIT

# Empty when piped, which is how data_path chooses a checkout over a fetch.
SCRIPT_DIR=""
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Output
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
else
  C_RESET="" C_DIM="" C_GREEN="" C_YELLOW="" C_RED=""
fi

log() {
  local status="$1"
  shift
  local color=""
  case "$status" in
    ok)         color="$C_DIM" ;;
    wrote|set)  color="$C_GREEN" ;;
    dry|skip|warn) color="$C_YELLOW" ;;
    error)      color="$C_RED" ;;
  esac
  printf '%s: %s%-6s%s %s\n' "$PROGRAM" "$color" "$status" "$C_RESET" "$*"
}

die() {
  log error "$*" >&2
  exit 1
}

changed() {
  CHANGES=$((CHANGES + 1))
}

# Helpers
have() {
  command -v "$1" >/dev/null 2>&1
}

# ${2:?...} would print bash's own message with a line number, and reject "".
need() {
  if [[ $# -lt 2 ]]; then
    die "$1 needs a value"
  fi
}

# The exec redirect and explicit exits silence the shell's own "Trace/breakpoint
# trap" report when a wrong-architecture binary dies from a signal.
runs_ok() {
  (
    exec >/dev/null 2>&1
    "$@" || exit 1
    exit 0
  )
}

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif have sudo; then
    sudo "$@"
  else
    die "need root but neither running as root nor able to sudo: $*"
  fi
}

tilde() {
  local path="$1"
  if [[ "$path" == "$HOME"/* ]]; then
    printf '~%s' "${path#"$HOME"}"
  else
    printf '%s' "$path"
  fi
}

mode_of() {
  stat -c '%a' "$1" 2>/dev/null || true
}

# Installs stdin at PATH with MODE, only when content or mode differs. Never
# pipe into this: a pipeline runs it in a subshell and the change count is lost.
write_file() {
  local path="$1" mode="$2" tmp target

  if [[ -d "$path" ]]; then
    die "$(tilde "$path") is a directory, refusing to replace it with a file"
  fi

  tmp="$(mktemp -p "$WORKDIR")"
  cat >"$tmp"

  if [[ -f "$path" ]] && cmp -s "$tmp" "$path" && [[ "$(mode_of "$path")" == "$mode" ]]; then
    log ok "$(tilde "$path")"
    return 0
  fi

  if ((DRY_RUN)); then
    log dry "would write $(tilde "$path") (mode $mode)"
    changed
    return 0
  fi

  # Through a symlink, not over it: rc files often point into a dotfiles repo.
  target="$path"
  if [[ -L "$path" ]]; then
    target="$(readlink -f "$path")"
  fi

  mkdir -p "$(dirname "$target")"
  STAGED="$target.bits.$$"
  # Staged private, then relaxed, so a 600 file is never briefly world-readable.
  (
    umask 077
    cat "$tmp" >"$STAGED"
  )
  chmod "$mode" "$STAGED"
  mv -f "$STAGED" "$target"
  STAGED=""
  log wrote "$(tilde "$path")"
  changed
}

ensure_dir() {
  local path="$1" mode="$2" action="create"

  if [[ -d "$path" ]]; then
    if [[ "$(mode_of "$path")" == "$mode" ]]; then
      log ok "$(tilde "$path")/"
      return 0
    fi
    action="chmod"
  fi

  if ((DRY_RUN)); then
    log dry "would $action $(tilde "$path")/ (mode $mode)"
    changed
    return 0
  fi
  mkdir -p "$path"
  chmod "$mode" "$path"
  log wrote "$(tilde "$path")/ (mode $mode)"
  changed
}

# Exact match, ignoring trailing whitespace and CR: when the guard and the
# rewrite disagreed, one trailing space made the rewrite swallow the file.
marker_count() {
  local file="$1" marker="$2"
  awk -v marker="$marker" '
    {
      line = $0
      sub(/\r$/, "", line)
      sub(/[ \t]+$/, "", line)
    }
    line == marker { n++ }
    END { print n + 0 }
  ' "$file"
}

# Maintains a marked region in a file bits does not own. "#" comments in
# ssh_config, .bashrc and .zshrc alike, so one implementation covers all three.
write_block() {
  local path="$1" mode="$2" body out begins=0 ends=0
  body="$(mktemp -p "$WORKDIR")"
  out="$(mktemp -p "$WORKDIR")"
  cat >"$body"

  if [[ -f "$path" ]]; then
    begins="$(marker_count "$path" "$BEGIN_MARKER")"
    ends="$(marker_count "$path" "$END_MARKER")"
  fi

  # Anything but a clean pair is how content gets lost. Leave the file alone.
  if [[ "$begins" -ne "$ends" ]] || [[ "$begins" -gt 1 ]]; then
    die "$(tilde "$path") has $begins bits begin and $ends end marker(s); fix it by hand"
  fi

  if [[ "$begins" -eq 1 ]]; then
    awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" -v bodyfile="$body" '
      function norm(s) {
        sub(/\r$/, "", s)
        sub(/[ \t]+$/, "", s)
        return s
      }
      norm($0) == begin {
        print
        while ((getline line < bodyfile) > 0) print line
        close(bodyfile)
        inblock = 1
        next
      }
      norm($0) == end { print; inblock = 0; next }
      !inblock { print }
    ' "$path" >"$out"
  else
    if [[ -s "$path" ]]; then
      cat "$path" >"$out"
      if [[ "$(tail -c1 "$path" | wc -l)" -eq 0 ]]; then
        printf '\n' >>"$out"
      fi
      printf '\n' >>"$out"
    fi
    {
      printf '%s\n' "$BEGIN_MARKER"
      cat "$body"
      printf '%s\n' "$END_MARKER"
    } >>"$out"
  fi

  write_file "$path" "$mode" <"$out"
}

# One key at a time: a wholesale rewrite would discard things put there by
# others, such as the credential.helper a VS Code dev container injects.
git_set() {
  local key="$1" value="$2" current
  current="$(git config --global --get "$key" 2>/dev/null || true)"
  if [[ "$current" == "$value" ]]; then
    log ok "git $key"
    return 0
  fi
  if ((DRY_RUN)); then
    log dry "would set git $key"
    changed
    return 0
  fi
  git config --global --replace-all "$key" "$value"
  log set "git $key"
  changed
}

# A checkout beside setup.sh wins, so editing setup/aliases.sh needs no round
# trip through GitHub; otherwise fetch at the ref this script came from.
data_path() {
  local relpath="$1" dest
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/$relpath" ]]; then
    printf '%s' "$SCRIPT_DIR/$relpath"
    return 0
  fi
  if ! have curl; then
    return 1
  fi
  dest="$WORKDIR/$(basename "$relpath")"
  if curl -fsSL "$REPO_RAW/$REF/$relpath" -o "$dest" 2>/dev/null; then
    printf '%s' "$dest"
    return 0
  fi
  return 1
}

selected() {
  local module="$1"
  if [[ -n "$ONLY" && ",$ONLY," != *",$module,"* ]]; then
    return 1
  fi
  if [[ -n "$SKIP" && ",$SKIP," == *",$module,"* ]]; then
    return 1
  fi
  return 0
}

# Prefers the key's own comment field, so repeated --auth-key needs no naming.
key_stem() {
  local comment
  comment="$(printf '%s' "$1" |
    awk '{ $1 = ""; $2 = ""; sub(/^ +/, ""); gsub(/ /, "_"); print }' |
    tr -cd 'A-Za-z0-9._@-')"
  printf '%s' "${comment:-$KEY_NAME}"
}

# Modules
# One mod_<name> per name in MODULES:
#   - log skip "<name> (reason)" when a prerequisite is missing,
#   - answer ((DRY_RUN)) before touching anything,
#   - and write through write_file, write_block, ensure_dir or git_set.
mod_ssh() {
  local ssh_dir="$HOME/.ssh"
  ensure_dir "$ssh_dir" 700

  # ${arr[@]+"${arr[@]}"}: set -u treats an empty array as unset before bash 4.4.
  local key base stem used="" n block
  local -a identities=()
  block="$(mktemp -p "$WORKDIR")"
  for key in ${AUTH_KEYS[@]+"${AUTH_KEYS[@]}"}; do
    base="$(key_stem "$key")"
    stem="$base"
    n=1
    while [[ " $used " == *" $stem "* ]]; do
      n=$((n + 1))
      stem="$base-$n"
    done
    used="$used $stem"
    write_file "$ssh_dir/$stem.pub" 644 <<<"$key"
    # Literal on purpose: ssh expands it, and $HOME would break a shared config.
    # shellcheck disable=SC2088
    identities+=("~/.ssh/$stem.pub")
  done

  # Last on purpose: ssh_config is first-match-wins, so a specific Host wins.
  # Composed, not piped: see write_file.
  {
    printf '%s\n' "Host *"
    local identity
    for identity in ${identities[@]+"${identities[@]}"}; do
      printf '    IdentityFile %s\n' "$identity"
    done
    printf '    IdentitiesOnly yes\n'
  } >"$block"
  write_block "$ssh_dir/config" 600 <"$block"

  if [[ -n "$SIGNING_KEY" && -n "$EMAIL" ]]; then
    write_file "$ssh_dir/allowed_signers" 644 <<<"$EMAIL $SIGNING_KEY"
  fi
}

mod_git() {
  if ! have git; then
    log skip "git (not installed)"
    return 0
  fi

  git_set user.name "$NAME"
  git_set user.email "$EMAIL"

  if [[ -z "$SIGNING_KEY" ]]; then
    log skip "git signing (no --signing-key)"
    return 0
  fi

  git_set gpg.format ssh
  git_set user.signingkey "$SIGNING_KEY"
  git_set commit.gpgsign true
  git_set tag.gpgsign true

  if selected ssh; then
    git_set gpg.ssh.allowedSignersFile "$HOME/.ssh/allowed_signers"
  fi
}

mod_shell() {
  local config_dir="$HOME/.config/bits" aliases composed

  if ! aliases="$(data_path setup/aliases.sh)"; then
    log skip "shell (cannot read setup/aliases.sh)"
    return 0
  fi

  ensure_dir "$config_dir" 755
  composed="$(mktemp -p "$WORKDIR")"

  # Composed, not piped: see write_file.
  {
    cat <<'HEADER'
# Generated by bits from setup/aliases.sh; edits here are lost on the next run.
# Machine-local additions belong in aliases.local.sh, which bits never touches.

HEADER
    cat "$aliases"
    cat <<'FOOTER'

# Local overrides
if [ -f "$HOME/.config/bits/aliases.local.sh" ]; then
  . "$HOME/.config/bits/aliases.local.sh"
fi
FOOTER
  } >"$composed"
  write_file "$config_dir/aliases.sh" 644 <"$composed"

  # Explicit source rather than ~/.bash_aliases, which zsh does not honour.
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    # Do not conjure a .zshrc on a machine that has neither zsh nor one already.
    if [[ "$rc" == *.zshrc && ! -f "$rc" ]] && ! have zsh; then
      continue
    fi
    write_block "$rc" 644 <<'RC'
if [ -f "$HOME/.config/bits/aliases.sh" ]; then
  . "$HOME/.config/bits/aliases.sh"
fi
RC
  done
}

mod_packages() {
  if ! have apt-get; then
    log skip "packages (no apt-get)"
    return 0
  fi

  local packages="$PACKAGES" list
  if [[ -z "$packages" ]]; then
    if ! list="$(data_path setup/packages.txt)"; then
      log skip "packages (cannot read setup/packages.txt)"
      return 0
    fi
    packages="$(sed -e 's/#.*//' "$list" | tr -d '\r' | tr '\n' ' ' | tr -s ' ')"
    packages="${packages# }"
    packages="${packages% }"
  fi
  if [[ -z "${packages// /}" ]]; then
    log ok "packages (none listed)"
    return 0
  fi

  local pkg
  local -a missing=()
  for pkg in $packages; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed'; then
      missing+=("$pkg")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    log ok "packages ($packages)"
    return 0
  fi

  if ((DRY_RUN)); then
    log dry "would install ${missing[*]}"
    changed
    return 0
  fi

  as_root apt-get update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  log wrote "packages (${missing[*]})"
  changed
}

mod_awscli() {
  local healthy=0 version=""
  if have aws && runs_ok aws --version; then
    healthy=1
    version="$(aws --version 2>/dev/null | sed -n 1p)"
  fi

  if ((healthy)) && ! ((UPGRADE)); then
    log ok "awscli ($version)"
    return 0
  fi
  if have aws && ! ((healthy)); then
    log warn "awscli is present but will not run"
  fi

  local arch machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64)  arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *)
      log skip "awscli (unsupported architecture $machine)"
      return 0
      ;;
  esac

  local url="https://awscli.amazonaws.com/awscli-exe-linux-$arch.zip"

  local tool
  for tool in curl unzip; do
    if ! have "$tool"; then
      log skip "awscli (no $tool)"
      return 0
    fi
  done

  if ((DRY_RUN)); then
    log dry "would install awscli from $url"
    changed
    return 0
  fi

  local tmpdir
  tmpdir="$(mktemp -d -p "$WORKDIR")"
  curl -fsSL "$url" -o "$tmpdir/awscliv2.zip"
  unzip -q "$tmpdir/awscliv2.zip" -d "$tmpdir"
  if have aws; then
    as_root "$tmpdir/aws/install" --update
    log wrote "awscli (updated)"
  else
    as_root "$tmpdir/aws/install"
    log wrote "awscli (installed)"
  fi
  changed
}

mod_claude() {
  # The installer drops it in ~/.local/bin, off PATH until the next login shell.
  if { have claude || [[ -x "$HOME/.local/bin/claude" ]]; } && ! ((UPGRADE)); then
    log ok "claude"
    return 0
  fi
  if ! have curl; then
    log skip "claude (no curl)"
    return 0
  fi
  if ((DRY_RUN)); then
    log dry "would install Claude Code"
    changed
    return 0
  fi
  curl -fsSL https://claude.ai/install.sh | bash
  log wrote "claude"
  changed
}

mod_playwright() {
  if ! have npm; then
    log skip "playwright (no npm)"
    return 0
  fi
  if have playwright-cli && ! ((UPGRADE)); then
    log ok "playwright-cli"
  elif ((DRY_RUN)); then
    log dry "would install @playwright/cli"
    changed
  else
    npm install -g @playwright/cli@latest
    log wrote "playwright-cli"
    changed
  fi

  if ((PLAYWRIGHT_BROWSERS)); then
    if ((DRY_RUN)); then
      log dry "would install playwright browsers and skills"
      changed
    else
      playwright-cli install-browser --with-deps --only-shell
      playwright-cli install --skills
      log wrote "playwright browsers and skills"
      changed
    fi
  fi
}

# Devcontainer generation
# Single quotes over printf %q: the result is committed and read by people.
shell_quote() {
  local value="$1"
  if [[ "$value" =~ ^[A-Za-z0-9._/@:=+-]+$ ]]; then
    printf '%s' "$value"
  else
    printf "'%s'" "${value//\'/\'\\\'\'}"
  fi
}

# The flags the generated bits.sh replays, one per line so a changed identity is
# a one-line diff. Already-quoted rather than pairs, so valueless flags fit.
host_args() {
  local -a lines=()
  local key

  if [[ -n "$NAME" ]]; then
    lines+=("--name $(shell_quote "$NAME")")
  fi
  if [[ -n "$EMAIL" ]]; then
    lines+=("--email $(shell_quote "$EMAIL")")
  fi
  for key in ${AUTH_KEYS[@]+"${AUTH_KEYS[@]}"}; do
    lines+=("--auth-key $(shell_quote "$key")")
  done
  if [[ -n "$SIGNING_KEY" ]]; then
    lines+=("--signing-key $(shell_quote "$SIGNING_KEY")")
  fi
  if [[ "$KEY_NAME" != "bits" ]]; then
    lines+=("--key-name $(shell_quote "$KEY_NAME")")
  fi
  if [[ -n "$ONLY" ]]; then
    lines+=("--only $(shell_quote "$ONLY")")
  fi
  if [[ -n "$SKIP_REQUESTED" ]]; then
    lines+=("--skip $(shell_quote "$SKIP_REQUESTED")")
  fi
  if [[ -n "$PACKAGES" ]]; then
    lines+=("--packages $(shell_quote "$PACKAGES")")
  fi
  if ((PLAYWRIGHT_BROWSERS)); then
    lines+=("--playwright-browsers")
  fi

  local out="" line
  for line in ${lines[@]+"${lines[@]}"}; do
    # $'...' because "\n" inside double quotes is the letter n, not a newline.
    out+=$' \\\n  '"$line"
  done
  printf '%s' "$out"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

devcontainer_json() {
  local name="$1"
  cat <<JSON | unexpand -t 2 --first-only
// For format details, see https://aka.ms/devcontainer.json. For config options, see the
// README at: https://github.com/devcontainers/templates/tree/main/src/go .
{
  "name": "$(json_escape "$name")",
  // Or use a Dockerfile or Docker Compose file. More info: https://containers.dev/guide/dockerfile
  "image": "$(json_escape "$IMAGE")",
  "mounts": [
    {
      "source": "$(json_escape "$VOLUME")",
      "target": "/home/$(json_escape "$REMOTE_USER")",
      "type": "volume"
    }
  ],
  // Features to add to the dev container. More info: https://containers.dev/features.
  "features": {
    "ghcr.io/devcontainers/features/node:2": {},
    "ghcr.io/tailscale/codespace/tailscale": {
      "version": "latest"
    }
  },
  // Use 'forwardPorts' to make a list of ports inside the container available locally.
  // "forwardPorts": [],
  // Use 'postCreateCommand' to run commands after the container is created.
  "postCreateCommand": {
    "bits": "bash .devcontainer/bits.sh"
  }
  // Configure tool-specific properties.
  // "customizations": {},
  // Uncomment to connect as root instead. More info: https://aka.ms/dev-containers-non-root.
  // "remoteUser": "root"
}
JSON
}

generate_devcontainer() {
  local dir="$TARGET/.devcontainer"
  local json="$dir/devcontainer.json"
  local script="$dir/bits.sh"
  local name tmp

  if [[ ! -d "$TARGET" ]]; then
    if ((DRY_RUN)); then
      log dry "would create $TARGET/"
      changed
    else
      mkdir -p "$TARGET"
      log wrote "$TARGET/"
      changed
    fi
  fi
  name="$(basename "$(cd "$TARGET" 2>/dev/null && pwd || printf '%s' "$TARGET")")"

  ensure_dir "$dir" 755

  write_file "$script" 755 <<SCRIPT
#!/usr/bin/env bash
# Generated by bits ($REPO). Regenerate with:
#   setup.sh --mode devcontainer --target .
set -euo pipefail

curl -fsSL $REPO_RAW/$REF/setup.sh | bash -s --$(host_args)
SCRIPT

  if [[ -f "$json" ]]; then
    log skip "$(tilde "$json") (exists)"
    cat <<SNIPPET
$PROGRAM:        add to "postCreateCommand": { "bits": "bash .devcontainer/bits.sh" }
$PROGRAM:        add to "mounts": { "source": "$VOLUME", "target": "/home/$REMOTE_USER", "type": "volume" }
SNIPPET
    return 0
  fi

  tmp="$(mktemp -p "$WORKDIR")"
  devcontainer_json "$name" >"$tmp"
  write_file "$json" 644 <"$tmp"
}

# Arguments
usage() {
  local modules="${MODULES[*]}"
  modules="${modules// /,}"

  cat <<USAGE
$PROGRAM setup.sh $VERSION — bootstrap a development environment

Usage:
  setup.sh [options]
  curl -fsSL $REPO_RAW/main/setup.sh | bash -s -- [options]

Identity (flag, else BITS_* environment variable):
  --name NAME           git user.name                       [BITS_NAME]
  --email EMAIL         git user.email                      [BITS_EMAIL]
  --auth-key KEY        SSH public key, repeatable          [BITS_AUTH_KEY]
  --signing-key KEY     SSH public key that signs commits   [BITS_SIGNING_KEY]
  --key-name NAME       filename stem for a key with no     [BITS_KEY_NAME]
                        comment field (default: $KEY_NAME)

Mode:
  --mode host           apply to this machine (default)
  --mode devcontainer   generate .devcontainer/ in --target
  --target DIR          where to generate (default: $TARGET)
  --image IMAGE         devcontainer image
  --remote-user USER    devcontainer user (default: $REMOTE_USER)
  --volume NAME         home volume name
  --ref REF             branch, tag or SHA the generated bits.sh fetches
                        (default: $REF)

Modules ($modules):
  --only a,b            run only these                      [BITS_MODULES]
  --skip a,b            run everything except these
  --packages "a b"      apt packages, overriding            [BITS_PACKAGES]
                        setup/packages.txt
  --playwright-browsers also download playwright browsers

Other:
  --upgrade             reinstall tools that are already present
  --dry-run             report what would change, change nothing
  --list-modules        list module names and exit
  -h, --help            this text
  --version             print version and exit

An SSH key's comment field becomes its filename, so --auth-key "ssh-ed25519 AAAA... <comment>" writes ~/.ssh/<comment>.pub.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)                need "$@"; NAME="$2"; shift 2 ;;
    --email)               need "$@"; EMAIL="$2"; shift 2 ;;
    --auth-key)            need "$@"; AUTH_KEYS_FLAG+=("$2"); shift 2 ;;
    --signing-key)         need "$@"; SIGNING_KEY="$2"; shift 2 ;;
    --key-name)            need "$@"; KEY_NAME="$2"; shift 2 ;;
    --mode)                need "$@"; MODE="$2"; shift 2 ;;
    --target)              need "$@"; TARGET="$2"; shift 2 ;;
    --image)               need "$@"; IMAGE="$2"; shift 2 ;;
    --remote-user)         need "$@"; REMOTE_USER="$2"; shift 2 ;;
    --volume)              need "$@"; VOLUME="$2"; shift 2 ;;
    --ref)                 need "$@"; REF="$2"; shift 2 ;;
    --only)                need "$@"; ONLY="$2"; shift 2 ;;
    --skip)                need "$@"; SKIP="$2"; shift 2 ;;
    --packages)            need "$@"; PACKAGES="$2"; shift 2 ;;
    --playwright-browsers) PLAYWRIGHT_BROWSERS=1; shift ;;
    --upgrade)             UPGRADE=1; shift ;;
    --dry-run)             DRY_RUN=1; shift ;;
    --list-modules)        printf '%s\n' "${MODULES[@]}"; exit 0 ;;
    -h|--help)             usage; exit 0 ;;
    --version)             printf '%s setup.sh %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
    *)                     die "unknown option: $1 (try --help)" ;;
  esac
done

if [[ ${#AUTH_KEYS_FLAG[@]} -gt 0 ]]; then
  AUTH_KEYS=("${AUTH_KEYS_FLAG[@]}")
fi

case "$MODE" in
  host|devcontainer) ;;
  *) die "unknown mode: $MODE (expected host or devcontainer)" ;;
esac

# Validation
# Canonicalise once so validation and selected() agree: "--skip 'a, b'" once
# validated but skipped only a.
ONLY="${ONLY//[[:space:]]/}"
SKIP="${SKIP//[[:space:]]/}"

# read -ra, not an unquoted $(...): that pathname-expands, so --only 's*h' globbed.
IFS=',' read -ra requested_modules <<<"$ONLY,$SKIP"
for module in ${requested_modules[@]+"${requested_modules[@]}"}; do
  if [[ -z "$module" ]]; then
    continue
  fi
  if [[ " ${MODULES[*]} " != *" $module "* ]]; then
    die "unknown module: $module (try --list-modules)"
  fi
done

if [[ -z "$VOLUME" ]]; then
  # Not ${VOLUME:-...}: the closing brace would end the expansion early. Single
  # quotes keep the name literal, for devcontainer.json rather than the shell.
  # shellcheck disable=SC2016
  VOLUME='${localWorkspaceFolderBasename}'"-home-$REMOTE_USER"
fi

# The fallback below appends to SKIP; a generated bits.sh has to replay what was
# asked for, not the fallback, or ssh and git stay off in the container forever.
SKIP_REQUESTED="$SKIP"

# Absent entirely means skip ssh and git; a half-filled set is a mistake.
IDENTITY=0
if [[ -n "$NAME" || -n "$EMAIL" || -n "$SIGNING_KEY" || ${#AUTH_KEYS[@]} -gt 0 ]]; then
  IDENTITY=1
fi

if ((IDENTITY)); then
  missing=()
  if selected ssh && [[ ${#AUTH_KEYS[@]} -eq 0 ]]; then
    missing+=(--auth-key)
  fi
  if selected git; then
    if [[ -z "$NAME" ]]; then
      missing+=(--name)
    fi
    if [[ -z "$EMAIL" ]]; then
      missing+=(--email)
    fi
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "incomplete identity, missing: ${missing[*]}"
  fi
else
  SKIP="${SKIP:+$SKIP,}ssh,git"
  log skip "ssh, git (no identity given)"
fi

# Main

# Every write roots at $HOME, which is what makes HOME=/tmp/x a real rehearsal.
if [[ -z "${GIT_CONFIG_GLOBAL:-}" ]]; then
  # XDG_CONFIG_HOME is ambient and not derived from $HOME: honouring it blindly
  # let a rehearsal write the real config. An explicit GIT_CONFIG_GLOBAL is git's.
  xdg_config="${XDG_CONFIG_HOME:-$HOME/.config}"
  if [[ "$xdg_config" != "$HOME"/* ]]; then
    xdg_config="$HOME/.config"
  fi
  if [[ ! -f "$HOME/.gitconfig" && -f "$xdg_config/git/config" ]]; then
    export GIT_CONFIG_GLOBAL="$xdg_config/git/config"
  else
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
  fi
fi

if [[ "$MODE" == "devcontainer" ]]; then
  generate_devcontainer
else
  for module in "${MODULES[@]}"; do
    if selected "$module"; then
      "mod_$module"
    fi
  done
fi

if [[ $CHANGES -eq 0 ]]; then
  log ok "no changes"
else
  log wrote "$CHANGES change(s)"
fi
