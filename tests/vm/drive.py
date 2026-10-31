#!/usr/bin/env python3
"""Runs one VM test inside the gi-vm container: install from the live ISO, reboot, check the result.

Usage: drive.py RUN_DIR. RUN_DIR holds xfer/ (repo.tar, config, secrets, guest.sh), made by run.sh.
Big files go to /work (the host's ~/.cache/gi-vm). Prints PASS or FAIL last; exits 0 on PASS.
"""
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pexpect

BASE = "https://distfiles.gentoo.org/releases/amd64/autobuilds/current-install-amd64-minimal/"
# Gentoo Linux Release Engineering (Automated Weekly Release Key), from https://www.gentoo.org/downloads/signatures/
RELENG_FPR = "13EBBDBEDE7A12775DFDB1BABB572E0E2D182910"
OVMF_CODE = "/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS = "/usr/share/OVMF/OVMF_VARS_4M.fd"
ISO_DIR = Path("/work/iso")
SERIAL_ARGS = "console=tty0 console=ttyS0,115200"
SSH_PORT = 2222

# Seconds. Generous, but every wait ends.
T_DOWNLOAD = 3600
T_ISO_BOOT = 600
T_EFIVARS = 300
T_INSTALL = 6 * 3600  # a console install with binary packages takes well under one
T_GUEST_END = 900
T_POWEROFF = 300
T_BOOT = 900
T_CHECK = 600

t0 = time.monotonic()


def say(msg):
    m, s = divmod(int(time.monotonic() - t0), 60)
    print(f"[{m // 60:02d}:{m % 60:02d}:{s:02d}] {msg}", flush=True)


class Fail(Exception):
    pass


def sh(*cmd, timeout=600, **kw):
    return subprocess.run(cmd, check=True, timeout=timeout, text=True, **kw)


def parse_kv(path):
    d = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            d[k] = v
    return d


def harness_opts(path):
    """Words after "# gi-vm:" in the config: instructions for the harness, comments to gentooinstall."""
    return {w for m in re.finditer(r"^#\s*gi-vm:(.*)$", Path(path).read_text(), re.M) for w in m.group(1).split()}


def fetch_iso():
    """Downloads the current minimal ISO once, verifies it against the release key, extracts the boot files."""
    ISO_DIR.mkdir(parents=True, exist_ok=True)
    latest = sh("curl", "-fsSL", "--max-time", "60", BASE + "latest-install-amd64-minimal.txt",
                capture_output=True).stdout
    name = re.search(r"^(install-amd64-minimal-\S+\.iso)\s", latest, re.M).group(1)
    iso = ISO_DIR / name
    verified = ISO_DIR / (name + ".verified")
    if not verified.exists():
        say(f"downloading {name}")
        sh("curl", "-fL", "-sS", "-C", "-", "--retry", "3", "--max-time", str(T_DOWNLOAD), "-o", str(iso), BASE + name,
           timeout=T_DOWNLOAD + 60)
        sh("curl", "-fsSL", "--max-time", "60", "-o", f"{iso}.asc", BASE + name + ".asc")
        with tempfile.TemporaryDirectory() as gnupg:
            env = dict(os.environ, GNUPGHOME=gnupg)
            sh("gpg", "-q", "--keyserver", "hkps://keys.gentoo.org", "--recv-keys", RELENG_FPR, env=env,
               capture_output=True)
            st = subprocess.run(["gpg", "--status-fd", "1", "--verify", f"{iso}.asc", str(iso)], env=env,
                                capture_output=True, text=True, timeout=600).stdout
        # VALIDSIG's last field is the primary key fingerprint, whichever subkey signed.
        if not re.search(rf"^\[GNUPG:\] VALIDSIG .* {RELENG_FPR}$", st, re.M):
            iso.unlink()
            raise Fail(f"{name}: bad or missing signature by {RELENG_FPR}; deleted it\n{st}")
        verified.touch()
        say(f"{name}: good signature by the Gentoo release key")
    ext = ISO_DIR / name.removesuffix(".iso")
    if not (ext / "boot/gentoo.igz").exists():
        ext.mkdir(exist_ok=True)
        sh("bsdtar", "-xf", str(iso), "-C", str(ext), "boot/gentoo", "boot/gentoo.igz", "boot/grub/grub.cfg")
    # The ISO's own command line, from its first menu entry, plus the serial console.
    grub = (ext / "boot/grub/grub.cfg").read_text()
    args = re.search(r"^\s*linux\s+/boot/gentoo\s+(.*)$", grub, re.M).group(1).strip()
    return iso, ext / "boot/gentoo", ext / "boot/gentoo.igz", f"{args} {SERIAL_ARGS}"


