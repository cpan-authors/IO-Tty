# CLAUDE.md — IO-Tty

## What is IO-Tty

IO::Tty is a CPAN module providing low-level pseudo-terminal (pty)
allocation and I/O for Perl. It is a dependency of Expect.pm and other
modules that need terminal emulation.

## Building and Testing

```bash
perl Makefile.PL && make && make test
```

Standard ExtUtils::MakeMaker workflow. Tests run in ~4 seconds.

For a distribution test: `make disttest`

## Architecture

- **Tty.xs** — XS/C code: pty allocation (POSIX methods + Windows
  ConPTY), tty operations, ioctl constants. The POSIX and Windows code
  paths are separated by `#ifdef HAVE_CONPTY`.
- **Tty.pm** — Perl layer for IO::Tty (terminal operations, set_raw,
  winsize, constant export).
- **Pty.pm** — Higher-level IO::Pty (master/slave management, spawn on
  Windows, make_slave_controlling_terminal on POSIX).
- **Makefile.PL** — Feature detection (devices, headers, symbols, ConPTY).
  Uses a WriteMakefile1 shim for backward-compatible EUMM features.

## Conventions

- Main branch is **main**.
- PRs target upstream `cpan-authors/IO-Tty`; `toddr-bot/IO-Tty` is the fork.
- `$VERSION` in Tty.pm is the single source of truth; Pty.pm and POD
  reference it.
- POSIX constants (TIOCNOTTY, TIOCSCTTY, etc.) are discovered at build
  time and generated into IO::Tty::Constant.

## Testing Rules

- **Never use BAIL_OUT** in tests. It stops the entire test suite
  immediately, which is always undesirable. Use `plan skip_all` instead
  when a test cannot run on the current platform.
- Tests that are platform-specific must use `plan skip_all` with a clear
  reason (e.g., "ConPTY tests only run on Windows").
- Indirect object syntax (`new IO::Pty`) is deprecated in Perl 5.36+.
  Always use `IO::Pty->new`.

## Windows ConPTY Notes

The Windows implementation uses:
- ConPTY (CreatePseudoConsole) API for pseudo-terminal allocation.
- A duplex named pipe as the master fd, with bridge threads copying
  data between the pipe and ConPTY I/O handles.
- Named pipes (not sockets) because Perl's sysread/syswrite on Windows
  use CRT _read/_write (ReadFile/WriteFile), which works for pipes but
  not for Winsock sockets.
- `O_NOCTTY` is POSIX-only; any use must be guarded with `#ifdef`.
- `alarm()` does not interrupt blocking I/O on Windows; do not rely on
  it for timeouts in tests.
