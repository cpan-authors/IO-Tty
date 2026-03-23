# Documentation at the __END__

package IO::Pty;

use strict;
use warnings;
use Carp;
use IO::Tty;
BEGIN {
    IO::Tty->import(qw(TIOCSCTTY TCSETCTTY TIOCNOTTY)) if $^O ne 'MSWin32';
}
use IO::File;
require POSIX if $^O ne 'MSWin32';

our @ISA     = qw(IO::Handle);
our $VERSION = '1.23';    # keep same as in Tty.pm

my $is_windows = ($^O eq 'MSWin32');

eval { local $^W = 0; local $SIG{__DIE__}; require IO::Stty };
push @ISA, "IO::Stty" if ( not $@ );    # if IO::Stty is installed

sub new {
    my ($class) = $_[0] || "IO::Pty";
    $class = ref($class) if ref($class);
    @_ <= 1 or croak 'usage: new $class';

    my ( $ptyfd, $ttyfd, $ttyname ) = pty_allocate();

    croak "Cannot open a pty" if not defined $ptyfd;

    my $pty = $class->SUPER::new_from_fd( $ptyfd, "r+" );
    croak "Cannot create a new $class from fd $ptyfd: $!" if not $pty;
    $pty->autoflush(1);
    bless $pty => $class;

    ${*$pty}{'io_pty_ttyname'} = $ttyname;

    if ($is_windows) {
        # On Windows with ConPTY, the slave side is internal to the
        # pseudo console.  There is no separate slave fd to wrap.
        ${*$pty}{'io_pty_conpty'} = 1;
    } else {
        my $slave = IO::Tty->new_from_fd( $ttyfd, "r+" );
        croak "Cannot create a new IO::Tty from fd $ttyfd: $!" if not $slave;
        $slave->autoflush(1);

        ${*$pty}{'io_pty_slave'}     = $slave;
        ${*$slave}{'io_tty_ttyname'} = $ttyname;
    }

    return $pty;
}

sub ttyname {
    @_ == 1 or croak 'usage: $pty->ttyname();';
    my $pty = shift;
    ${*$pty}{'io_pty_ttyname'};
}

sub close_slave {
    @_ == 1 or croak 'usage: $pty->close_slave();';

    my $master = shift;

    if ( exists ${*$master}{'io_pty_slave'} ) {
        close ${*$master}{'io_pty_slave'};
        delete ${*$master}{'io_pty_slave'};
    }
}

sub slave {
    @_ == 1 or croak 'usage: $pty->slave();';

    my $master = shift;

    if ($is_windows) {
        croak "slave() is not available on Windows. "
            . "Use \$pty->spawn(\$command) instead.";
    }

    if ( exists ${*$master}{'io_pty_slave'} ) {
        return ${*$master}{'io_pty_slave'};
    }

    my $tty = ${*$master}{'io_pty_ttyname'};

    my $slave_fd = IO::Tty::_open_tty($tty);
    croak "Cannot open slave $tty: $!" if $slave_fd < 0;

    my $slave = IO::Tty->new_from_fd( $slave_fd, "r+" );
    croak "Cannot create IO::Tty from fd $slave_fd: $!" if not $slave;
    $slave->autoflush(1);

    ${*$slave}{'io_tty_ttyname'}    = $tty;
    ${*$master}{'io_pty_slave'}     = $slave;

    return $slave;
}

sub make_slave_controlling_terminal {
    @_ == 1 or croak 'usage: $pty->make_slave_controlling_terminal();';

    my $self = shift;

    if ($is_windows) {
        # On Windows, ConPTY handles the console association internally.
        # This method is a no-op.
        return 1;
    }

    local (*DEVTTY);

    # loose controlling terminal explicitly
    if ( defined &TIOCNOTTY ) {
        if ( open( \*DEVTTY, "/dev/tty" ) ) {
            ioctl( \*DEVTTY, TIOCNOTTY(), 0 );
            close \*DEVTTY;
        }
    }

    # Create a new 'session', lose controlling terminal.
    if ( POSIX::setsid() == -1 ) {
        warn "setsid() failed, strange behavior may result: $!\r\n" if $^W;
    }

    if ( open( \*DEVTTY, "/dev/tty" ) ) {
        warn "Could not disconnect from controlling terminal?!\n" if $^W;
        close \*DEVTTY;
    }

    # now open slave, this should set it as controlling tty on some systems
    my $ttyname = ${*$self}{'io_pty_ttyname'};
    my $slv     = IO::Tty->new;
    $slv->open( $ttyname, O_RDWR )
      or croak "Cannot open slave $ttyname: $!";

    if ( not exists ${*$self}{'io_pty_slave'} ) {
        ${*$self}{'io_pty_slave'} = $slv;
    }
    else {
        $slv->close;
    }

    # Acquire a controlling terminal if this doesn't happen automatically
    if ( not open( \*DEVTTY, "/dev/tty" ) ) {
        if ( defined &TIOCSCTTY ) {
            if ( not defined ioctl( ${*$self}{'io_pty_slave'}, TIOCSCTTY(), 0 ) ) {
                warn "warning: TIOCSCTTY failed, slave might not be set as controlling terminal: $!" if $^W;
            }
        }
        elsif ( defined &TCSETCTTY ) {
            if ( not defined ioctl( ${*$self}{'io_pty_slave'}, TCSETCTTY(), 0 ) ) {
                warn "warning: TCSETCTTY failed, slave might not be set as controlling terminal: $!" if $^W;
            }
        }
        else {
            warn "warning: You have neither TIOCSCTTY nor TCSETCTTY on your system\n" if $^W;
            return 0;
        }
    }

    if ( not open( \*DEVTTY, "/dev/tty" ) ) {
        warn "Error: could not connect pty as controlling terminal!\n";
        return undef;
    }
    else {
        close \*DEVTTY;
    }

    return 1;
}

