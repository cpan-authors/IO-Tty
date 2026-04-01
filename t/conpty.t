#!perl

# Force clean exit when skipping: ConPTY cleanup can set $? in
# END/DESTROY, causing Test::Harness to see a non-zero exit despite
# skip_all.  This END must be registered before any 'use' statements
# so that it runs last (END blocks execute in LIFO order).
# Use a package variable so the END block (which compiles in its own
# scope) can see the flag.
our $_conpty_force_zero;
END { $? = 0 if $_conpty_force_zero }

use strict;
use warnings;

use Test::More;

if ($^O ne 'MSWin32') {
    plan skip_all => 'ConPTY tests only run on Windows';
}

use IO::Pty;

# Test 1: basic pty creation
my $pty = eval { IO::Pty->new };
if (!$pty) {
    $_conpty_force_zero = 1;
    plan skip_all => "Cannot open a pty on this Windows host: $@";
}

plan tests => 4;
ok( $pty, "IO::Pty->new succeeded on Windows" );

# Test 2: ttyname returns something
my $name = $pty->ttyname;
ok( defined $name && $name =~ /^conpty/, "ttyname returns conpty name: $name" );

# Test 3: spawn a process
my $pid = $pty->spawn("cmd.exe /c echo hello");
ok( $pid && $pid > 0, "spawn returned pid: $pid" );

# Test 4: read output from spawned process
# Note: sysread on the ConPTY named pipe currently blocks indefinitely.
# alarm() does not interrupt blocking I/O on Windows, and select()
# does not work with named pipe handles (only sockets).
# See PR #43 discussion with @tonycoz.
#
# Use a subprocess as a watchdog to prevent CI from hanging for hours.
# The watchdog kills us after 15 seconds if sysread hasn't returned.
my $my_pid = $$;
my $watchdog_pid = system(1, $^X, '-e',
    "sleep(15); kill(9, $my_pid)");

my $buf = '';
while (1) {
    my $n = sysread($pty, my $chunk, 1024);
    if (defined $n && $n > 0) {
        $buf .= $chunk;
        last if $buf =~ /hello/;
    } else {
        last;  # EOF or error
    }
}

# Kill watchdog if we got here normally
kill(9, $watchdog_pid) if $watchdog_pid;

like( $buf, qr/hello/, "read output from spawned cmd.exe" );

$pty->close;
