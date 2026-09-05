#!/usr/bin/env bash
#
# Install bb-cli: symlink the executable onto PATH and the man page onto
# MANPATH, then say plainly whether either is actually reachable.
#
# Symlinks rather than copies, so `git pull` upgrades the installed tool and
# `bb-cli docs` can still find the documentation that ships beside the script.
#
#   ./install.sh                       ~/.local/bin + ~/.local/share/man/man1
#   ./install.sh --prefix /usr/local   <prefix>/bin + <prefix>/share/man/man1
#   ./install.sh --bin-dir ~/bin       just the executable
#   ./install.sh --uninstall

# Must run under bash. Kept POSIX and placed before `set -o pipefail`, which is
# the first line dash chokes on: `curl ... | sh` is a common habit, and on
# Debian and Ubuntu /bin/sh is dash, where the failure is "Illegal option -o
# pipefail" at a line number that names neither the cause nor the fix.
if [ -z "${BASH_VERSION:-}" ]; then
    echo "The bb-cli installer needs bash, not sh." >&2
    echo "" >&2
    echo "  curl -fsSL https://raw.githubusercontent.com/jonasporto/bb-cli/main/install.sh | bash" >&2
    echo "" >&2
    exit 1
fi

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

BIN_DIR=""
MAN_DIR=""
PREFIX=""
UNINSTALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)     PREFIX="$2"; shift 2 ;;
        --prefix=*)   PREFIX="${1#*=}"; shift ;;
        --bin-dir)    BIN_DIR="$2"; shift 2 ;;
        --bin-dir=*)  BIN_DIR="${1#*=}"; shift ;;
        --man-dir)    MAN_DIR="$2"; shift 2 ;;
        --man-dir=*)  MAN_DIR="${1#*=}"; shift ;;
        --uninstall)  UNINSTALL=true; shift ;;
        -h|--help)    sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -n "$PREFIX" ]]; then
    [[ -n "$BIN_DIR" ]] || BIN_DIR="${PREFIX}/bin"
    [[ -n "$MAN_DIR" ]] || MAN_DIR="${PREFIX}/share/man/man1"
fi
[[ -n "$BIN_DIR" ]] || BIN_DIR="${HOME}/.local/bin"
[[ -n "$MAN_DIR" ]] || MAN_DIR="${HOME}/.local/share/man/man1"

if [[ "$UNINSTALL" == true ]]; then
    rm -f "${BIN_DIR}/bb-cli" "${MAN_DIR}/bb-cli.1"
    echo -e "${GREEN}✓${NC} Removed ${BIN_DIR}/bb-cli and ${MAN_DIR}/bb-cli.1"
    echo "  Credentials at ~/.config/bb-cli/credentials were left alone."
    echo "  Remove them with: rm -rf ~/.config/bb-cli"
    exit 0
fi

# --- dependencies ----------------------------------------------------------
# Before the bootstrap clone, not after: a machine without jq should be told
# that before it downloads a repository it cannot use yet.
missing=()
for dep in curl jq git; do
    command -v "$dep" > /dev/null 2>&1 || missing+=("$dep")
done

if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}Missing dependencies:${NC} ${missing[*]}"
    echo ""
    if command -v brew > /dev/null 2>&1; then
        echo -e "  ${CYAN}brew install ${missing[*]}${NC}"
    elif command -v apt-get > /dev/null 2>&1; then
        echo -e "  ${CYAN}sudo apt-get install ${missing[*]}${NC}"
    elif command -v dnf > /dev/null 2>&1; then
        echo -e "  ${CYAN}sudo dnf install ${missing[*]}${NC}"
    elif command -v pacman > /dev/null 2>&1; then
        echo -e "  ${CYAN}sudo pacman -S ${missing[*]}${NC}"
    fi
    echo ""
    exit 1
fi

