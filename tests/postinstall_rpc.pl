#!/usr/bin/perl
# The image RPC script, hotfix and the two post-install helpers. The RPC
# takes its input from configd as root: none of it may reach a shell.
use strict;
use warnings;
use Test::More;
use File::Temp  qw(tempdir);
use File::Path  qw(make_path);
use File::Slurp qw(read_file write_file);
use IPC::Open3  qw(open3);
use JSON        qw(encode_json decode_json);
use Time::HiRes qw(time);
use FindBin;

my $repo = "$FindBin::Bin/..";
my $work = tempdir( CLEANUP => 1 );
make_path( "$work/bin", "$work/sbin" );

# stub commands append their arguments to $work/NAME.args, one call a line
sub stub {
    my ( $dir, $cmd, $body ) = @_;
    write_file( "$dir/$cmd", "#!/bin/sh\necho \"\$*\" >> $work/$cmd.args\n" . ( $body // '' ) );
    chmod 0755, "$dir/$cmd";
    return;
}

sub calls {
    my ($cmd) = @_;
    return -e "$work/$cmd.args" ? [ split /\n/x, read_file("$work/$cmd.args") ] : [];
}

my $real_parser =
  grep { -f "$_/XorpConfigParser.pm" } ( $ENV{XORP_PARSER_DIR} // (), '/opt/vyatta/share/perl5' );

sub run_script {
    my ( $stdin, $script, @args ) = @_;
    local $ENV{PATH}              = "$work/bin:$ENV{PATH}";
    local $ENV{vyatta_sbindir}    = "$work/sbin";
    local $ENV{TEST_LIVE_ROOT}    = "$work/root";
    local $ENV{TEST_LIVE_CALLS}   = "$work/live.calls";
    local $ENV{TEST_CONFIGD_TREE} = "$work/tree.json";
    my @inc = (
        ( $ENV{XORP_PARSER_DIR} ? ( '-I', $ENV{XORP_PARSER_DIR} ) : () ),
        '-I', "$FindBin::Bin/lib-live", '-I', "$FindBin::Bin/lib"
    );
    my $pid = open3( my $in, my $out, undef, $^X, @inc, "$repo/scripts/$script", @args );
    print {$in} $stdin;
    close $in;
    my $output = do { local $/ = undef; <$out> }
      // '';
    waitpid $pid, 0;
    return ( $? >> 8, $output );
}
my ( $rc, $out );

# --- vyatta-image-rpc
stub( "$work/sbin", 'vyatta-install-image', "echo \"user=\$VY_ADD_IMG_USER\"\n" );
( $rc, $out ) = run_script(
    encode_json(
        { location => "http://x/a.iso;touch $work/pwned", username => 'u', password => 'p' }
    ),
    'vyatta-image-rpc',
    '--action=add-image'
);
ok( !-e "$work/pwned", 'add-image: the location is not shell text' );
is_deeply(
    calls('vyatta-install-image'),
    ["-y http://x/a.iso;touch $work/pwned"],
    '... and is the URL to install'
);
is( $out, '{}', '... and the RPC answers' );
( $rc, $out ) =
  run_script( encode_json( { name => 'img2' } ), 'vyatta-image-rpc', '--action=delete-image' );
like( read_file("$work/live.calls"), qr/^delete_image[ ]img2$/mx, 'delete-image' );
( $rc, $out ) = run_script( '', 'vyatta-image-rpc', '--action=get-state' );
my $state = decode_json($out);
is( $state->{'running-image'}, 'img1', 'get-state: the running image' );
is_deeply(
    [ map { $_->{'name'} } @{ $state->{'installed-images'} } ],
    [ 'img1', 'img2' ],
    '... the images'
);

# --- vyatta-hotfix: clone, install into the clone, then put it in place
write_file(
    "$work/tree.json",
    encode_json(
        {
            'system-image' => {
                'installed-images' => [ { name => 'img1' }, { name => 'img2' } ],
                'running-image'    => 'img1'
            }
        }
    )
);
write_file( "$work/a.deb", 'x' );
write_file( "$work/b.deb", 'x' );
stub( "$work/bin", 'clone-image.pl' );
stub( "$work/bin", 'vyatta-squashfs-chroot',
    "echo \"pkgs=\$VYATTA_NEW_PKGS\" >> $work/vyatta-squashfs-chroot.args\n" );
stub( "$work/bin", 'rename-image.pl',
    "sleep 1; echo renamed > $work/renamed; echo rename-noise\n" );
unlink "$work/live.calls";
my $start = time;
( $rc, $out ) = run_script( '', 'vyatta-hotfix', 'img2', 'install', "$work/a.deb", "$work/b.deb" );
is( $rc, 0, 'hotfix' ) or diag $out;
like(
    calls('clone-image.pl')->[0],
    qr/^--old_name[ ]img2[ ]--new_name[ ]img2[.]\d/x,
    '... clones the image'
);
like(
    join( "\n", @{ calls('vyatta-squashfs-chroot') } ),
    qr/^pkgs=\Q$work\E\/a[.]deb[ ]\Q$work\E\/b[.]deb$/mx,
    '... installs both packages into the clone'
);
ok( -e "$work/renamed", '... and has put the clone in place before it returns' );
unlike( $out, qr/rename-noise/x, '... quietly' );
like( read_file("$work/live.calls"), qr/^delete_image[ ]img2$/mx, '... in place of the image' );
( $rc, $out ) = run_script( '', 'vyatta-hotfix', 'img1', 'install', "$work/a.deb" );
like( $out, qr/Cannot[ ]install[ ]packages[ ]to[ ]current[ ]image/x, 'not into the running image' );
( $rc, $out ) = run_script( '', 'vyatta-hotfix', 'img2', 'install', "$work/a b.deb" );
isnt( $rc, 0, 'a package path with a space is refused' );

# --- vyatta-postinstall-setup-console and vyatta-postinstall-configure
SKIP: {
    skip "vyatta-config-migrate's XorpConfigParser is not installed", 6 unless $real_parser;
    my $root = "$work/target";
    make_path( "$root/config", "$root/boot/grub" );
    write_file( "$root/config/config.boot", "system {\n    host-name r1\n}\n" );
    stub( "$work/bin", 'grub-editenv' );
    ( $rc, $out ) = run_script(
        '',                'vyatta-postinstall-setup-console',
        "--root=$root",    '--file=config/config.boot',
        '--console=ttyS1', '--speed=115200'
    );
    is( $rc, 0, 'setup-console' ) or diag $out;
    is_deeply(
        calls('grub-editenv'),
        [
            map { "$root/boot/grub/grubenv set $_" } 'boot_console=ttyS1', 'serial_unit=1',
            'serial_speed=115200'
        ],
        '... sets the grub environment'
    );

    # the shape install image has always written (device, unit, speed and its
    # value as nested nodes)
    my $open = sub { my ($name) = @_; return qr/\Q$name\E[ ][{]\n\s+/x };
    my ( $device, $unit, $speed ) = ( $open->('device'), $open->('ttyS1'), $open->('speed') );
    like(
        read_file("$root/config/config.boot"),
        qr/$device$unit${speed}115200[ ][{]/x,
        '... and the console'
    );

    write_file( "$root/boot/grub/grub.cfg",
        "menuentry x {\n    linux /boot/i/vmlinuz boot=live vyatta-union=/boot/i\n}\n" );
    ( $rc, $out ) = run_script(
        '',             'vyatta-postinstall-configure',
        "--root=$root", '--services=ssh,https',
        '--grub-options=console=ttyS1,115200 quiet'
    );
    is( $rc, 0, 'postinstall-configure' ) or diag $out;
    like(
        read_file("$root/config/config.boot"),
        qr/service[ ][{]\n\s+ssh[ ][{]\n\s+[}]\n\s+https[ ][{]/x,
        '... adds the services'
    );
    like(
        read_file("$root/boot/grub/grub.cfg"),
        qr{vyatta-union=/boot/i[ ]console=ttyS1,115200[ ]quiet$}mx,
        '... and the kernel options'
    );
}

done_testing();
