# **** License ****
#
# Copyright (C) 2017-2020 AT&T Intellectual Property.
# All Rights Reserved.
#
# Copyright (c) 2014-2017, Brocade Communications Systems, Inc.
# All rights reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2006, 2007, 2008 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# **** End License ****
package Vyatta::Live;

use strict;
use warnings;

use Exporter qw(import);
use File::Basename;
use File::Copy;
use File::Slurp qw/ edit_file_lines read_file /;
use File::Sync  qw / fsync /;
use File::Temp  qw/ :mktemp tempdir /;
use IPC::Run3;
use Sys::Syslog;
use Template;
use Try::Tiny;

## no critic (Modules::ProhibitAutomaticExportation) reason: the image scripts take these by default
our @EXPORT =
  qw(what_is_mounted_on get_live_image_root get_persistence_label parse_grub_cfg read_grub_config get_images_from_grub_entries list_images get_image_version get_image_storage get_kernel_command_line get_running_image get_default_boot_image delete_image set_default_boot_image is_installed_system print_default_index is_onie_system flush_grub_cfg);
## use critic
our $SCRIPT;

BEGIN {

    foreach ( $ENV{vyatta_sbindir}, qw(/opt/vyatta/sbin) ) {
        next if ( !defined($_) );
        my $file = $_ . "/" . "vyatta-live-image.functions";
        if ( -e $file ) {
            $SCRIPT = $file;
            last;
        }
    }

    die("File not found: vyatta-live-image.functions\n") unless defined $SCRIPT;
    openlog("SystemImage");
}

# The output of a function of vyatta-live-image.functions, its words joined
# by single spaces. $function may carry arguments of its own, separated by
# spaces; the words go to bash as arguments, not as shell text.
sub call_install_functions {
    my ( $class, $function, @arguments ) = @_;
    my @words  = ( split( /[ ]+/x, $function ), @arguments );
    my $result = '';
    run3( [ '/bin/bash', '-c', 'source "$0"; echo $("$@")', $SCRIPT, @words ], \undef, \$result );
    $result =~ s/^\s+|\s+$//gx;
    return $result;
}

sub what_is_mounted_on {
    my ($path) = @_;

    return split( /[ ]/x, Vyatta::Live->call_install_functions( "what_is_mounted_on " . $path ) );
}

sub get_live_image_root {
    my ($class) = @_;

    return Vyatta::Live->call_install_functions("get_live_rootfs_path");
}

sub get_persistence_label {
    my ($class) = @_;

    return Vyatta::Live->call_install_functions("get_live_persistence_label");
}

sub get_persistence_path_from_rootfs {
    my @args = @_;
    return Vyatta::Live->call_install_functions( "get_image_persistence_path_from_rootfs", @args );
}

# One menu entry's kernel line, as parse_grub_cfg describes it
sub _grub_entry {
    my ( $line, $idx, $running_boot_img ) = @_;

    # Remove extra space in grub.cfg kcmd as /proc/cmdline does not
    # have trailing spaces.
    $line =~ s/[ ]+/ /gx;

    my %ehash = ( 'idx' => $idx, 'ver' => undef );

    # union install
    if ( $line =~ m{^\s+linux[ ]/boot/([^/ ]+)/.*[ ]boot=live[ ]}x ) {
        $ehash{'ver'} = $1;
    }
    $ehash{'term'}     = $line =~ /console=tty0.*console=ttyS0/x ? 'serial' : 'kvm';
    $ehash{'reset'}    = $line =~ /standalone_root_pw_reset/x    ? 1        : 0;
    $ehash{'recovery'} = $line =~ /standalone_config_recovery/x  ? 1        : 0;

    # the image name is text, not a pattern: names may hold a "+"
    $ehash{'running_vers'} = $line =~ /\Q$running_boot_img\E\b/x ? 1 : 0;
    return \%ehash;
}

# Settings outside the menu entries: the key each sets, and its pattern
my @grub_settings = (
    [ 'default',         qr/^set[ ]default=(\d+)$/x ],
    [ 'superusers',      qr/^set[ ]superusers="(\S+)"$/x ],
    [ 'password_pbkdf2', qr/^password_pbkdf2[ ]\w+[ ](\S+)$/x ],
);

