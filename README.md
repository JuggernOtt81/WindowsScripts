# Media Copy Script v2.0

**Robust media file organizer with automatic categorization by file extension**

[![PowerShell](https://img.shields.io/badge/PowerShell-7%2B-blue)](https://github.com/PowerShell/PowerShell)
[![License](https://img.shields.io/badge/License-MIT-green)]()
[![Status](https://img.shields.io/badge/Status-Production%20Ready-brightgreen)]()

---

## 📋 Overview

A professional PowerShell script that copies and organizes files from a source directory to a destination, automatically categorizing them by file type (images, video, audio, documents, etc.). Features robust error handling, progress tracking, and enterprise-grade logging.

### ✨ Key Features

- 🗂️ **Automatic Organization** - Files sorted into category folders by extension
- 🚀 **High Performance** - Multi-threaded robocopy with configurable batch sizes
- 🔄 **Smart Retry Logic** - Handles temporary failures with exponential backoff
- 📊 **Progress Tracking** - Real-time progress indicators and detailed logging
- 🛡️ **Collision Handling** - Hash-based unique naming for duplicate files
- 📝 **Comprehensive Logging** - File, console, and Windows Event Log support
- ⚡ **WhatIf Support** - Test operations without actually copying files
- 🎯 **Interactive Launcher** - User-friendly wizard with presets

---

## 🚀 Quick Start

### Option 1: Interactive Launcher (Easiest)

Double-click `Start-MediaCopy.bat` and follow the prompts.

### Option 2: Direct Command Line

```powershell
.\robocopy.ps1 -Source "C:\Photos" -Destination "D:\Organized" -LogFile "copy.log"
```

### Option 3: Test First (Recommended)

```powershell
.\robocopy.ps1 -Source "C:\Photos" -Destination "D:\Organized" -LogFile "copy.log" -WhatIf
```

---

## 📦 What's Included

```
robo/
├── Start-MediaCopy.bat          # Windows batch launcher (double-click)
├── Start-MediaCopy.ps1          # Interactive PowerShell launcher
├── robocopy.ps1                 # Main script (advanced users)
├── extensions.xml               # Extension-to-category mapping (source of truth)
│
├── modules/                     # Core functionality modules
│   ├── Logging.psm1            # Logging with Event Log support
│   ├── Elevation.psm1          # Admin privilege handling
│   ├── ExtensionMap.psm1       # File categorization logic
│   └── CopyOps.psm1            # Copy operations and collision handling
│
└── tests/
    └── Logging.Tests.ps1       # Pester tests for logging
```

---

## 🎯 Launcher Presets

The interactive launcher offers optimized presets:

| Preset | Description | Best For |
|--------|-------------|----------|
| **Quick** | Fast copy with minimal validation | Small datasets (< 1000 files) |
| **Standard** | Balanced performance (⭐ recommended) | General use |
| **HighPerformance** | Maximum speed | Fast disks (SSD/NVMe) |
| **Network** | Optimized for network shares | UNC paths, slow connections |
| **Safe** | Maximum reliability, continues on errors | Large/unreliable sources |

---

## 📂 How It Works

### Input
```
C:\Photos/
├── IMG_001.jpg
├── IMG_002.jpg
├── video.mp4
├── song.mp3
└── document.pdf
```

### Output
```
D:\Organized/
├── images/
│   ├── IMG_001.jpg
│   └── IMG_002.jpg
├── video/
│   └── video.mp4
├── audio/
│   └── song.mp3
└── documents/
    └── document.pdf
```

---

## ⚙️ Requirements

- **Windows 10/11** or **Windows Server 2016+**
- **PowerShell 7+** (PowerShell Core)
  - Download: https://github.com/PowerShell/PowerShell/releases
- **Robocopy** (built into Windows)
- **Admin rights** (optional, only for Event Log registration)

### Check Your PowerShell Version
```powershell
$PSVersionTable.PSVersion
# Should show 7.0 or higher
```

---

## 🎓 Usage Examples

### Example 1: Basic Copy
```powershell
.\Start-MediaCopy.ps1 -Source "C:\Media" -Destination "D:\Backup"
```

### Example 2: High Performance
```powershell
.\Start-MediaCopy.ps1 -Preset HighPerformance -Source "C:\Photos" -Destination "E:\Organized"
```

### Example 3: Network Share with Retries
```powershell
.\robocopy.ps1 `
    -Source "\\NAS\Photos" `
    -Destination "E:\Backup" `
    -LogFile "logs\nas_backup.log" `
    -MaxRetries 5 `
    -RobocopyThreads 4 `
    -ContinueOnFailure
```

### Example 4: Test Without Copying
```powershell
.\robocopy.ps1 -Source "C:\Test" -Destination "D:\Test" -LogFile "test.log" -WhatIf
```

---

## 📊 File Categories

Files are automatically organized into these categories:

| Category | Extensions |
|----------|-----------|
| **images** | jpg, png, gif, bmp, webp, heic, raw, cr2, etc. |
| **video** | mp4, avi, mkv, mov, wmv, flv, etc. |
| **audio** | mp3, wav, flac, aac, ogg, wma, etc. |
| **documents** | pdf, doc, docx, txt, xls, ppt, etc. |
| **archives** | zip, rar, 7z, tar, gz, etc. |
| **code** | js, py, java, c, cpp, html, css, etc. |
| **executables** | exe, msi, apk, dmg, etc. |
| **cad** | dwg, dxf, stl, step, skp, etc. |
| **databases** | db, sqlite, mdb, accdb, etc. |
| **uncategorized** | Unknown extensions |

See `extensions.xml` for extension-to-category mapping.

---

## 🛠️ Advanced Configuration

### Custom Batch Size
```powershell
.\robocopy.ps1 ... -BatchSize 100  # Process 100 files at a time
```

### More Threads (Faster)
```powershell
.\robocopy.ps1 ... -RobocopyThreads 16  # Use 16 threads
```

### Continue on Errors
```powershell
.\robocopy.ps1 ... -ContinueOnFailure  # Don't stop on errors
```

### Custom Extension Map (XML)
```powershell
\.\robocopy.ps1 ... -ExtensionMapPath "my_extensions.xml"
```

---

## 📖 Documentation

| Document | Description |
|----------|-------------|
| **OPERATIONS_RUNBOOK.md** | Operational guide and troubleshooting |
| **TEST_PLAN.md** | Test plan and scenarios |

---

## 🔍 Troubleshooting

### "Event Log source not registered"
Event Log entries are optional. If not running as admin, the script will continue and write to file logs.

### "robocopy.exe not found"
Robocopy is built into Windows. Check with:
```powershell
where.exe robocopy  # Should show C:\Windows\System32\robocopy.exe
```

### "PowerShell 7 required"
Install from: https://github.com/PowerShell/PowerShell/releases

### Files not copying correctly
1. Check log file for errors
2. Verify source path exists
3. Ensure destination has enough space
4. Try with `-WhatIf` first

See `FIXES_AND_IMPROVEMENTS.md` for detailed troubleshooting.

---

## ✅ Pre-Flight Checklist

Before running on important data:

- [ ] Tested with `-WhatIf` flag
- [ ] Tested with small dataset (10-20 files)
- [ ] Verified destination has enough space
- [ ] Reviewed log file output
- [ ] Backed up source data (if critical)
- [ ] Checked PowerShell version (7+)

---

## 🏆 Highlights

- Robust logging with optional Windows Event Log integration (throttled)
- Deduplication index to skip already-copied files
- Secure extension map parsing and category organization
- WhatIf/Confirm support and progress indicators
- Baseline performance tracking and audit trail

---

## 🤝 Contributing

Suggestions and improvements welcome! This is a production-ready script that has been:
- ✅ Code reviewed
- ✅ Tested with various scenarios
- ✅ Documented comprehensively
- ✅ Fixed for all known issues

---

## 📄 License

MIT License - Feel free to use and modify for personal or commercial use.

---

## 🙏 Acknowledgments

- Built with PowerShell best practices
- Leverages Windows robocopy for performance
- Inspired by media library organization needs
- Code reviewed and production-hardened

---

## 📞 Support

For help:
1. Check `QUICK_REFERENCE.md` for common commands
2. See `FIXES_AND_IMPROVEMENTS.md` for detailed troubleshooting
3. Review log files for error details
4. Check Windows Event Viewer → Application → MediaCopyScript

---

## 🎯 Quick Links

- 📚 [Quick Reference](QUICK_REFERENCE.md) - Most common commands
- 🔧 [Troubleshooting Guide](FIXES_AND_IMPROVEMENTS.md#support-and-troubleshooting) - Fix common issues
- 🎨 [Customize Categories](EXTENSION_MAP_GUIDE.md) - Edit extension mapping
- 💻 [Code Review](CODE_REVIEW.md) - Technical details

---

**Last Updated:** November 2, 2025

**Happy organizing!** 🎉
