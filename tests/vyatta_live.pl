#!/usr/bin/perl -w -I ../lib

# Copyright (c) 2014-2016 by Brocade Communications Systems, Inc.
# All rights reserved.

use strict;
use warnings 'all';
use Test::More 'no_plan';    # or use Test::More 'no_plan';
use File::Path qw(make_path);
use File::Slurp;
use File::Temp qw(tempdir);
use FindBin;

use_ok('Vyatta::Live');

# mock the /proc/mounts file being used to make this work on all platforms
my @proc_mounts = <<'EOF';
proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0
sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0
proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0
udev /dev devtmpfs rw,relatime,size=10240k,nr_inodes=254000,mode=755 0 0
devpts /dev/pts devpts rw,nosuid,noexec,relatime,gid=5,mode=620 0 0
tmpfs /run tmpfs rw,nosuid,relatime,size=410568k,mode=755 0 0
EOF

local $ENV{'SHUNIT_TMPDIR'} = tempdir( CLEANUP => 1 );
make_path( $ENV{'SHUNIT_TMPDIR'} . '/proc' );
write_file( $ENV{'SHUNIT_TMPDIR'} . '/proc/mounts', @proc_mounts );

# one test to ensure that calling into the shell script works
my %paths = map { $_ => 1 } what_is_mounted_on("/proc");
is( exists( $paths{'proc'} ), '1', 'proc is mounted on \'/proc\'' );

# Do not repeat any test that we already do in vyatta-live-image.shunit2 here

# --- grub.cfg as install image writes it: three images, each with its
# normal, password reset and configuration recovery entries; the default
# is entry 2. The first image's name has a "+", which image names may.
my $data      = "$FindBin::Bin/data";
my $grub_text = scalar read_file("$data/grub.cfg");
my $cmdline =
  'BOOT_IMAGE=/boot/1.0+a/vmlinuz boot=live quiet vyatta-union=/boot/1.0+a console=ttyS0,115200';

my $gref = parse_grub_cfg( $grub_text, $cmdline );
is( $gref->{'default'},             2,  'parse_grub_cfg: the default entry' );
is( scalar @{ $gref->{'entries'} }, 12, 'parse_grub_cfg: every menu entry' );
is(
    $gref->{'password_pbkdf2'},
    'grub.pbkdf2.sha512.10000.FIXTURE',
    'parse_grub_cfg: the grub password hash'
);
is_deeply(
    [ map { $_->{'ver'} } @{ $gref->{'entries'} } ],
    [ ('1.0+a') x 4, ('img2') x 4, ('img3') x 4 ],
    'parse_grub_cfg: the image of each entry'
);
is_deeply(
    [ map { $_->{'reset'} } @{ $gref->{'entries'} } ],
    [ ( 0, 0, 1, 0 ) x 3 ],
    'reset entries'
);
is_deeply(
    [ map { $_->{'recovery'} } @{ $gref->{'entries'} } ],
    [ ( 0, 0, 0, 1 ) x 3 ],
    'recovery entries'
);
is_deeply( [ list_images($gref) ], [ '1.0+a', 'img2', 'img3' ], 'list_images: each image once' );
is( get_default_boot_image($gref), '1.0+a', 'get_default_boot_image: entry 2 is the first image' );
is( get_running_image($gref),      '1.0+a', 'get_running_image: an image name with a "+"' );
is( get_running_image( parse_grub_cfg( $grub_text, 'BOOT_IMAGE=/boot/img3/vmlinuz boot=live' ) ),
    'img3', 'get_running_image: another image' );
is( Vyatta::Live::get_index_of_matching_image( $gref, 'img2' ), 4, 'the first entry of an image' );
is( Vyatta::Live::get_index_of_matching_image( $gref, 'img2', 'serial' ),
    undef, 'none on another terminal' );
my $found = eval { Vyatta::Live::check_image_exists( 'img9', $gref ); 1 };
ok( !$found, 'an image not in grub.cfg' );
like( $@, qr/Image[ ]"img9"[ ]not[ ]found/x, '... is reported' );