# --- bootstrap: piped from curl, with no checkout to work from --------------
# `curl -fsSL .../install.sh | bash` runs this script with no repository around
# it, so fetch one first. A clone rather than a tarball on purpose: `bb-cli
# upgrade` is `git pull`, and a tarball install would have nothing to pull.
if [[ ! -f "${SRC}/bin/bb-cli" ]]; then
    BB_CLI_REPO="${BB_CLI_REPO:-https://github.com/jonasporto/bb-cli.git}"

    # Where the checkout lands. `~/.bb-cli` is the default because it is the
    # convention for a directory the tool manages rather than one you work in
    # (~/.nvm, ~/.rbenv, ~/.oh-my-zsh). An existing checkout wins over the
    # default, so re-running this never leaves a second copy behind - including
    # for anyone installed at the old ~/llm-tools/bb-cli path.
    if [[ -z "${BB_CLI_HOME:-}" ]]; then
        for candidate in "${HOME}/.bb-cli" "${HOME}/llm-tools/bb-cli"; do
            if [[ -d "${candidate}/.git" ]]; then
                BB_CLI_HOME="$candidate"
                break
            fi
        done
    fi
    BB_CLI_HOME="${BB_CLI_HOME:-${HOME}/.bb-cli}"

    echo ""
    if [[ -d "${BB_CLI_HOME}/.git" ]]; then
        echo "Updating existing checkout at ${BB_CLI_HOME}"
        git -C "$BB_CLI_HOME" pull --ff-only --quiet || {
            echo -e "${RED}Could not update ${BB_CLI_HOME}.${NC} Resolve it there and re-run." >&2
            exit 1
        }
    else
        echo "Cloning ${BB_CLI_REPO}"
        mkdir -p "$(dirname "$BB_CLI_HOME")"
        git clone --quiet "$BB_CLI_REPO" "$BB_CLI_HOME" || {
            echo -e "${RED}Clone failed.${NC}" >&2
            echo "  If the repository is private, clone it yourself first:" >&2
            echo "    git clone git@github.com:jonasporto/bb-cli.git ${BB_CLI_HOME}" >&2
            echo "    ${BB_CLI_HOME}/install.sh" >&2
            exit 1
        }
    fi
    SRC="$BB_CLI_HOME"
fi

echo ""
echo "Installing bb-cli from ${SRC}"
echo ""
echo -e "  ${GREEN}✓${NC} curl, jq and git are present"


# --- executable ------------------------------------------------------------
mkdir -p "$BIN_DIR"
ln -sf "${SRC}/bin/bb-cli" "${BIN_DIR}/bb-cli"
chmod +x "${SRC}/bin/bb-cli"
echo -e "  ${GREEN}✓${NC} ${BIN_DIR}/bb-cli -> ${SRC}/bin/bb-cli"

# --- man page --------------------------------------------------------------
if [[ -f "${SRC}/man/bb-cli.1" ]]; then
    mkdir -p "$MAN_DIR"
    ln -sf "${SRC}/man/bb-cli.1" "${MAN_DIR}/bb-cli.1"
    echo -e "  ${GREEN}✓${NC} ${MAN_DIR}/bb-cli.1"
fi

echo ""

# --- is any of it reachable? -----------------------------------------------
warned=false

case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *)
        warned=true
        echo -e "${YELLOW}!${NC} ${BIN_DIR} is not on your PATH. Add this to your shell profile:"
        echo ""
        echo -e "    ${CYAN}export PATH=\"${BIN_DIR}:\$PATH\"${NC}"
        echo ""
        ;;
esac

if command -v manpath > /dev/null 2>&1; then
    man_root="${MAN_DIR%/man1}"
    case ":$(manpath 2>/dev/null):" in
        *":${man_root}:"*) ;;
        *)
            warned=true
            echo -e "${YELLOW}!${NC} ${man_root} is not on your MANPATH, so \`man bb-cli\` will not find the page."
            echo ""
            echo -e "    ${CYAN}export MANPATH=\"${man_root}:\$MANPATH\"${NC}"
            echo ""
            echo -e "  Or just use ${CYAN}bb-cli man${NC}, which opens the page from the repository."
            echo ""
            ;;
    esac
fi

# --- what next -------------------------------------------------------------
if [[ "$warned" == false ]]; then
    echo -e "${GREEN}Installed.${NC}"
    echo ""
fi

if [[ -f "${HOME}/.config/bb-cli/credentials" ]]; then
    echo "  Credentials already exist. Check them with:"
    echo ""
    echo -e "    ${CYAN}bb-cli status${NC}"
else
    echo "  Next: create an Atlassian API token with the Bitbucket app and five"
    echo "  scopes, then store it."
    echo ""
    echo -e "    ${CYAN}bb-cli docs setup${NC}     what to click, and why those five"
    echo -e "    ${CYAN}bb-cli login${NC}          store the token"
    echo -e "    ${CYAN}bb-cli status${NC}         confirm it works"
fi

echo ""
echo -e "  Using an AI agent? ${CYAN}bb-cli skill install${NC} teaches it this tool"
echo -e "  (or ${CYAN}npx skills add jonasporto/bb-cli${NC}, which works for any agent)."
echo ""