sub parse_grub_cfg {
    my ( $grub_cfg, $running_boot_cmd ) = @_;
    my @cfg_data = split( "\n", $grub_cfg );
    my %ghash    = ();
    my @entries  = ();
    my $in_entry = 0;
    my $idx      = 0;

    $running_boot_cmd =~ s/BOOT_IMAGE=//x;
    my ($running_boot_img) = split( /\s+/x, $running_boot_cmd, 2 );
    foreach my $line (@cfg_data) {
        if ($in_entry) {
            if ( $line =~ /^}/x ) {
                if ( $in_entry == 1 ) {

                    # Entry did not have linux kernel line
                    push @entries,
                      {
                        'idx'      => $idx,
                        'ver'      => undef,
                        'term'     => undef,
                        'reset'    => undef,
                        'recovery' => undef
                      };
                }
                $in_entry = 0;
                ++$idx;
            }
            elsif ( $line =~ /^\s+linux[ ]/x ) {
                push @entries, _grub_entry( $line, $idx, $running_boot_img );
                $in_entry++;
            }
            next;
        }
        if ( $line =~ /^menuentry[ ]/x ) {
            $in_entry = 1;
            next;
        }
        foreach my $setting (@grub_settings) {
            my ( $key, $pattern ) = @$setting;
            if ( $line =~ $pattern ) {
                $ghash{$key} = $1;
                last;
            }
        }
    }

    $ghash{'entries'} = \@entries;
    return \%ghash;
}

sub get_images_from_grub_entries {
    my ($entries) = @_;
    my %vhash     = ();
    my @list      = ();
    foreach ( @{$entries} ) {
        my ( $ver, $term ) = ( $_->{'ver'}, $_->{'term'} );
        next if ( !defined($ver) );             # Skip non-vyatta entry
        next if ( $_->{'reset'} );              # skip password reset entry
        next if ( $_->{'recovery'} );           # skip config recovery entry
        next if ( defined( $vhash{$ver} ) );    # version already in list

        $vhash{$ver} = 1;
        push @list, $_;
    }
    return \@list;
}

sub get_grub_config_filename {
    my $live_image_root = get_live_image_root();
    my $LIVE_CD         = '/live/image/live';
    my $UNION_BOOT      = "$live_image_root/boot";
    my $UNION_GRUB_CFG  = "$UNION_BOOT/grub/grub.cfg";
    return $UNION_GRUB_CFG if ( -e $UNION_GRUB_CFG );
    die "System running on Live-CD\n"
      if ( ( !-d $UNION_BOOT ) && ( -d $LIVE_CD ) );
    die "Can not open Grub config file\n";
}

sub open_grub_config {
    my $grub_cfg = get_grub_config_filename();
    open( my $fd, '<', $grub_cfg )
      or die "Can't open grub config $grub_cfg: $!\n";
    return $fd;
}

sub read_grub_config {
    my $fd       = open_grub_config();
    my $cfg_data = do { local $/ = undef; <$fd>; };
    close($fd);
    return $cfg_data;
}

sub get_kernel_command_line {
    my $running_boot_cmd = read_file('/proc/cmdline');
    $running_boot_cmd =~ s/console=.*//gx;
    chomp($running_boot_cmd);
    return $running_boot_cmd;
}

sub list_images {
    my ($gconfig) = @_;
    $gconfig = parse_grub_cfg( read_grub_config(), get_kernel_command_line() )
      if !defined($gconfig);
    my $images = get_images_from_grub_entries( $gconfig->{'entries'} );
    return map { $_->{'ver'} } @{$images};
}

sub get_running_image {
    my ($gconfig) = @_;
    $gconfig = parse_grub_cfg( read_grub_config(), get_kernel_command_line() )
      if !defined($gconfig);
    my ($running_image) =
      grep { defined( $_->{'running_vers'} ) && $_->{'running_vers'} == 1 }
      @{ $gconfig->{'entries'} };
    return $running_image->{'ver'};
}

sub get_default_boot_image {
    my ($gconfig) = @_;
    $gconfig = parse_grub_cfg( read_grub_config(), get_kernel_command_line() )
      if !defined($gconfig);
    my $default = ${ $gconfig->{'entries'} }[ $gconfig->{'default'} ];
    return $default->{'ver'};
}

