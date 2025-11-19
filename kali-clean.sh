#!/usr/bin/env bash
# kali-clean.sh
# v0.2.0 — safer, more interactive, privacy-first Kali/Debian cleaner
# Goals:
# - Be conservative: avoid any destructive action without explicit, hard confirmation
# - Encrypt and protect backups (symmetric GPG by default)
# - Provide a dry-run mode and a selective interactive workflow
# - Separate "dangerous" operations behind an explicit flag and typed confirmation
# - Keep a minimal, private log; provide a no-log option

set -u

VERSION="0.2.0"
TS="$(date +%F_%H-%M-%S)"
BACKUP_DIR="$HOME/.kali-clean-backups"
LOGFILE="$BACKUP_DIR/kali-clean.$TS.log"
DRY_RUN=false
QUIET=false
AUTO_YES=false
DANGEROUS=false
NO_LOG=false
GPG_RECIPIENT=""

usage() {
  cat <<EOF
kali-clean.sh v$VERSION
Usage: $0 [--dry-run] [--yes] [--dangerous] [--no-log] [--help]

Options:
  --dry-run       Print actions that would be taken, don't delete anything.
  --yes, -y       Answer Yes to safe prompts. Dangerous actions still require explicit typed confirmation.
  --dangerous     Enable destructive operations (msfdb reset, purge GVM) but still require typing RESET when prompted.
  --no-log        Do not write command outputs to the logfile (only record high-level actions).
  --help          Show this help and exit.

Security notes:
 - Backups are encrypted with GPG symmetric encryption by default (you will be prompted for a passphrase).
 - Backups and logs are stored in $BACKUP_DIR with strict permissions (0700 for dir, 0600 for logs).
 - The script will NEVER run destructive database wipes unless --dangerous is passed and you type the confirmation keyword.

Recommended workflow:
 1) Run with --dry-run to review actions.
 2) Run without --dry-run to perform non-destructive cleanup.
 3) If you really need to purge DBs, run with --dangerous and follow the typed confirmation steps.
EOF
}

log() {
  local msg="$1"
  if [ "$NO_LOG" = true ]; then
    # Still print to stdout for user, but don't persist
    echo "$(date +'%F %T') - $msg"
  else
    mkdir -p "$BACKUP_DIR"
    # ensure strict permissions
    umask 077
    touch "$LOGFILE" 2>/dev/null || true
    chmod 600 "$LOGFILE" 2>/dev/null || true
    echo "$(date +'%F %T') - $msg" | tee -a "$LOGFILE"
  fi
}

confirm() {
  local prompt="$1"
  # If dry-run we automatically return 'no' for destructive prompts to be extra safe
  if $DRY_RUN; then
    log "DRY-RUN: would prompt: $prompt"
    return 1
  fi
  if $AUTO_YES && [ "$2" != "dangerous" ]; then
    return 0
  fi
  if $QUIET; then
    return 1
  fi
  read -p "$prompt [y/N]: " ans
  case "$ans" in
    [Yy]*) return 0 ;;
    *) return 1 ;;
  esac
}

# Hard confirmation that requires typing a keyword
typed_confirm() {
  local prompt="$1"
  local keyword="$2"
  if $DRY_RUN; then
    log "DRY-RUN: would typed-confirm: $prompt (keyword=$keyword)"
    return 1
  fi
  echo
  echo "$prompt"
  echo "To confirm, type the keyword exactly: $keyword"
  read -p "> " input
  if [ "$input" = "$keyword" ]; then
    return 0
  fi
  return 1
}

run_cmd() {
  local cmd="$1"
  if $DRY_RUN; then
    log "DRY-RUN: $cmd"
    return 0
  fi
  if [ "$NO_LOG" = true ]; then
    log "RUN: $cmd (no-log mode)"
    bash -c "$cmd"
  else
    log "RUN: $cmd"
    bash -c "$cmd" 2>&1 | tee -a "$LOGFILE"
  fi
}

