#!/usr/bin/env bash
###############################################################################
#  devops-setup.sh
#  DevOps & Cloud Engineering Tools — Setup / Update / Upgrade / Revert
#
#  Made by @sharadverma638
#
#  Features:
#    - 44 curated DevOps/Cloud tools across 7 logical categories
#    - Browse categories (multi-select) with full tool descriptions
#    - Custom selection — pick any individual tools across categories
#    - Quick Install Everything — one shot, all categories
#    - Per-category "quick install all" or "one-by-one" choice
#    - After each category: continue to next or exit, your choice
#    - Full REVERT mode — undo any previous run
#    - Built-in Help screen with full script info
#    - Robust error handling, colorful terminal UI
#
#  Usage:
#    chmod +x devops-setup.sh
#    ./devops-setup.sh              interactive menu
#    ./devops-setup.sh --run        go straight to category browsing
#    ./devops-setup.sh --revert     go straight to revert mode
#    ./devops-setup.sh --help       show help and exit
###############################################################################

set -uo pipefail   # (not -e on purpose: errors are handled per-command)

# ----------------------------------------------------------------------------
# Colors & symbols
# ----------------------------------------------------------------------------
readonly C_RESET=$'\033[0m'
readonly C_BOLD=$'\033[1m'
readonly C_DIM=$'\033[2m'
readonly C_RED=$'\033[0;31m'
readonly C_GREEN=$'\033[0;32m'
readonly C_YELLOW=$'\033[0;33m'
readonly C_BLUE=$'\033[0;34m'
readonly C_CYAN=$'\033[0;36m'
readonly C_MAGENTA=$'\033[0;35m'

readonly ICON_OK="${C_GREEN}✔${C_RESET}"
readonly ICON_FAIL="${C_RED}✘${C_RESET}"
readonly ICON_WARN="${C_YELLOW}⚠${C_RESET}"
readonly ICON_INFO="${C_BLUE}ℹ${C_RESET}"

# ----------------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------------
LOG_FILE="/tmp/devops-setup-$(date +%Y%m%d-%H%M%S).log"
STATE_DIR="/var/lib/devops-setup"
BACKUP_DIR="/var/backups/devops-setup"
STATE_FILE=""

SUDO=""
AUTO_YES=false
REPO_JUST_ADDED=false
APT_CACHE_REFRESHED=false
LAST_KUBECTL_BACKUP=""

# ----------------------------------------------------------------------------
# Logging & UI helpers
# ----------------------------------------------------------------------------
log() { echo -e "$(date '+%H:%M:%S') | $*" >> "$LOG_FILE"; }

say()      { echo -e "$*"; log "$*"; }
info()     { say "  ${ICON_INFO}  ${C_CYAN}$*${C_RESET}"; }
success()  { say "  ${ICON_OK}  ${C_GREEN}$*${C_RESET}"; }
warn()     { say "  ${ICON_WARN}  ${C_YELLOW}$*${C_RESET}"; }
error()    { say "  ${ICON_FAIL}  ${C_RED}$*${C_RESET}"; }

hr() { printf '%*s\n' "${COLUMNS:-70}" '' | tr ' ' '─'; }

banner() {
    clear 2>/dev/null || true
    echo -e "${C_BOLD}${C_MAGENTA}"
    cat <<'EOF'
  ____              ___
 |  _ \  _____   __/ _ \ _ __  ___
 | | | |/ _ \ \ / / | | | '_ \/ __|
 | |_| |  __/\ V /| |_| | |_) \__ \
 |____/ \___| \_/  \___/| .__/|___/
                         |_|   Setup & Upgrade Assistant
EOF
    echo -e "${C_RESET}"
    echo -e "  ${C_DIM}Made by ${C_RESET}${C_BOLD}${C_MAGENTA}@sharadverma638${C_RESET}"
    hr
    echo -e "  ${C_DIM}Log file: $LOG_FILE${C_RESET}"
    hr
}

section() {
    echo
    echo -e "${C_BOLD}${C_BLUE}▶ $*${C_RESET}"
    hr
}

