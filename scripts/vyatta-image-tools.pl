#!/usr/bin/perl
# SPDX-License-Identifier: GPL-2.0-only

# Copyright (c) 2017-2020, AT&T Intellectual Property.
# All Rights Reserved.

# Copyright (c) 2014-2017 by Brocade Communications Systems, Inc.
# All rights reserved.

use strict;
use warnings;

use Getopt::Long;
use lib "/opt/vyatta/share/perl5/";

use IO::Prompt;
use File::Slurp qw(read_file);

use Vyatta::Configd;
use Vyatta::Live;
use Vyatta::SSHClient;
use IPC::Run3;
use URI;

my ( $show, $delete, $updateone );
my $check = 1;
my @copy;
my @update;
my $live_image_root = get_live_image_root();
my $u               = '';
my $p               = '';
my $si              = '';
my $insecure        = $ENV{VY_COPY_INSECURE};
my $rtdomain        = $ENV{VYATTA_VRF};
$u  = $ENV{VY_COPY_USER}       if defined $ENV{VY_COPY_USER};
$p  = $ENV{VY_COPY_PASS}       if defined $ENV{VY_COPY_PASS};
$si = $ENV{VY_COPY_SOURCEINTF} if defined $ENV{VY_COPY_SOURCEINTF};

# URL schemes copy file takes (set before the actions below run)
my %url_schemes = map { $_ => 1 } qw(tftp http ftp scp sftp);

# the direction of a curl transfer
my $DOWNLOAD              = 0;
my $UPLOAD                = 1;
my $VYATTA_SHARED_STORAGE = '/opt/vyatta/sbin/vyatta_shared_storage';

GetOptions(
    "show=s"      => \$show,
    "delete=s"    => \$delete,
    "update=s{2}" => \@update,
    "updateone=s" => \$updateone,
    "copy=s{2}"   => \@copy,
    "check"       => \$check
);

if ( defined $show ) {
    show($show);
}
if ( defined $delete ) {
    delete_file($delete);
}
if (@update) {
    update(@update);
}
if ( defined($updateone) ) {
    update( $updateone, "running" );
}
if (@copy) {

    # Per requirement, set source interface according to
    # 'security ssh-client source-interface'
    if ( !length $si ) {
        my $client = Vyatta::Configd::Client->new();
        my $ret    = eval { $client->tree_get_hash("security ssh-client source-interface"); };
        $si = $ret->{'source-interface'} if defined $ret->{'source-interface'};
    }
    copy(@copy);
}

sub check_home {
    my ($file) = @_;
    my $uid = read_file('/proc/self/loginuid');
    chomp $uid;
    my $home;
    if ($uid) {
        my @pwe = getpwuid($uid);
        $home = $pwe[7] if ( scalar(@pwe) >= 8 );
    }
    return if !defined($home) || length($home) <= 1;
    return substr( $file, 0, length($home) ) eq $home;
}

sub check_file_perm {
    my ( $file, $perm ) = @_;
    return 1 unless $check;
    return 1 unless ( -x ${VYATTA_SHARED_STORAGE} );
    return 1 if check_home($file);
    my $result;
    my @cmd = ( ${VYATTA_SHARED_STORAGE}, '--check', ${perm}, ${file} );
    run3( \@cmd, \undef, \$result );
    chomp $result;
    return 1 if ( defined($result) && $result eq "allowed" );
    print "Cannot access $file: permission denied\n";
    return;
}

