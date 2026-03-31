#!perl

use strict;
use warnings;

use Test::More;

use IO::Pty;

# Portable fd-open check: dup the fd to see if it's still in the table.
# We avoid POSIX::fcntl() which is unreliable on Perl 5.42, and avoid
# raw syscall() which requires OS-specific syscall numbers.
sub fd_is_open {
    my $fd = shift;
    if ( open my $fh, '<&', $fd ) {
        close $fh;
        return 1;
    }
    return 0;
}

# Some kernels (e.g. NetBSD) revoke the slave pty when the master is
# closed, making the slave fd invalid even if Perl still holds a
# reference.  Probe for this so we can skip the external-ref tests.
my $kernel_revokes_slave;
{
    my $slave_fileno;
    my $slave_ref;
    {
        my $probe = IO::Pty->new;
        $slave_ref    = $probe->slave;
        $slave_fileno = $slave_ref->fileno;
    }
    # Master is gone.  Is the slave fd still usable?
    $kernel_revokes_slave = !fd_is_open($slave_fileno);
    undef $slave_ref;
}

plan tests => $kernel_revokes_slave ? 2 : 5;

# Test that destroying an IO::Pty object closes the slave fd
# when no external references are held.
# See https://github.com/toddr/IO-Tty/issues/14

{
    my $slave_fileno;
    {
        my $pty = IO::Pty->new;
        ok( defined $pty, "IO::Pty created" );
        $slave_fileno = $pty->slave->fileno;
    }
    # $pty is now out of scope and destroyed.
    # The slave fd should have been closed (no external refs).
    ok( !fd_is_open($slave_fileno),
        "slave fd $slave_fileno closed after IO::Pty destruction (no external refs)" );
}

# Test that the slave stays open when an external reference is held,
# and closes only when that reference is dropped.
# See https://github.com/cpan-authors/IO-Tty/issues/62

SKIP: {
    skip "kernel revokes slave when master closes (e.g. NetBSD)", 3
        if $kernel_revokes_slave;

    my $slave_fileno;
    my $slave_ref;
    {
        my $pty = IO::Pty->new;
        ok( defined $pty, "IO::Pty created for external-ref test" );
        $slave_ref    = $pty->slave;
        $slave_fileno = $slave_ref->fileno;
    }
    # $pty destroyed, but $slave_ref still holds the slave.
    ok( fd_is_open($slave_fileno),
        "slave fd $slave_fileno stays open while external ref held" );

    # Now drop the external reference.
    undef $slave_ref;
    ok( !fd_is_open($slave_fileno),
        "slave fd $slave_fileno closed after external ref dropped" );
}
