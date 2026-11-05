#!/bin/bash
# ============================================================
#  SSH Keep-Alive Setup Script (with error handling)
#  You choose how long SSH waits before it disconnects.
#  Works for: (1) SSH client (your WSL / laptop)
#             (2) SSH server (the remote machine you control)
#
#  HOW TO RUN:
#     chmod +x ssh_keepalive_setup.sh
#     ./ssh_keepalive_setup.sh
# ============================================================
#
#  ------------------------------------------------------------
#  TERMINAL FROZEN? NOT TAKING ANY INPUT? (stuck SSH session)
#  ------------------------------------------------------------
#  Follow these steps in order. Stop as soon as one works.
#
#  STEP 1: Wait about 10-20 seconds. Sometimes the network is
#          just slow and the screen will wake up by itself.
#
#  STEP 2: Press these keys ONE BY ONE (not together):
#              1) Enter
#              2) ~     (tilde key: Shift + the key left of number 1)
#              3) .     (full stop / dot)
#          This closes ONLY the stuck SSH session and brings you
#          back to your own prompt. You will see a message like:
#              "Connection to <server> closed."
#          Note: always press Enter first. The ~ trick works only
#          at the start of a new line.
#
#  STEP 3: If Step 2 does nothing, close the terminal window
#          (or the tab) and open a new one.
#          In Windows WSL you can also open PowerShell and run:
#              wsl --shutdown
#          then open WSL (Ubuntu) again.
#
#  STEP 4: Connect to the server again:
#              ssh your_username@server_address
#          Example:  ssh ravi@203.0.113.25
#
#  STEP 5: Run this script again and pick the right option:
#              - Option 1 on your OWN computer / WSL
#              - Option 2 on the SERVER (log in to the server first)
#          To copy this script to the server from your own computer:
#              scp ssh_keepalive_setup.sh your_username@server_address:~/
#
#  TIP: Settings on the server apply only to NEW logins. After
#       running the script, close the old session and connect again.
#  ------------------------------------------------------------

# ---------- Colors ----------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------- Settings (filled in when you choose below) ----------
INTERVAL=60          # A "are you there?" signal is sent every 60 seconds
TOTAL_MINUTES=60     # Default. You will be asked to choose.
COUNT=60             # Number of missed signals allowed (= minutes, because interval is 60 s)
MARKER="# --- Added by ssh_keepalive_setup.sh ---"

# ---------- Result tracking ----------
CLIENT_STATUS="not run"
SERVER_STATUS="not run"
TMPFILE=""

# ---------- Helper functions ----------
line()  { echo -e "${BLUE}------------------------------------------------------------${NC}"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARNING]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
hint()  { echo -e "${YELLOW}  -> How to fix:${NC} $1"; }

# Clean up temp files and handle Ctrl+C
cleanup() { [ -n "$TMPFILE" ] && [ -f "$TMPFILE" ] && rm -f "$TMPFILE"; }
trap cleanup EXIT
trap 'echo ""; err "Cancelled by user (Ctrl+C). No half-finished changes were left."; exit 130' INT TERM

# Ask a yes/no question. Returns 0 for yes, 1 for no.
ask_yes_no() {
    local answer
    while true; do
        read -r -p "$1 (y/n): " answer || { err "No input received."; return 1; }
        case "$answer" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
            *) echo "Please type y or n." ;;
        esac
    done
}

# Make minutes easy to read (90 -> "1 hour 30 minutes")
pretty_time() {
    local m=$1 h mm out=""
    h=$((m / 60)); mm=$((m % 60))
    [ "$h" -gt 0 ] && out="$h hour"; [ "$h" -gt 1 ] && out="${out}s"
    if [ "$mm" -gt 0 ]; then
        [ -n "$out" ] && out="$out "
        out="${out}${mm} minutes"
    fi
    echo "$out"
}

# ---------- Pre-checks ----------
if [ -z "${BASH_VERSION:-}" ]; then
    echo "[ERROR] This script needs bash. Run it like this:  bash ssh_keepalive_setup.sh"
    exit 1
fi

if [ "$(uname -s)" != "Linux" ]; then
    err "This script is made for Linux / WSL. Your system is: $(uname -s)"
    hint "Open WSL (Ubuntu) and run the script there."
    exit 1
