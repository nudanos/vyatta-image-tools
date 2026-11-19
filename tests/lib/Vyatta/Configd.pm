# Test stub: vyatta_update_grub.pl makes a configd client when it starts;
# the actions the tests run never ask it anything.
## no critic (Modules::RequireFilenameMatchesPackage, Modules::ProhibitMultiplePackages) reason: as the real module, which holds both packages
package Vyatta::Configd::Client;
use strict;
use warnings;

our $AUTO = 'auto';

sub new { my ($class) = @_; return bless {}, $class; }

package Vyatta::Configd;

1;