def qemu(run, extra, log_name):
    # A fixed slot gives the disk a known by-path name, /dev/disk/by-path/pci-0000:00:05.0. A config
    # that names it there gets a disk without a serial, so it has no by-id link.
    serial = "" if "/by-path/" in parse_kv(run / "xfer/config").get("disk", "") else ",serial=gi-target"
    cmd = ["qemu-system-x86_64", "-machine", "q35,accel=kvm", "-cpu", "host", "-smp", "8", "-m", "8G",
           "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={OVMF_CODE}",
           "-drive", f"if=pflash,format=raw,unit=1,file={run}/OVMF_VARS.fd",
           "-drive", f"file={run}/target.img,format=raw,if=none,id=target",
           "-device", f"virtio-blk-pci,drive=target,bus=pcie.0,addr=0x5{serial}",
           "-display", "none", "-serial", "stdio", "-monitor", f"unix:{run}/monitor.sock,server=on,wait=off",
           "-no-reboot"] + extra
    (run / f"{log_name}.cmd").write_text(shlex.join(cmd) + "\n")
    child = pexpect.spawn(cmd[0], cmd[1:], encoding="utf-8", codec_errors="replace", timeout=None,
                          searchwindowsize=8192)
    child.logfile_read = open(run / f"{log_name}.log", "w")
    return child


# Patterns must end where the line does: the console arrives in chunks, and a match takes what's there.
def wait(child, pattern, timeout, what):
    i = child.expect([pattern, pexpect.EOF, pexpect.TIMEOUT], timeout=timeout)
    if i == 1:
        raise Fail(f"the VM exited while waiting for {what}")
    if i == 2:
        raise Fail(f"timed out after {timeout} s waiting for {what}")
    return child.match


def stop(child, timeout):
    """Waits for the VM to power off by itself, then kills it."""
    if child.isalive() and child.expect([pexpect.EOF, pexpect.TIMEOUT], timeout=timeout) == 1:
        say("VM didn't power off; killing it")


def monitor(run, command):
    try:
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(10)
            s.connect(str(run / "monitor.sock"))
            s.recv(4096)
            s.sendall(command.encode() + b"\n")
            time.sleep(2)
    except OSError as e:
        say(f"monitor command {command!r} failed: {e}")


def install(run, timing):
    iso, kernel, initrd, append = fetch_iso()
    sh("qemu-img", "create", "-q", "-f", "raw", str(run / "target.img"), "60G")
    sh("cp", OVMF_VARS, str(run / "OVMF_VARS.fd"))
    sh("mkfs.ext4", "-q", "-L", "gi-xfer", "-d", str(run / "xfer"), str(run / "xfer.img"), "1G")
    if "interrupt-world" in harness_opts(run / "xfer/config"):
        live_session(run, timing, iso, kernel, initrd, append, "serial-install", "", interrupt=True)
        live_session(run, timing, iso, kernel, initrd, append, "serial-resume", "resume")
    else:
        live_session(run, timing, iso, kernel, initrd, append, "serial-install", "")