sub spawn {
    @_ == 2 or croak 'usage: $pty->spawn($command)';
    my ( $self, $command ) = @_;

    if (not $is_windows) {
        croak "spawn() is only available on Windows. "
            . "Use fork() and make_slave_controlling_terminal() on POSIX.";
    }

    my ($pid) = IO::Pty::conpty_spawn_process( fileno($self), $command );
    croak "Cannot spawn process: $command" if not defined $pid;
    return $pid;
}

sub set_winsize {
    my $self = shift;
    if ($is_windows) {
        my ($row, $col) = @_;
        my ($ret) = IO::Pty::conpty_resize_console( fileno($self),
            $row || 24, $col || 80 );
        return $ret;
    }
    my $winsize = IO::Tty::pack_winsize(@_);
    ioctl( $self, IO::Tty::Constant::TIOCSWINSZ(), $winsize )
      or croak "Cannot TIOCSWINSZ - $!";
}

sub DESTROY {
    my $self = shift;
    if ($is_windows && ${*$self}{'io_pty_conpty'}) {
        IO::Pty::conpty_close_console( fileno($self) );
    }
    if ( exists ${*$self}{'io_pty_slave'} ) {
        close ${*$self}{'io_pty_slave'};
        delete ${*$self}{'io_pty_slave'};
    }
}

*clone_winsize_from = \&IO::Tty::clone_winsize_from;
*get_winsize        = \&IO::Tty::get_winsize;
*set_raw            = \&IO::Tty::set_raw;

1;

__END__

=head1 NAME

IO::Pty - Pseudo TTY object class

=head1 VERSION

1.23

=head1 SYNOPSIS

    use IO::Pty;

    $pty = IO::Pty->new;

    # POSIX (Unix/Linux/macOS/Cygwin):
    $slave  = $pty->slave;

    foreach $val (1..10) {
	print $pty "$val\n";
	$_ = <$slave>;
	print "$_";
    }

    close($slave);

    # Windows (Strawberry Perl, requires Windows 10 1809+):
    $pty = new IO::Pty;
    $pid = $pty->spawn("cmd.exe");
    print $pty "echo hello\r\n";
    my $buf;
    sysread($pty, $buf, 1024);
    print $buf;


=head1 DESCRIPTION

C<IO::Pty> provides an interface to allow the creation of a pseudo tty.

C<IO::Pty> inherits from C<IO::Handle> and so provide all the methods
defined by the C<IO::Handle> package.

Please note that pty creation is very system-dependent.  If you have
problems, see L<IO::Tty> for help.

On Windows (native Perl, e.g. Strawberry Perl), IO::Pty uses the
Windows ConPTY (Pseudo Console) API, available since Windows 10
version 1809.  The Windows implementation has some differences from
POSIX; see L</"WINDOWS NOTES"> below.


=head1 CONSTRUCTOR

=over 3

=item new

The C<new> constructor takes no arguments and returns a new file
object which is the master side of the pseudo tty.

=back

=head1 METHODS

=over 4

=item ttyname()

Returns the name of the slave pseudo tty. On UNIX machines this will
be the pathname of the device.  On Windows this returns a synthetic
name like "conpty0".  Use this name for informational purpose only,
to get a slave filehandle, use slave().

=item slave()

The C<slave> method will return the slave filehandle of the given
master pty, opening it anew if necessary.  If IO::Stty is installed,
you can then call C<$slave-E<gt>stty()> to modify the terminal settings.

B<Not available on Windows.>  Use C<spawn()> instead.

=item close_slave()

The slave filehandle will be closed and destroyed.  This is necessary
in the parent after forking to get rid of the open filehandle,
otherwise the parent will not notice if the child exits.  Subsequent
calls of C<slave()> will return a newly opened slave filehandle.

