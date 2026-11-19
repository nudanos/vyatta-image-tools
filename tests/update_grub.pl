#!/usr/bin/perl
# vyatta_update_grub.pl writes grub.cfg from a template, the ONIE master
# grub.cfg, and grub settings into config.boot. Run it as install image
# does and check what it writes. The tests that edit config.boot need
# vyatta-config-migrate's XorpConfigParser and are skipped without it.
use strict;
use warnings;
use Test::More;
use File::Temp  qw(tempdir);
use File::Slurp qw(read_file write_file);
use IPC::Open3  qw(open3);
use FindBin;

my $repo   = "$FindBin::Bin/..";
my $script = "$repo/scripts/vyatta_update_grub.pl";
my $tmpl   = "$repo/etc/grub/default-union-grub.template";
my $onie   = "$repo/etc/grub/grub-onie.template";
my $work   = tempdir( CLEANUP => 1 );

# lspci reports a VGA controller; grub-mkpasswd-pbkdf2 records what it is
# given and prints a fixed hash
mkdir "$work/bin" or die "mkdir: $!\n";
write_file( "$work/bin/lspci", "#!/bin/sh\necho '00:02.0 VGA compatible controller: QEMU'\n" );
write_file( "$work/bin/grub-mkpasswd-pbkdf2",
        "#!/bin/sh\nhead -n 2 > $work/mkpasswd.in\n"
      . "echo 'Enter password:'\necho 'Reenter password:'\n"
      . "echo 'PBKDF2 hash of your password is grub.pbkdf2.sha512.10000.FAKE'\n" );
chmod 0755, "$work/bin/lspci", "$work/bin/grub-mkpasswd-pbkdf2";
local $ENV{PATH} = "$work/bin:$ENV{PATH}";

