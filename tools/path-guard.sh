#!/usr/bin/env bash
# tools/path-guard.sh — no build-machine path or account name in a repo of the Glance family.
#
#   path-guard.sh check             the gate: the pre-push hook is installed and is this script,
#                                   and the working tree (tracked and new files) is clean
#   path-guard.sh installed         only: the pre-push hook is installed and is this script
#   path-guard.sh install           install this script as the repo's pre-push hook
#   path-guard.sh tree [<rev>]      every file and file name of a tree (default HEAD)
#   path-guard.sh commits <rev-list arguments>
#                                   those commits: author, committer, message, and every file each adds or changes
#   path-guard.sh history           every ref: all commits, all tag messages, all ref names
#   path-guard.sh files <path>...   files and folders on disk, binaries included (an app bundle, a mounted DMG, a log)
#   path-guard.sh selftest          every rule fires on a made-up path and stays quiet on a generic one
#
# Installed as .git/hooks/pre-push it reads the refs git is about to push and scans every commit the
# remote does not have yet (as `commits`), every annotated tag and every ref name. Exit 0 = clean,
# 1 = at least one hit (the push is refused), 2 = the guard could not run.
#
# What is a hit (the whole list is `scan_line` in the Perl below; <name> stands for any name):
#   home paths      a macOS, Windows or Linux home folder with <name> in it, also when the path
#                   was made into a folder name (slashes as dashes)
#   temporary paths the per-user folder under /var/folders, a session's scratch folder under /tmp
#   volumes         a volume <name> under /Volumes
#   host names      <name> with the home network's suffix, a Mac's Bonjour or sharing name
#   session links   claude.ai session URLs and session ids
#   listings        the owner column of `ls -l` output
#   names           this machine's account name, home folder and host names, wherever they stand, and
#                   the family's known private names (kept here as SHA-256 only, never in clear)
# <name> is anything except the short fixed lists of made-up names tests and docs use (GENERIC below).
# A real name never goes on those lists; a hit is fixed at the source. The script holds no real path
# and passes its own scan.
#
# bash only starts Perl (5.10+, core modules): `perl -x` runs the program below the marker line.
exec perl -x "$0" "$@"
#!/usr/bin/perl
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Basename qw(basename dirname);
use File::Copy ();
use File::Find ();
use IPC::Open2 qw(open2);

# ---- GENERIC: made-up names only. Never a real account, machine or drive. ----
my %GEN_USER = map { lc($_) => 1 } qw(Shared x a u me you name user test nobody-here Resolume runner);
my %GEN_WIN  = (%GEN_USER, map { lc($_) => 1 } qw(Public Default runneradmin));
my %GEN_HOME = map { $_ => 1 } qw(runner user me you name x test);
my %GEN_VOL  = map { $_ => 1 } (
    qw(A D M X Y XY Mo My Fix Fixture Here Here2 There Gone Other Out Show Clips ClipDrive ClipDriveX Data Media VJ),
    qw(NoSuchVolume NotMounted Macintosh Recovery Preboot .timemachine), 'My%20Clips',
);
# A scratch disk image or an app's own DMG: the product's name, then anything.
my $GEN_VOL_RE   = qr/^(?:Glance|CueGlance|GlEnc|MaCrate|GlancEhr)[A-Za-z0-9._%-]*$/;
my %GEN_LS_OWNER = map { $_ => 1 } qw(root runner user);

# ---- Private names, as SHA-256 of the lower-cased name. ----
my %PRIVATE_SHA = map { $_ => 1 } qw(
    60009e85ec0ed70edc39bdd9f8a58ffc73544a04c97d945b9c97654084e41579
);

