# kind of duplicate of Makefile.PL
#	but convenient for Continuous Integration

on 'test' => sub {
    requires 'Test::More'     => 0;
};
