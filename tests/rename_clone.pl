#!/usr/bin/perl
# rename-image.pl and clone-image.pl take image names an operator types.
# A name is what install image accepts (letters, digits and ._+-): a "/"
# would leave the boot directory, and a newline or brace would end up in
# grub.cfg. clone-image.pl must run as root; its tests are skipped
# otherwise.
use strict;
use warnings;
use Test::More;
use File::Temp  qw(tempdir);
use File::Path  qw(make_path);
use File::Slurp qw(read_file write_file);
use IPC::Open3  qw(open3);
use FindBin;

my $repo = "$FindBin::Bin/..";

# a boot directory with the three images of the fixture grub.cfg
sub boot_dir {
    my $root = tempdir( CLEANUP => 1 );
    make_path( map { "$root/boot/$_/persistence" } '1.0+a', 'img2', 'img3' );
    make_path("$root/boot/grub");
    write_file( "$_/data", 'x' x 2000 ) for glob("$root/boot/*/persistence");
    write_file( "$root/boot/grub/grub.cfg",
        scalar( read_file("$FindBin::Bin/data/grub.cfg") ) . "# 100% kept\n" );
    return $root;
}

sub run_script {
    my ( $root, $script, @args ) = @_;
    local $ENV{TEST_LIVE_ROOT} = $root;
    local $ENV{vyatta_sbindir} = "$root/sbin";
    my $pid =
      open3( my $in, my $out, undef, $^X, '-I', "$FindBin::Bin/lib-live", "$repo/scripts/$script",
        @args );
    close $in;
    my $output = do { local $/ = undef; <$out> }
      // '';
    waitpid $pid, 0;
    return ( $? >> 8, $output );
}

my ( $root, $rc, $out );

# --- rename
$root = boot_dir();
( $rc, $out ) =
  run_script( $root, 'rename-image.pl', '--old_name', 'img2', '--new_name', 'img2-renamed' );
is( $rc, 0, 'rename' ) or diag $out;
ok( -d "$root/boot/img2-renamed" && !-e "$root/boot/img2", '... moves the image' );
my $grub = read_file("$root/boot/grub/grub.cfg");
like( $grub, qr{vyatta-union=/boot/img2-renamed[ ]}x,      '... and its boot entries' );
like( $grub, qr/^menuentry[ ]"Vyatta[ ]img2-renamed[ ]/mx, '... and its menu entries' );
unlike( $grub, qr{/boot/img2/}x, '... all of them' );
like( $grub, qr/^[#][ ]100%[ ]kept$/mx, '... and copies the rest as it was' );

for my $bad ( '../escaped', "two\nlines", 'a}b', 'x y', '' ) {
    $root = boot_dir();
    ( $rc, $out ) =
      run_script( $root, 'rename-image.pl', '--old_name', 'img2', '--new_name', $bad );
    my $shown = $bad =~ s/\n/\\n/gxr;
    isnt( $rc, 0, "rename to '$shown' is refused" );
    ok( -d "$root/boot/img2", '... and the image stays' );
}
$root = boot_dir();
( $rc, $out ) =
  run_script( $root, 'rename-image.pl', '--old_name', '../boot/img2', '--new_name', 'x' );
isnt( $rc, 0, 'an old name with a "/" is refused' );
$root = boot_dir();
( $rc, $out ) = run_script( $root, 'rename-image.pl', '--old_name', 'img2', '--new_name', 'grub' );
like( $out, qr/reserved[ ]image[ ]name/x, 'a reserved name is refused' );

# --- clone
SKIP: {
    skip 'clone-image.pl must run as root', 7 if $> != 0;
    $root = boot_dir();
    make_path("$root/sbin");
    write_file( "$root/sbin/vyatta_update_grub.pl",
        "#!/bin/sh\necho \"\$@\" > $root/update-grub.args\n" );
    chmod 0755, "$root/sbin/vyatta_update_grub.pl";
    ( $rc, $out ) =
      run_script( $root, 'clone-image.pl', '--old_name', 'img3', '--new_name', 'img3-copy' );
    is( $rc, 0, 'clone' ) or diag $out;
    ok(
        -f "$root/boot/img3-copy/persistence/data",
        '... copies the image with its read-write part'
    );
    is( -e "$root/update-grub.args" ? read_file("$root/update-grub.args") : undef,
        "--generate-grub=img3-copy\n", '... and adds it to grub.cfg' );

    ( $rc, $out ) =
      run_script( $root, 'clone-image.pl', '--old_name', 'img2', '--new_name', 'img2-ro',
        '--no_rw' );
    ok( -d "$root/boot/img2-ro/persistence" && !-e "$root/boot/img2-ro/persistence/data",
        'clone without the read-write part' );

    for my $bad ( '../escaped', "two\nlines" ) {
        ( $rc, $out ) =
          run_script( $root, 'clone-image.pl', '--old_name', 'img3', '--new_name', $bad );
        isnt( $rc, 0, 'clone to an invalid name is refused' );
    }
    ok( !-e "$root/escaped", '... without writing outside the boot directory' );
}

done_testing();