# ---- This machine's own names (nothing generic, nothing short). ----
my @MACHINE;    # [label, compiled regex]
{
    my %skip = map { $_ => 1 } qw(runner root user admin ubuntu localhost mac macbook imac);
    my $user = eval { (getpwuid($<))[0] } // $ENV{USER} // $ENV{USERNAME} // '';
    push @MACHINE, [ 'account name', qr/\Q$user\E/i ] if length($user) >= 4 && !$skip{ lc $user };
    my $home = $ENV{HOME} // '';
    push @MACHINE, [ 'home folder', qr/\Q$home\E/ ]
        if length($home) >= 8 && $home !~ m{^/(?:root|home/runner|Users/runner)$};
    my @hosts;
    for my $cmd ( 'hostname', 'scutil --get LocalHostName', 'scutil --get ComputerName' ) {
        my $h = `$cmd 2>/dev/null`;
        next unless defined $h;
        $h =~ s/\s+$//;
        push @hosts, $h;
    }
    my %seen;
    for my $h (@hosts) {
        next if $seen{ lc $h }++ || $skip{ lc $h } || length($h) < 6;
        push @MACHINE, [ 'host name', qr/(?<![A-Za-z0-9-])\Q$h\E(?![A-Za-z0-9-])/i ];
    }
}

my $MASK = $ENV{CI} ? 1 : 0;    # a public log never repeats what it found
my ( @hits, %tok_cache, %by_rule );
my $SHOWN = 60;    # lines printed; the count is always of all hits
my ( $n_objects, $n_bytes ) = ( 0, 0 );

sub hit {
    my ( $label, $line, $rule, $text ) = @_;
    $text = substr( $text, 0, 120 );
    $text =~ s/[^\x20-\x7e]/?/g;
    $text = substr( $text, 0, 3 ) . '...(' . length($text) . ' characters)' if $MASK;
    $by_rule{$rule}++;
    push @hits, sprintf( '%s:%s: [%s] %s', $label, $line, $rule, $text );
}

sub volume_generic {
    my ($v) = @_;
    $v =~ s/[.\x{2026}]+$//;    # the full stop or ellipsis that ends a sentence
    return 1 if $v !~ /[A-Za-z0-9]/;
    return $GEN_VOL{$v} || $v =~ $GEN_VOL_RE;
}