print_list() {
    local title="$1"; local color="$2"; shift 2
    local -a items=("$@")
    if [[ ${#items[@]} -gt 0 ]]; then
        echo -e "  ${color}${title} (${#items[@]}):${C_RESET} ${items[*]}"
    fi
}

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    if [[ "$AUTO_YES" == "true" ]]; then
        say "  ${ICON_INFO}  ${prompt} ${C_DIM}(auto-yes, quick install mode)${C_RESET}"
        return 0
    fi
    local hint="[y/N]"
    [[ "$default" == "y" ]] && hint="[Y/n]"
    local reply
    while true; do
        read -rp "$(echo -e "  ${C_YELLOW}?${C_RESET} ${prompt} ${hint} ")" reply
        reply="${reply:-$default}"
        case "$reply" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "  Please answer y or n." ;;
        esac
    done
}

parse_number_list() {
    echo "$1" | tr ',' ' ' | tr -s ' ' '\n' | grep -E '^[0-9]+$'
}

print_help() {
    cat <<EOF
Usage: $0 [OPTION]

Options:
  --run       Go straight to category browsing (skips the menu)
  --revert    Go straight to revert mode (skips the menu)
  -h, --help  Show this help message

With no options, an interactive menu is shown.

Every install/upgrade is logged to:
  $STATE_DIR/state-<timestamp>.log
so it can be undone later with --revert.

Made by @sharadverma638
EOF
}

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------
preflight_checks() {
    section "Pre-flight checks"

    if ! command -v apt-get &>/dev/null; then
        error "This script requires an apt-based distro (Debian/Ubuntu)."
        exit 1
    fi
    success "apt-based distribution detected"

    if [[ $EUID -eq 0 ]]; then
        SUDO=""
        success "Running as root"
    elif command -v sudo &>/dev/null; then
        SUDO="sudo"
        info "Not root — will use 'sudo' for privileged commands"
        if ! sudo -v; then
            error "Could not obtain sudo privileges. Aborting."
            exit 1
        fi
    else
        error "Not running as root and 'sudo' is not installed. Aborting."
        exit 1
    fi

    if command -v curl &>/dev/null; then
        if ! curl -fsS --max-time 5 https://deb.debian.org >/dev/null 2>&1 \
           && ! curl -fsS --max-time 5 https://google.com >/dev/null 2>&1; then
            warn "Could not verify internet connectivity. Continuing anyway..."
        else
            success "Internet connectivity OK"
        fi
    fi

    $SUDO mkdir -p "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null || true
}

init_state() {
    STATE_FILE="$STATE_DIR/state-$(date +%Y%m%d-%H%M%S).log"
    $SUDO touch "$STATE_FILE" 2>/dev/null || STATE_FILE="/tmp/$(basename "$STATE_FILE")"
    touch "$STATE_FILE" 2>/dev/null || true
    info "Recording actions to: $STATE_FILE"
}

record_action() {
    local line="$1"
    echo "$line" | $SUDO tee -a "$STATE_FILE" >/dev/null 2>&1 || echo "$line" >> "$STATE_FILE"
}

refresh_apt_cache_once() {
    [[ "$APT_CACHE_REFRESHED" == "true" ]] && return
    section "Refresh package index"
    if confirm "Run 'apt-get update' to refresh package lists?" "y"; then
        if $SUDO apt-get update -y >>"$LOG_FILE" 2>&1; then
            success "Package index refreshed"
        else
            error "Failed to refresh package index. Check $LOG_FILE"
        fi
    else
        warn "Skipped apt-get update — version checks may be inaccurate"
    fi
    APT_CACHE_REFRESHED=true
}

# ----------------------------------------------------------------------------
# Category & tool registry
# ----------------------------------------------------------------------------
CATEGORY_IDS=(foundation cloud containers iac cicd security productivity)

declare -A CATEGORY_TITLES=(
    [foundation]="Foundation Tools"
    [cloud]="Cloud Provider CLIs"
    [containers]="Containers & Kubernetes"
    [iac]="Infrastructure as Code & Config Management"
    [cicd]="CI/CD & Version Control"
    [security]="Monitoring & Security"
    [productivity]="Productivity Extras"
)

declare -A CATEGORY_DESC=(
    [foundation]="Everyday CLI basics almost every engineer needs — safe to install first."
    [cloud]="Command-line tools to manage resources on major cloud providers."
    [containers]="Build, run, and manage containers and Kubernetes clusters."
    [iac]="Define infrastructure and automate server configuration as code."
    [cicd]="Work with Git repos, pull requests, and pipelines from the terminal."
    [security]="Scan for vulnerabilities, leaked secrets, and shell script issues."
    [productivity]="Optional terminal quality-of-life upgrades — not essential, just nice."
)

declare -A CATEGORY_TOOLS=(
    [foundation]="git curl wget unzip vim tmux htop jq yq tree gnupg openssh make nettools dnsutils"
    [cloud]="awscli azurecli gcloud doctl"
    [containers]="docker dockercompose podman kubectl helm k9s kind dive lazydocker"
    [iac]="terraform packer vagrant ansible"
    [cicd]="gh gitlfs act"
    [security]="trivy shellcheck gitleaks stern argocd"
    [productivity]="ripgrep fzf bat ncdu"
)

# tool_info: LABEL|METHOD|P1|P2|DESCRIPTION
#   APT       -> P1=apt package name          P2=(unused)
#   APT_REPO  -> P1=apt package name          P2=repo key (hashicorp/github-cli/trivy/google-cloud)
#   GH_BIN    -> P1=github "owner/repo"       P2=version check args
#   SPECIAL   -> P1,P2 unused, handled by its own function
tool_info() {
    case "$1" in
        git)        echo "git|APT|git||Distributed version control system — tracks code changes and enables team collaboration." ;;
        curl)       echo "curl|APT|curl||Command-line tool to transfer data and call APIs/URLs." ;;
        wget)       echo "wget|APT|wget||Simple command-line tool to download files from the web." ;;
        unzip)      echo "unzip|APT|unzip||Extracts .zip archive files." ;;
        vim)        echo "vim|APT|vim||Powerful terminal-based text editor." ;;
        tmux)       echo "tmux|APT|tmux||Terminal multiplexer — keeps sessions running after you disconnect." ;;
        htop)       echo "htop|APT|htop||Interactive, real-time process and resource monitor." ;;
        jq)         echo "jq|APT|jq||Command-line JSON processor — parse and filter JSON output." ;;
        yq)         echo "yq|GH_BIN|mikefarah/yq|--version|Command-line YAML processor — like jq, but for YAML files." ;;
        tree)       echo "tree|APT|tree||Displays a directory's contents as a visual tree." ;;
        gnupg)      echo "gnupg|APT|gnupg||Encryption & signing toolkit — needed to securely add software repos." ;;
        openssh)    echo "openssh-client|APT|openssh-client||ssh/scp client — connect to and copy files to remote servers." ;;
        make)       echo "make|APT|make||Runs build/automation steps defined in a Makefile." ;;
        nettools)   echo "net-tools|APT|net-tools||Classic networking commands (ifconfig, netstat, route)." ;;
        dnsutils)   echo "dnsutils|APT|dnsutils||DNS lookup tools (dig, nslookup) for troubleshooting." ;;

        awscli)     echo "aws-cli|SPECIAL|||Official AWS command-line tool — manage AWS resources from the terminal." ;;
        azurecli)   echo "azure-cli|SPECIAL|||Official Microsoft Azure command-line tool." ;;
        gcloud)     echo "gcloud|APT_REPO|google-cloud-cli|google-cloud|Official Google Cloud command-line tool." ;;
        doctl)      echo "doctl|GH_BIN|digitalocean/doctl|version|Official DigitalOcean command-line tool." ;;

        docker)         echo "docker|APT|docker.io||Build, run, and manage containers." ;;
        dockercompose)  echo "docker-compose|APT|docker-compose||Define and run multi-container Docker apps with one file." ;;
        podman)         echo "podman|APT|podman||Daemonless, rootless alternative to Docker for running containers." ;;
        kubectl)        echo "kubectl|SPECIAL|||Official Kubernetes command-line tool — control and inspect clusters." ;;
        helm)           echo "helm|GH_BIN|helm/helm|version --short|Package manager for Kubernetes — install/upgrade apps as 'charts'." ;;
        k9s)            echo "k9s|GH_BIN|derailed/k9s|version --short|Terminal UI to browse and manage a Kubernetes cluster visually." ;;
        kind)           echo "kind|GH_BIN|kubernetes-sigs/kind|version|Runs a local Kubernetes cluster inside Docker — great for testing." ;;
        dive)           echo "dive|GH_BIN|wagoodman/dive|--version|Explores Docker image layers to find ways to shrink image size." ;;
        lazydocker)     echo "lazydocker|GH_BIN|jesseduffield/lazydocker|--version|Terminal UI for managing Docker containers, images, and volumes." ;;

        terraform)  echo "terraform|APT_REPO|terraform|hashicorp|Define and provision cloud infrastructure as code." ;;
        packer)     echo "packer|APT_REPO|packer|hashicorp|Automates building machine images (e.g. AMIs) from code." ;;
        vagrant)    echo "vagrant|APT_REPO|vagrant|hashicorp|Spins up reproducible local development VMs from code." ;;
        ansible)    echo "ansible|APT|ansible||Automates server configuration and app deployment over SSH." ;;

        gh)         echo "gh|APT_REPO|gh|github-cli|Official GitHub CLI — manage repos, pull requests, and issues from the terminal." ;;
        gitlfs)     echo "git-lfs|APT|git-lfs||Git extension for versioning large files without bloating the repo." ;;
        act)        echo "act|GH_BIN|nektos/act|--version|Runs your GitHub Actions workflows locally to test them before pushing." ;;

        trivy)      echo "trivy|APT_REPO|trivy|trivy|Scans container images and code for known vulnerabilities." ;;
        shellcheck) echo "shellcheck|APT|shellcheck||Static analysis tool that finds bugs in your shell scripts." ;;
        gitleaks)   echo "gitleaks|GH_BIN|gitleaks/gitleaks|version|Scans git repositories for accidentally committed secrets/API keys." ;;
        stern)      echo "stern|GH_BIN|stern/stern|--version|Tails logs from multiple Kubernetes pods at once, live." ;;
        argocd)     echo "argocd|GH_BIN|argoproj/argo-cd|version --client --short|CLI for ArgoCD — manage GitOps deployments to Kubernetes." ;;

        ripgrep)    echo "ripgrep|APT|ripgrep||Extremely fast recursive text/code search (the 'rg' command)." ;;
        fzf)        echo "fzf|APT|fzf||Fuzzy finder — interactively search files, history, or any list." ;;
        bat)        echo "bat|APT|bat||A 'cat' replacement with syntax highlighting and line numbers." ;;
        ncdu)       echo "ncdu|APT|ncdu||Interactive disk usage analyzer for the terminal." ;;

        *) echo "" ;;
    esac
}