sub get_default_terminal {
    my ($gconfig) = @_;
    $gconfig = parse_grub_cfg( read_grub_config(), get_kernel_command_line() )
      if !defined($gconfig);
    my $default = ${ $gconfig->{'entries'} }[ $gconfig->{'default'} ];
    return $default->{'term'} if defined($default);
    return "kvm";    #pick a default if we can't find one elsewhere.
}

sub get_dpkg_path {
    my ($image_path) = @_;
    return $image_path . "/var/lib/dpkg";
}

sub get_version_from_dpkg {
    my ($image_path) = @_;
    my $dpkg_path    = get_dpkg_path($image_path);
    my $vers         = '';
    run3(
        [
            'dpkg-query',              "--admindir=$dpkg_path",
            '--showformat=${Version}', '--show',
            'vyatta-version'
        ],
        \undef,
        \$vers,
        \undef
    );
    $vers = 'unknown' unless length($vers);
    return $vers;
}

sub get_image_path {
    my ($image_name) = @_;
    return get_persistence_path_from_rootfs( $image_name, get_live_image_root() );
}

sub get_image_version {
    my ($image_name) = @_;

    my $live_image_root = get_live_image_root();
    my $image_path      = get_image_path($image_name);

    return get_version_from_dpkg($image_path)
      if ( -e get_dpkg_path($image_path) );

    # used a cached image version if one exists for this image
    # mounting and unmounting is an expensive operation, only
    # do it once per image. We can do this because versions are
    # immutable.
    my $infofile = "$live_image_root/boot/$image_name/.imageinfo";
    return get_cached_version($infofile)
      if ( -e $infofile );

    my $TEMPLATE     = "/tmp/squash_mount.XXXXXXXX";
    my @squash_files = glob("$live_image_root/boot/$image_name/*.squashfs");
    foreach my $squash_file (@squash_files) {
        next unless ( -e $squash_file );

        my $squash_mount_path = tempdir( $TEMPLATE, CLEANUP => 1 )
          or die "Can't create temp dir for squash mount: $!\n";

        system( "mount", "-o", "loop,ro", "-t", "squashfs", $squash_file, $squash_mount_path );

        my $vers = get_version_from_dpkg($squash_mount_path);

        system( "umount", $squash_mount_path );

        # cache the version we found in the image to avoid lookup later.
        cache_version( $infofile, $vers );
        return $vers;
    }

    # None found
    return "unknown2";
}

sub get_cached_version {
    my ($infofile) = @_;
    my $imageinfo = read_key_value_file($infofile);
    return "unknown" if !defined( $imageinfo->{"VERSION"} );
    return $imageinfo->{"VERSION"};
}

sub read_key_value_file {
    my ($infofile) = @_;
    my $out = {};

    open( my $fh, '<', $infofile )
      or return $out;
    my @lines = <$fh>;
    close($fh);

    foreach my $line (@lines) {
        chomp($line);
        my ( $key, $value ) = split( "=", $line );
        next if !defined($key) || !defined($value);
        chomp($key);
        chomp($value);
        $out->{$key} = $value;
    }
    return $out;
}

sub cache_version {
    my ( $infofile, $version ) = @_;
    my ( $wfd,      $tfile )   = mkstemp('/tmp/image_version.XXXXXX');

    my $imageinfo = read_key_value_file($infofile);
    $imageinfo->{"VERSION"} = $version;

    foreach my $key ( keys( %{$imageinfo} ) ) {
        print $wfd "$key=" . $imageinfo->{$key} . "\n";
    }

    close($wfd);
    move( $tfile, $infofile );
    return;
}

sub get_image_storage {
    my ($image)         = @_;
    my $live_image_root = get_live_image_root();
    my $imagedir        = "$live_image_root/boot";
    my $output          = {};

    return unless ( -e "$imagedir/$image" );

    # the first number du prints
    my $du = sub {
        my ( $quiet, @args ) = @_;
        my $out = '';
        run3( [ 'du', '-s', '-b', @args ], \undef, \$out, $quiet ? \undef : undef );
        my ($size) = split( ' ', $out );
        return $size;
    };
    $output->{'total'} = $du->( 0, "$imagedir/$image" );
    $output->{'read-only'} =
      $du->( 1, "$imagedir/$image", '--exclude=live-rw', '--exclude=persistence' );
    $output->{'read-write'} =
      $du->( 1, "$imagedir/$image/live-rw", "$imagedir/$image/persistence" );

    return $output;
}

