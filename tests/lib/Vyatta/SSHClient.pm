# Test stub of vyatta-client-ssh's Vyatta::SSHClient: no host key is known,
# so an scp or sftp copy asks to accept the one ssh-keyscan reports.
package Vyatta::SSHClient;
use strict;
use warnings;
use Exporter qw(import);

## no critic (Modules::ProhibitAutomaticExportation) reason: as the real module
our @EXPORT = qw($SSH_KNOWN_HOSTS @SSH_KEY_TYPES ssh_get_fingerprint ssh_key_select
  ssh_get_host_to_delete ssh_delete_config ssh_set_config);
## use critic
our $SSH_KNOWN_HOSTS = '/nonexistent/ssh_known_hosts';
our @SSH_KEY_TYPES   = ( "RSA", "ED25519" );

sub ssh_key_select         { my ( $file, $host, @entries ) = @_; return ( $entries[0] ); }
sub ssh_get_fingerprint    { return ( 'SHA256:test', 'ED25519' ); }
sub ssh_get_host_to_delete { return; }
sub ssh_delete_config      { return; }
sub ssh_set_config         { return; }

1;
