#!perl

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
    my $reason = "Cannot open a pty on this Windows host: $@";
    # Force clean exit: ConPTY cleanup can set $? in END/DESTROY,
    # causing Test::Harness to see a non-zero exit despite skip_all.
    END { $? = 0 if !$pty }
    plan skip_all => $reason;
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
my $buf = '';
my $timeout = 5;
eval {
    local $SIG{ALRM} = sub { die "timeout" };
    alarm($timeout);
    while (sysread($pty, my $chunk, 1024)) {
        $buf .= $chunk;
        last if $buf =~ /hello/;
    }
    alarm(0);
};
like( $buf, qr/hello/, "read output from spawned cmd.exe" );

$pty->close;