fi

if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
    err "Your HOME folder could not be found."
    hint "Run the script as a normal user, not from a restricted shell."
    exit 1
fi

# ============================================================
#  ASK THE USER FOR THE TIMEOUT
# ============================================================
ask_timeout() {
    local pick tries custom
    while true; do
        line
        echo -e "${GREEN}How long should SSH wait before disconnecting?${NC}"
        line
        echo ""
        echo "How it works (simple):"
        echo "  - Your computer sends a tiny 'Are you there?' signal to the"
        echo "    server every 60 seconds. This also stops routers and"
        echo "    firewalls from closing an idle session."
        echo "  - If the server does NOT reply for the time you choose below,"
        echo "    SSH disconnects. A longer time is more patient with weak"
        echo "    internet, but a dead connection stays frozen for longer."
        echo ""
        echo "Pick the time:"
        echo ""
        echo "  1) 15 minutes   - Stable broadband or office network"
        echo "  2) 30 minutes   - Normal home Wi-Fi"
        echo -e "  3) 60 minutes   - ${GREEN}RECOMMENDED${NC} (best balance for most people)"
        echo "  4) 120 minutes  - Weak / changing network, or long idle work"
        echo "  5) Custom       - Type your own number of minutes"
        echo ""
        echo "Example: on mobile data (like a Jio / Airtel hotspot) choose 3 or 4."
        echo ""

        tries=0
        while true; do
            read -r -p "Type 1-5 and press Enter (just press Enter for 3): " pick || { echo ""; err "No input received. Exiting."; exit 1; }
            pick="${pick:-3}"
            case "$pick" in
                1) TOTAL_MINUTES=15;  break ;;
                2) TOTAL_MINUTES=30;  break ;;
                3) TOTAL_MINUTES=60;  break ;;
                4) TOTAL_MINUTES=120; break ;;
                5)
                    local ctries=0
                    while true; do
                        read -r -p "Type the number of minutes (1 to 1440, example 90): " custom || { echo ""; err "No input received. Exiting."; exit 1; }
                        if [[ "$custom" =~ ^[0-9]+$ ]] && [ "$custom" -ge 1 ] && [ "$custom" -le 1440 ]; then
                            TOTAL_MINUTES=$((10#$custom))
                            break
                        fi
                        ctries=$((ctries + 1))
                        err "'$custom' is not valid. Type only a whole number from 1 to 1440 (no letters, no spaces)."
                        if [ "$ctries" -ge 5 ]; then
                            err "Too many wrong inputs. Please run the script again."
                            exit 1
                        fi
                    done
                    break
                    ;;
                *)
                    tries=$((tries + 1))
                    err "'$pick' is not valid. Please type only 1, 2, 3, 4 or 5."
                    if [ "$tries" -ge 5 ]; then
                        err "Too many wrong inputs. Please run the script again."
                        exit 1
                    fi
                    ;;
            esac
        done

        INTERVAL=60
        COUNT=$TOTAL_MINUTES

        echo ""
        echo -e "You chose: ${GREEN}$(pretty_time "$TOTAL_MINUTES")${NC}"
        echo "  Signal every : $INTERVAL seconds"
        echo "  Missed signals allowed : $COUNT"
        echo "  Total wait   : $INTERVAL x $COUNT = $((INTERVAL * COUNT)) seconds"
        if [ "$TOTAL_MINUTES" -gt 240 ]; then
            warn "That is a very long time. A broken connection may look frozen for hours."
        fi
        echo ""
        if ask_yes_no "Use these settings?"; then
            echo ""
            return 0
        fi
        echo ""
        echo "No problem, let's choose again."
        echo ""
    done
}