# ----------------------------------------------------------------------------
# Summary tracking
# ----------------------------------------------------------------------------
declare -a SUMMARY_INSTALLED=()
declare -a SUMMARY_UPGRADED=()
declare -a SUMMARY_SKIPPED=()
declare -a SUMMARY_FAILED=()
declare -a SUMMARY_UPTODATE=()

declare -a REVERT_OK=()
declare -a REVERT_FAILED=()
declare -a REVERT_SKIPPED=()
declare -a REVERT_MANUAL=()

print_summary() {
    section "Summary"
    print_list "Installed"          "$C_GREEN"  "${SUMMARY_INSTALLED[@]}"
    print_list "Upgraded"           "$C_GREEN"  "${SUMMARY_UPGRADED[@]}"
    print_list "Already up-to-date" "$C_CYAN"   "${SUMMARY_UPTODATE[@]}"
    print_list "Skipped"            "$C_YELLOW" "${SUMMARY_SKIPPED[@]}"
    print_list "Failed"             "$C_RED"    "${SUMMARY_FAILED[@]}"
    hr
    [[ -n "$STATE_FILE" ]] && echo -e "  ${C_DIM}State saved to: $STATE_FILE  (use Revert to undo)${C_RESET}"
    echo -e "  ${C_DIM}Full log: $LOG_FILE${C_RESET}"
    hr
    if [[ ${#SUMMARY_FAILED[@]} -gt 0 ]]; then
        warn "Some tools failed — check the log for details."
    else
        success "All done!"
    fi
}

# ----------------------------------------------------------------------------
# apt status helpers + generic apt handler
# ----------------------------------------------------------------------------
check_apt_status() {
    local pkg="$1"
    if ! dpkg -s "$pkg" &>/dev/null; then echo "missing"; return; fi
    local upgradable
    upgradable=$($SUDO apt list --upgradable 2>/dev/null | grep -c "^${pkg}/")
    if [[ "$upgradable" -gt 0 ]]; then echo "upgradable"; else echo "up-to-date"; fi
}
get_installed_version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || echo "unknown"; }
get_candidate_version()  { apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}'; }

process_apt_package() {
    local label="$1" pkg="$2"
    echo
    echo -e "  ${C_BOLD}${label}${C_RESET} ${C_DIM}(${pkg})${C_RESET}"
    local status; status=$(check_apt_status "$pkg")

    case "$status" in
        missing)
            warn "Not installed"
            if confirm "Install ${label}?" "y"; then
                if $SUDO apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1; then
                    success "${label} installed ($(get_installed_version "$pkg"))"
                    SUMMARY_INSTALLED+=("$label")
                    record_action "INSTALL|${label}|apt|${pkg}|"
                else
                    error "Failed to install ${label}. See $LOG_FILE"
                    SUMMARY_FAILED+=("$label")
                fi
            else
                warn "Skipped ${label}"; SUMMARY_SKIPPED+=("$label")
            fi
            ;;
        upgradable)
            local cur new
            cur=$(get_installed_version "$pkg")
            new=$(get_candidate_version "$pkg")
            warn "Outdated  (installed: ${cur}  →  available: ${new})"
            if confirm "Upgrade ${label}?" "y"; then
                if $SUDO apt-get install --only-upgrade -y "$pkg" >>"$LOG_FILE" 2>&1; then
                    success "${label} upgraded to $(get_installed_version "$pkg")"
                    SUMMARY_UPGRADED+=("$label")
                    record_action "UPGRADE|${label}|apt|${pkg}|${cur}"
                else
                    error "Failed to upgrade ${label}. See $LOG_FILE"
                    SUMMARY_FAILED+=("$label")
                fi
            else
                warn "Skipped upgrading ${label}"; SUMMARY_SKIPPED+=("$label")
            fi
            ;;
        up-to-date)
            success "Already up to date ($(get_installed_version "$pkg"))"
            SUMMARY_UPTODATE+=("$label")
            ;;
    esac
}

# ----------------------------------------------------------------------------
# Repo-backed apt tools (terraform/packer/vagrant, gh, trivy, gcloud)
# ----------------------------------------------------------------------------
add_hashicorp_repo() {
    if [[ -f /etc/apt/sources.list.d/hashicorp.list ]]; then REPO_JUST_ADDED=false; return 0; fi
    REPO_JUST_ADDED=true
    $SUDO apt-get install -y gnupg curl lsb-release \
      && curl -fsSL https://apt.releases.hashicorp.com/gpg | $SUDO gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
      && echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
         | $SUDO tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
}

