# Test stub of vyatta-cfg's Vyatta::RestClient: the local clone tests never
# reach a remote router.
## no critic (Modules::RequireFilenameMatchesPackage) reason: as the real module, whose class is RestClient
package RestClient;
use strict;
use warnings;

sub new { my ($class) = @_; return bless {}, $class; }

1;