# safer variant that does not log command output even if logging is enabled
run_cmd_no_output() {
  local cmd="$1"
  if $DRY_RUN; then
    log "DRY-RUN: $cmd (no output)"
    return 0
  fi
  log "RUN (no-output): $cmd"
  bash -c "$cmd" >/dev/null 2>&1
}

ensure_prereqs() {
  if ! command -v sudo >/dev/null 2>&1; then
    echo "This script requires 'sudo'. Please install sudo or run as root." >&2
    exit 1
  fi
}

# Backup a file or directory, then add to encrypted archive
backup_file() {
  local src="$1"
  local name
  name=$(basename "$src")
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  if [ ! -e "$src" ]; then
    log "Backup skipped, not found: $src"
    return 0
  fi
  local tmpdest="$BACKUP_DIR/${name}_$TS"
  log "Backing up $src -> $tmpdest"
  if $DRY_RUN; then
    return 0
  fi
  # use cp -a for files/dirs
  cp -a --preserve=mode,ownership,timestamps "$src" "$tmpdest" 2>/dev/null || cp -a "$src" "$tmpdest" 2>/dev/null || true
  chmod 600 "$tmpdest" 2>/dev/null || true
}

encrypt_backups() {
  # Create a timestamped tar.gz and gpg symmetric-encrypted archive (AES256). Ask for passphrase interactively.
  if $DRY_RUN; then
    log "DRY-RUN: would archive and encrypt $BACKUP_DIR to $BACKUP_DIR/kali-clean-backup-$TS.tar.gz.gpg"
    return 0
  fi
  if ! command -v gpg >/dev/null 2>&1; then
    log "gpg not found. Install gnupg to enable encrypted backups. Skipping encryption."
    return 1
  fi
  local out="$BACKUP_DIR/kali-clean-backup-$TS.tar.gz.gpg"
  log "Archiving and encrypting backups to $out"
  # create tar.gz from the directory contents, then encrypt
  tar -C "$BACKUP_DIR" -czf - . | gpg --symmetric --cipher-algo AES256 -o "$out"
  if [ $? -eq 0 ]; then
    log "Encrypted backup created: $out"
    # Optionally remove plain files but keep the encrypted archive
    if confirm "Remove plain backup files and keep only encrypted archive?"; then
      run_cmd "find \"$BACKUP_DIR\" -mindepth 1 -maxdepth 1 -type f -not -name '*.gpg' -delete"
      run_cmd "find \"$BACKUP_DIR\" -mindepth 1 -maxdepth 1 -type d -not -name '*.gpg' -exec rm -rf {} +"
    else
      log "Keeping plain backup files alongside encrypted archive"
    fi
  else
    log "Encryption failed, keeping plain backups"
  fi
}

# Cleaning operations
clean_apt() {
  log "--- apt cache clean/start ---"
  run_cmd "sudo apt-get clean"
  run_cmd "sudo apt-get autoclean"
  run_cmd "sudo apt-get autoremove -y"
  log "--- apt cache clean/end ---"
}

clean_var_cache() {
  log "--- /var/cache inspection ---"
  run_cmd "sudo du -sh /var/cache || true"
  if confirm "Clear /var/cache (apt cache etc.)?"; then
    run_cmd "sudo rm -rf /var/cache/apt/archives/*"
    run_cmd "sudo rm -rf /var/cache/* || true"
  else
    log "Skipped /var/cache cleanup"
  fi
}

clean_journal() {
  log "--- systemd journal vacuum ---"
  if confirm "Vacuum journal logs to 200M? This will permanently remove old logs."; then
    run_cmd "sudo journalctl --vacuum-size=200M"
  else
    log "Skipped journal vacuum"
  fi
}

clean_var_log() {
  log "--- /var/log cleanup ---"
  run_cmd "sudo du -sh /var/log || true"
  if confirm "Rotate and remove old /var/log files?"; then
    run_cmd "sudo journalctl --rotate || true"
    run_cmd "sudo journalctl --vacuum-time=7d || true"
    run_cmd "sudo find /var/log -type f -name '*.gz' -delete || true"
    run_cmd "sudo find /var/log -type f -name '*.[0-9]' -delete || true"
  else
    log "Skipped /var/log cleanup"
  fi
}