add_github_cli_repo() {
    local list=/etc/apt/sources.list.d/github-cli.list
    if [[ -f "$list" ]]; then REPO_JUST_ADDED=false; return 0; fi
    REPO_JUST_ADDED=true
    $SUDO apt-get install -y gnupg curl \
      && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | $SUDO tee /usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null \
      && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         | $SUDO tee "$list" >/dev/null
}

add_trivy_repo() {
    local list=/etc/apt/sources.list.d/trivy.list
    if [[ -f "$list" ]]; then REPO_JUST_ADDED=false; return 0; fi
    REPO_JUST_ADDED=true
    $SUDO apt-get install -y gnupg curl \
      && curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | $SUDO gpg --dearmor -o /usr/share/keyrings/trivy-archive-keyring.gpg \
      && echo "deb [signed-by=/usr/share/keyrings/trivy-archive-keyring.gpg] https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" \
         | $SUDO tee "$list" >/dev/null
}

add_google_cloud_repo() {
    local list=/etc/apt/sources.list.d/google-cloud-sdk.list
    if [[ -f "$list" ]]; then REPO_JUST_ADDED=false; return 0; fi
    REPO_JUST_ADDED=true
    $SUDO apt-get install -y gnupg curl \
      && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | $SUDO gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
      && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
         | $SUDO tee "$list" >/dev/null
}

process_repo_apt_tool() {
    local label="$1" pkg="$2" repo_key="$3"
    local list="" key="" setup_fn=""
    case "$repo_key" in
        hashicorp)    list=/etc/apt/sources.list.d/hashicorp.list;        key=/usr/share/keyrings/hashicorp-archive-keyring.gpg;   setup_fn=add_hashicorp_repo ;;
        github-cli)   list=/etc/apt/sources.list.d/github-cli.list;       key=/usr/share/keyrings/githubcli-archive-keyring.gpg;   setup_fn=add_github_cli_repo ;;
        trivy)        list=/etc/apt/sources.list.d/trivy.list;            key=/usr/share/keyrings/trivy-archive-keyring.gpg;       setup_fn=add_trivy_repo ;;
        google-cloud) list=/etc/apt/sources.list.d/google-cloud-sdk.list; key=/usr/share/keyrings/cloud.google.gpg;                setup_fn=add_google_cloud_repo ;;
    esac

    if ! dpkg -s "$pkg" &>/dev/null && [[ ! -f "$list" ]]; then
        info "Setting up the ${repo_key} repository for ${label}..."
        if ! "$setup_fn" >>"$LOG_FILE" 2>&1; then
            warn "Could not set up the ${repo_key} repository (network issue?) — skipping ${label}"
            SUMMARY_SKIPPED+=("$label")
            return
        fi
        $SUDO apt-get update -y >>"$LOG_FILE" 2>&1
    fi

    process_apt_package "$label" "$pkg"

    if [[ "$REPO_JUST_ADDED" == "true" ]]; then
        record_action "REPO_ADDED|${repo_key}-repo|repo|${list}|${key}"
        REPO_JUST_ADDED=false
    fi
}

# ----------------------------------------------------------------------------
# Generic GitHub-release binary installer (helm, k9s, kind, dive, lazydocker,
# yq, doctl, gitleaks, stern, argocd, act)
# ----------------------------------------------------------------------------
install_github_binary() {
    local repo="$1" final_name="$2"
    local release_json url fname tmp bin_path

    release_json=$(curl -fsSL --max-time 15 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null)
    [[ -z "$release_json" ]] && return 1

    url=$(echo "$release_json" \
        | grep -oE '"browser_download_url": *"[^"]+"' \
        | sed -E 's/.*"(https[^"]+)"/\1/' \
        | grep -i 'linux' \
        | grep -iE 'amd64|x86_64' \
        | grep -viE 'arm|\.sha256|\.sha256sum|\.asc|\.sig|\.txt|\.pem' \
        | head -n1)
    [[ -z "$url" ]] && return 1

    tmp=$(mktemp -d) || return 1
    fname=$(basename "$url")

    if ! curl -fsSL --max-time 90 "$url" -o "${tmp}/${fname}" >>"$LOG_FILE" 2>&1; then
        rm -rf "$tmp"; return 1
    fi

    case "$fname" in
        *.tar.gz|*.tgz)
            tar -xzf "${tmp}/${fname}" -C "$tmp" >>"$LOG_FILE" 2>&1
            bin_path=$(find "$tmp" -maxdepth 3 -type f -name "$final_name" | head -n1)
            ;;
        *.zip)
            ( cd "$tmp" && unzip -q "$fname" ) >>"$LOG_FILE" 2>&1
            bin_path=$(find "$tmp" -maxdepth 3 -type f -name "$final_name" | head -n1)
            ;;
        *)
            bin_path="${tmp}/${fname}"
            ;;
    esac

    if [[ -z "${bin_path:-}" || ! -f "$bin_path" ]]; then
        rm -rf "$tmp"; return 1
    fi

    chmod +x "$bin_path"
    if $SUDO mv "$bin_path" "/usr/local/bin/${final_name}" >>"$LOG_FILE" 2>&1; then
        rm -rf "$tmp"; return 0
    else
        rm -rf "$tmp"; return 1
    fi
}