# --- edits of a grub.cfg copy, as delete image and set default make them
{
    my $dir = tempdir( CLEANUP => 1 );
    my $cfg = "$dir/grub.cfg";
    write_file( $cfg, $grub_text );
    no warnings qw(redefine once);    ## no critic (TestingAndDebugging::ProhibitNoWarnings) reason: a function replaced for the test
    local *Vyatta::Live::get_grub_config_filename = sub { return $cfg };

    Vyatta::Live::set_default_grub_image( $cfg, 9 );
    like( scalar read_file($cfg), qr/^set[ ]default=9$/mx, 'set_default_grub_image' );
    my $text = read_file($cfg);
    my $n    = () = $text =~ /^set[ ]default=/mgx;
    is( $n, 1, '... in the one place' );

    Vyatta::Live::delete_grub_entries('img2');
    my $remaining = parse_grub_cfg( scalar read_file($cfg), $cmdline );
    is_deeply(
        [ list_images($remaining) ],
        [ '1.0+a', 'img3' ],
        'delete_grub_entries: the image is gone'
    );
    is( scalar @{ $remaining->{'entries'} }, 8, '... with all its entries' );
    like( scalar read_file($cfg), qr/^set[ ]superusers=/mx, '... and the rest kept' );
}

# --- the version cache of an image
{
    my $dir  = tempdir( CLEANUP => 1 );
    my $info = "$dir/.imageinfo";
    is( Vyatta::Live::get_cached_version($info), 'unknown', 'no cache, no version' );
    write_file( $info, "OTHER=x\n" );
    Vyatta::Live::cache_version( $info, '2.0' );
    is( Vyatta::Live::get_cached_version($info), '2.0', 'cache_version then get_cached_version' );
    is( Vyatta::Live::read_key_value_file($info)->{'OTHER'}, 'x', 'other keys kept' );
}

# --- dpkg-query on an image's package database
{
    my $root = tempdir( CLEANUP => 1 );
    make_path("$root/var/lib/dpkg/info");
    is( Vyatta::Live::get_version_from_dpkg($root), 'unknown', 'no vyatta-version installed' );
    write_file( "$root/var/lib/dpkg/status",
        "Package: vyatta-version\nStatus: install ok installed\nVersion: 3.1-x\nArchitecture: all\n"
          . "Maintainer: m\nDescription: d\n\n" );
    is( Vyatta::Live::get_version_from_dpkg($root), '3.1-x', 'the installed vyatta-version' );
}

# --- disk use of an image, read-only and read-write parts
{
    my $root = tempdir( CLEANUP => 1 );
    make_path("$root/boot/img/persistence");
    write_file( "$root/boot/img/img.squashfs",        'x' x 5000 );
    write_file( "$root/boot/img/persistence/rw.file", 'y' x 3000 );
    no warnings qw(redefine once);    ## no critic (TestingAndDebugging::ProhibitNoWarnings) reason: a function replaced for the test
    local *Vyatta::Live::get_live_image_root = sub { return $root };
    my $s = get_image_storage('img');
    cmp_ok( $s->{'total'},      '>=', 8000, 'get_image_storage: total' );
    cmp_ok( $s->{'read-only'},  '>=', 5000, '... read-only part' );
    cmp_ok( $s->{'read-only'},  '<',  8000, '... without the persistence' );
    cmp_ok( $s->{'read-write'}, '>=', 3000, '... read-write part' );
    is( get_image_storage('nope'), undef, '... nothing for an image that is not there' );
}

# --- the kernel command line, without its console arguments
{
    my $want = scalar read_file('/proc/cmdline');
    $want =~ s/console=.*//gx;
    chomp $want;
    is( get_kernel_command_line(), $want, 'get_kernel_command_line' );
}

# --- output of a shell function, words joined by single spaces
is(
    Vyatta::Live->call_install_functions(
        'get_image_persistence_path_from_rootfs',
        'x', '/nonexistent'
    ),
    '',
    'a function printing nothing'
);
