#!/usr/bin/perl
# SPDX-License-Identifier: GPL-2.0-only

# **** License ****
#
# Copyright (c) 2021, Ciena Corporation, All Rights Reserved
# Copyright (c) 2018-2020, AT&T Intellectual Property.
# All Rights Reserved.
#
# License:
#
# This software is licensed, and not freely redistributable. See the
# subscription license agreement for details.
#
# **** End License ****

# The folowing script does:
#   - Update grub.cfg with a grub superuser and accompanying password.
#   - Populate vyatta config boot-loader superuser and password nodes
#

use strict;
use warnings;

my $vyatta_lib;

BEGIN {
    # During installation, In newer versions $ENV{vyatta_prefix} is set to
    # /mnt/cdsquash/opt/vyatta.
    # But in older versions this it is set to /mnt/cdsquash.

    $vyatta_lib = "/opt/vyatta/share/perl5";
    if ( $ENV{vyatta_prefix} ) {
        my $vyatta_prefix = $ENV{vyatta_prefix};
        if ( -d "$vyatta_prefix/share/perl5" ) {
            $vyatta_lib = "${vyatta_prefix}/share/perl5";
        }
    }
}
use lib $vyatta_lib;

use Vyatta::Configd;
use Vyatta::Live;
use File::Basename qw(basename);
use File::Compare;
use File::Slurp;
use File::Temp qw(tempfile);
use Getopt::Long;
use IPC::Run3;
use Template;
use XorpConfigParser;

my $configd = Vyatta::Configd::Client->new();
my $db      = $Vyatta::Configd::Client::AUTO;

my $grub_cfg           = '/boot/grub/grub.cfg';
my $grub_template      = '/opt/vyatta/etc/grub/default-union-grub.template';
my $grub_onie_cfg      = '/boot/grub-master/boot/grub/grub.cfg';
my $grub_onie_template = '/opt/vyatta/etc/grub/grub-onie.template';

my $cfg_file = '/config/config.boot';

my $pt_enable = 'iommu=pt ';

# A path as these options take it: word characters, dots, slashes and dashes
my $path_arg = qr{[\w./-]*}x;