def live_session(run, timing, iso, kernel, initrd, append, log_name, mode, interrupt=False):
    """Boots the ISO and runs guest.sh MODE. With interrupt, pulls the plug halfway through the package install."""
    say(f"booting {iso.name} (serial: {log_name}.log)")
    child = qemu(run, ["-drive", f"file={run}/xfer.img,format=raw,if=none,id=xfer",
                       "-device", "virtio-blk-pci,drive=xfer,serial=gi-xfer",
                       "-cdrom", str(iso), "-kernel", str(kernel), "-initrd", str(initrd), "-append", append,
                       "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0"], log_name)
    rc = guest_rc = None
    try:
        start = time.monotonic()
        wait(child, r"root@livecd [^\r\n]*# ", T_ISO_BOOT, "the live system's root shell")
        timing.setdefault("iso_boot", time.monotonic() - start)
        say(f"live system up after {time.monotonic() - start:.0f} s")
        child.sendline("mkdir -p /mnt/xfer && mount /dev/disk/by-id/virtio-gi-xfer /mnt/xfer && "
                       f"bash /mnt/xfer/guest.sh {mode}; echo GI-VM-GUEST-EXIT=$?; poweroff")
        m = wait(child, r"GI-VM: (efivars ok[^\r\n]*|FAIL[^\r\n]*)[\r\n]", T_EFIVARS, "the efivars check")
        say(m.group(1))
        if m.group(1).startswith("FAIL"):
            raise Fail(m.group(1))
        wait(child, r"GI-VM: install start", T_EFIVARS, "the install to start")
        start = time.monotonic()
        say(f"gentooinstall {mode or 'install'} running (timeout {T_INSTALL // 3600} h)")
        if interrupt:
            # The package install's progress lines, "N of M  category/package (binary)".
            while True:
                m = wait(child, r"(\d+) of (\d+)  \S+ \((?:binary|source)\)", T_INSTALL, "the package install")
                if 2 * int(m.group(1)) >= int(m.group(2)):
                    break
            timing["install"] = time.monotonic() - start
            say(f"pulling the plug at package {m.group(1)} of {m.group(2)}")
            return
        m = wait(child, r"GI-VM: install exit (\d+) after", T_INSTALL, "gentooinstall to finish")
        timing["install"] = timing.get("install", 0) + time.monotonic() - start
        rc = int(m.group(1))
        say(f"gentooinstall exited {rc} after {(time.monotonic() - start) / 60:.1f} min")
        m = wait(child, r"GI-VM-GUEST-EXIT=(\d+)[\r\n]", T_GUEST_END, "the guest script to finish")
        guest_rc = int(m.group(1))
        stop(child, T_POWEROFF)
    finally:
        child.terminate(force=True)
        child.logfile_read.close()
        # Also after a timeout: whatever the guest wrote to the transfer disk helps the diagnosis.
        # rdump won't write into an existing directory, and the disk has all of an earlier session's files.
        shutil.rmtree(run / "out", ignore_errors=True)
        subprocess.run(["debugfs", "-R", f"rdump /out {run}", str(run / "xfer.img")], capture_output=True, timeout=600)
    if rc != 0:
        raise Fail(f"gentooinstall exited {rc}; see out/install.log and {log_name}.log")
    if guest_rc != 0:
        raise Fail(f"guest.sh exited {guest_rc} after the install (instrumenting the boot entry)")