sub scan_line {
    my ( $label, $n, $s ) = @_;
    while ( $s =~ m{/Users/([A-Za-z0-9][A-Za-z0-9._-]*)}g ) {
        hit( $label, $n, 'home path', $& ) unless $GEN_USER{ lc $1 };
    }
    while ( $s =~ m{-Users-([A-Za-z0-9]+)-}g ) {
        hit( $label, $n, 'home path', $& ) unless $GEN_USER{ lc $1 };
    }
    while ( $s =~ m{[A-Za-z]:\\+Users\\+([A-Za-z0-9][A-Za-z0-9._-]*)}g ) {
        hit( $label, $n, 'home path', $& ) unless $GEN_WIN{ lc $1 };
    }
    while ( $s =~ m{(?<![A-Za-z0-9._~/-])/home/([a-z_][a-z0-9_.-]*)/}g ) {
        hit( $label, $n, 'home path', $& ) unless $GEN_HOME{$1};
    }
    while ( $s =~ m{/var/folders/[A-Za-z0-9_+]{2}/[A-Za-z0-9_+]{6,}}g ) { hit( $label, $n, 'temporary path', $& ); }
    while ( $s =~ m{/(?:private/)?tmp/claude-[0-9]+}g )                  { hit( $label, $n, 'temporary path', $& ); }
    while ( $s =~ m{/Volumes/([^/\s"'`<>()\[\]{}*\$\\,;:|#?&=]+)}g ) {
        hit( $label, $n, 'volume', $& ) unless volume_generic($1);
    }
    while ( $s =~ m{(?<![A-Za-z0-9._-])[A-Za-z][A-Za-z0-9-]*\.lan\b(?![\w(])}g )  { hit( $label, $n, 'host name', $& ); }
    while ( $s =~ m{\b[A-Za-z0-9-]*(?:MacBook|iMac|Mac-?mini|Mac-?Studio|Mac-?Pro)[A-Za-z0-9-]*\.(?:local|lan|home)\b}g ) {
        hit( $label, $n, 'host name', $& );
    }
    while ( $s =~ m{\b[A-Za-z0-9]+s-(?:MacBook|iMac|Mac)(?:-[A-Za-z0-9]+)*\b}g )  { hit( $label, $n, 'host name', $& ); }
    while ( $s =~ m{\b[A-Z][a-z]+(?:'|\xe2\x80\x99)s (?:MacBook|iMac|Mac (?:mini|Studio|Pro))\b}g ) {
        hit( $label, $n, 'host name', $& );
    }
    while ( $s =~ m{claude\.ai/(?:code|chat|share|public)/[A-Za-z0-9_-]{8,}}g ) { hit( $label, $n, 'session link', $& ); }
    while ( $s =~ m{\bsession_01[A-Za-z0-9]{20,}}g )                            { hit( $label, $n, 'session link', $& ); }
    if ( $s =~ m{^[-dlbcps][-rwxsStT]{9}[@+.]?\s+\d+\s+([A-Za-z_][\w.-]*)\s+[A-Za-z_][\w.-]*\s+\d+\s} ) {
        hit( $label, $n, 'listing owner', $1 ) unless $GEN_LS_OWNER{$1};
    }
    for my $m (@MACHINE) {
        while ( $s =~ /$m->[1]/g ) { hit( $label, $n, "this machine's $m->[0]", $& ); }
    }
    while ( $s =~ /([A-Za-z0-9]{6,40})/g ) {
        my $t = lc $1;
        my $p = $tok_cache{$t} //= ( $PRIVATE_SHA{ sha256_hex($t) } ? 1 : 0 );
        hit( $label, $n, 'private name', $t ) if $p;
    }
}

sub scan_text {
    my ( $label, $data ) = @_;
    $n_objects++;
    $n_bytes += length $data;
    my $n = 0;
    for my $line ( split /\r?\n/, $data, -1 ) { scan_line( $label, ++$n, $line ) if length $line; }
    if ( index( $data, "\0" ) >= 0 ) {    # a binary: also as UTF-16 text (Windows paths)
        ( my $wide = $data ) =~ s/([\x20-\x7e])\0/$1/g;
        if ( $wide ne $data ) {
            $n = 0;
            for my $line ( split /[\0\r\n]+/, $wide ) { scan_line( "$label (UTF-16)", ++$n, $line ) if length $line; }
        }
    }
}

# ---- git plumbing ----
sub git_lines {
    my @cmd = ( 'git', @_ );
    open( my $fh, '-|', @cmd ) or die "path-guard: cannot run @cmd\n";
    local $/ = "\0";
    my @out = <$fh>;
    close($fh) or die "path-guard: @cmd failed\n";
    chomp @out;
    return @out;
}

sub git_out {
    my @cmd = ( 'git', @_ );
    open( my $fh, '-|', @cmd ) or die "path-guard: cannot run @cmd\n";
    local $/;
    my $out = <$fh>;
    close($fh) or die "path-guard: @cmd failed\n";
    return $out // '';
}

my ( $cat_in, $cat_out, $cat_pid );

sub object {    # (type, content) of an object id
    my ($oid) = @_;
    $cat_pid ||= open2( $cat_out, $cat_in, 'git', 'cat-file', '--batch' );
    print {$cat_in} "$oid\n";
    $cat_in->flush;
    my $head = readline($cat_out) // die "path-guard: git cat-file stopped\n";
    my ( undef, $type, $size ) = split ' ', $head;
    die "path-guard: no object $oid\n" unless defined $size && $size =~ /^\d+$/;
    my $data = '';
    while ( length($data) < $size ) {
        my $got = read( $cat_out, $data, $size - length($data), length($data) );
        die "path-guard: short read of $oid\n" unless $got;
    }
    read( $cat_out, my $nl, 1 );
    return ( $type, $data );
}

my %seen_blob;

sub scan_blob {
    my ( $oid, $label ) = @_;
    return if $seen_blob{$oid}++;
    my ( $type, $data ) = object($oid);
    scan_text( $label, $data ) if $type eq 'blob';
}

sub scan_tree {
    my ($rev) = @_;
    my $short = $rev =~ /^[0-9a-f]{40}$/ ? substr( $rev, 0, 7 ) : $rev;
    for my $e ( git_lines( 'ls-tree', '-r', '-z', $rev ) ) {
        my ( $meta, $path ) = split /\t/, $e, 2;
        my ( undef, $type, $oid ) = split ' ', $meta;
        scan_text( "$short: file name", $path );
        scan_blob( $oid, "$short:$path" ) if $type eq 'blob';
    }
}

sub scan_commit {
    my ($c) = @_;
    my $short = substr( $c, 0, 7 );
    my ( undef, $raw ) = object($c);
    my ( $head, $msg ) = split /\n\n/, $raw, 2;
    for my $l ( split /\n/, $head ) { scan_text( "commit $short: $1", $2 ) if $l =~ /^(author|committer) (.*) \d+ [-+]\d{4}$/; }
    scan_text( "commit $short: message", $msg // '' );
    my @f = git_lines( 'diff-tree', '-r', '-z', '--root', '-m', '--no-renames', '--no-commit-id', '--diff-filter=ACMRT', $c );
    while (@f) {
        my $meta = shift @f;
        my $path = shift @f;
        next unless defined $path;
        my ( undef, $mode, undef, $oid ) = split ' ', $meta;
        scan_text( "commit $short: file name", $path );
        scan_blob( $oid, "commit $short:$path" ) unless $mode eq '160000';
    }
}

sub scan_tag_object {
    my ( $oid, $name ) = @_;
    my ( $type, $raw ) = object($oid);
    return unless $type eq 'tag';
    my ( $head, $msg ) = split /\n\n/, $raw, 2;
    for my $l ( split /\n/, $head ) { scan_text( "tag $name: tagger", $1 ) if $l =~ /^tagger (.*) \d+ [-+]\d{4}$/; }
    scan_text( "tag $name: message", $msg // '' );
}

sub scan_commits { scan_commit($_) for git_lines( 'rev-list', '-z', @_ ); }

sub scan_files {
    for my $root (@_) {
        die "path-guard: no such file or folder: $root\n" unless -e $root || -l $root;
        my @files;
        if   ( -d $root && !-l $root ) { File::Find::find( { wanted => sub { push @files, $File::Find::name if -f $_ && !-l $_ }, no_chdir => 1 }, $root ); }
        else                           { push @files, $root if -f $root; }
        for my $f ( sort @files ) {
            my $rel = $f eq $root ? basename($f) : substr( $f, length($root) );
            $rel =~ s{^/}{};
            scan_text( "$rel: file name", $rel );
            open( my $fh, '<:raw', $f ) or die "path-guard: cannot read $f\n";
            local $/;
            my $data = <$fh>;
            close $fh;
            scan_text( $rel, $data // '' );
        }
    }
}

sub hooks_dir {
    my $d = git_out( 'rev-parse', '--git-path', 'hooks' );
    $d =~ s/\s+$//;
    return $d;
}

sub same_file {
    my ( $a, $b ) = @_;
    return 0 unless -f $a && -f $b && -s $a == -s $b;
    local $/;
    open( my $fa, '<:raw', $a ) or return 0;
    open( my $fb, '<:raw', $b ) or return 0;
    return <$fa> eq <$fb>;
}

sub hook_state {    # '' when the hook is this script, else why not
    my $hook = hooks_dir() . '/pre-push';
    return "no pre-push hook at $hook" unless -f $hook;
    return "$hook is not executable"   unless -x $hook;
    return "$hook is not this script ($0)" unless same_file( $hook, $0 );
    return '';
}

sub install {
    my $dir  = hooks_dir();
    my $hook = "$dir/pre-push";
    if ( -e $hook && !same_file( $hook, $0 ) ) {
        open( my $fh, '<', $hook ) or die "path-guard: cannot read $hook\n";
        my $is_guard = grep { /^# tools\/path-guard\.sh / } <$fh>;
        close $fh;
        die "path-guard: $hook exists and is another hook; the guard does not replace it. Call the guard from it, or remove it.\n" unless $is_guard;
    }
    mkdir $dir unless -d $dir;
    File::Copy::copy( $0, $hook ) or die "path-guard: cannot write $hook\n";
    chmod 0755, $hook;
    my @st = stat($0);
    utime $st[8], $st[9], $hook;
    print "path-guard: installed $hook\n";
}

sub selftest {
    # Every line is put together from pieces, so this file holds nothing that looks like a hit.
    my $u = 'jo' . 'doe';
    my ( $us, $vol, $vf ) = ( '/Use' . 'rs', '/Volu' . 'mes', '/var/fol' . 'ders' );
    my @bad = (
        "$us/$u/Movies/a.mov",            "file://$us/$u/a.mov",                  'C:\\Use' . "rs\\$u\\a.mov",
        '/ho' . "me/$u/src",              '/tmp/x/-Use' . "rs-$u-Documents-y/z",  "/private$vf/ab/0123456789abcdef0123456789/T/x",
        "$vf/ab/0123456789abcdef/T",      '/private/tmp/cla' . 'ude-501/x',       "$vol/T7 Shield/clips",
        "$vol/Backup/a.mov",              'Machine: Mac' . '.lan (M9)',           'Jo' . 's-Mac' . 'Book-Pro' . '.local',
        'Jo' . 's-Mac' . 'Book-Pro',      "Jo's Mac" . 'Book',                    'https://clau' . 'de.ai/code/sess' . 'ion_0123456789abcdefABCDEFGH',
        'session: sess' . 'ion_01ABCDEFGHJKLMNPQRSTUVWX', '-rw-r--r--' . "  1 $u  staff  140 Oct 11 12:25 fuzz.txt",
    );
    my @good = (
        "$us/x/Movies/a.mov",    "$us/Shared/x",        "no $us/<name>, no $vol/<private>",
        "$vol/Fixture/Old/a.mov", "$vol/Glance 1.0/x",  "$vol/<APP_NAME>*", "under $vol/.",
        "`$vf/\xe2\x80\xa6` becomes `/private$vf/\xe2\x80\xa6`", '$TMPDIR/glance-kit', 'the plan.', 'a WLAN and a LAN',
        '-rw-r--r--' . ' 2949 Jul 21 14:42 notes.md', '-rw-r--r--' . '  1 <user>  staff  140 Oct 11 12:25 fuzz.txt', '/ho' . 'me/runner/work/x',
        'https://github.com/home/x', '~/claude-handoffs/x_brief.md', 'session_configuration_changed',
    );
    my $fail = 0;
    for my $i ( 0 .. $#bad ) {
        @hits = ();
        scan_text( 'selftest', $bad[$i] );
        unless (@hits) { $fail++; print "selftest: MISSED made-up line " . ( 1 + $i ) . "\n"; }
    }
    for my $g (@good) {
        @hits = ();
        scan_text( 'selftest', $g );
        if (@hits) { $fail++; print "selftest: a generic line was a hit: $g -> @hits\n"; }
    }
    for my $m (@MACHINE) {    # this machine's own names, built the way the guard reads them
        @hits = ();
        my $probe = $m->[0] eq 'account name' ? ( getpwuid($<) )[0] : $m->[0] eq 'home folder' ? $ENV{HOME} : undef;
        next unless defined $probe;
        scan_text( 'selftest', "x $probe y" );
        unless (@hits) { $fail++; print "selftest: MISSED this machine's $m->[0]\n"; }
    }
    @hits = ();
    printf "path-guard selftest: %d lines that must hit, %d that must not, %d of this machine's names: %s\n", scalar @bad, scalar @good, scalar @MACHINE,
        $fail ? "$fail FAILED" : 'ok';
    exit( $fail ? 1 : 0 );
}

sub finish {
    my ($what) = @_;
    if (@hits) {
        my $last = $#hits < $SHOWN ? $#hits : $SHOWN - 1;
        print "$_\n" for @hits[ 0 .. $last ];
        printf "... and %d more. All hits by rule: %s\n", @hits - $SHOWN, join( ', ', map { "$_ $by_rule{$_}" } sort keys %by_rule ) if @hits > $SHOWN;
        printf "path-guard: %d hit%s in %s (%d objects, %d bytes). Fix each at its source; nothing is waved through.\n", scalar @hits, @hits == 1 ? '' : 's', $what,
            $n_objects, $n_bytes;
        exit 1;
    }
    printf "path-guard: clean - %s (%d objects, %d bytes)\n", $what, $n_objects, $n_bytes;
    exit 0;
}

# ---- modes ----
my $ok = eval {
    if ( basename($0) eq 'pre-push' ) {
        my $remote = $ARGV[0] // 'origin';
        my $n      = 0;
        while ( my $l = <STDIN> ) {
            my ( $lref, $lsha, $rref, $rsha ) = split ' ', $l;
            next unless defined $rsha;
            scan_text( 'ref name', $rref );
            next if $lsha =~ /^0+$/;    # a delete
            scan_tag_object( $lsha, $rref );
            my @new = git_lines( 'rev-list', '-z', $lsha, '--not', "--remotes=$remote" );
            $n += @new;
            scan_commit($_) for @new;
        }
        finish("the $n commits of this push");
    }
    my $mode = shift(@ARGV) // '';
    if    ( $mode eq 'selftest' ) { selftest(); }
    elsif ( $mode eq 'install' )  { install(); exit 0; }
    elsif ( $mode eq 'installed' || $mode eq 'check' ) {
        my $why = hook_state();
        if ($why) { print "path-guard: $why. Run: tools/path-guard.sh install\n"; exit 1; }
        if ( $mode eq 'installed' ) { print "path-guard: the pre-push hook is installed and is this script\n"; exit 0; }
        my $top = git_out( 'rev-parse', '--show-toplevel' );
        $top =~ s/\s+$//;
        chdir $top or die "path-guard: cannot enter $top\n";
        for my $f ( git_lines( 'ls-files', '-z', '-c', '-o', '--exclude-standard' ) ) {
            next unless -f $f && !-l $f;
            scan_text( "$f: file name", $f );
            open( my $fh, '<:raw', $f ) or die "path-guard: cannot read $f\n";
            local $/;
            my $data = <$fh>;
            close $fh;
            scan_text( $f, $data // '' );
        }
        finish('the hook is installed; the working tree');
    }
    elsif ( $mode eq 'tree' ) { my $rev = $ARGV[0] // 'HEAD'; scan_tree($rev); finish("the tree of $rev"); }
    elsif ( $mode eq 'commits' ) {
        die "path-guard: commits needs rev-list arguments (a range, a commit, --all)\n" unless @ARGV;
        scan_commits(@ARGV);
        finish("the commits of @ARGV");
    }
    elsif ( $mode eq 'history' ) {
        scan_commits('--all');
        for my $r ( git_lines( 'for-each-ref', '--format=%(objectname) %(objecttype) %(refname)%00' ) ) {
            $r =~ s/^\s+//;
            my ( $oid, $type, $ref ) = split ' ', $r, 3;
            next unless defined $ref;
            scan_text( 'ref name', $ref );
            scan_tag_object( $oid, $ref ) if $type eq 'tag';
        }
        finish('every ref: commits, files, tag messages, ref names');
    }
    elsif ( $mode eq 'files' ) {
        die "path-guard: files needs at least one path\n" unless @ARGV;
        scan_files(@ARGV);
        finish( join ', ', map { basename($_) } @ARGV );
    }
    else {
        print "usage: path-guard.sh check | installed | install | tree [<rev>] | commits <rev-list arguments> | history | files <path>... | selftest\n";
        exit 2;
    }
    1;
};
unless ($ok) { print STDERR $@ || "path-guard: failed\n"; exit 2; }
__END__
