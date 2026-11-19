# Test stub, used only where vyatta-config-migrate's real parser is not
# installed: the tests that edit config.boot are skipped then.
package XorpConfigParser;
use strict;
use warnings;

sub new { my ($class) = @_; return bless {}, $class; }

1;
