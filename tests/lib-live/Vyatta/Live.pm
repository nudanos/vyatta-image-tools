# Test stub of Vyatta::Live for the scripts that only need the image root:
# it is $ENV{TEST_LIVE_ROOT}.
package Vyatta::Live;
use strict;
use warnings;
use Exporter qw(import);

## no critic (Modules::ProhibitAutomaticExportation) reason: as the real module
our @EXPORT = qw(get_live_image_root get_persistence_label);
## use critic

sub get_live_image_root   { return $ENV{TEST_LIVE_ROOT}; }
sub get_persistence_label { return 'persistence'; }

1;