=item make_slave_controlling_terminal()

This will set the slave filehandle as the controlling terminal of the
current process, which will become a session leader, so this should
only be called by a child process after a fork(), e.g. in the callback
to C<sync_exec()> (see L<Proc::SyncExec>).  See the C<try> script
(also C<test.pl>) for an example how to correctly spawn a subprocess.

On Windows this is a no-op since ConPTY handles console association
automatically via C<spawn()>.

=item spawn($command)

B<Windows only.>  Spawns a child process attached to the pseudo
console and returns the process ID.  The command string is passed
to CreateProcessW.  Example:

  my $pid = $pty->spawn("cmd.exe");
  my $pid = $pty->spawn("powershell.exe -NoProfile");

On POSIX systems, use fork() + make_slave_controlling_terminal()
instead.

=item set_raw()

Will set the pty to raw.  Note that this is a one-way operation, you
need IO::Stty to set the terminal settings to anything else.

On some systems, the master pty is not a tty.  This method checks for
that and returns success anyway on such systems.  Note that this
method must be called on the slave, and probably should be called on
the master, just to be sure, i.e.

  $pty->slave->set_raw();
  $pty->set_raw();


=item clone_winsize_from(\*FH)

Gets the terminal size from filehandle FH (which must be a terminal)
and transfers it to the pty.  Returns true on success and undef on
failure.  Note that this must be called upon the I<slave>, i.e.

 $pty->slave->clone_winsize_from(\*STDIN);

On some systems, the master pty also isatty.  I actually have no
idea if setting terminal sizes there is passed through to the slave,
so if this method is called for a master that is not a tty, it
silently returns OK.

See the C<try> script for example code how to propagate SIGWINCH.

=item get_winsize()

Returns the terminal size, in a 4-element list.

 ($row, $col, $xpixel, $ypixel) = $tty->get_winsize()

=item set_winsize($row, $col, $xpixel, $ypixel)

Sets the terminal size. If not specified, C<$xpixel> and C<$ypixel> are set to
0.  As with C<clone_winsize_from>, this must be called upon the I<slave>.

On Windows, this calls ResizePseudoConsole() and can be called on the
master pty object directly.  Only C<$row> and C<$col> are used.

=back

=head1 WINDOWS NOTES

On native Windows (Strawberry Perl, ActivePerl), IO::Pty uses the
ConPTY API.  Key differences from POSIX:

=over 4

=item *

B<No fork().>  Use C<$pty-E<gt>spawn($command)> to create a child
process attached to the pseudo console.

=item *

B<No slave filehandle.>  The C<slave()> and C<close_slave()> methods
are not available.  ConPTY manages the slave side internally.

=item *

B<No controlling terminal.>  C<make_slave_controlling_terminal()> is
a no-op.  ConPTY automatically associates the console with the
spawned process.

=item *

B<No termios.>  C<set_raw()> is a no-op on Windows.  Terminal
constants (TIOCSCTTY, etc.) are not available.

=item *

B<Requires Windows 10 1809+.>  The ConPTY API was introduced in the
October 2018 Update.

=back


=head1 SEE ALSO

L<IO::Tty>, L<IO::Tty::Constant>, L<IO::Handle>, L<Expect>, L<Proc::SyncExec>


=head1 MAILING LISTS

As this module is mainly used by Expect, support for it is available
via the two Expect mailing lists, expectperl-announce and
expectperl-discuss, at

  http://lists.sourceforge.net/lists/listinfo/expectperl-announce

and

  http://lists.sourceforge.net/lists/listinfo/expectperl-discuss


=head1 AUTHORS

Originally by Graham Barr E<lt>F<gbarr@pobox.com>E<gt>, based on the
Ptty module by Nick Ing-Simmons E<lt>F<nik@tiuk.ti.com>E<gt>.

Now maintained and heavily rewritten by Roland Giersig
E<lt>F<RGiersig@cpan.org>E<gt>.

Contains copyrighted stuff from openssh v3.0p1, authored by 
Tatu Ylonen <ylo@cs.hut.fi>, Markus Friedl and Todd C. Miller
<Todd.Miller@courtesan.com>.


=head1 COPYRIGHT

Now all code is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

Nevertheless the above AUTHORS retain their copyrights to the various
parts and want to receive credit if their source code is used.
See the source for details.


=head1 DISCLAIMER

THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS
OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
DAMAGE.

In other words: Use at your own risk.  Provided as is.  Your mileage
may vary.  Read the source, Luke!

And finally, just to be sure:

Any Use of This Product, in Any Manner Whatsoever, Will Increase the
Amount of Disorder in the Universe. Although No Liability Is Implied
Herein, the Consumer Is Warned That This Process Will Ultimately Lead
to the Heat Death of the Universe.

=cut

