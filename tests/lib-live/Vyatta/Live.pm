# Test stub of Vyatta::Live for the scripts that use it as a library: the
# image root is $ENV{TEST_LIVE_ROOT}; the calls that change images are
# appended to $ENV{TEST_LIVE_CALLS}, one per line.
package Vyatta::Live;
use strict;
use warnings;
use Exporter    qw(import);
use File::Slurp qw(append_file);

## no critic (Modules::ProhibitAutomaticExportation) reason: as the real module
our @EXPORT = qw(get_live_image_root get_persistence_label delete_image set_default_boot_image
  list_images get_image_version get_image_storage get_running_image get_default_boot_image);
## use critic

sub record_call {
    my @call = @_;
    append_file( $ENV{TEST_LIVE_CALLS}, "@call\n" ) if $ENV{TEST_LIVE_CALLS};
    return;
}

sub get_live_image_root   { return $ENV{TEST_LIVE_ROOT}; }
sub get_persistence_label { return 'persistence'; }
sub delete_image          { my ($name) = @_; return record_call( 'delete_image', $name ); }

sub set_default_boot_image {
    my ($name) = @_;
    return record_call( 'set_default_boot_image', $name );
}
sub list_images            { return ( 'img1', 'img2' ); }
sub get_image_version      { my ($name) = @_; return "$name-version"; }
sub get_image_storage      { return { 'total' => 3 }; }
sub get_running_image      { return 'img1'; }
sub get_default_boot_image { return 'img2'; }

1;