# ============================================================
#  CLIENT SETUP  (~/.ssh/config)
# ============================================================
setup_client() {
    line
    echo -e "${GREEN}Setting up SSH CLIENT...${NC}"
    line

    # 1. Is the ssh client installed?
    if ! command -v ssh >/dev/null 2>&1; then
        err "SSH client is not installed on this machine."
        hint "Install it with:  sudo apt update && sudo apt install openssh-client"
        CLIENT_STATUS="FAILED (ssh not installed)"
        return 1
    fi

    # 2. Warn if running as root (config would go to /root, not your user)
    if [ "$EUID" -eq 0 ]; then
        warn "You are running as root. Settings will be saved for the root user only."
        ask_yes_no "Continue anyway?" || { CLIENT_STATUS="skipped by user"; return 1; }
    fi

    local SSH_DIR="$HOME/.ssh"
    local CONFIG="$SSH_DIR/config"

    # 3. Create ~/.ssh folder
    if ! mkdir -p "$SSH_DIR" 2>/dev/null; then
        err "Could not create folder $SSH_DIR"
        hint "Check that you have permission to write in $HOME"
        CLIENT_STATUS="FAILED (cannot create .ssh)"
        return 1
    fi
    chmod 700 "$SSH_DIR" 2>/dev/null || warn "Could not set permissions on $SSH_DIR"

    # 4. Create config file if missing
    if ! touch "$CONFIG" 2>/dev/null; then
        err "Could not create or open $CONFIG"
        hint "Check permissions with:  ls -ld $SSH_DIR $CONFIG"
        CLIENT_STATUS="FAILED (cannot write config)"
        return 1
    fi
    chmod 600 "$CONFIG" 2>/dev/null || warn "Could not set permissions on $CONFIG"

    # 5. Already configured?
    local REPLACE_OLD=0
    if grep -qxF "$MARKER" "$CONFIG" 2>/dev/null; then
        warn "Settings from an earlier run of this script were found in $CONFIG"
        if ask_yes_no "Replace them with your new choice?"; then
            REPLACE_OLD=1
        else
            CLIENT_STATUS="skipped (kept old settings)"
            echo "Kept your old settings."
            return 0
        fi
    elif grep -q "^[[:space:]]*ServerAliveInterval" "$CONFIG" 2>/dev/null; then
        warn "A ServerAliveInterval setting already exists in $CONFIG (not made by this script)."
        warn "SSH uses the FIRST value it finds, so the new one may be ignored."
        if ! ask_yes_no "Add the new settings anyway?"; then
            CLIENT_STATUS="skipped (already configured)"
            echo "Skipped client setup."
            return 0
        fi
    fi

    # 6. Backup (stop if backup fails)
    local BACKUP="$CONFIG.backup.$(date +%Y%m%d_%H%M%S)"
    if ! cp -p "$CONFIG" "$BACKUP" 2>/dev/null; then
        err "Could not create a backup of $CONFIG. Stopping to keep your file safe."
        CLIENT_STATUS="FAILED (backup failed)"
        return 1
    fi
    ok "Backup saved: $BACKUP"

    # 7. Remove our old block if replacing (marker line + the 3 lines after it)
    if [ "$REPLACE_OLD" -eq 1 ]; then
        if ! sed -i "\|^$MARKER\$|,+3d" "$CONFIG" 2>/dev/null; then
            err "Could not remove the old settings. Restoring your old file..."
            cp -p "$BACKUP" "$CONFIG" 2>/dev/null && ok "Old file restored."
            CLIENT_STATUS="FAILED (could not replace old settings)"
            return 1
        fi
    fi

    # 8. Add settings
    if ! cat >> "$CONFIG" <<EOF

$MARKER
Host *
    ServerAliveInterval $INTERVAL
    ServerAliveCountMax $COUNT
EOF
    then
        err "Could not write to $CONFIG. Restoring your old file..."
        cp -p "$BACKUP" "$CONFIG" 2>/dev/null && ok "Old file restored."
        CLIENT_STATUS="FAILED (write error)"
        return 1
    fi

    # 9. Verify the change really happened
    if grep -q "ServerAliveInterval $INTERVAL" "$CONFIG" && grep -q "ServerAliveCountMax $COUNT" "$CONFIG"; then
        ok "Client settings added to $CONFIG"
        CLIENT_STATUS="SUCCESS"
        return 0
    else
        err "Settings were not found in $CONFIG after writing. Restoring backup..."
        cp -p "$BACKUP" "$CONFIG" 2>/dev/null && ok "Old file restored."
        CLIENT_STATUS="FAILED (verification failed)"
        return 1
    fi
}