clean_thumbnails() {
  log "--- thumbnail cache clean ---"
  run_cmd "rm -rf $HOME/.cache/thumbnails/* 2>/dev/null || true"
}

clean_browser_cache() {
  log "--- browser cache cleanup (Firefox) ---"
  if [ -d "$HOME/.cache/mozilla" ]; then
    if confirm "Clear Firefox cache (~/.cache/mozilla)?"; then
      run_cmd "rm -rf $HOME/.cache/mozilla/*"
    else
      log "Skipped Firefox cache cleanup"
    fi
  else
    log "No Firefox cache found"
  fi
}

clean_burp_tmp() {
  local bust="$HOME/BurpSuitePro"
  if [ -d "$bust" ]; then
    if confirm "Clean BurpSuite temp/log files in $bust? (keeps config)"; then
      run_cmd "find \"$bust\" -type f \( -name '*.tmp' -o -name '*.log' -o -name '*.bak' \) -delete"
      run_cmd "find \"$bust\" -type f -name 'project-backup*' -delete"
    else
      log "Skipped Burp cleanup"
    fi
  else
    log "No BurpSuitePro folder at $bust"
  fi
}

clean_downloads_installers() {
  log "--- removing common installer files in ~/Downloads (interactive) ---"
  if [ -d "$HOME/Downloads" ]; then
    if confirm "Delete large known installers in ~/Downloads (e.g. burpsuite, Nessus .deb, ISOs)?"; then
      run_cmd "find \"$HOME/Downloads\" -maxdepth 1 -type f \( -iname '*burp*' -o -iname '*burpsuite*' -o -iname '*.deb' -o -iname '*.iso' -o -iname '*.zip' -o -iname '*.tar.gz' \) -size +1M -print -delete"
    else
      log "Skipped deleting installers from Downloads"
    fi
  fi
}

clean_go_cache() {
  if [ -d "$HOME/go" ]; then
    if confirm "Remove entire ~/go workspace (delete all Go binaries/packages)?"; then
      run_cmd "rm -rf $HOME/go"
    else
      log "Skipped Go workspace cleanup"
    fi
  fi
}

# Safe Metasploit reset — requires hard typed confirmation and creates an encrypted DB dump first
clean_msfdb_reset() {
  log "--- Metasploit DB SAFE RESET ---"
  if [ ! -d "/var/lib/postgresql" ]; then
    log "No PostgreSQL directory found; skipping msfdb reset"
    return 0
  fi
  if [ "$DANGEROUS" != true ]; then
    log "msfdb reset is disabled unless --dangerous is passed"
    return 0
  fi
  log "Preparing an encrypted pg_dump backup of Metasploit DB before reset"
  # make sure pg_dump exists
  if ! command -v pg_dump >/dev/null 2>&1; then
    log "pg_dump not found. Attempting to install postgresql-client-common (may ask for sudo)."
    run_cmd "sudo apt-get update && sudo apt-get install -y postgresql-client"
  fi
  # Ask user for confirmation (typed)
  if ! typed_confirm "You are about to RESET the Metasploit DB (this is irreversible)." "RESET-MSFDB"; then
    log "Typed confirmation failed; aborting msfdb reset"
    return 1
  fi
  # create backup
  local dumpfile="$BACKUP_DIR/msfdb_backup_$TS.sql"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  log "Dumping msfdb to $dumpfile (this may take time)"
  if $DRY_RUN; then
    log "DRY-RUN: would pg_dump msfdb to $dumpfile"
  else
    # run pg_dump as postgres user; silence output to avoid leaking to logfile
    sudo -u postgres pg_dump msf > "$dumpfile" 2>/dev/null || sudo -u postgres pg_dumpall > "$dumpfile" 2>/dev/null || { log "pg_dump failed; aborting reset"; return 1; }
    chmod 600 "$dumpfile" 2>/dev/null || true
    log "msfdb dump saved to $dumpfile"
    # encrypt the dump
    if command -v gpg >/dev/null 2>&1; then
      tar -C "$BACKUP_DIR" -czf - "$(basename "$dumpfile")" | gpg --symmetric --cipher-algo AES256 -o "$BACKUP_DIR/msfdb_dump_$TS.sql.gpg"
      if [ $? -eq 0 ]; then
        log "Encrypted msfdb dump created: $BACKUP_DIR/msfdb_dump_$TS.sql.gpg"
        rm -f "$dumpfile"
      else
        log "Encryption of msfdb dump failed; keeping plain dump at $dumpfile"
      fi
    else
      log "gpg not available; plain dump retained at $dumpfile"
    fi
  fi
  # Now perform the reset using msfdb tools — destructive step
  log "Now resetting msfdb (this will remove Metasploit workspaces, loot, and hosts)"
  run_cmd "sudo msfdb stop || true"
  run_cmd "sudo msfdb delete || true"
  run_cmd "sudo msfdb init || true"
  log "msfdb reset attempted"
}