process_github_tool() {
    local label="$1" repo="$2" version_args="$3"
    local final_name="$label"

    echo
    echo -e "  ${C_BOLD}${label}${C_RESET} ${C_DIM}(${repo})${C_RESET}"

    local latest_tag
    latest_tag=$(curl -fsSL --max-time 15 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
                 | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    if [[ -z "$latest_tag" ]]; then
        warn "Could not reach GitHub to check ${label} — skipping"
        SUMMARY_SKIPPED+=("$label"); return
    fi

    local installed_ver=""
    if command -v "$final_name" &>/dev/null; then
        local -a vargs
        IFS=' ' read -ra vargs <<< "$version_args"
        installed_ver=$("$final_name" "${vargs[@]}" 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    fi

    local latest_clean="${latest_tag#v}"
    local installed_clean="${installed_ver#v}"

    if [[ -z "$installed_ver" ]]; then
        warn "Not installed  (latest available: ${latest_tag})"
        if confirm "Install ${label} ${latest_tag}?" "y"; then
            if install_github_binary "$repo" "$final_name"; then
                success "${label} ${latest_tag} installed"
                SUMMARY_INSTALLED+=("$label")
                record_action "INSTALL|${label}|binary|/usr/local/bin/${final_name}|"
            else
                error "Failed to install ${label}. See $LOG_FILE"
                SUMMARY_FAILED+=("$label")
            fi
        else
            warn "Skipped ${label}"; SUMMARY_SKIPPED+=("$label")
        fi
    elif [[ "$installed_clean" != "$latest_clean" ]]; then
        warn "Outdated  (installed: ${installed_ver}  →  available: ${latest_tag})"
        if confirm "Upgrade ${label} to ${latest_tag}?" "y"; then
            local backup=""
            if [[ -f "/usr/local/bin/${final_name}" ]]; then
                backup="$BACKUP_DIR/${final_name}.$(date +%Y%m%d%H%M%S)"
                $SUDO cp "/usr/local/bin/${final_name}" "$backup" 2>>"$LOG_FILE" || backup=""
            fi
            if install_github_binary "$repo" "$final_name"; then
                success "${label} upgraded to ${latest_tag}"
                SUMMARY_UPGRADED+=("$label")
                record_action "UPGRADE|${label}|binary|/usr/local/bin/${final_name}|${backup}"
            else
                error "Failed to upgrade ${label}. See $LOG_FILE"
                SUMMARY_FAILED+=("$label")
            fi
        else
            warn "Skipped upgrading ${label}"; SUMMARY_SKIPPED+=("$label")
        fi
    else
        success "Already up to date (${installed_ver})"
        SUMMARY_UPTODATE+=("$label")
    fi
}

# ----------------------------------------------------------------------------
# SPECIAL tools: kubectl, aws-cli, azure-cli
# ----------------------------------------------------------------------------
install_kubectl_binary() {
    local ver="$1" backup_existing="${2:-false}"
    LAST_KUBECTL_BACKUP=""
    if [[ "$backup_existing" == "true" && -f /usr/local/bin/kubectl ]]; then
        LAST_KUBECTL_BACKUP="$BACKUP_DIR/kubectl.$(date +%Y%m%d%H%M%S)"
        $SUDO cp /usr/local/bin/kubectl "$LAST_KUBECTL_BACKUP" 2>>"$LOG_FILE" || LAST_KUBECTL_BACKUP=""
    fi
    local tmp; tmp=$(mktemp -d) || return 1
    ( curl -fsSL --max-time 30 "https://dl.k8s.io/release/${ver}/bin/linux/amd64/kubectl" -o "${tmp}/kubectl" \
        && chmod +x "${tmp}/kubectl" \
        && $SUDO mv "${tmp}/kubectl" /usr/local/bin/kubectl ) >>"$LOG_FILE" 2>&1
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

process_kubectl() {
    echo
    echo -e "  ${C_BOLD}kubectl${C_RESET} ${C_DIM}(Kubernetes CLI — official binary via dl.k8s.io)${C_RESET}"

    local installed_ver="" latest_ver
    if command -v kubectl &>/dev/null; then
        installed_ver=$(kubectl version --client --output=yaml 2>/dev/null | awk '/gitVersion/{print $2; exit}')
    fi
    latest_ver=$(curl -fsSL --max-time 8 https://dl.k8s.io/release/stable.txt 2>/dev/null)

    if [[ -z "$latest_ver" ]]; then
        warn "Could not reach kubectl release server — skipping"
        SUMMARY_SKIPPED+=("kubectl"); return
    fi

    if [[ -z "$installed_ver" ]]; then
        warn "Not installed  (latest available: ${latest_ver})"
        if confirm "Install kubectl ${latest_ver}?" "y"; then
            if install_kubectl_binary "$latest_ver" "false"; then
                success "kubectl ${latest_ver} installed"
                SUMMARY_INSTALLED+=("kubectl")
                record_action "INSTALL|kubectl|binary|/usr/local/bin/kubectl|"
            else
                error "Failed to install kubectl"; SUMMARY_FAILED+=("kubectl")
            fi
        else
            warn "Skipped kubectl"; SUMMARY_SKIPPED+=("kubectl")
        fi
    elif [[ "$installed_ver" != "$latest_ver" ]]; then
        warn "Outdated  (installed: ${installed_ver}  →  available: ${latest_ver})"
        if confirm "Upgrade kubectl to ${latest_ver}?" "y"; then
            if install_kubectl_binary "$latest_ver" "true"; then
                success "kubectl upgraded to ${latest_ver}"
                SUMMARY_UPGRADED+=("kubectl")
                record_action "UPGRADE|kubectl|binary|/usr/local/bin/kubectl|${LAST_KUBECTL_BACKUP}"
            else
                error "Failed to upgrade kubectl"; SUMMARY_FAILED+=("kubectl")
            fi
        else
            warn "Skipped upgrading kubectl"; SUMMARY_SKIPPED+=("kubectl")
        fi
    else
        success "Already up to date (${installed_ver})"
        SUMMARY_UPTODATE+=("kubectl")
    fi
}

process_awscli() {
    echo
    echo -e "  ${C_BOLD}aws-cli${C_RESET} ${C_DIM}(AWS CLI v2 — official installer)${C_RESET}"

    if command -v aws &>/dev/null; then
        local ver; ver=$(aws --version 2>&1 | awk -F/ '{print $2}' | awk '{print $1}')
        success "Already installed (${ver:-unknown}) — re-run installer manually to upgrade"
        SUMMARY_UPTODATE+=("aws-cli")
        return
    fi

    warn "Not installed"
    if confirm "Install AWS CLI v2?" "y"; then
        local tmp; tmp=$(mktemp -d)
        if ( cd "$tmp" \
             && curl -fsSL --max-time 30 "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
             && unzip -q awscliv2.zip \
             && $SUDO ./aws/install ) >>"$LOG_FILE" 2>&1; then
            success "aws-cli installed"
            SUMMARY_INSTALLED+=("aws-cli")
            record_action "INSTALL|aws-cli|dir|/usr/local/aws-cli|"
        else
            error "Failed to install aws-cli"; SUMMARY_FAILED+=("aws-cli")
        fi
        rm -rf "$tmp"
    else
        warn "Skipped aws-cli"; SUMMARY_SKIPPED+=("aws-cli")
    fi
}

process_azure_cli() {
    echo
    echo -e "  ${C_BOLD}azure-cli${C_RESET} ${C_DIM}(Azure CLI — Microsoft's official installer)${C_RESET}"

    if dpkg -s azure-cli &>/dev/null; then
        process_apt_package "azure-cli" "azure-cli"
        return
    fi

    warn "Not installed"
    if confirm "Install Azure CLI (runs Microsoft's official install script)?" "y"; then
        if curl -sL https://aka.ms/InstallAzureCLIDeb | $SUDO bash >>"$LOG_FILE" 2>&1; then
            success "azure-cli installed ($(get_installed_version azure-cli))"
            SUMMARY_INSTALLED+=("azure-cli")
            record_action "INSTALL|azure-cli|apt|azure-cli|"
        else
            error "Failed to install azure-cli"; SUMMARY_FAILED+=("azure-cli")
        fi
    else
        warn "Skipped azure-cli"; SUMMARY_SKIPPED+=("azure-cli")
    fi
}

# ----------------------------------------------------------------------------
# Dispatcher: run the right handler for a tool id
# ----------------------------------------------------------------------------
process_tool_by_id() {
    local id="$1"
    local meta; meta=$(tool_info "$id")
    if [[ -z "$meta" ]]; then warn "Unknown tool id: $id"; return; fi

    local label method p1 p2 desc
    IFS='|' read -r label method p1 p2 desc <<< "$meta"

    case "$method" in
        APT)      process_apt_package "$label" "$p1" ;;
        APT_REPO) process_repo_apt_tool "$label" "$p1" "$p2" ;;
        GH_BIN)   process_github_tool "$label" "$p1" "$p2" ;;
        SPECIAL)
            case "$id" in
                awscli)   process_awscli ;;
                azurecli) process_azure_cli ;;
                kubectl)  process_kubectl ;;
            esac
            ;;
    esac
}

