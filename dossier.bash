# Source from ~/.bashrc (Git Bash) to get cc and a routed `claude`:
#   source /path/to/dossier/dossier.bash
# Set DOSSIER_NO_CLAUDE_SHIM=1 before sourcing to keep plain claude.
DOSSIER_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# The path is baked in because shell snapshots and similar copy functions without variables.
eval "cc() { pwsh -NoProfile -File $(printf '%q' "$DOSSIER_DIR/windows/Invoke-Dossier.ps1") \"\$@\"; }"
if [ -z "$DOSSIER_NO_CLAUDE_SHIM" ]; then
    claude() { cc "$@"; }
fi