# The place a file argument names and its path: running, disk-install, an
# image's name, or url (the argument itself)
sub conv_file {
    my ($filein) = @_;
    my $file = $filein;
    my $topdir;
    if ( $file =~ m{(.+?)://(.*)}x ) {
        $topdir = $1;
        $file   = $2;
    }
    elsif ( $file =~ m{^/}x ) {
        $topdir = "running";
    }
    else {
        print "File: $filein not found \n";
        exit 1;
    }
    if ( $topdir eq "running" ) {
        $file = "/$file";
    }
    elsif ( lc($topdir) eq 'disk-install' ) {
        $file = "$live_image_root/$file";
    }
    elsif ( $url_schemes{ lc($topdir) } ) {
        $file   = $filein;
        $topdir = 'url';
    }
    else {
        my $found;
        foreach (qw(live-rw persistence persistence/rw)) {
            print "$live_image_root/boot/$topdir/$_ \n";

            if ( -e "$live_image_root/boot/$topdir/$_/$file" ) {
                $found = "$live_image_root/boot/$topdir/$_/$file";
                last;
            }
        }

        # not one of the image's directories: the file is not there
        if ( !defined $found ) {
            print "Image $topdir not found!\n";
            exit 1;
        }
        $file = $found;
    }

    # Trim extra /'s for pretty output
    $file =~ s{^//}{/}gx;
    return ( $topdir, $file );
}

sub conv_file_to_rel {
    my ( $topdir, $filename ) = @_;
    if ( $topdir eq "running" ) {
        $filename =~ s{/}{$topdir://}x;
    }
    elsif ( $topdir eq "disk-install" ) {
        $filename =~ s{\Q$live_image_root\E/}{$topdir://}x;
    }
    else {
        my $image_dirs = qr{(?:live-rw|persistence|persistence/rw)}x;
        $filename =~ s{\Q$live_image_root\E/boot/\Q$topdir\E/$image_dirs/}{$topdir://}x;
    }
    return $filename;
}

sub delete_file {
    my ($file) = @_;
    ( my $topdir, $file ) = conv_file($file);
    if ( $topdir eq 'url' ) {
        print "Cannot delete files from a url\n";
        exit 1;
    }
    exit 1 unless check_file_perm( $file, 'rw' );
    if ( -d $file ) {
        my $print_dir = conv_file_to_rel( $topdir, $file );
        if ( y_or_n("Do you want to erase the entire $print_dir directory?") ) {
            system( 'rm', '-rf', '--', $file );
            print("Directory erased\n");
        }
    }
    elsif ( -f $file ) {
        my $print_file = conv_file_to_rel( $topdir, $file );
        if ( y_or_n("Do you want to erase the $print_file file?") ) {
            system( 'rm', '-rf', '--', $file );
            print("File erased\n");
        }
    }
    return;
}

# $text with each line's eight-space indent removed, after a newline, and
# without its last newline: the form of the questions below
sub question {
    my ($text) = @_;
    $text =~ s/^[ ]{8}//mgx;
    chomp $text;
    return "\n$text";
}

sub insecure_confirm {
    my ($host) = @_;

    return 0 unless $insecure;

    my $msg = question(<<"END");
        The authenticity of host '$host' cannot be verified.
        You have chosen to skip host validation. While the traffic is encrypted,
        this option is insecure in that the remote host identification will
        not be checked. So man-in-the-middle attacks (MITM) cannot be detected
        due to a subsequent change to the public key of the host.
        By accepting, you are trusting this host for this SSH connection.
        Are you sure you want to continue?
END

    return 1 if y_or_n($msg);

    $insecure = undef;
    return 0;
}

sub ssh_keys_manage {
    my ($uristr) = @_;
    return unless $uristr =~ m{(.+?)://(.*)}x;

    my $scheme = lc($1);
    my $part   = $2;
    return unless $scheme eq "scp" || $scheme eq "sftp";

    # URI module does not support scp, use sftp which has same scheme handling.
    # Do not use canonical form so that uppercase characters kept in hostname,
    # but this is then not normalized so trailing ':' must be removed.
    my $uri  = URI->new( "sftp://" . $part );
    my $host = $uri->host();
    my $port = $uri->port();
    $host =~ s/:.*//x;
    return unless length($host);
    return if insecure_confirm($host);

    my $known_hosts_file = $SSH_KNOWN_HOSTS;
    my @vrfcmd           = ();
    if ( length( $rtdomain // '' ) ) {
        $known_hosts_file = "/run/ssh/vrf/$rtdomain/ssh_known_hosts";
        @vrfcmd           = ( 'chvrf', $rtdomain );
    }

    my $key_req = join( ",", @SSH_KEY_TYPES );
    my $keyscan = '';
    run3( [ @vrfcmd, 'ssh-keyscan', '-p', $port, '-H', '-t', $key_req, $host ],
        \undef, \$keyscan, \undef );
    my @key_entries = split /\n/x, $keyscan;
    return unless @key_entries;

    my ( $key_entry, $stored_fp_str, $stored_fp_key_type ) =
      ssh_key_select( $known_hosts_file, $host, @key_entries );
    return unless $key_entry;

    my ( $hash, $key_type, $pub_key ) = split /[ ]/x, $key_entry;
    my ( $fp_str, $fp_key_type ) = ssh_get_fingerprint($key_entry);

    if ($stored_fp_str) {

        my $msg = question(<<"END");
        ***********************************************************
        *    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED      *
        ***********************************************************
        IT IS POSSIBLE THAT YOU ARE SUBJECT TO A MAN-IN-THE-MIDDLE ATTACK
        AND ARE BEING EAVESDROPPED ON!
        It is also possible that the key for this host has recently changed.
        The fingerprint for the $fp_key_type key sent by the remote host is
        $fp_str.
        The fingerprint for the $stored_fp_key_type key stored for this host is
        $stored_fp_str.
        By accepting, you are trusting the new host key from now on for all
        initiated SSH connections, the config will be updated using this hash:
        $hash
        Are you sure you want to continue?
END

        return unless y_or_n($msg);

        my $host_to_delete;
        if ( -f $known_hosts_file ) {
            $host_to_delete = ssh_get_host_to_delete( $known_hosts_file, $host, $stored_fp_str );
        }

        # The entry in SSH_KNOWN_HOSTS was changed under us
        if ( !$host_to_delete ) {
            print "\nConfig not updated due to another change, please retry\n";
            return;
        }

        my $cfg_client = Vyatta::Configd::Client->new();
        $cfg_client->session_setup("$$");
        if ( $host_to_delete ne $hash ) {
            ssh_delete_config( $cfg_client, $host_to_delete, $rtdomain );
        }
        ssh_set_config( $cfg_client, $hash, $key_type, $pub_key, $rtdomain );
        $cfg_client->commit("User accepted updated ssh host key for '$host'");
        $cfg_client->session_teardown();

    }
    else {

        my $msg = question(<<"END");
        The authenticity of host '$host' cannot be verified.
        $fp_key_type key fingerprint is $fp_str.
        By accepting, you are trusting this host from now on for all initiated
        SSH connections, and the configuration will be updated using this hash:
        $hash
        Are you sure you want to continue?
END

        return unless y_or_n($msg);

        my $cfg_client = Vyatta::Configd::Client->new();
        $cfg_client->session_setup("$$");
        ssh_set_config( $cfg_client, $hash, $key_type, $pub_key, $rtdomain );
        $cfg_client->commit("User accepted ssh host key for '$host'");
        $cfg_client->session_teardown();
    }
    return;
}

sub url_copy {
    my ( $from, $to ) = @_;
    my ( $f_topdir, $t_topdir );
    ( $f_topdir, $from ) = conv_file($from);
    ( $t_topdir, $to )   = conv_file($to);
    if ( $t_topdir eq 'url' && $f_topdir eq 'url' ) {
        print "Cannot copy a url to a url\n";
        exit 1;
    }
    elsif ( $t_topdir eq 'url' ) {
        exit 1 unless check_file_perm( $from, 'r' );
        if ( -d $from ) {
            print "Cannot upload an entire directory to url\n";
            exit 1;
        }
        elsif ( $to =~ /http/x ) {
            print "Cannot upload to http url\n";
            exit 1;
        }
        ssh_keys_manage($to);
        curl( $from, $to, $UPLOAD );
    }
    elsif ( $f_topdir eq 'url' ) {
        if ( -d $to ) {
            my ($from_file) = $from =~ m{.*/(.*)}x;
            $to = "$to/$from_file";
            exit 1 unless check_file_perm( $to, 'rw' );
            if ( -f "$to" ) {
                if ( !y_or_n("This file exists; overwrite if needed?") ) {
                    exit 0;
                }
            }
        }
        ssh_keys_manage($from);
        curl( $from, $to, $DOWNLOAD );
    }
    exit 0;
}

sub copy {
    my ( $from, $to ) = @_;
    my ( $f_topdir, $t_topdir );
    ( $f_topdir, $from ) = conv_file($from);
    if ( $f_topdir eq 'url' ) {
        url_copy( $from, $to );
    }
    ( $t_topdir, $to ) = conv_file($to);
    if ( $t_topdir eq 'url' ) {
        url_copy( $from, $to );
    }
    exit 1 unless check_file_perm( $from, 'r' );
    exit 1 unless check_file_perm( $to,   'rw' );
    my ($from_file) = $from =~ m{.*/(.*)}x;
    if ( -d $from && -e $to && !( -d $to ) ) {
        print "Cannot copy a directory to a file.\n";
        return 1;
    }
    elsif ( -f $to || ( -d $to && -f "$to/$from_file" ) ) {
        if ( y_or_n("This file exists; overwrite if needed?") ) {
            rsync( $from, $to );
        }
    }
    elsif ( -d $to && -d $from ) {
        if ( y_or_n("This directory exists; would you like to merge?") ) {
            rsync( $from, $to );
        }
    }
    else {
        rsync( $from, $to );
    }
    return;
}

sub update {
    my ( $to, $from ) = @_;
    my ( $t_topdir, $f_topdir );
    ( $f_topdir, $from ) = conv_file("$from://");
    if ( $f_topdir eq 'url' ) {
        print "Cannot clone from a url\n";
        exit 1;
    }
    ( $t_topdir, $to ) = conv_file("$to://");
    if ( $t_topdir eq 'running' ) {
        print "Cannot clone to running\n";
        exit 1;
    }
    if ( $t_topdir eq 'disk-install' ) {
        print "Cannot clone to disk-install\n";
        exit 1;
    }
    if ( $t_topdir eq 'url' ) {
        print "Cannot clone to a url\n";
        exit 1;
    }
    my $print_from = conv_file_to_rel( $f_topdir, $from );
    my $print_to   = conv_file_to_rel( $t_topdir, $to );
    my $msg =
        "WARNING: This is a destructive copy of the /config directories\n"
      . "This will erase all data in the "
      . $print_to
      . "config directory\n"
      . "This data will be replaced with the data from "
      . $print_from
      . "config\n"
      . "The current config data will be backed up in "
      . $print_to
      . "config.preclone\n"
      . "Do you wish to continue?";
    if ( y_or_n("$msg") ) {
        system( 'rm', '-rf', '--',         "$to/config.preclone" );
        system( 'mv', '--',  "$to/config", "$to/config.preclone" ) if ( -d "$to/config" );
        my $confdir = "config";
        $confdir = "opt/vyatta/etc/config" if ( $f_topdir eq "disk-install" );
        if ( rsync( "$from/$confdir", $to ) > 0 ) {
            print "Clone Failed!\nRestoring old config\n";
            system( 'mv', '--', "$to/config.preclone", "$to/config" );
        }
    }
    return;
}

sub rsync {
    my ( $from, $to ) = @_;
    system( 'rsync', '-a', '--progress', '--exclude', '.wh.*', $from, $to );
    return $?;
}

sub curl {
    my ( $from, $to, $direction_flag ) = @_;
    $direction_flag = $DOWNLOAD unless defined $direction_flag;

    my ( @args, $stdout, $err );
    if ( $direction_flag == $UPLOAD ) {
        @args = ( "vyatta-curl-wrapper", "-K-", "-#", "-T", $from, $to );
    }
    elsif ( $direction_flag == $DOWNLOAD ) {
        @args = ( "vyatta-curl-wrapper", "-K-", "-#", "-o", $to, $from );
    }

    push( @args, "-k" ) if $insecure;

    my $stdin = '';
    if ( length $u && length $p ) {
        $stdin = "user=\"$u:$p\"\n";
    }
    elsif ( length $u ) {
        $stdin = "user=\"$u:\"\n";
        print
"SSH public-key based authentication not yet implemented. Please provide a plaintext password.\n";
        exit 1;
    }
    if ( length $si ) {
        my $client = Vyatta::Configd::Client->new();
        die "Unable to connect to the Vyatta Configuration Daemon\n"
          unless defined($client);
        my $oper_state = $client->tree_get_full_hash("interfaces statistics interface $si");
        my @addrs      = defined $oper_state->{addresses} ? @{ $oper_state->{addresses} } : ();
        foreach my $ip (@addrs) {
            my $address = $ip->{address};
            $address =~ s{/.*}{}x;
            if ( $stdin =~ /interface=/x ) {
                $stdin =~ s/interface=.*/interface=\"$address\"/x;
            }
            else {
                $stdin .= "interface=\"$address\"\n";
            }
            print "Using source-interface address: $address\n";
            run3 \@args, \$stdin, \$stdout, \$err;
            if ( $? != 0 ) {
                print "$err";
                next;
            }
            print "Success.\n";
            return;
        }
        return;
    }
    run3 \@args, \$stdin, \$stdout, \$err;
    if ( $? != 0 ) {
        print "$err";
        return;
    }
    print "Success.\n";
    return;
}

sub y_or_n {
    my ($msg) = @_;
    my $process_client = $ENV{'VYATTA_PROCESS_CLIENT'};
    if ( defined $process_client ) {
        return 1 if ( $process_client =~ /gui2_rest/x );
    }
    print "$msg (Y/N): ";
    my $input = <>;
    return 1 if ( defined $input && $input =~ /Y|y/x );
    return 0;
}

# The file details show prints for a file, from ls -lGh
sub show_file_info {
    my ( $topdir, $file, $kind ) = @_;
    print "########### FILE INFO ###########\n";
    my $filename = conv_file_to_rel( $topdir, $file );
    print "File Name: $filename\n";
    print "$kind File: \n";
    my $lsstr = '';
    run3( [ 'ls', '-lGh', '--', $file ], \undef, \$lsstr );
    parsels($lsstr);
    print "  Description:\t";
    system( 'file', '-sb', '--', $file );
    print "\n########### FILE DATA ###########\n";
    return;
}

sub show {
    my ($arg) = @_;
    my ( $topdir, $file ) = conv_file($arg);
    if ( $topdir eq 'url' ) {
        print "Cannot show files from a url\n";
        exit 1;
    }
    exit 1 unless check_file_perm( $file, 'r' );
    if ( -d $file ) {
        print "########### DIRECTORY LISTING ###########\n";
        system( 'ls', '-lGph', '--group-directories-first', '--', $file );
        return;
    }

    # the file is an argument of the pipeline, never part of its text
    my %viewer = (
        'text'   => [ 'cat', '--', $file ],
        'pcap'   => [ 'sh',  '-c', 'tshark -r "$1" | less',     'sh', $file ],
        'binary' => [ 'sh',  '-c', 'hexdump -C -- "$1" | less', 'sh', $file ],
    );
    my ( $kind, $view ) =
        -T $file              ? ( 'Text',   'text' )
      : $file =~ /.*[.]pcap/x ? ( 'Binary', 'pcap' )
      : -B $file              ? ( 'Binary', 'binary' )
      :                         ();
    if ( !$view ) {
        my $filename = conv_file_to_rel( $topdir, $file );
        print "File: $filename not found\n";
        return;
    }
    show_file_info( $topdir, $file, $kind );
    system( @{ $viewer{$view} } );
    return;
}

sub parsels {
    my ($lsout) = @_;
    my @ls = split( ' ', $lsout );
    print "  Permissions: $ls[0]\n";
    print "  Owner:\t$ls[2]\n";
    print "  Size:\t\t$ls[3]\n";
    print "  Modified:\t$ls[4] $ls[5] $ls[6]\n";
    return;
}