sub set_default_boot_image {
    my ( $image_name, $gref, $terminal ) = @_;

    my $grub_cfg = get_grub_config_filename();

    $gref = parse_grub_cfg( read_grub_config(), get_kernel_command_line() )
      if !defined($gref);

    $terminal = get_default_terminal($gref)
      if !defined($terminal);

    check_image_exists( $image_name, $gref );

    my $def_index = get_index_of_matching_image( $gref, $image_name, $terminal );

    # look for an the image with a non-matching terminal if we didn't find one
    # with a matching terminal
    $def_index = get_index_of_matching_image( $gref, $image_name )
      if !defined($def_index);

    die "Can't find entry for $image_name in grub config file.\n"
      if ( !defined($def_index) );

    set_default_grub_image( $grub_cfg, $def_index );

    my $default_image = get_default_boot_image();
    set_default_xen_image( $default_image, $image_name );

    syslog( "warning|local3", "Default boot image has been changed from %s to %s'",
        $default_image, $image_name );
    return;
}

sub print_default_index {
    my $gref = parse_grub_cfg( read_grub_config(), get_kernel_command_line() );
    return "$gref->{'default'}";
}

sub do_fsync {
    my @files = @_;

    for my $f (@files) {
        if ( open( my $fd, '<', $f ) ) {
            fsync($fd);
            close($fd);
        }
        else {
            syslog( "warning|local3", "Failed to flush $f to disk" );
        }
    }
    return;
}

sub flush_grub_cfg {
    my ($grub_cfg) = @_;
    my $grub_dir = dirname($grub_cfg);
    do_fsync( $grub_cfg, $grub_dir );
    return;
}

sub set_default_grub_image {
    my ( $grub_cfg, $def_index ) = @_;

    # Set default pointer in grub config file to point to the new
    # default version.
    try {
        my $pat = qr/^set[ ]default=.*$/x;
        edit_file_lines( sub { s/$pat/set default=$def_index/x }, $grub_cfg, { atomic => 1 } );
        flush_grub_cfg($grub_cfg);
    }
    catch {
        die "Failed to set the default boot image: $_\n"
    };
    return;
}

sub get_index_of_matching_image {
    my ( $gref, $image_name, $terminal ) = @_;

    # Find the entry that matches the new default version
    my $entries = $gref->{'entries'};
    foreach my $entry ( @{$entries} ) {

        # Skip non-vyatta entries
        next if ( !defined( $entry->{'ver'} ) );

        # Skip entries that are not using the same term type as before
        next
          if ( defined($terminal) && $entry->{'term'} ne $terminal );

        # Skip the password reset entries
        next if ( $entry->{'reset'} );

        # Skip the config recovery entries
        next if ( $entry->{'recovery'} );

        return $entry->{'idx'}
          if ( $entry->{'ver'} eq $image_name );
    }
    return;
}

sub set_default_xen_image {
    my ( $default_image, $image_name ) = @_;
    my $live_image_root   = get_live_image_root();
    my $UNION_BOOT        = "$live_image_root/boot";
    my $XEN_DEFAULT_IMAGE = "$UNION_BOOT/%%default_image";
    my $backup_symlink    = $XEN_DEFAULT_IMAGE . ".orig";

    return if !( -l $XEN_DEFAULT_IMAGE );

    if ( !move( $XEN_DEFAULT_IMAGE, $backup_symlink ) ) {
        syslog(
            "warning|local3",
            "Default boot image attempt to change from"
              . " %s to %s failed: cannot back up symlink",
            $default_image,
            $image_name
        );
        die(    "Unable to back up Xen default image symlink: "
              . "$XEN_DEFAULT_IMAGE\n"
              . "Default boot image has not been changed.\n" );
    }
    if ( !symlink( $image_name, $XEN_DEFAULT_IMAGE ) ) {
        move( $backup_symlink, $XEN_DEFAULT_IMAGE );
        syslog(
            "warning|local3",
            "Default boot image attempt to change from" . " %s to %s failed: cant back up symlink",
            $default_image,
            $image_name
        );
        die(    "Unable to back up Xen default image symlink: "
              . "$XEN_DEFAULT_IMAGE\n"
              . "Default boot image has not been changed.\n" );
    }
}