my $real_parser =
  grep { -f "$_/XorpConfigParser.pm" } ( $ENV{XORP_PARSER_DIR} // (), '/opt/vyatta/share/perl5' );
my @inc = (
    ( $ENV{XORP_PARSER_DIR} ? ( '-I', $ENV{XORP_PARSER_DIR} ) : () ),
    '-I', "$repo/lib", '-I', "$FindBin::Bin/lib"
);

# run the script with @args; returns (exit status, stdout and stderr)
sub update_grub {
    my @args = @_;
    my $pid  = open3( my $in, my $out, undef, $^X, @inc, $script, @args );
    close $in;
    my $output = do { local $/ = undef; <$out> }
      // '';
    waitpid $pid, 0;
    return ( $? >> 8, $output );
}

my ( $rc, $out );

( $rc, $out ) = update_grub("--build-grub=0,1,,,$work/grub.cfg,$tmpl,img1,img2");
is( $rc, 0, 'build-grub succeeds' ) or diag $out;
my $cfg = read_file("$work/grub.cfg");
like( $cfg, qr/^set[ ]default=1$/mx,         'default image index' );
like( $cfg, qr{vyatta-union=/boot/img1[ ]}x, 'first image has its entry' );
like( $cfg, qr{vyatta-union=/boot/img2[ ]}x, 'second image has its entry' );
unlike( $cfg, qr/superusers/x, 'no grub user unless asked for' );
like( $cfg, qr/iommu=pt[ ]/x, 'IOMMU passthrough by default' );
my $full = () = $cfg =~ /^menuentry[ ]/gmx;

my $inode = ( stat "$work/grub.cfg" )[1];
( $rc, $out ) = update_grub("--build-grub=0,1,,,$work/grub.cfg,$tmpl,img1,img2");
is( $rc,                                     0,      'rebuilding succeeds' );
is( ( stat "$work/grub.cfg" )[1],            $inode, 'an unchanged grub.cfg is left alone' );
is( scalar( () = glob("$work/grub.cfg.*") ), 0,      'and its temporary file removed' );

( $rc, $out ) = update_grub("--build-grub=1,0,admin,secret,$work/reduced.cfg,$tmpl,img1");
is( $rc, 0, 'build-grub with a grub user succeeds' ) or diag $out;
$cfg = read_file("$work/reduced.cfg");
like( $cfg, qr/^set[ ]superusers="admin[ ]"$/mx, 'the user is a superuser' );
like(
    $cfg,
    qr/password_pbkdf2[ ]admin[ ]grub\.pbkdf2\.sha512\.10000\.FAKE/x,
    'with the hashed password'
);
is( read_file("$work/mkpasswd.in"),
    "secret\nsecret\n", 'the password went to grub-mkpasswd-pbkdf2 twice' );
my $reduced = () = $cfg =~ /^menuentry[ ]/gmx;
cmp_ok( $reduced, '<', $full, 'the reduced menu has fewer entries' );

( $rc, $out ) = update_grub("--build-grub=0,,,,$work/x.cfg,$tmpl,img1");
isnt( $rc, 0, 'build-grub without a default index fails' );
like( $out, qr/Missing[ ]input:[ ]\$index/x, '... and says why' );
( $rc, $out ) = update_grub("--build-grub=0,1,,,$work/x.cfg,$tmpl,img 1");
isnt( $rc, 0, 'an image name with a space is malformed input' );
like( $out, qr/build-grub:[ ]Input[ ]string[ ]malformed/x, '... and says so' );
( $rc, $out ) = update_grub("--build-grub=0,1,,,$work/x.cfg,$work/no-such.template,img1");
isnt( $rc, 0, 'a missing template fails' );
ok( !-e "$work/x.cfg", '... without writing grub.cfg' );

# build-onie always reads the installed ONIE template
if ( -f '/opt/vyatta/etc/grub/grub-onie.template' ) {
    ( $rc, $out ) = update_grub("--build-onie=ttyS1,115200,,,$work/onie.cfg");
    is( $rc, 0, 'build-onie succeeds' ) or diag $out;
    $cfg = read_file("$work/onie.cfg");
    like( $cfg, qr/^serial[ ]--unit=1[ ]--speed=115200/mx, 'the serial console and its speed' );
    ( $rc, $out ) = update_grub("--build-onie=ttyS12,9600,root,pw,$work/onie2.cfg");
    $cfg = read_file("$work/onie2.cfg");
    like( $cfg, qr/^serial[ ]--unit=12[ ]/mx,       'a two-digit serial console' );
    like( $cfg, qr/^set[ ]superusers="root[ ]"$/mx, 'an ONIE grub user' );
}
else {
    ( $rc, $out ) = update_grub("--build-onie=ttyS1,115200,,,$work/onie.cfg");
    isnt( $rc, 0, 'build-onie without its template fails' );
    ok( !-e "$work/onie.cfg", '... without writing grub.cfg' );
}

( $rc, $out ) = update_grub('--no-such-action');
isnt( $rc, 0, 'no action is an error' );

SKIP: {
    skip "vyatta-config-migrate's XorpConfigParser is not installed", 6 unless $real_parser;
    my $boot = "$work/config.boot";
    write_file( $boot, "system {\n    host-name r1\n}\n" );
    ( $rc, $out ) = update_grub("--create-vy-grub-ubac=admin,secret,$boot");
    is( $rc,  0,  'adding a grub user to config.boot succeeds' ) or diag $out;
    is( $out, '', '... printing nothing' );
    my $c         = read_file($boot);
    my $user_node = qr/user[ ]admin[ ][{]/x;
    my $fake_hash = qr/grub[.]pbkdf2[.]sha512[.]10000[.]FAKE/x;
    like(
        $c,
        qr/boot-loader[ ][{]\n\s+${user_node}\n\s+encrypted-password[ ]${fake_hash}\n/x,
        'the user and its hashed password'
    );
    ( $rc, $out ) = update_grub("--create-vy-grub-ubac=admin,secret,$boot");
    isnt( $rc, 0, 'adding the same user again fails' );

    ( $rc, $out ) = update_grub("--create-vy-grub-reduced=true,$boot");
    is( $rc, 0, 'setting the reduced menu succeeds' ) or diag $out;
    like( read_file($boot), qr/^\s+reduced[ ]true$/mx, 'reduced is set' );
}

done_testing();
