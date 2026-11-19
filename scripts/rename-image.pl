#!/usr/bin/perl
# SPDX-License-Identifier: GPL-2.0-only

# **** License ****
#
# Copyright (c) 2017-2019, AT&T Intellectual Property.
# All Rights Reserved.
#
# Copyright (c) 2014-2017 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2010-2013 Vyatta, Inc.
# All Rights Reserved.
#
# Description: Script to re-name a system image.
#
# **** End License ****

use strict;
use warnings;
use Getopt::Long;
use File::Temp qw/ tempfile tempdir /;
use File::Copy;
use Sys::Syslog qw/:standard :macros/;

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Live;

use File::Slurp qw(read_file);

# Names install image refuses, as it does: reserved for grub and the
# kernel files beside the images, and anything but letters, digits and
# ._+- (a "/" would leave the boot directory; grub.cfg holds the name).
sub name_problem {
    my ($name) = @_;
    return "Can't use reserved image name."
      if $name eq "Old-non-image-installation"
      || $name eq "grub"
      || $name =~ /^(?:initrd|vmlinuz|System[.]map|config-|%%)/x;
    return "Image name must be composed of a-z, A-Z, 0-9, or one of ._+-"
      if $name !~ /^[a-zA-Z0-9._+-]+$/x;
    return;
}

# The name of the running image, from the kernel command line or, on a Xen
# system booted by pygrub, from the device mounted on /boot
sub running_image {
    my ( $live_image_root, $xen_default_image ) = @_;
    my ($cur_name) = split( ' ', read_file('/proc/cmdline') );
    if ( $cur_name =~ s{BOOT_IMAGE=/boot/}{}x ) {
        $cur_name =~ s{/vmlinuz.*}{}x;
        return $cur_name;
    }

    # Boot command line is not formatted as it would be for a system
    # booted via grub2 with union mounted root filesystem.  Another
    # possibility is that it the system is Xen booted via pygrub.
    return $cur_name unless -l $xen_default_image;

    # On Xen/pygrub systems, we figure out the running version by
    # looking at the bind mount of /boot.
    my ($dev) =
      map { ( split /[ ]/x )[0] } grep { ( split /[ ]/x )[1] eq '/boot' } read_file('/proc/mounts');
    $dev //= '';
    $dev =~ s{^\Q$live_image_root\E/boot/}{}x;
    return $dev;
}

# grub.cfg's lines with the image's entries renamed
sub renamed_grub {
    my ( $old_name, $new_name, @lines ) = @_;

    # This is sensitive to the format of menu entries and boot paths
    # in the grub config file.
    #
    # NB: The configuration recovery option was added after the other standard
    #     GRUB menu entries so that when installing images with this option from
    #     older images, they aren't able to modify the GRUB template to insert
    #     the image name.  So, the template uses 'for above image' instead of
    #     '@@IMAGE_NAME@@' so it looks ok!  This is replaced when installed from
    #     newer images but not from older ones, hence the need to deal with both
    #     options below.
    foreach my $line (@lines) {
        $line =~ s{/boot/\Q$old_name\E/}{/boot/$new_name/}gx;
        $line =~ s{/boot/\Q$old_name\E[ ]}{/boot/$new_name }gx;
        $line =~ s/Vyatta[ ]\Q$old_name\E[ ]/Vyatta $new_name /x;
        $line =~ s/Vyatta[ ]image[ ]\Q$old_name\E[ ]/Vyatta image $new_name /x;
        $line =~ s/Lost[ ]password[ ]change[ ]\Q$old_name\E[ ]/Lost password change $new_name /x;
        $line =~ s/Configuration[ ]Recovery[ ]\Q$old_name\E[ ]/Configuration Recovery $new_name /x;
        $line =~
          s/Configuration[ ]Recovery[ ]for[ ]above[ ]image[ ]/Configuration Recovery $new_name /x;
    }
    return @lines;
}

my $live_image_root   = get_live_image_root();
my $UNION_BOOT        = "$live_image_root/boot";
my $XEN_DEFAULT_IMAGE = "$UNION_BOOT/%%default_image";

my $old_name;
my $new_name;

GetOptions(
    'old_name:s' => \$old_name,
    'new_name:s' => \$new_name,
);

if ( !defined($old_name) || !defined($new_name) ) {
    printf("Must specify both old and new name.\n");
    exit 1;
}

my $image_path = "$live_image_root/boot";

if ( !-e "$image_path" ) {

    # must be running on old non-image installed system
    $image_path = "";
}

if ( $old_name !~ /^[a-zA-Z0-9._+-]+$/x || !-e "$image_path/$old_name" ) {
    printf("Old name $old_name does not exist.\n");
    exit 1;
}

if ( my $problem = name_problem($new_name) ) {
    print "$problem\n";
    exit 1;
}

my $cur_name = running_image( $live_image_root, $XEN_DEFAULT_IMAGE );

if ( $old_name eq $cur_name ) {
    printf("Can't re-name the running image.\n");
    exit 1;
}

if ( -e "$image_path/$new_name" ) {
    printf("New name $new_name already exists.\n");
    exit 1;
}

printf("Renaming image $old_name to $new_name.\n");

my $tmpfh;
my $tmpfilename;
( $tmpfh, $tmpfilename ) = tempfile();

open( my $grubfh, '<', "${image_path}/grub/grub.cfg" )
  or die "Can't open grub file.\n";
my @grub = <$grubfh>;
close($grubfh);

print {$tmpfh} renamed_grub( $old_name, $new_name, @grub );
close($tmpfh) or die "Close temp grub file failed: $!\n";

move( "$image_path/$old_name", "$image_path/$new_name" )
  or die "rename $old_name to $new_name failed: $!\n";

copy( $tmpfilename, "$image_path/grub/grub.cfg" )
  or die "copy $tmpfilename to grub.cfg failed: $!\n";

syslog( "warning", "System image $old_name has been renamed $new_name" );

printf("Done.\n");
