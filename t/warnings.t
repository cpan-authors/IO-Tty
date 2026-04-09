#!perl

use strict;
use warnings;

use Test::More tests => 3;
use IO::Pty;

# IO::Tty and IO::Pty register custom warning categories via warnings::register.
# warnings::enabled() (no args) is called from WITHIN the module to check if
# the caller has warnings active.  Inject a test function to verify this works.

{
    package IO::Tty;
    sub _test_warnings_enabled { return warnings::enabled() ? 1 : 0 }
}

# With 'use warnings' in effect, module warnings should be enabled
{
    use warnings;
    ok( IO::Tty::_test_warnings_enabled(),
        "IO::Tty warnings enabled when caller has 'use warnings'" );
}

# With 'no warnings' in effect, module warnings should be disabled
{
    no warnings;
    ok( !IO::Tty::_test_warnings_enabled(),
        "IO::Tty warnings disabled when caller has 'no warnings'" );
}

# Selective suppression of IO::Tty category
{
    use warnings;
    no warnings 'IO::Tty';
    ok( !IO::Tty::_test_warnings_enabled(),
        "IO::Tty warnings disabled with 'no warnings \"IO::Tty\"'" );
}
