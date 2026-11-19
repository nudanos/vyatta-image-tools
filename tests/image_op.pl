#!/usr/bin/perl
# vyatta-image-op runs the operational image commands: show, select and
# delete images, and show an image's logs. Its arguments are what an
# operator typed, so none of them may reach a shell. Run it with a stub
# configd and stub commands, and check what it prints and calls.
use strict;
use warnings;
use Test::More;
use File::Temp  qw(tempdir);
use File::Slurp qw(read_file write_file);
use IPC::Open3  qw(open3);
use JSON        qw(encode_json decode_json);
use FindBin;

my $repo   = "$FindBin::Bin/..";
my $script = "$repo/scripts/vyatta-image-op";
my $work   = tempdir( CLEANUP => 1 );

write_file(
    "$work/tree.json",
    encode_json(
        {
            'system-image' => {
                'installed-images' => [
                    {
                        'name'    => 'img1',
                        'version' => '1.0',
                        'storage' => { 'read-only' => 1024, 'read-write' => 2048, 'total' => 3072 }
                    },
                    {
                        'name'    => 'img2',
                        'version' => '2.0',
                        'storage' => { 'read-only' => 10, 'read-write' => 20, 'total' => 30 }
                    },
                ],
                'default-boot-image' => 'img2',
                'running-image'      => 'img1',
            }
        }
    )
);

# stub commands: each records its arguments, one per line, in $work/NAME.args
mkdir "$work/bin"  or die "mkdir: $!\n";
mkdir "$work/sbin" or die "mkdir: $!\n";
for my $cmd (qw(journalctl vyatta-show-log-file vyatta-install-image reboot ls)) {
    write_file( "$work/bin/$cmd",
        "#!/bin/sh\nprintf '%s\\n' \"\$@\" > $work/$cmd.args\necho $cmd output\n" );
}
write_file( "$work/sbin/vyatta-live-image",
        "#!/bin/sh\nprintf '%s\\n' \"\$@\" > $work/live-image.args\n"
      . "[ \"\$2\" = img1 ] || exit 1\necho $work/persist1\n" );
chmod 0755, glob("$work/bin/*"), "$work/sbin/vyatta-live-image";

# run with @args and $stdin; returns (exit status, output)
sub image_op {
    my ( $stdin, @args ) = @_;
    local $ENV{PATH}              = "$work/bin:$ENV{PATH}";
    local $ENV{vyatta_sbindir}    = "$work/sbin";
    local $ENV{TEST_CONFIGD_TREE} = "$work/tree.json";
    local $ENV{TEST_CONFIGD_RPCS} = "$work/rpcs";
    local $ENV{LOGNAME}           = 'vyatta';
    unlink "$work/rpcs";
    my $pid = open3( my $in, my $out, undef, $^X, '-I', "$FindBin::Bin/lib", $script, @args );
    print {$in} $stdin;
    close $in;
    my $output = do { local $/ = undef; <$out> }
      // '';
    waitpid $pid, 0;
    return ( $? >> 8, $output );
}

sub rpcs {
    return [ map { decode_json($_) } -e "$work/rpcs" ? read_file("$work/rpcs") : () ];
}

sub args_of {
    my ($cmd) = @_;
    return -e "$work/$cmd.args" ? [ split /\n/x, read_file("$work/$cmd.args") ] : undef;
}

my ( $rc, $out );

( $rc, $out ) = image_op( '', '--action=show-images' );
is( $rc, 0, 'show-images' );
like( $out, qr/^[ ]+1:[ ]img1[ ][(]running[ ]image[)]$/mx, '... the running image' );
like( $out, qr/^[ ]+2:[ ]img2[ ][(]default[ ]boot[)]$/mx,  '... the default boot image' );
( $rc, $out ) = image_op( '', '--action=show-versions' );
like( $out, qr/img1[ ]\[1[.]0\]/x, 'show-versions' );
( $rc, $out ) = image_op( '', '--action=list-images' );
is( $out, "img1\nimg2\n", 'list-images' );
( $rc, $out ) = image_op( '', '--action=show-storage' );
like( $out, qr/^img1[ ]+1[.]0K[ ]+2[.]0K[ ]+3[.]0K$/mx, 'show-storage' );

