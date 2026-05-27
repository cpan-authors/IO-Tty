#!perl

use strict;
use warnings;

use Test::More tests => 10;
use IO::Pty;
require POSIX;

# Test slave() returns a valid tty
{
    my $pty = IO::Pty->new;
    ok( defined $pty, "IO::Pty created" );

    my $slave = $pty->slave;
    ok( defined $slave, "slave() returns a handle" );
    ok( POSIX::isatty($slave), "slave is a tty" );
}

# Test close_slave() and slave re-opening
{
    my $pty = IO::Pty->new;
    my $slave1 = $pty->slave;
    my $fileno1 = fileno($slave1);
    ok( defined $fileno1, "first slave has a fileno" );

    $pty->close_slave();

    # After close_slave, calling slave() should re-open it
    my $slave2 = $pty->slave;
    ok( defined $slave2, "slave() works after close_slave()" );
    ok( POSIX::isatty($slave2), "re-opened slave is a tty" );
}

# Test that calling slave() twice returns the same object
{
    my $pty = IO::Pty->new;
    my $slave1 = $pty->slave;
    my $slave2 = $pty->slave;
    is( fileno($slave1), fileno($slave2),
        "slave() returns same handle when not closed" );
}

# Test that slave() after close_slave() gets a fresh handle
{
    my $pty = IO::Pty->new;
    my $slave1 = $pty->slave;
    my $fn1 = fileno($slave1);

    $pty->close_slave();

    my $slave2 = $pty->slave;
    ok( defined fileno($slave2),
        "re-opened slave has a valid fileno" );
}

# Test that slave() after close_slave() does not cache (GitHub #91)
# If the re-opened slave is cached, the parent keeps an open fd to the
# slave side, preventing EOF detection on the master when the child exits.
{
    my $pty = IO::Pty->new;
    $pty->close_slave;

    my $slave_tmp = $pty->slave;
    ok( defined fileno($slave_tmp), "temporary slave has valid fd" );
    undef $slave_tmp;

    ok( ! exists ${*$pty}{'io_pty_slave'},
        "slave() after close_slave() does not re-cache" );
}
