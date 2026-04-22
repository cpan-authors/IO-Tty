#!perl

use strict;
use warnings;

use Test::More;
use IO::Pty;

my $is_win32 = ( $^O eq 'MSWin32' );

# On Windows, slave() is not available but ttyname() works (returns conpty name)
if ($is_win32) {
    plan tests => 3;
} else {
    plan tests => 5;
}

# Test ttyname() on the master pty object
{
    my $pty = IO::Pty->new;
    ok( defined $pty, "IO::Pty created" );

    my $ttyname = $pty->ttyname;
    ok( defined $ttyname, "ttyname() returns a value" );

    if ($is_win32) {
        like( $ttyname, qr{conpty}i, "ttyname() looks like a ConPTY name" );
    } else {
        like( $ttyname, qr{/dev/}, "ttyname() looks like a device path" );
    }
}

# Test that slave ttyname matches what ttyname() returns (POSIX only)
SKIP: {
    skip "slave() not available on Windows", 2 if $is_win32;

    my $pty = IO::Pty->new;
    my $ttyname = $pty->ttyname;
    my $slave = $pty->slave;
    ok( defined $slave, "got slave" );

    # The XS-level ttyname on the slave should match the stored name
    my $slave_ttyname = IO::Tty::ttyname($slave);
    is( $slave_ttyname, $ttyname,
        "XS ttyname() on slave matches Pty->ttyname()" );
}