clean_gvm() {
  log "--- GVM/OpenVAS data purge (SAFE wrapper) ---"
  if [ ! -d "/var/lib/gvm" ]; then
    log "No /var/lib/gvm found; skipping"
    return 0
  fi
  if [ "$DANGEROUS" != true ]; then
    log "GVM purge is disabled unless --dangerous is passed"
    return 0
  fi
  if ! typed_confirm "You are about to PURGE GVM/OpenVAS data (this will remove scan results and feeds)." "PURGE-GVM"; then
    log "Typed confirmation failed; aborting GVM purge"
    return 1
  fi
  mkdir -p "$BACKUP_DIR/gvm_backup_$TS"
  log "Archiving /var/lib/gvm into backup folder first (may take time)"
  if $DRY_RUN; then
    log "DRY-RUN: would tar and encrypt /var/lib/gvm"
  else
    sudo tar -C /var/lib -czf "$BACKUP_DIR/gvm_backup_$TS.tar.gz" gvm || { log "Tar of /var/lib/gvm failed"; }
    if command -v gpg >/dev/null 2>&1; then
      gpg --symmetric --cipher-algo AES256 -o "$BACKUP_DIR/gvm_backup_$TS.tar.gz.gpg" "$BACKUP_DIR/gvm_backup_$TS.tar.gz" && rm -f "$BACKUP_DIR/gvm_backup_$TS.tar.gz"
      log "Encrypted GVM backup created: $BACKUP_DIR/gvm_backup_$TS.tar.gz.gpg"
    fi
    if confirm "Delete /var/lib/gvm after backup?"; then
      run_cmd "sudo rm -rf /var/lib/gvm/*"
      run_cmd "sudo gvm-setup || true"
    else
      log "Left /var/lib/gvm in place after backup"
    fi
  fi
}

report_space() {
  log "--- Disk usage summary ---"
  run_cmd "df -h"
  run_cmd "sudo du -sh /var/lib/postgresql || true"
}

main() {
  ensure_prereqs

  # parse args
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --no-log) NO_LOG=true ;;
      --yes|-y) AUTO_YES=true; QUIET=true ;;
      --dangerous) DANGEROUS=true ;;
      --help) usage; exit 0 ;;
      *) echo "Unknown arg $1"; usage; exit 1 ;;
    esac
    shift
  done

  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  umask 077

  log "kali-clean started (dry-run=$DRY_RUN, dangerous=$DANGEROUS, no-log=$NO_LOG)"
  backup_file "/etc/apt/sources.list"
  backup_file "/etc/hosts"

  report_space

  clean_apt
  clean_var_cache
  clean_journal
  clean_var_log
  clean_thumbnails
  clean_browser_cache
  clean_burp_tmp
  clean_downloads_installers
  clean_go_cache

  if confirm "Run optional: Reset msfdb and/or purge GVM (dangerous, requires --dangerous flag)?"; then
    if [ "$DANGEROUS" = true ]; then
      clean_msfdb_reset
      clean_gvm
    else
      log "You must pass --dangerous to enable DB purges. Skipping."
    fi
  else
    log "Skipped optional DB purges"
  fi

  encrypt_backups
  report_space
  log "kali-clean finished"
}

main "$@"
