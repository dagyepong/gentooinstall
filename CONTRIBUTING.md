# Contributing

Thanks for helping. Bug reports, fixes, new options and docs are all welcome.

## AI-assisted contributions are welcome

This installer was written with an AI coding assistant ([how it was made](HOW-IT-WAS-MADE.md)), and contributions made with one are welcome here too. Gentoo itself doesn't accept them ([its policy](https://wiki.gentoo.org/wiki/Project:Council/AI_policy)), so this is a place where they can go.

However a change was written, two things are asked of everyone:

- You understand what you submit and can answer questions about it.
- You ran the tests, and checked anything that changes what gets installed (see below).

If an assistant helped, say so in the pull request, so reviewers know where to look closely.

Since this project isn't part of Gentoo, please don't send its bugs or patches to Gentoo's bug tracker, forums or IRC.

## Where to start

- To report a bug, use the [bug report form](https://github.com/w0x7y/gentooinstall/issues/new?template=bug_report.yml) and attach the log.
- Issues labeled [good first issue](https://github.com/w0x7y/gentooinstall/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) are small and self-contained. [help wanted](https://github.com/w0x7y/gentooinstall/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22) ones are bigger.
- For anything large, open an issue first, so we agree on the approach before you write it.

## Setting up

```sh
git clone https://github.com/w0x7y/gentooinstall
cd gentooinstall
tests/bootstrap.sh                                 # once: downloads shellcheck and bats into .tools/
tests/run.sh                                       # shellcheck and every test
tests/run.sh tests/disk.bats lib/steps/disk.sh     # only the files you name
```

The tests never run as root or touch a disk. Never run the installer itself on your own machine, since it partitions disks. Try changes with `--dry-run`, in a virtual machine, or with the VM tests.

## What a change needs

- Read [SPEC.md](SPEC.md), which says what the installer does and why, and [ARCHITECTURE.md](ARCHITECTURE.md), which covers the code layout, the conventions and the test helpers. A change in behavior updates SPEC.md, and a new config key goes in ARCHITECTURE.md's table.
- Follow the conventions in ARCHITECTURE.md: Bash 5, shellcheck clean, `local` for every variable, everything that changes a system through `run_cmd`, `run_chroot` or the file writers, and comments that say why rather than what.
- New logic gets a test in `tests/`. A bug fix gets a test that fails without it.
- Check Portage facts, like package names, USE flags and keywords, against the real tree rather than memory. A Gentoo container works:

  ```sh
  docker create -v /var/db/repos/gentoo --name gentoo-tree gentoo/portage
  docker run --rm --volumes-from gentoo-tree gentoo/stage3 emerge --pretend --verbose app-editors/vim
  ```

- For a change to what gets installed, run the VM test closest to it, like `tests/vm/run.sh tests/vm/configs/smoke.conf`. It needs Docker and `/dev/kvm`; see [tests/vm/README.md](tests/vm/README.md).
- Text the user reads, like questions, help lines, messages and docs, is plain US English in short sentences. Help lines fit on one 78-column line, since dialog cuts the rest.

## Pull requests

- One change per pull request, with a commit message that says what changed and why.
- Run `tests/run.sh` before you push, and say which VM tests you ran, if any.
- By contributing, you agree that your contribution is licensed under the [MIT license](LICENSE).