def ssh(user, pw, command, timeout):
    try:
        return subprocess.run(
            ["sshpass", "-e", "ssh", "-p", str(SSH_PORT), "-o", "StrictHostKeyChecking=no",
             "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10",
             "-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive",
             f"{user}@127.0.0.1", command],
        env=dict(os.environ, SSHPASS=pw), capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess([], 124, "", f"ssh timed out after {timeout} s\n")


def as_root(cfg, q, command):
    """COMMAND run through the config's sudo or doas, with the user's password Q (shell-quoted)."""
    if cfg.get("privilege", "sudo") == "sudo":
        return f"printf '%s\\n' {q} | sudo -S -p '' sh -c {shlex.quote(command)}"
    # doas reads the password from the terminal and flushes what was typed ahead, so script gives it
    # one and the password follows once doas waits for it.
    return (f"{{ sleep 3; printf '%s\\n' {q}; }} | script -qec {shlex.quote('doas sh -c ' + shlex.quote(command))} "
            "/dev/null | tr -d '\\r'")


# Login screens of the desktops that have one with display_manager=auto.
DMS = {"plasma": "sddm", "gnome": "gdm", "xfce": "lightdm", "budgie": "lightdm", "cinnamon": "lightdm"}
# Window managers: what their start command and shipped default config run, and a command that
# loads that config without a seat (empty where there's none; sway's --validate needs a seat).
WMS = {
    "i3": ("startx i3 xterm dmenu_run i3status i3lock xss-lock dex", "i3 -C -c /etc/i3/config"),
    "dwm": ("startx dwm st dmenu_run", ""),
    "sway": ("sway foot wmenu-run swaybg dbus-update-activation-environment", ""),
    "dwl": ("dwl foot wmenu-run dbus-update-activation-environment", ""),
    "hyprland": ("start-hyprland Hyprland kitty hyprlauncher", "Hyprland --verify-config"),
    "niri": ("niri alacritty fuzzel waybar swaylock", ""),
    "mangowm": ("mango foot rofi", ""),
}

# Where each Wayland session's keyboard layout lands, as a check on the layout $l.
KBD = {
    "sway": "grep -E \"^export XKB_DEFAULT_LAYOUT=.?$l.?\\$\" /etc/profile.env",
    "dwl": "grep -E \"^export XKB_DEFAULT_LAYOUT=.?$l.?\\$\" /etc/profile.env",
    "niri": "grep -E \"^export XKB_DEFAULT_LAYOUT=.?$l.?\\$\" /etc/profile.env",
    "mangowm": "grep -x \"xkb_rules_layout=\\\"$l\\\"\" /etc/mango/config.conf",
    "hyprland": "grep -F \"kb_layout = \\\"$l\\\"\" /etc/xdg/hypr/hyprland.lua",
    "budgie": "grep -x \"XKBLAYOUT=\\\"$l\\\"\" /etc/default/keyboard",
}


def checks(cfg, pw):
    """(name, shell command run as the test user that must exit 0) for the config's answers."""
    init, fs, swap = cfg.get("init", "openrc"), cfg.get("filesystem", "ext4"), cfg.get("swap", "zram")
    user = cfg["users"].split()[0]
    q = shlex.quote(pw)
    c = [
        (f"init is {init}",
         "test \"$(cat /proc/1/comm)\" = init && test -d /run/openrc && rc-status -r" if init == "openrc"
         else "test \"$(cat /proc/1/comm)\" = systemd && test -d /run/systemd/system && echo systemd"),
        ("no failed services",
         "! rc-status -a | grep -E 'crashed|failed'" if init == "openrc"
         else "test -z \"$(systemctl --failed --no-legend)\" || { systemctl --failed; false; }"),
        (f"root filesystem is {fs}", f"findmnt -no FSTYPE,SOURCE / && test \"$(findmnt -no FSTYPE /)\" = {fs}"),
        ("fstab has no discard", "cat /etc/fstab && ! grep -v '^[[:space:]]*#' /etc/fstab | grep -qw discard"),
        (f"swap is {swap}",
         {"none": "cat /proc/swaps && test \"$(wc -l < /proc/swaps)\" -eq 1",
          "zram": "cat /proc/swaps && grep -q '^/dev/zram' /proc/swaps",
          "file": "cat /proc/swaps && grep -q 'file' /proc/swaps"}[swap]),
        ("network is up",
         "ip -4 route show default | grep . && getent hosts distfiles.gentoo.org && "
         "{ curl -fsS -o /dev/null https://distfiles.gentoo.org/ || wget -q -O /dev/null https://distfiles.gentoo.org/; }"),
        (f"hostname is {cfg.get('hostname', 'gentoo')}",
         f"cat /proc/sys/kernel/hostname && test \"$(cat /proc/sys/kernel/hostname)\" = {cfg.get('hostname', 'gentoo')}"),
        # SPEC 16: the installer's own firmware entry boots, not the firmware's fallback for the disk.
        ("booted from the installer's firmware boot entry",
         "efibootmgr && cur=$(efibootmgr | sed -n 's/^BootCurrent: //p') && "
         "efibootmgr | grep \"^Boot$cur\" | grep -v auto_created_boot_option"),
        ("emerge --info works", "out=$(emerge --info) && printf '%s\\n' \"$out\" | head -n 3"),
        ("kernel and command line (info)", "uname -r && cat /proc/cmdline"),
        ("disk and memory use (info)", "df -h / /efi && free -m"),
    ]
    net = cfg.get("network", "networkmanager")
    c.append((f"{net} running", {"networkmanager": "pgrep -x NetworkManager && nmcli -t -f STATE general",
                                 "dhcpcd": "pgrep -x dhcpcd", "networkd": "pgrep -f systemd-networkd"}[net]))
    if cfg.get(f"user.{user}.admin", "yes") == "yes":
        c.append((f"{user} is in wheel", "id && id -nG | tr ' ' '\\n' | grep -qx wheel"))
        c.append((f"{cfg.get('privilege', 'sudo')} works", f"{as_root(cfg, q, 'id -u')} | grep -x 0"))
        if cfg.get("root", "password") == "locked":
            c.append(("root is locked", f"{as_root(cfg, q, 'passwd -S root')} | grep '^root L'"))
    if cfg.get("encryption", "none") == "luks2":
        c.append(("root is on LUKS", "findmnt -no SOURCE / | grep '^/dev/mapper/'"))
    if cfg.get("bootloader", "systemd-boot") == "systemd-boot":
        # systemd-boot sets LoaderInfo; GRUB doesn't.
        c.append(("booted by systemd-boot",
                  "f=/sys/firmware/efi/efivars/LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f && "
                  "test -e $f && tail -c +5 $f | tr -d '\\0'"))
    elif cfg["bootloader"] == "limine":
        # Limine sets the same variable to "Limine <version>".
        c.append(("booted by Limine",
                  "f=/sys/firmware/efi/efivars/LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f && "
                  "tail -c +5 $f | tr -d '\\0' | grep '^Limine '"))
    else:
        c.append(("booted by GRUB", "grep -o 'BOOT_IMAGE=[^ ]*' /proc/cmdline"))
    desktop = cfg.get("desktop", "plasma")
    if desktop in WMS:
        # Window managers start from the console; their shipped default config must find its programs.
        progs, conf = WMS[desktop]
        if desktop == "i3" and net == "networkmanager":
            progs += " nm-applet"
        c.append((f"{desktop}'s start command and default programs are installed",
                  f"for p in {progs}; do command -v $p || {{ echo \"missing $p\"; exit 1; }}; done && "
                  "grep -A1 'start the desktop with:' ~/first-steps.txt"))
        if conf:
            c.append((f"{desktop}'s default config loads", conf))
    if desktop in KBD:
        # Wayland sessions don't read xorg.conf.d; the installer gives each the X layout its own way.
        c.append((f"{desktop} gets the keyboard layout",
                  "l=$(sed -n 's/.*\"XkbLayout\" \"\\([^\"]*\\)\".*/\\1/p' /etc/X11/xorg.conf.d/00-keyboard.conf) && "
                  f"echo \"layout $l\" && {KBD[desktop]}"))
    if desktop == "none" or desktop in WMS or cfg.get("display_manager", "auto") == "none":
        c.append(("login prompt on tty1", "pgrep -a -t tty1 agetty"))
    else:
        dm = DMS[desktop]
        c.append((f"{dm} enabled and running",
                  f"rc-update show default | grep -w display-manager && rc-status default | grep -w display-manager | "
                  f"grep -w started && grep -x 'DISPLAYMANAGER=\"{dm}\"' /etc/conf.d/display-manager && pgrep -a {dm}"
                  if init == "openrc" else
                  f"systemctl is-enabled {dm}.service && systemctl is-active {dm}.service && "
                  f"systemctl get-default | grep -x graphical.target && pgrep -a {dm}"))
        if dm == "lightdm":
            # LightDM keeps running when its greeter's X server fails; the greeter only runs once X is up.
            c.append(("lightdm-gtk-greeter running", "pgrep -af lightdm-gtk-greeter"))
    return c


def boot_and_check(run, cfg, secrets, timing):
    user = cfg["users"].split()[0]
    pw = secrets[f"user.{user}.password"]
    say("booting the installed disk (serial: serial-boot.log)")
    child = qemu(run, ["-netdev", f"user,id=n0,hostfwd=tcp:127.0.0.1:{SSH_PORT}-:22",
                       "-device", "virtio-net-pci,netdev=n0"], "serial-boot")
    results = []
    try:
        start = time.monotonic()
        while True:
            # Reading the console keeps QEMU from blocking on a full pty.
            i = child.expect([r"[Pp]assphrase for", pexpect.EOF, pexpect.TIMEOUT], timeout=5)
            if i == 0:
                say("typing the LUKS passphrase")
                child.sendline(secrets["luks_passphrase"])
            elif i == 1:
                raise Fail("the installed system powered off or rebooted instead of booting")
            if ssh(user, pw, "true", 30).returncode == 0:
                break
            if time.monotonic() - start > T_BOOT:
                raise Fail(f"no ssh login as {user} within {T_BOOT} s of boot; see serial-boot.log")
        timing["boot"] = time.monotonic() - start
        say(f"logged in as {user} over ssh after {timing['boot']:.0f} s")
        # A display manager's greeter takes a little longer to come up than a getty.
        time.sleep(10 if cfg.get("desktop", "plasma") == "none" else 30)
        monitor(run, f"screendump {run}/screen.png -f png")
        with open(run / "checks.txt", "w") as out:
            for name, command in checks(cfg, pw):
                r = ssh(user, pw, command, T_CHECK)
                ok = r.returncode == 0
                results.append((name, ok))
                say(f"{'ok  ' if ok else 'FAIL'} {name}")
                out.write(f"== {'ok' if ok else 'FAIL'}: {name}\n$ {command.replace(shlex.quote(pw), '***')}\n"
                          f"{r.stdout}{r.stderr}\n")
    finally:
        child.terminate(force=True)
        child.logfile_read.close()
    return results


def main():
    run = Path(sys.argv[1])
    cfg, secrets = parse_kv(run / "xfer/config"), parse_kv(run / "xfer/secrets")
    timing, results, error = {}, [], None
    try:
        install(run, timing)
        results = boot_and_check(run, cfg, secrets, timing)
    except (Fail, subprocess.SubprocessError) as e:
        error = str(e)
    passed = error is None and results and all(ok for _, ok in results)
    lines = [f"result: {'PASS' if passed else 'FAIL'}"]
    if error:
        lines.append(f"error: {error}")
    for k, label in (("iso_boot", "ISO boot to shell"), ("install", "install"), ("boot", "installed boot to ssh")):
        if k in timing:
            lines.append(f"{label}: {timing[k]:.0f} s ({timing[k] / 60:.1f} min)")
    if results:
        lines.append(f"checks: {sum(ok for _, ok in results)}/{len(results)} ok")
    lines += [f"  {'ok  ' if ok else 'FAIL'} {name}" for name, ok in results]
    (run / "result.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines[1:]))
    print("PASS" if passed else "FAIL")
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