# ----------------------------------------------------------------------------
# REVERT MODE
# ----------------------------------------------------------------------------
select_state_file() {
    local -a files=()
    while IFS= read -r f; do files+=("$f"); done < <(ls -1t "$STATE_DIR"/state-*.log 2>/dev/null)

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "  No previous run logs found in $STATE_DIR." >&2
        return 1
    fi
    if [[ ${#files[@]} -eq 1 ]]; then
        echo "${files[0]}"; return 0
    fi

    echo -e "  ${C_BOLD}Available previous runs (most recent first):${C_RESET}" >&2
    local i=1
    for f in "${files[@]}"; do
        local ts; ts=$(basename "$f" | sed -E 's/state-([0-9]{8}-[0-9]{6})\.log/\1/')
        local n; n=$(grep -c . "$f" 2>/dev/null); n="${n:-0}"
        echo "    $i) $ts   (${n} action(s))" >&2
        ((i++))
    done
    echo >&2
    local choice
    read -rp "  Choose a run to revert [1 = most recent, Enter = 1]: " choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#files[@]} )); then
        echo "${files[$((choice-1))]}"
    else
        echo "  Invalid choice." >&2
        return 1
    fi
}

revert_apt_install() {
    local label="$1" pkg="$2"
    info "Removing ${label} (${pkg})..."
    if $SUDO apt-get remove -y "$pkg" >>"$LOG_FILE" 2>&1; then
        success "${label} removed"; REVERT_OK+=("$label")
    else
        error "Failed to remove ${label}. See $LOG_FILE"; REVERT_FAILED+=("$label")
    fi
}

revert_apt_upgrade() {
    local label="$1" pkg="$2" prev="$3"
    if [[ -z "$prev" || "$prev" == "unknown" ]]; then
        warn "${label}: no previous version recorded — cannot auto-downgrade."
        REVERT_MANUAL+=("$label"); return
    fi
    info "Attempting to downgrade ${label} to ${prev}..."
    if $SUDO apt-get install --allow-downgrades -y "${pkg}=${prev}" >>"$LOG_FILE" 2>&1; then
        success "${label} downgraded to ${prev}"; REVERT_OK+=("$label")
    else
        warn "${label}: version ${prev} is no longer available in apt — cannot auto-downgrade. Manual action required."
        REVERT_MANUAL+=("$label")
    fi
}

revert_binary_install() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        if $SUDO rm -f "$path" >>"$LOG_FILE" 2>&1; then
            success "${label} removed (${path})"; REVERT_OK+=("$label")
        else
            error "Failed to remove ${label}"; REVERT_FAILED+=("$label")
        fi
    else
        warn "${label} binary not found at ${path} — already gone"
        REVERT_SKIPPED+=("$label")
    fi
}

revert_binary_upgrade() {
    local label="$1" path="$2" backup="$3"
    if [[ -n "$backup" && -f "$backup" ]]; then
        if $SUDO mv "$backup" "$path" >>"$LOG_FILE" 2>&1 && $SUDO chmod +x "$path"; then
            success "${label} restored to its previous version"; REVERT_OK+=("$label")
        else
            error "Failed to restore ${label} from backup"; REVERT_FAILED+=("$label")
        fi
    else
        warn "${label}: no backup available — cannot auto-revert. Manual action required."
        REVERT_MANUAL+=("$label")
    fi
}

revert_dir_install() {
    local label="$1" path="$2"
    info "Removing ${label} (${path})..."
    $SUDO rm -rf "$path" >>"$LOG_FILE" 2>&1
    if [[ "$label" == "aws-cli" ]]; then
        $SUDO rm -f /usr/local/bin/aws /usr/local/bin/aws_completer >>"$LOG_FILE" 2>&1
    fi
    success "${label} removed"; REVERT_OK+=("$label")
}

revert_repo_added() {
    local label="$1" list_file="$2" key_file="$3"
    info "Removing repo files for ${label}..."
    $SUDO rm -f "$list_file" "$key_file" >>"$LOG_FILE" 2>&1
    success "${label} repo files removed"; REVERT_OK+=("$label")
}

print_revert_summary() {
    section "Revert Summary"
    print_list "Reverted successfully" "$C_GREEN"   "${REVERT_OK[@]}"
    print_list "Skipped"                "$C_YELLOW" "${REVERT_SKIPPED[@]}"
    print_list "Needs manual action"    "$C_MAGENTA" "${REVERT_MANUAL[@]}"
    print_list "Failed"                 "$C_RED"     "${REVERT_FAILED[@]}"
    hr
    echo -e "  ${C_DIM}Full log: $LOG_FILE${C_RESET}"
    hr
    if [[ ${#REVERT_FAILED[@]} -gt 0 || ${#REVERT_MANUAL[@]} -gt 0 ]]; then
        warn "Some items could not be fully auto-reverted — see above for manual steps."
    else
        success "Revert completed successfully."
    fi
}

revert_run() {
    section "Revert a Previous Run"

    local chosen_file
    chosen_file=$(select_state_file) || { error "Nothing to revert."; return 1; }

    if [[ ! -s "$chosen_file" ]]; then
        warn "That run recorded no changes — nothing to revert."
        return 0
    fi

    echo
    echo -e "  ${C_BOLD}Actions that will be reverted (in reverse order):${C_RESET}"
    tac "$chosen_file" | nl -w2 -s'. ' | sed 's/^/    /'
    echo

    local auto_all="n"
    confirm "Revert ALL of the above without asking per item?" "n" && auto_all="y"
    echo

    while IFS='|' read -r type label method target extra; do
        [[ -z "$type" ]] && continue

        local do_it="n"
        if [[ "$auto_all" == "y" ]]; then
            do_it="y"
        else
            confirm "Revert: [${type}] ${label}?" "y" && do_it="y"
        fi
        if [[ "$do_it" != "y" ]]; then
            warn "Skipped revert of ${label}"
            REVERT_SKIPPED+=("$label")
            continue
        fi

        case "$type" in
            INSTALL)
                case "$method" in
                    apt)    revert_apt_install "$label" "$target" ;;
                    binary) revert_binary_install "$label" "$target" ;;
                    dir)    revert_dir_install "$label" "$target" ;;
                    *)      warn "Unknown install method '${method}' for ${label}"; REVERT_SKIPPED+=("$label") ;;
                esac
                ;;
            UPGRADE)
                case "$method" in
                    apt)    revert_apt_upgrade "$label" "$target" "$extra" ;;
                    binary) revert_binary_upgrade "$label" "$target" "$extra" ;;
                    *)      warn "Unknown upgrade method '${method}' for ${label}"; REVERT_SKIPPED+=("$label") ;;
                esac
                ;;
            REPO_ADDED)
                revert_repo_added "$label" "$target" "$extra"
                ;;
            *)
                warn "Unknown action type '${type}' for ${label} — skipping"
                REVERT_SKIPPED+=("$label")
                ;;
        esac
    done < <(tac "$chosen_file")

    print_revert_summary
}