sub gen_pass {
    my ($p) = @_;

    # the password goes to grub-mkpasswd-pbkdf2 on its standard input, twice
    # (it asks for it again), not through a shell
    my $out = '';
    run3( ['grub-mkpasswd-pbkdf2'], \"$p\n$p\n", \$out );
    my @lines    = split /\n/x, $out;
    my ($pbkdf2) = ( $lines[-1] // '' ) =~ /(grub.pbkdf2.*)/x;
    return $pbkdf2 // '';
}

# config.boot rewritten from the parsed tree; dies if it cannot be written
sub write_config {
    my ( $xcp, $c ) = @_;
    open my $fh, '>', $c or die __FILE__ . ": Cannot write $c: $!\n";
    $xcp->output_to( $fh, 0 );
    close $fh or die __FILE__ . ": Cannot write $c: $!\n";
    return;
}

# Should only be called by on the first system install (i.e. install image), if at all.
#
sub create_vyatta_config_grub_options {
    my ( $u, $p, $c ) = @_;

    my $gen_pass = gen_pass($p);
    my $xcp      = XorpConfigParser->new();
    $xcp->parse($c);

    # the parser keeps "user NAME" as one node name
    if ( $xcp->get_node( [ 'system', 'boot-loader', "user $u" ] ) ) {
        die __FILE__ . ": Grub user node for user $u alredy exists.\n";
    }

    my $boot_loader = $xcp->create_node( [ 'system', 'boot-loader' ] );
    push @{ $boot_loader->{'children'} },
      {
        'name'     => "user $u",
        'value'    => undef,
        'children' => [
            {
                'name'  => 'encrypted-password',
                'value' => $gen_pass,
            }
        ]
      };

    write_config( $xcp, $c );
    return;
}

sub vga_is_present {
    my $out = '';
    eval { run3( ['lspci'], \undef, \$out, \undef ); 1 } or return 0;
    return $out =~ /VGA/x;
}

# Ignore our generated header which includes a date
sub ignore_header {
    my ( $old, $new ) = @_;

    my $header = qr/^[#][ ]Generated[ ]by[ ]vyatta/x;
    if ( $old =~ $header && $new =~ $header ) {
        return 0;
    }

    return $old ne $new;
}

sub call_flush_grub_cfg {
    my @args = @_;
    my $fn   = \&Vyatta::Live::flush_grub_cfg;
    if ( defined(&$fn) ) {
        print "Flushing grub configuration file\n";
        $fn->(@args);
    }
    else {
        print "Could not flush grub configuration file\n";
    }
    return;
}

# $template filled with %tree_in into a new temporary file next to $cfg;
# returns its name. Dies, writing nothing, if the template cannot be read.
sub fill_template {
    my ( $template_file, $cfg, $tree_in, $what ) = @_;

    open my $fh, '<', $template_file
      or die __FILE__ . ": Cannot read the $what template $template_file: $!\n";
    my $text = do { local $/ = undef; <$fh> };
    close $fh;

    my ( $tmpfh, $cfg_new ) = tempfile( "$cfg.XXXXXXXX", UNLINK => 0 );
    my $template = Template->new();
    if ( !$template->process( \$text, $tree_in, $tmpfh ) ) {
        close $tmpfh;
        unlink $cfg_new;
        die __FILE__ . ": Could not fill out $what template\n";
    }
    close $tmpfh or die __FILE__ . ": Cannot write $cfg_new: $!\n";
    return $cfg_new;
}

# Writes grub.cfg for @images; %$opt: reduced, index (required),
# grub_users, cfg, template, pt_cmd, dhcp, cloud_init.
sub build_grub_cmd {
    my ( $opt, @images ) = @_;
    my $index = $opt->{'index'} // '';
    if ( $index eq "" ) {
        die __FILE__ . ": Missing input: \$index.\n";
    }
    my $reduced    = ( $opt->{'reduced'}  // '' ) eq '' ? 0              : $opt->{'reduced'};
    my $gcfg       = ( $opt->{'cfg'}      // '' ) eq '' ? $grub_cfg      : $opt->{'cfg'};
    my $gtemplate  = ( $opt->{'template'} // '' ) eq '' ? $grub_template : $opt->{'template'};
    my $grub_users = $opt->{'grub_users'} // '';

    my @out = map { { "image-name" => $_ } } grep { $_ ne '' } @images;

    my $global = {
        'reduced'    => $reduced,
        'date'       => scalar localtime(),
        'default'    => $index,
        'pt-cmd'     => $opt->{'pt_cmd'},
        'dhcp'       => $opt->{'dhcp'},
        'cloud-init' => $opt->{'cloud_init'},

        # If no VGA in system, 1st serial port automatically becomes the console
        'append-serial' => vga_is_present() ? 'yes' : 'no',
    };

    if ( $grub_users ne '' ) {
        $global->{'ubac'}       = 'yes';
        $global->{'grub-users'} = $grub_users;
    }

    my $gcfg_new =
      fill_template( $gtemplate, $gcfg, { 'images' => \@out, 'global' => $global }, 'Grub' );

    # If the grub.cfg hasn't changed, don't update it.
    if ( compare( "$gcfg_new", "$gcfg", sub { ignore_header( $_[0], $_[1] ); } ) ) {
        rename( $gcfg_new, $gcfg )
          or die __FILE__ . ": Could not rename new Grub configuration\n";
        call_flush_grub_cfg($gcfg);
    }
    else {
        unlink($gcfg_new);
    }
    return;
}

sub build_onie_cmd {
    my ( $console, $console_speed, $grub_users, $t, $c ) = @_;

    my $global = {};
    my ($unit) = $console =~ m/ttyS?(\d+)/x;
    $global->{'console'}       = $unit // 0;
    $global->{'console-speed'} = $console_speed;

    if ( $grub_users ne '' ) {
        $global->{'ubac'}       = 'yes';
        $global->{'grub-users'} = $grub_users;
    }

    $global->{'efi'} = ( -d "/sys/firmware/efi" ) ? "yes" : "no";

    my $c_new = fill_template( $t, $c, { 'global' => $global }, 'Grub ONIE' );
    rename( $c_new, $c )
      or die __FILE__ . ": Could not rename new Grub ONIE configuration\n";
    return;
}

# The image may have been booted with ip=dhcp or cloud-init.
# These parameters should be preserved across reboots.
#
sub get_kernel_bootparams {
    my $kernel_cmdline = read_file("/proc/cmdline");

    my $dhcp = "";
    if ( $kernel_cmdline =~ /ip=dhcp/x ) {
        $dhcp = "ip=dhcp";
    }

    my $cloud_init = "";
    if ( $kernel_cmdline =~ /cloud-init/x ) {
        $cloud_init = "cloud-init";
    }

    return $dhcp, $cloud_init;
}

# The name of the device mounted on /boot/grub (as the first mount line
# naming it), without its directory
sub boot_grub_disk {
    open my $mounts, '<', '/proc/mounts' or return '';
    my @lines = <$mounts>;
    close $mounts;
    foreach my $line (@lines) {
        next unless $line =~ m{/boot/grub}x;
        my ($dev) = split /[ ]/x, $line;
        return basename($dev);
    }
    return '';
}

sub generate_grub_cmd {
    my ($image) = @_;

    # A live system has no grub configuration of its own: install image
    # writes it, and the installed system regenerates it when it commits the
    # same configuration. Failing here failed every live boot's commit.
    if ( !is_installed_system() ) {
        return;
    }

    my $vgc = $configd->tree_get_full_hash("system boot-loader");
    $vgc = $vgc->{'boot-loader'};

    my $grub_users = '';
    if ( defined $vgc->{'user'} ) {
        $grub_users = { 'user' => $vgc->{'user'} };
    }

    my $reduced = $vgc->{'reduced'};
    $reduced = 0 unless defined $reduced;

    my $index  = print_default_index();
    my @images = list_images();
    if ( defined $image && $image ne "" ) {
        push( @images, $image );
    }

    my ( $dhcp, $cloud_init ) = get_kernel_bootparams();

    my $pt_cmd = $pt_enable;
    my $iommu  = $configd->tree_get_full_hash("system");
    $iommu = $iommu->{'system'}->{'iommu'};
    if ( defined($iommu) ) {
        my $passthrough = $iommu->{'passthrough'};
        $pt_cmd = $passthrough ? $pt_enable : "";
    }

    # Build a working grub.cfg with all images found...
    build_grub_cmd(
        {
            reduced    => $reduced,
            index      => $index,
            grub_users => $grub_users,
            cfg        => $grub_cfg,
            template   => $grub_template,
            pt_cmd     => $pt_cmd,
            dhcp       => $dhcp,
            cloud_init => $cloud_init,
        },
        @images
    );

    # Update onie
    if ( is_onie_system() ) {
        my $vcc = $configd->tree_get_full_hash("system console");
        $vcc = $vcc->{'console'};
        my $console = $vcc->{'serial-boot-console'};
        $console = "ttyS0" unless defined $console;
        my $console_speed = '';
        foreach my $i ( @{ $vcc->{'device'} } ) {
            if ( $i->{'tagnode'} eq $console ) {
                $console_speed = $i->{'speed'};
            }
        }

        # find the correct onie grub.cfg
        my $disk = boot_grub_disk();
        $grub_onie_cfg = "/run/live/persistence/$disk/$grub_onie_cfg";
        build_onie_cmd( $console, $console_speed, $grub_users,
            $grub_onie_template, $grub_onie_cfg );
    }
    return;
}

sub toggle_reduced_cmd {
    my ( $option, $c ) = @_;

    my $xcp = XorpConfigParser->new();
    $xcp->parse($c);

    if ( $xcp->node_exists("system boot-loader reduced") ) {
        die __FILE__ . ": Grub reduced node alredy exists.\n";
    }

    $xcp->create_node( [ 'system', 'boot-loader', 'reduced' ] );
    $xcp->set_value( [ 'system', 'boot-loader', 'reduced' ], $option );

    write_config( $xcp, $c );
    return;
}

# A grub user as the templates take it, or '' without a user and password
sub grub_users {
    my ( $user, $pass ) = @_;
    return '' if $user eq '' || $pass eq '';
    return {
        "user" => [
            {
                "user-id"            => $user,
                "encrypted-password" => gen_pass($pass),
            }
        ]
    };
}

# EX: --create-vy-grub-ubac=vyatta,password,/config/config.boot
#     --create-vy-grub-ubac=vyatta,password
# This function adds grub user and password options to the vyatta config. Used
# to modify config.boot outside of configd. It sets the following nodes:
#   system boot-loader encrypted-passowrd
#   system boot-loader user
# Called by: install image
#
sub create_user_action {
    my ($arg) = @_;
    my ( $user, $pass, $file ) = $arg =~ m{^(\w*),?(\w*),?($path_arg)$}x
      or die __FILE__ . ": create-user: Input string malformed.\n";
    if ( $user eq '' ) {
        die __FILE__ . ": No grub username specified.\n";
    }
    if ( $pass eq '' ) {
        die __FILE__ . ": No grub password specified.\n";
    }
    create_vyatta_config_grub_options( $user, $pass, $file eq '' ? $cfg_file : $file );
    return;
}

# EX: --toggle-reduced-grub=true/false
#
# This function lets you toggle the reduced grub menu option. It sets
# the following nodes:
#   system boot-loader reduced true/false
# Called by: install image
#
sub toggle_reduced_action {
    my ($arg) = @_;
    my ( $option, $file ) = $arg =~ m{^(\w*),?($path_arg)$}x
      or die __FILE__ . ": create-user: Input string malformed.\n";
    if ( $option eq '' ) {
        die __FILE__ . ": No reduced toggle option specified.\n";
    }
    toggle_reduced_cmd( $option, $file eq '' ? $cfg_file : $file );
    return;
}

# EX: --build-grub=true,0,vyatta,password,/boot/grub/grub.cfg,"",image_name1,image_name2,...
#     --build-grub= [reduced grub layout:OPTIONAL],
#                   [default boot index:REQUIRED],
#                   [grub user:OPTIONAL],
#                   [grub pass:OPTIONAL],
#                   [default grub location:OPTIONAL],
#                   [default_template_location:OPTIONAL],
#                   [image_name:REQUIRED],...
#
# Builds a full or condensed grub.cfg. Grub and template parameters can be left blank for defaults
# or if not applicable.
# Called by: install image
#
sub build_grub_action {
    my ($arg)    = @_;
    my $settings = qr/(\w*),(\w*),(\w*),(\w*)/x;
    my $files    = qr/($path_arg),($path_arg)/x;
    my ( $reduced, $index, $grub_user, $grub_pass, $cfg_path, $template_cfg, $images ) =
      $arg =~ m{^$settings,$files,(\S*)$}x
      or die __FILE__ . ": build-grub: Input string malformed.\n";

    my ( $dhcp, $cloud_init ) = get_kernel_bootparams();
    build_grub_cmd(
        {
            reduced    => $reduced,
            index      => $index,
            grub_users => grub_users( $grub_user, $grub_pass ),
            cfg        => $cfg_path,
            template   => $template_cfg,
            pt_cmd     => $pt_enable,
            dhcp       => $dhcp,
            cloud_init => $cloud_init,
        },
        split( /,/x, $images )
    );
    return;
}

# EX: --build-onie=ttyS0,1500,vyatta,password,/path/grub.cfg
#
# Build a grub-master onie config. Console and console speed should not be
# ommited. Leaving out inputs will attempt to get them from vconfig.
# Only called by install image.
#
sub build_onie_action {
    my ($arg) = @_;
    my ( $console, $console_speed, $grub_user, $grub_pass, $onie_cfg ) =
      $arg =~ m{^(\w*),(\w*),(\w*),(\w*),($path_arg)$}x
      or die __FILE__ . ": build-onie: Input string malformed.\n";
    build_onie_cmd( $console, $console_speed, grub_users( $grub_user, $grub_pass ),
        $grub_onie_template, $onie_cfg );
    return;
}

# EX: --set-default-boot-index=18.3.0,/boot/grub/grub.cfg
#
# Wrapper for Live.pm function
# Called by: Installer
#
sub set_index_action {
    my ($image) = @_;
    if ( $image eq '' ) {
        die __FILE__ . ": No image name specified.\n";
    }
    set_default_boot_image($image);
    return;
}

my (
    $create_user, $build_grub,    $build_onie,     $list_images,
    $print_index, $generate_grub, $toggle_reduced, $set_index
);

GetOptions(
    "create-vy-grub-ubac=s"    => \$create_user,
    "create-vy-grub-reduced=s" => \$toggle_reduced,
    "build-grub:s"             => \$build_grub,
    "build-onie:s"             => \$build_onie,
    "list-images"              => \$list_images,
    "print-default-index"      => \$print_index,
    "set-default-boot-index=s" => \$set_index,
    "generate-grub:s"          => \$generate_grub
);

# The first action given runs, in this order.
my @actions = (
    [ $create_user,    \&create_user_action ],
    [ $toggle_reduced, \&toggle_reduced_action ],
    [ $build_grub,     \&build_grub_action ],
    [ $build_onie,     \&build_onie_action ],

    # Helper function: prints the names of all installed images in a special
    # format. Called by: Configd
    [ $list_images, sub { print join( ',', list_images() ); return; } ],

    # Prints the index of the default boot image. Called by: Configd
    [ $print_index, sub { print_default_index(); return; } ],
    [ $set_index,   \&set_index_action ],

    # Generate the grub config from scratch, with an optional extra image
    [ $generate_grub, sub { generate_grub_cmd( $_[0] =~ /^(\S*)/x ); return; } ],
);
foreach my $action (@actions) {
    my ( $arg, $run ) = @$action;
    next unless defined $arg;
    $run->($arg);
    exit 0;
}

print "error: grub update cannot find an action.\n";
exit 1;
