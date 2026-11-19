# Test stub of the configd client. tree_get_full_hash returns the JSON in
# $ENV{TEST_CONFIGD_TREE} (a file), if set; call_rpc_hash appends each call
# to $ENV{TEST_CONFIGD_RPCS}. vyatta_update_grub.pl makes a client when it
# starts and the actions its tests run never ask it anything.
## no critic (Modules::RequireFilenameMatchesPackage, Modules::ProhibitMultiplePackages) reason: as the real module, which holds both packages
package Vyatta::Configd::Client;
use strict;
use warnings;
use JSON        qw(decode_json encode_json);
use File::Slurp qw(read_file append_file);

our $AUTO = 'auto';

sub new { my ($class) = @_; return bless {}, $class; }

sub tree_get_full_hash {
    my ( $self, $path ) = @_;
    return {} unless $ENV{TEST_CONFIGD_TREE};
    return decode_json( scalar read_file( $ENV{TEST_CONFIGD_TREE} ) );
}

sub call_rpc_hash {
    my ( $self, $module, $rpc, $input ) = @_;
    append_file( $ENV{TEST_CONFIGD_RPCS}, encode_json( [ $module, $rpc, $input ] ) . "\n" )
      if $ENV{TEST_CONFIGD_RPCS};
    return {};
}

# a configuration session, as accepting an ssh host key opens
sub session_setup    { return 1; }
sub commit           { return 1; }
sub session_teardown { return 1; }
sub tree_get_hash    { return {}; }

package Vyatta::Configd;

1;
