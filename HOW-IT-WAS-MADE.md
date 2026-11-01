# How gentooinstall was made

The code, tests and docs were written with an AI coding assistant. I decided what the installer should do and how: which choices it offers, what it leaves out, and how each problem it ran into was fixed. Then I tested it, and it installed Gentoo on my laptop.

## How it's checked

- Every script passes shellcheck.
- About 630 automated tests run the installer's logic against fake commands. They never run as root or touch a disk.
- Test installs, in virtual machines and on a real laptop, covered OpenRC and systemd, ext4, xfs and btrfs, LUKS, all three bootloaders, and desktops including Plasma, GNOME and Sway.

Newer options, like installing next to Windows and keeping Secure Boot on, have tests but haven't run on real hardware yet.

You don't have to take any of this on trust. `./gentooinstall --dry-run` prints every command an install would run without changing anything, and every real install saves the commands it ran to `/var/log/gentooinstall/replay.sh`. [SPEC.md](SPEC.md) says what it does and why, and [ARCHITECTURE.md](ARCHITECTURE.md) how the code fits together.

## Gentoo and AI

In April 2024 the Gentoo Council banned contributions to Gentoo made with AI tools, citing copyright, quality and ethical concerns ([the policy](https://wiki.gentoo.org/wiki/Project:Council/AI_policy)). For this installer that means:

- It isn't part of Gentoo and can't become part of it.
- Its bugs belong in [this project's issues](https://github.com/w0x7y/gentooinstall/issues), not on Gentoo's bug tracker, forums or IRC.
- The policy allows Gentoo to package software that was made with AI tools, but an ebuild for it would itself have to be written without them.