sub delete_grub_entries {
    my ($del_ver) = @_;
    my $grub_cfg  = get_grub_config_filename();
    my $rfd       = undef;
    return 'Cannot delete GRUB entries'
      if ( !open( $rfd, '<', $grub_cfg ) );
    my @lines = <$rfd>;
    close($rfd);
    my ( $wfd, $tfile ) = mkstemp('/tmp/boot-image.XXXXXX');

    my @entry = ();
    my ( $in_entry, $ver ) = ( 0, 0 );
    foreach my $line (@lines) {
        next if ( $line =~ /^$/x );    # ignore empty lines
        if ($in_entry) {
            if ( $line =~ /^}/x ) {
                if ( $ver ne $del_ver ) {

                    # output entry
                    print $wfd "\n";
                    foreach my $l (@entry) {
                        print $wfd $l;
                    }
                    print $wfd "}\n";
                }
                $in_entry = 0;
                $ver      = 0;
                @entry    = ();
            }
            else {
                # kernel line
                if ( $line =~ m{^\s+linux[ ]/boot/([^/ ]+)/.*[ ]boot=live[ ]}x ) {
                    $ver = $1;
                }
                push @entry, $line;
            }
        }
        elsif ( $line =~ /^menuentry[ ]/x ) {
            $in_entry = 1;
            push @entry, $line;
        }
        else {
            print $wfd $line;
        }
    }
    close($wfd);

    my $p = ( stat($grub_cfg) )[2];
    die "Failed to modify GRUB configuration\n"
      if ( !defined($p) || !chmod( ( $p & oct(7777) ), $tfile ) );

    move( $tfile, $grub_cfg )
      or die "Failed to delete GRUB entries\n";
    flush_grub_cfg($grub_cfg);
    return;
}

sub get_boot_dir {
    my $live_image_root = get_live_image_root();
    my $UNION_BOOT      = "$live_image_root/boot";
    return $UNION_BOOT if ( -d $UNION_BOOT );
    return;
}

sub check_image_exists {
    my ( $image_name, $gconfig ) = @_;
    my ($image) =
      grep { $_->{'ver'} eq $image_name } @{ $gconfig->{'entries'} };
    die "Image \"$image_name\" not found\n" if !defined($image);
    return;
}

sub delete_image {
    my ($image_name) = @_;
    my $gconfig =
      parse_grub_cfg( read_grub_config(), get_kernel_command_line() );

    check_image_exists( $image_name, $gconfig );

    my $default_image = get_default_boot_image($gconfig);
    my $running_image = get_running_image($gconfig);

    # without a boot directory the path would be /IMAGE, at the root
    my $boot_dir = get_boot_dir()
      or die "Error deleting the image: no boot directory. Exiting...\n";

    delete_grub_entries($image_name);
    system( 'rm', '-rf', '--', "$boot_dir/$image_name" );
    if ( $? >> 8 ) {
        die "Error deleting the image. Exiting...\n";
    }

    # Need to reset the grub default pointer becuase entry before default
    # may have been deleted, or the default entry itself may have
    # been deleted.
    $gconfig =
      parse_grub_cfg( read_grub_config(), get_kernel_command_line() );

    my $new_default = ( $image_name eq $default_image ) ? $running_image : $default_image;
    set_default_boot_image( $new_default, $gconfig );

    syslog( "warning|local3", "System Image $image_name has been deleted" );
    return;
}

sub is_installed_system {
    system('grep -q vyatta-union /proc/cmdline');
    my $ret = $? >> 8;

    # Bash to perl exit code conversion...
    if ( $ret == 0 ) {
        return 1;
    }
    else {
        return 0;
    }
}

sub is_onie_system {
    system("lsblk --exclude 1,2 --noheadings --output=PARTLABEL | grep -q 'ONIE-BOOT'");
    my $ret = $? >> 8;
    if ( $ret == 0 ) {
        system("grep -q 'vyatta-union' /proc/cmdline");
        $ret = $? >> 8;
        if ( $ret == 0 ) {
            return 1;
        }
    }
    return 0;
}

1;
