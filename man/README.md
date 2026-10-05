# Utility manpages

The section 1 pages here document all five installed utilities. Edit these
roff sources alongside changes to public CLI options and behavior. Examples,
configuration paths, and exit statuses should agree with the implementation and
the command-line reference in `manual/04-command-line.md`.

DUB post-build commands stage the pages in `build/man/man1`. The root `Rattspec`
has a `man-<utility>` target for each page, included in the default build. To
stage all pages independently without a D compiler:

```sh
python3 tools/build-man.py
```

The Python installer and `install.sh` copy authored pages to
`<prefix>/share/man/man1`, including `--build`, custom build directories, upgrades,
and `--destdir` packaging. No man or roff tool is a build dependency.

Preview and check the pages when the local tools are available:

```sh
man -l man/rattbuild.1
mandoc -T lint man/*.1
groff -man -Tutf8 man/rattbuild.1
python3 -m unittest discover -s tests/tooling
```
