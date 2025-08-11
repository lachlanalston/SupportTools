# Shortcuts & Commands

Quick reference for common helpdesk keyboard shortcuts and commands.

## Table of Contents

- [Shortcuts](#shortcuts)
  - [Microsoft Remote Desktop – Reset Password](#microsoft-remote-desktop--reset-password)
  - [Reload Graphics Driver](#reload-graphics-driver)
  - [macOS Reset NVRAM/PRAM](#macos-reset-nvrampram)
  - [Safe Boot](#safe-boot)
- [Commands](#commands)
  - [Battery Report](#battery-report)
  - [System Boot Time](#system-boot-time)

---

## Shortcuts

### Microsoft Remote Desktop – Reset Password  
**Windows:** `Ctrl + Alt + End`  
Sends the equivalent of `Ctrl + Alt + Delete` to the remote session, allowing you to change a password or access security options.

**macOS:** `fn + Control + Option + Delete`  
(Some Mac keyboards may require `fn + Control + Option + Backspace` depending on key mapping.)

---

### Reload Graphics Driver  
**Windows:** `Ctrl + Shift + Windows + B`  
Restarts the graphics driver without rebooting. Useful for fixing frozen or glitchy displays.

---

### macOS Reset NVRAM/PRAM  
**macOS:** Restart Mac and hold `Option + Command + P + R` for about 20 seconds.

---

### Safe Boot  
**Windows:** Hold the `Shift` key and click **Restart** (power icon in lower-left corner).  
**macOS:** Restart Mac and hold the `Shift` key.

---

## Commands

### Battery Report  
`powercfg /batteryreport`

---

### System Boot Time  
`systeminfo | find System Boot Time`

---
