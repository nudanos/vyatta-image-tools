#!/usr/bin/perl
# vyatta-image-tools.pl does "show file", "delete file" and "copy file"
# on paths and URLs an operator types. None of them may reach a shell: a
# space must stay part of a name, and ";" must not start a command. Run it
# with stub commands and check what it does and calls.
use strict;
use warnings;
use Test::More;
use File::Temp  qw(tempdir);
use File::Slurp qw(read_file write_file);
use IPC::Open3  qw(open3);
use Cwd         qw(getcwd);
use FindBin;

my $repo   = "$FindBin::Bin/..";
my $script = "$repo/scripts/vyatta-image-tools.pl";
my $work   = tempdir( CLEANUP => 1 );
my $files  = "$work/files";
mkdir $files      or die "mkdir: $!\n";
mkdir "$work/bin" or die "mkdir: $!\n";

# stub commands record their arguments, one per line, in $work/NAME.args
for my $cmd (qw(rsync vyatta-curl-wrapper ssh-keyscan chvrf)) {
    my $extra = $cmd eq 'ssh-keyscan' ? "echo '|1|hash= ssh-ed25519 AAAAkey'\n" : '';
    write_file( "$work/bin/$cmd", "#!/bin/sh\nprintf '%s\\n' \"\$@\" > $work/$cmd.args\n$extra" );
}
chmod 0755, glob("$work/bin/*");

# run with @args and $stdin, in the files directory; returns (status, output)
sub image_tools {
    my ( $stdin, @args ) = @_;
    local $ENV{PATH}           = "$work/bin:$ENV{PATH}";
    local $ENV{vyatta_sbindir} = "$repo/scripts";
    my $cwd = getcwd();
    chdir $files or die "chdir: $!\n";
    my $pid = open3(
        my $in, my $out,     undef,   $^X, '-I', "$FindBin::Bin/lib",
        '-I',   "$repo/lib", $script, @args
    );
    print {$in} $stdin;
    close $in;
    my $output = do { local $/ = undef; <$out> }
      // '';
    waitpid $pid, 0;
    chdir $cwd or die "chdir: $!\n";
    return ( $? >> 8, $output );
}

sub args_of {
    my ($cmd) = @_;
    return -e "$work/$cmd.args" ? [ split /\n/x, read_file("$work/$cmd.args") ] : undef;
}

my ( $rc, $out );

# --- show file
write_file( "$files/two words.txt", "hello there\n" );
( $rc, $out ) = image_tools( '', '--show', "$files/two words.txt" );
like(
    $out,
    qr/^File[ ]Name:[ ]running:\/\/.*two[ ]words[.]txt$/mx,
    'show file: a name with a space'
);
like( $out, qr/^hello[ ]there$/mx,         '... prints its contents' );
like( $out, qr/^[ ]+Permissions:[ ]-rw/mx, '... and its details' );

# --- delete file
write_file( "$files/a b", "x" );
write_file( "$files/a",   "x" );
( $rc, $out ) = image_tools( "y\n", '--delete', "$files/a b" );
ok( !-e "$files/a b", 'delete file: a name with a space is deleted' );
ok( -e "$files/a",    '... and not the file named by its first word' );
write_file( "$files/q;touch pwned", "x" );
( $rc, $out ) = image_tools( "y\n", '--delete', "$files/q;touch pwned" );
ok( !-e "$files/q;touch pwned", 'delete file: a name with a ";" is deleted' );
ok( !-e "$files/pwned",         '... and runs nothing' );
write_file( "$files/keep", "x" );
( $rc, $out ) = image_tools( "n\n", '--delete', "$files/keep" );
ok( -e "$files/keep", 'delete file: kept unless confirmed' );

# --- copy file, on the router
write_file( "$files/src file", "data" );
( $rc, $out ) = image_tools( '', '--copy', "$files/src file", "$files/dst dir" );
is_deeply(
    args_of('rsync'),
    [ '-a', '--progress', '--exclude', '.wh.*', "$files/src file", "$files/dst dir" ],
    'copy file: rsync gets each path as one argument'
);

# --- copy file from and to a URL
( $rc, $out ) = image_tools( '', '--copy', 'http://example.invalid/image.iso', "$files/image.iso" );
is_deeply(
    args_of('vyatta-curl-wrapper'),
    [ '-K-', '-#', '-o', "$files/image.iso", 'http://example.invalid/image.iso' ],
    'copy file: a download'
);
( $rc, $out ) =
  image_tools( "y\n", '--copy', "$files/src file", 'scp://user@host.example:2222/upload/x' );
is_deeply(
    args_of('ssh-keyscan'),
    [ '-p', '2222', '-H', '-t', 'RSA,ED25519', 'host.example' ],
    'copy file to scp: the host key is looked up'
);
is_deeply(
    args_of('vyatta-curl-wrapper'),
    [ '-K-', '-#', '-T', "$files/src file", 'scp://user@host.example:2222/upload/x' ],
    '... then uploaded'
);

# --- a file in an image that does not exist
( $rc, $out ) = image_tools( '', '--show', 'img9://config/config.boot' );
isnt( $rc, 0, 'show file in no such image fails' );
like( $out, qr/^Image[ ]img9[ ]not[ ]found!$/mx, '... and says so' );
write_file( "$files/config.boot", "x" );
( $rc, $out ) = image_tools( "y\n", '--delete', 'img9://config.boot' );
ok( -e "$files/config.boot",
    'delete file in no such image deletes nothing in the current directory' );

done_testing();