# ----------------------------------------------------------------------------
# Category browsing / custom selection / quick install flows
# ----------------------------------------------------------------------------
process_category() {
    local cat_id="$1"
    banner
    section "${CATEGORY_TITLES[$cat_id]}"
    echo -e "  ${CATEGORY_DESC[$cat_id]}"
    echo
    echo -e "  ${C_BOLD}Included tools:${C_RESET}"
    for id in ${CATEGORY_TOOLS[$cat_id]}; do
        local meta label method p1 p2 desc
        meta=$(tool_info "$id")
        IFS='|' read -r label method p1 p2 desc <<< "$meta"
        echo -e "    ${C_CYAN}•${C_RESET} ${C_BOLD}${label}${C_RESET} — ${desc}"
    done
    echo
    echo "  1) Quick install ALL tools in this category (no per-tool prompts)"
    echo "  2) Go through one-by-one (choose install/upgrade per tool)"
    echo "  3) Skip this category"
    local choice
    read -rp "  Choose an option [1-3]: " choice
    case "$choice" in
        1) AUTO_YES=true ;;
        2) AUTO_YES=false ;;
        *) info "Skipped ${CATEGORY_TITLES[$cat_id]}"; return ;;
    esac

    for id in ${CATEGORY_TOOLS[$cat_id]}; do
        process_tool_by_id "$id"
    done
    AUTO_YES=false
}