# ============================================================
#  SERVER SETUP  (/etc/ssh/sshd_config)
# ============================================================
setup_server() {
    line
    echo -e "${GREEN}Setting up SSH SERVER...${NC}"
    line

    local SSHD="/etc/ssh/sshd_config"
    local SUDO=""

    # 1. Is the SSH server installed?
    if [ ! -f "$SSHD" ]; then
        err "Could not find $SSHD. The SSH server is probably not installed here."
        hint "Install it with:  sudo apt update && sudo apt install openssh-server"
        hint "Are you on your own PC? Then you probably wanted option 1 (client)."
        SERVER_STATUS="FAILED (sshd_config not found)"
        return 1
    fi

    # 2. Check admin (sudo) access
    if [ "$EUID" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            err "sudo is not installed and you are not root."
            hint "Log in as root, or install sudo, then run the script again."
            SERVER_STATUS="FAILED (no sudo)"
            return 1
        fi
        SUDO="sudo"
        echo "Admin (sudo) access is needed. You may be asked for your password."
        echo "(Nothing shows on screen while typing a password. This is normal.)"
        if ! sudo -v; then
            err "Sudo password was wrong, or your user is not allowed to use sudo."
            hint "Try again with the correct password, or ask the server admin for access."
            SERVER_STATUS="FAILED (sudo denied)"
            return 1
        fi
    fi

    # 3. Is the sshd program available for the safety test?
    local SSHD_BIN
    SSHD_BIN="$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)"
    if [ ! -x "$SSHD_BIN" ]; then
        err "The sshd program was not found, so the config cannot be tested safely."
        hint "Install it with:  sudo apt install openssh-server"
        SERVER_STATUS="FAILED (sshd not found)"
        return 1
    fi

    # 4. Backup (stop if backup fails)
    local BACKUP="$SSHD.backup.$(date +%Y%m%d_%H%M%S)"
    if ! $SUDO cp -p "$SSHD" "$BACKUP"; then
        err "Could not create a backup of $SSHD. Stopping to keep your server safe."
        SERVER_STATUS="FAILED (backup failed)"
        return 1
    fi
    ok "Backup saved: $BACKUP"

    # 5. Build new config in a temp file (old values removed, new ones at top)
    TMPFILE="$(mktemp 2>/dev/null)" || { err "Could not create a temporary file."; SERVER_STATUS="FAILED (mktemp)"; return 1; }
    {
        echo "ClientAliveInterval $INTERVAL"
        echo "ClientAliveCountMax $COUNT"
        grep -Ev '^[#[:space:]]*(ClientAliveInterval|ClientAliveCountMax)[[:space:]]' "$SSHD"
    } > "$TMPFILE" 2>/dev/null

    if [ ! -s "$TMPFILE" ]; then
        err "Could not prepare the new configuration."
        SERVER_STATUS="FAILED (could not build config)"
        return 1
    fi

    # 6. Apply the new config
    if ! $SUDO cp "$TMPFILE" "$SSHD"; then
        err "Could not write to $SSHD."
        hint "Check that you have sudo/root access and the disk is not full (df -h)."
        $SUDO cp -p "$BACKUP" "$SSHD" 2>/dev/null
        SERVER_STATUS="FAILED (write error)"
        return 1
    fi

    # 7. Test the config BEFORE restarting (very important for safety)
    $SUDO mkdir -p /run/sshd 2>/dev/null   # sshd -t needs this folder on some systems
    local TEST_OUTPUT
    if ! TEST_OUTPUT="$($SUDO "$SSHD_BIN" -t 2>&1)"; then
        err "The new configuration has an error:"
        echo "$TEST_OUTPUT"
        warn "Restoring your old configuration..."
        if $SUDO cp -p "$BACKUP" "$SSHD"; then
            ok "Old configuration restored. Your server is safe."
        else
            err "Restore failed! Manually run:  sudo cp $BACKUP $SSHD"
        fi
        SERVER_STATUS="FAILED (config test failed, rolled back)"
        return 1
    fi
    ok "Config test passed."

    # 8. Restart SSH (service name differs between systems)
    echo "Restarting SSH service..."
    local RESTARTED=0
    if command -v systemctl >/dev/null 2>&1 && $SUDO systemctl restart ssh 2>/dev/null; then
        RESTARTED=1
    elif command -v systemctl >/dev/null 2>&1 && $SUDO systemctl restart sshd 2>/dev/null; then
        RESTARTED=1
    elif $SUDO service ssh restart 2>/dev/null; then
        RESTARTED=1
    elif $SUDO service sshd restart 2>/dev/null; then
        RESTARTED=1
    fi

    if [ "$RESTARTED" -ne 1 ]; then
        err "Settings were saved, but SSH could not be restarted automatically."
        hint "Try manually:  sudo systemctl restart ssh   (or: sudo service ssh restart)"
        hint "On WSL without systemd, use:  sudo service ssh restart"
        SERVER_STATUS="PARTIAL (saved, restart needed)"
        return 1
    fi
    ok "SSH service restarted."

    # 9. Verify the live settings
    local LIVE
    LIVE="$($SUDO "$SSHD_BIN" -T 2>/dev/null | grep -i '^clientalive')"
    if echo "$LIVE" | grep -qi "clientaliveinterval $INTERVAL" && echo "$LIVE" | grep -qi "clientalivecountmax $COUNT"; then
        ok "Verified: server is now using the new settings."
        SERVER_STATUS="SUCCESS"
        return 0
    else
        warn "Could not confirm the live settings. Current values:"
        echo "$LIVE"
        SERVER_STATUS="DONE (could not verify)"
        return 0
    fi
}

# ============================================================
#  MAIN MENU
# ============================================================
clear 2>/dev/null
line
echo -e "${GREEN}   SSH Keep-Alive Setup${NC}"
line
echo ""
echo "This script helps your SSH session stay connected when you are"
echo "idle (not typing anything). You will choose the time yourself."
echo ""
echo -e "${YELLOW}Where are you running this script right now?${NC}"
echo ""
echo "  1) On MY OWN computer / WSL  (I connect TO a server)"
echo "       -> Sets up the SSH CLIENT"
echo ""
echo "  2) On the REMOTE SERVER  (I control this server)"
echo "       -> Sets up the SSH SERVER (needs sudo / admin)"
echo ""
echo "  3) Both (only if this machine is both client and server)"
echo ""
echo "  4) Exit"
echo ""
echo "Not sure? Choose 1 if you type 'ssh user@server' from this machine."
echo ""

# Keep asking until the input is valid (max 5 tries)
TRIES=0
while true; do
    read -r -p "Type 1, 2, 3 or 4 and press Enter: " CHOICE || { echo ""; err "No input received. Exiting."; exit 1; }
    case "$CHOICE" in
        1|2|3|4) break ;;
        *)
            TRIES=$((TRIES + 1))
            err "'$CHOICE' is not valid. Please type only 1, 2, 3 or 4."
            if [ "$TRIES" -ge 5 ]; then
                err "Too many wrong inputs. Please run the script again."
                exit 1
            fi
            ;;
    esac
done
echo ""

if [ "$CHOICE" = "4" ]; then
    echo "Bye!"
    exit 0
fi

# Ask for the timeout (only when we are going to change something)
ask_timeout

case "$CHOICE" in
    1) setup_client ;;
    2) setup_server ;;
    3) setup_client; echo ""; setup_server ;;
esac

# ============================================================
#  SUMMARY
# ============================================================
echo ""
line
echo -e "${GREEN}Summary${NC}"
line
echo "  Chosen time  : $(pretty_time "$TOTAL_MINUTES")"
echo "  Client setup : $CLIENT_STATUS"
echo "  Server setup : $SERVER_STATUS"
line

if [[ "$CLIENT_STATUS" == FAILED* || "$SERVER_STATUS" == FAILED* || "$SERVER_STATUS" == PARTIAL* ]]; then
    err "Some steps did not finish. Read the messages above for the fix."
    exit 1
fi

echo -e "${GREEN}All finished!${NC} SSH will now wait up to $(pretty_time "$TOTAL_MINUTES") for a reply before disconnecting."
echo -e "${YELLOW}Tip:${NC} Close and reconnect your SSH session for changes to apply."
echo "If your terminal ever freezes, see the steps at the top of this script."
line
exit 0
