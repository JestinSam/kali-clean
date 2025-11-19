# kali-clean

**kali-clean** is an interactive, privacy-first cleanup and encrypted backup tool for Kali Linux & Debian systems.

It safely removes unnecessary files, rotates logs, compresses system journals, cleans browser/Burp caches, and backs up sensitive files using **GPG AES-256 encryption**.

The script is designed with **security**, **auditability**, and **zero-data-loss** principles.

---

## 🔐 Features

### ✔ Safe Cleanup (Interactive)
- Apt cache cleanup  
- `/var/cache` cleanup  
- Journal log vacuuming  
- Log rotation  
- Thumbnail cleanup  
- Firefox cache cleanup  
- BurpSuite temp/log cleanup  
- Cleanup of large installers in `~/Downloads`  
- Optional Go workspace cleanup  

### ✔ Encrypted Backups
Backs up:
- `/etc/hosts`
- `/etc/apt/sources.list`
- Optional Metasploit DB dump
- Optional GVM/OpenVAS data

Backups use:
- **GPG symmetric encryption (AES-256)**
- Stored at: `~/.kali-clean-backups/`
- Folder permissions automatically set to `700`

Plain files can be auto-deleted after encryption.

---

## ✔ Dry-Run Mode

No actions performed; shows everything that *would* happen:

```bash
./kali-clean.sh --dry-run
```

# 🚀 Usage

### Run safely (recommended first):

```bash
chmod +x kali-clean.sh
./kali-clean.sh --dry-run

```
Normal cleanup (interactive):
```
./kali-clean.sh
```
Dangerous mode (Metasploit / GVM purge)

Requires:

--dangerous flag

AND typed confirmation (RESET-MSFDB or PURGE-GVM)
```
./kali-clean.sh --dangerous
```
#📦 Backup Location

Encrypted backups are stored in:
```
~/.kali-clean-backups/*.tar.gz.gpg
```
Backup directory permissions:
```
chmod 700 ~/.kali-clean-backups
```
### 
The script enforces this automatically.