flow_browse_categories() {
    banner
    section "Choose Categories"
    local -a order=("${CATEGORY_IDS[@]}")
    local i=1
    declare -A idx_to_cat
    for c in "${order[@]}"; do
        local count; count=$(echo "${CATEGORY_TOOLS[$c]}" | wc -w)
        echo -e "  ${C_BOLD}$i) ${CATEGORY_TITLES[$c]}${C_RESET} ${C_DIM}(${count} tools)${C_RESET}"
        echo -e "     ${CATEGORY_DESC[$c]}"
        idx_to_cat[$i]="$c"
        ((i++))
    done
    local all_idx=$i
    echo -e "  ${C_BOLD}${all_idx}) Select ALL categories${C_RESET}"
    echo
    local sel
    read -rp "  Enter category number(s) — comma/space separated (e.g. 1,3,5): " sel

    local -a chosen=()
    while IFS= read -r n; do
        if [[ "$n" == "$all_idx" ]]; then
            chosen=("${order[@]}")
            break
        elif [[ -n "${idx_to_cat[$n]:-}" ]]; then
            chosen+=("${idx_to_cat[$n]}")
        fi
    done < <(parse_number_list "$sel")

    if [[ ${#chosen[@]} -eq 0 ]]; then
        warn "No valid categories selected."
        return
    fi

    local idx=0 total=${#chosen[@]}
    for c in "${chosen[@]}"; do
        idx=$((idx+1))
        process_category "$c"
        if [[ $idx -lt $total ]]; then
            echo
            if ! confirm "Continue to the next selected category?" "y"; then
                if confirm "Exit the script now?" "y"; then
                    print_summary
                    exit 0
                else
                    break
                fi
            fi
        fi
    done
    print_summary
}

flow_custom_selection() {
    banner
    section "Custom Selection"
    echo -e "  Pick any individual tools you want, across all categories."
    echo
    local i=1
    declare -A idx_to_id
    for c in "${CATEGORY_IDS[@]}"; do
        echo -e "  ${C_BOLD}${CATEGORY_TITLES[$c]}${C_RESET}"
        for id in ${CATEGORY_TOOLS[$c]}; do
            local meta label method p1 p2 desc
            meta=$(tool_info "$id")
            IFS='|' read -r label method p1 p2 desc <<< "$meta"
            printf "    %2d) %-16s %s\n" "$i" "$label" "- $desc"
            idx_to_id[$i]="$id"
            ((i++))
        done
        echo
    done

    local sel
    read -rp "  Enter tool numbers, comma/space separated (e.g. 2,5,14): " sel

    local -a chosen_ids=()
    while IFS= read -r n; do
        [[ -n "${idx_to_id[$n]:-}" ]] && chosen_ids+=("${idx_to_id[$n]}")
    done < <(parse_number_list "$sel")

    if [[ ${#chosen_ids[@]} -eq 0 ]]; then
        warn "No valid selections made."
        return
    fi

    echo
    if confirm "Install/upgrade all ${#chosen_ids[@]} selected tools automatically without per-tool prompts?" "n"; then
        AUTO_YES=true
    else
        AUTO_YES=false
    fi
    for id in "${chosen_ids[@]}"; do
        process_tool_by_id "$id"
    done
    AUTO_YES=false
    print_summary
}

flow_quick_all() {
    banner
    section "Quick Install Everything"
    local total=0
    for c in "${CATEGORY_IDS[@]}"; do
        total=$((total + $(echo "${CATEGORY_TOOLS[$c]}" | wc -w)))
    done
    warn "This will check/install/upgrade ALL ${total} tools across every category."
    if ! confirm "Continue?" "n"; then
        info "Cancelled."
        return
    fi
    if confirm "Run silently (auto-yes to every install/upgrade)? Choosing 'n' asks per tool." "y"; then
        AUTO_YES=true
    else
        AUTO_YES=false
    fi
    for c in "${CATEGORY_IDS[@]}"; do
        section "${CATEGORY_TITLES[$c]}"
        for id in ${CATEGORY_TOOLS[$c]}; do
            process_tool_by_id "$id"
        done
    done
    AUTO_YES=false
    print_summary
}

# ----------------------------------------------------------------------------
# Help screen (interactive, menu option 5)
# ----------------------------------------------------------------------------
show_help() {
    banner
    section "Help / About This Script"
    cat <<EOF
  ${C_BOLD}What is this?${C_RESET}
  devops-setup.sh checks, installs, and upgrades common DevOps & Cloud
  Engineering command-line tools on Debian/Ubuntu systems. It never
  installs anything without your confirmation (unless you choose a
  "quick install" mode), and every change can be undone later with
  the Revert option.

  ${C_BOLD}Main Menu Options${C_RESET}
   1) Browse & Install by Category — pick one or more categories, see
      every tool inside with a plain-English explanation, then choose
      to quick-install the whole category or go tool-by-tool. After
      each category you can continue to the next or exit.
   2) Custom Selection — pick individual tools from a flat list,
      regardless of category.
   3) Quick Install Everything — checks/installs/upgrades every tool
      this script knows about, in one go.
   4) Revert a Previous Run — undo installs/upgrades from an earlier
      run (uninstall what was installed, downgrade/restore what was
      upgraded, where possible).
   5) Help — this screen.
   6) Exit.

  ${C_BOLD}How installs happen${C_RESET}
   - Most tools come from apt (Debian/Ubuntu's official package manager).
   - Some (terraform, packer, vagrant, gh, trivy, gcloud) need their
     vendor's official apt repository added first — done automatically,
     safely, and only once.
   - Some (kubectl, helm, k9s, argocd, etc.) are installed as a single
     binary from the tool's official GitHub releases or download URL.
   - aws-cli and azure-cli use their vendors' official installers.

  ${C_BOLD}Logs & State${C_RESET}
   - Full run log: $LOG_FILE
   - Every install/upgrade is recorded to: $STATE_DIR/state-<timestamp>.log
   - Binary backups (for clean revert of upgrades): $BACKUP_DIR

  ${C_BOLD}Command-line flags${C_RESET}
   ./devops-setup.sh              interactive menu (default)
   ./devops-setup.sh --run        jump straight to category browsing
   ./devops-setup.sh --revert     jump straight to revert mode
   ./devops-setup.sh --help       show help and exit

EOF
    section "Full Tool List by Category (44 tools)"
    for c in "${CATEGORY_IDS[@]}"; do
        echo -e "  ${C_BOLD}${CATEGORY_TITLES[$c]}${C_RESET} ${C_DIM}— ${CATEGORY_DESC[$c]}${C_RESET}"
        for id in ${CATEGORY_TOOLS[$c]}; do
            local meta label method p1 p2 desc
            meta=$(tool_info "$id")
            IFS='|' read -r label method p1 p2 desc <<< "$meta"
            echo -e "    ${C_CYAN}•${C_RESET} ${C_BOLD}${label}${C_RESET} — ${desc}"
        done
        echo
    done
    hr
    echo -e "  ${C_MAGENTA}${C_BOLD}Made by @sharadverma638${C_RESET}"
    hr
    read -rp "  Press Enter to return to the main menu... " _
}

# ----------------------------------------------------------------------------
# Main menu / entrypoint
# ----------------------------------------------------------------------------
main_menu() {
    banner
    echo -e "  ${C_BOLD}What would you like to do?${C_RESET}"
    echo "   1) Browse & Install by Category"
    echo "   2) Custom Selection (pick individual tools)"
    echo "   3) Quick Install Everything (all categories)"
    echo "   4) Revert a Previous Run"
    echo "   5) Help / About this Script"
    echo "   6) Exit"
    echo
    while true; do
        if ! read -rp "  Choose an option [1-6]: " MENU_CHOICE; then
            echo
            warn "No more input received — exiting."
            exit 0
        fi
        case "$MENU_CHOICE" in
            1|2|3|4|5|6) break ;;
            *) echo "  Please enter a number from 1 to 6." ;;
        esac
    done
}

main_loop() {
    while true; do
        main_menu
        case "$MENU_CHOICE" in
            1) preflight_checks; init_state; refresh_apt_cache_once; flow_browse_categories ;;
            2) preflight_checks; init_state; refresh_apt_cache_once; flow_custom_selection ;;
            3) preflight_checks; init_state; refresh_apt_cache_once; flow_quick_all ;;
            4) preflight_checks; revert_run ;;
            5) show_help; continue ;;
            6) banner
               echo -e "  ${C_DIM}Thanks for using devops-setup — made by @sharadverma638${C_RESET}"
               exit 0 ;;
        esac
        echo
        read -rp "  Press Enter to return to the main menu... " _
    done
}

trap 'error "Unexpected error near line $LINENO. See $LOG_FILE for details."; exit 1' ERR

case "${1:-}" in
    --run)
        preflight_checks; init_state; refresh_apt_cache_once
        flow_browse_categories
        exit 0
        ;;
    --revert)
        preflight_checks
        revert_run
        exit 0
        ;;
    -h|--help)
        print_help
        exit 0
        ;;
    "")
        main_loop
        ;;
    *)
        echo "Unknown option: $1"
        print_help
        exit 1
        ;;
esac