( $rc, $out ) = image_op( "2\n", '--action=select-image-prompt' );
isnt( $rc, 0, 'selecting the default image again is refused' );
( $rc, $out ) = image_op( "1\n", '--action=select-image-prompt' );
is( $rc, 0, 'select-image-prompt' ) or diag $out;
is_deeply(
    rpcs(),
    [ [ 'vyatta-image-v1', 'set-default-boot-image', { 'name' => 'img1' } ] ],
    '... sets the default'
);
( $rc, $out ) = image_op( "3\n", '--action=select-image-prompt' );
isnt( $rc, 0, 'an image number past the list is refused' );
like(
    $out,
    qr/Invalid[ ]selection[.][ ]Default[ ]is[ ]not[ ]changed/x,
    '... as an invalid selection'
);
is_deeply( rpcs(), [], '... and nothing set' );

( $rc, $out ) = image_op( "2\nyes\n", '--action=delete-image-prompt' );
is( $rc, 0, 'delete-image-prompt' ) or diag $out;
is_deeply(
    rpcs(),
    [ [ 'vyatta-image-v1', 'delete-image', { 'name' => 'img2' } ] ],
    '... deletes the image'
);
( $rc, $out ) = image_op( "3\n", '--action=delete-image-prompt' );
like(
    $out,
    qr/Invalid[ ]selection[.][ ]Nothing[ ]is[ ]deleted/x,
    'an image number past the list is refused'
);
is_deeply( rpcs(), [], '... and nothing deleted' );
( $rc, $out ) = image_op( "no\n", '--action=delete-image', 'img2' );
isnt( $rc, 0, 'delete-image unless confirmed' );
is_deeply( rpcs(), [], '... deletes nothing' );
( $rc, $out ) = image_op( '', '--action=delete-image', 'img1' );
like(
    $out,
    qr/Cannot[ ]delete[ ]current[ ]running[ ]image/x,
    'the running image cannot be deleted'
);

( $rc, $out ) = image_op( '', '--action=show-log', 'img1' );
is( $rc, 0, 'show-log' ) or diag $out;
is_deeply( args_of('live-image'), [ 'get_image_persistence_path', 'img1' ], '... finds the image' );
is_deeply(
    args_of('journalctl'),
    [ '-a', '--no-pager', "--root=$work/persist1" ],
    '... reads its journal'
);
like( $out, qr/journalctl[ ]output/x, '... and prints it' );
( $rc, $out ) = image_op( '', '--action=show-log', 'img9' );
isnt( $rc, 0, 'show-log of no such image' );
like( $out, qr/img9:[ ]No[ ]such[ ]image/x, '... says so' );
( $rc, $out ) = image_op( '', '--action=show-log-tail', 'img1', '25' );
is_deeply( args_of('journalctl'), [ '-a', '--no-pager', '-n', '25', "--root=$work/persist1" ],
    'show-log-tail' );
( $rc, $out ) = image_op( '', '--action=show-log-file', 'img1', 'messages' );
is_deeply(
    args_of('vyatta-show-log-file'),
    [ 'messages', "$work/persist1/var/log/vyatta" ],
    'show-log-file'
);
( $rc, $out ) = image_op( '', '--action=list-log-files', 'img1' );
is_deeply( args_of('ls'), ["$work/persist1/var/log/vyatta"], 'list-log-files' );

# what an operator types is data, never shell text
for my $case (
    [ 'show-log',       "img1;touch $work/pwned1" ],
    [ 'show-log-tail',  'img1', "1;touch $work/pwned2" ],
    [ 'show-log-file',  'img1', "\$(touch $work/pwned3)" ],
    [ 'list-log-files', "img1 \$(touch $work/pwned4)" ],
  )
{
    my ( $action, @args ) = @$case;
    image_op( '', "--action=$action", @args );
}
is_deeply( [ glob("$work/pwned*") ], [], 'no argument of the log commands runs as a command' );

( $rc, $out ) =
  image_op( '', '--action=vyatta-autoinstall', "http://x/a'b;touch $work/pwned5", '.' );
is_deeply(
    args_of('vyatta-install-image'),
    [ '-y', "http://x/a'b;touch $work/pwned5" ],
    'autoinstall installs the image'
);
ok( !-e "$work/pwned5",      '... and its URL is not shell text' );
ok( !-e "$work/reboot.args", '... without a reboot' );
( $rc, $out ) = image_op( '', '--action=vyatta-autoinstall', 'http://x/a', '..' );
ok( -e "$work/reboot.args", 'autoinstall then reboot' );

done_testing();
