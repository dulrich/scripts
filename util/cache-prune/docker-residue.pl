#!/usr/bin/perl
# docker-residue.pl: the JSON half of docker-residue.sh (capture shaping,
# classifier, footprint sum), in perl + JSON::PP so cache-prune needs no jq.
# Not a util subcommand: it sits under util/cache-prune/, which the router
# never lists. Invoked as `perl docker-residue.pl <mode> [args]`; reads stdin.
#
# Modes:
#   capture <repo-root>     runs the docker / compose subprocesses itself and prints
#                           the capture document (see docker-residue.sh); no JSON
#                           passes through argv or the shell
#   classify                stdin: capture JSON -> TSV rows (see docker-residue.sh)
#   footprint               stdin: `system df` JSON lines -> bytes, exit 1 if incomplete
#
# hbytes (below) and docker_size_to_bytes (runtimes/docker.sh, bash, so the
# docker build-cache probe needs no perl) are one contract: the shared vector
# table in util/tests/cache-prune/adapters.sh asserts both.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
use strict;
use warnings;
use JSON::PP ();

my $J = JSON::PP->new->utf8->canonical;
my $mode = shift @ARGV // '';
binmode STDOUT;

sub slurp { local $/; my $s = <STDIN>; return defined $s ? $s : ''; }
sub dec { return $J->decode($_[0]); }
sub enc { return $J->encode($_[0]); }
sub isbool { return JSON::PP::is_bool($_[0]); }
# jq truthiness: everything except null and false.
sub truthy { my $v = shift; return 0 unless defined $v; return 0 if isbool($v) && !$v; return 1; }
sub alt { my ($v, $d) = @_; return truthy($v) ? $v : $d; }
sub isobj { return ref($_[0]) eq 'HASH'; }
sub isnum { my $v = shift; return defined($v) && !ref($v) && JSON::PP->new->allow_nonref->encode($v) !~ /^"/; }

# jq tostring.
sub tostr {
    my $v = shift;
    return 'null' unless defined $v;
    if (isbool($v)) { return $v ? 'true' : 'false'; }
    if (ref $v) { return JSON::PP->new->canonical->encode($v); }
    return "$v";
}

# hbytes: docker's decimal human sizes -> integer bytes, or undef.
my %UNIT = ('' => 1, B => 1, kB => 1e3, KB => 1e3, MB => 1e6, GB => 1e9, TB => 1e12);
sub hbytes {
    my $s = tostr(shift);
    $s = (split / /, $s, -1)[0] // '';
    return undef unless $s =~ /^([0-9.]+)([A-Za-z]*)$/;
    my ($n, $u) = ($1, $2);
    die "hbytes: not a number: $n\n" unless $n =~ /^(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$/;
    my $m = exists $UNIT{$u} ? $UNIT{$u} : 1;
    my $r = ($n + 0) * $m;
    my $i = int($r);
    $i -= 1 if $i > $r;
    return $i;
}

# tonumber? on a string: a number, or undef.
sub tonum {
    my $v = shift;
    return $v + 0 if isnum($v);
    return undef if ref $v || !defined $v;
    return $v =~ /^\s*-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\s*$/ ? $v + 0 : undef;
}

sub norm {
    my $s = shift;
    $s =~ s{^docker\.io/}{};
    $s =~ s{^library/}{};
    return $s if index($s, '@') >= 0;
    my @parts = split m{/}, $s, -1;
    return $s if @parts && index($parts[-1], ':') >= 0;
    return "$s:latest";
}

sub repo {
    my $s = shift;
    return (split /@/, $s, -1)[0] if index($s, '@') >= 0;
    $s =~ s{:[^:/]*$}{};
    return $s;
}

sub days_from_civil {
    my ($y, $m, $d) = @_;
    $y -= $m <= 2 ? 1 : 0;
    my $era = int(($y >= 0 ? $y : $y - 399) / 400);
    my $yoe = $y - $era * 400;
    my $doy = int((153 * ($m + ($m > 2 ? -3 : 9)) + 2) / 5) + $d - 1;
    my $doe = $yoe * 365 + int($yoe / 4) - int($yoe / 100) + $doy;
    return $era * 146097 + $doe - 719468;
}

# ts: ISO-8601 (optional fraction, Z or +-HH:MM) -> epoch seconds, or undef.
# A shape that matches but is no calendar time is an error, as in jq.
sub ts {
    my $s = shift;
    return undef unless defined $s && !ref $s;
    return undef unless $s =~ /^([0-9-]+T[0-9:]{8})(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$/;
    my ($d, $f, $z) = ($1, $2, $3);
    die "ts: bad date $d\n" unless $d =~ /^([0-9]+)-([0-9]{1,2})-([0-9]{1,2})T([0-9]{2}):([0-9]{2}):([0-9]{2})$/
        && $2 >= 1 && $2 <= 12 && $3 >= 1 && $3 <= 31 && $4 <= 23 && $5 <= 59 && $6 <= 60;
    my $epoch = days_from_civil($1, $2, $3) * 86400 + $4 * 3600 + $5 * 60 + $6;
    my $t = $epoch + ("0" . ($f // '')) ;
    if ($z ne 'Z') {
        my $sign = substr($z, 0, 1) eq '-' ? -1 : 1;
        $t -= $sign * (substr($z, 1, 2) * 3600 + substr($z, 4, 2) * 60);
    }
    return $t;
}

sub tsv { return join("\t", map { tostr($_) } @_); }
sub arr { my $v = shift; return ref($v) eq 'ARRAY' ? @$v : (); }

sub classify {
    my $in = shift;
    my @vols = sort { $b->{size} <=> $a->{size} || $a->{name} cmp $b->{name} } arr($in->{volumes});
    my @vol = map { tsv('volume', $_->{name}, $_->{size}, $_->{links}, ($_->{links} == 0 ? 'dangling' : 'linked')) } @vols;
    push @vol, map { tsv('anonvolume', $_->{name}, $_->{size}) }
        grep { $_->{links} == 0 && isbool($_->{anonymous}) && $_->{anonymous} } @vols;
    push @vol, tsv('unavailable', 'volumes', $in->{volume_error}) if truthy($in->{volume_error});

    if (truthy($in->{image_error})) {
        return (tsv('unavailable', 'images', $in->{image_error}), @vol);
    }
    my @images = arr($in->{images});
    my %byref;
    for my $img (@images) { $byref{norm($_)} = $img->{id} for arr($img->{tags}); }
    my (%svcs, @crefs);
    for my $c (arr($in->{compose})) {
        my $p = tostr($c->{project});
        for my $s (arr($c->{services})) {
            $svcs{"$p/" . tostr($s->{name})} = 1;
            if (truthy($s->{image})) { push @crefs, $s->{image}; }
            elsif (truthy($s->{build})) { push @crefs, "$p-" . tostr($s->{name}) . ':latest'; }
        }
    }
    my @stale = grep {
        my $st = $_->{state} // '';
        ($st eq 'created' || $st eq 'exited')
            && !(defined $_->{project} && defined $_->{service}
                 && $svcs{tostr($_->{project}) . '/' . tostr($_->{service})})
    } arr($in->{containers});
    my %staleid = map { (tostr($_->{id}) => 1) } @stale;
    my %live;
    $live{tostr($_->{image_id})} = 1 for grep { !$staleid{tostr($_->{id})} } arr($in->{containers});
    for my $r (@crefs, arr($in->{base_refs})) {
        my $id = $byref{norm($r)};
        $live{$id} = 1 if truthy($id);
    }
    my (%newest, %seen);
    for my $img (grep { $live{tostr($_->{id})} } @images) {
        my $t = ts($img->{created});
        for my $tag (arr($img->{tags})) {
            my $k = repo(norm($tag));
            $seen{$k} = 1;
            $newest{$k} = $t if defined $t && (!defined $newest{$k} || $t > $newest{$k});
        }
    }
    my @rows;
    for my $img (grep { !$live{tostr($_->{id})} } @images) {
        my @tags = arr($img->{tags});
        @tags = ('<none>') unless @tags;
        my @blk = map { $_->{name} } grep { tostr($_->{image_id}) eq tostr($img->{id}) } @stale;
        my $blockers = @blk ? join(',', map { tostr($_) } @blk) : '-';
        my $ct = ts($img->{created});
        for my $tag (@tags) {
            my $n = $newest{repo(norm($tag))};
            my $class = ($tag ne '<none>' && defined $n && defined $ct && $ct <= $n) ? 'superseded' : 'unreferenced';
            push @rows, tsv($class, $tag, $img->{id}, $img->{size}, $img->{created}, $blockers);
        }
    }
    @rows = sort @rows;
    push @rows, map { tsv('stale', $_->{name}, $_->{image_id}, alt($_->{size_rw}, 'unavailable'),
                          $_->{created}, $_->{state}, alt($_->{image_ref}, '-')) } @stale;
    return (@rows, @vol);
}

# jq -s: every JSON value in the input, in order.
sub values_of {
    my $p = JSON::PP->new->utf8;
    $p->incr_parse(shift);
    my @out;
    while (defined(my $v = $p->incr_parse)) { push @out, $v; }
    die "trailing garbage\n" if $p->incr_text =~ /\S/;
    return @out;
}

### capture ####################################################################

# run_cmd: run one command (argv list, no shell) with stdin and stderr on
# /dev/null; returns (success, stdout bytes with trailing newlines stripped,
# as `$(...)` did). A command that cannot be started fails like a nonzero exit.
sub run_cmd {
    my @cmd = @_;
    my $pid = open(my $fh, '-|');
    die "fork: $!\n" unless defined $pid;
    if (!$pid) {
        open(STDIN, '<', '/dev/null');
        open(STDERR, '>', '/dev/null');
        { exec { $cmd[0] } @cmd; }
        exit 127;
    }
    local $/;
    my $out = <$fh>;
    $out = '' unless defined $out;
    close $fh;
    $out =~ s/\n+\z//;
    return ($? == 0, $out);
}

# cap_volumes: `docker system df -v --format json` -> volumes array.
sub cap_volumes {
    my $doc = dec(shift);
    my $src = isobj($doc) ? $doc->{Volumes} : undef;
    return [ map {
        my $links = tonum(alt($_->{Links}, '0'));
        my $labels = tostr(alt($_->{Labels}, ''));
        my $anon = grep { ((split /=/, $_, 2)[0] // '') eq 'com.docker.volume.anonymous' } split /,/, $labels;
        { name => $_->{Name}, size => (hbytes($_->{Size}) // 0), links => (defined $links ? $links : 0),
          anonymous => ($anon ? JSON::PP::true : JSON::PP::false) }
    } arr($src) ];
}

# cap_images: `docker image inspect` -> images array.
sub cap_images {
    return [ map { { id => $_->{Id}, tags => alt($_->{RepoTags}, []), created => $_->{Created}, size => $_->{Size} } }
        arr(dec(shift)) ];
}

# cap_sizes: `docker ps -a --size` {id,size} lines -> {id: bytes}.
sub cap_sizes {
    my %out;
    $out{tostr($_->{id})} = hbytes($_->{size}) for values_of(shift);
    return \%out;
}

# cap_containers: `docker container inspect` -> containers array.
sub cap_containers {
    my ($text, $sizes) = @_;
    return [ map {
        my $name = tostr($_->{Name}); $name =~ s{^/}{};
        my $lab = isobj($_->{Config}) && isobj($_->{Config}{Labels}) ? $_->{Config}{Labels} : {};
        { name => $name, id => $_->{Id}, image_id => $_->{Image},
          image_ref => (isobj($_->{Config}) ? $_->{Config}{Image} : undef),
          state => (isobj($_->{State}) ? $_->{State}{Status} : undef), created => $_->{Created},
          project => alt($lab->{'com.docker.compose.project'}, undef),
          service => alt($lab->{'com.docker.compose.service'}, undef),
          size_rw => alt($sizes->{tostr($_->{Id})}, undef) }
    } arr(dec($text)) ];
}

# compose_files: compose*.yml / compose*.yaml regular files up to three levels
# under $root, bytewise sorted (find -maxdepth 3 -type f, never following
# symlinks, as before).
sub compose_files {
    my $root = shift;
    return () unless -d $root && !-l $root;
    my @out;
    my $walk;
    $walk = sub {
        my ($dir, $depth) = @_;
        return if $depth >= 3;
        opendir(my $dh, $dir) or return;
        my @names = readdir $dh;
        closedir $dh;
        for my $n (@names) {
            next if $n eq '.' || $n eq '..';
            my $p = ($dir =~ m{/\z} ? $dir : "$dir/") . $n;
            next if -l $p;
            if (-d _) { $walk->($p, $depth + 1); }
            elsif (-f _ && $n =~ /^compose.*\.ya?ml\z/s) { push @out, $p; }
        }
    };
    $walk->($root, 0);
    return sort @out;
}

# compose_project_dir: the `--project-directory` argv for one compose file.
# CACHE_PRUNE_COMPOSE_PROJECT_DIRS pins chosen files: newline-separated
# `<file>=<dir>` pairs, both relative to the root (an optional overlay module
# supplies the deployment default). Every other file keeps compose's default
# project directory.
sub compose_project_dir {
    my ($root, $file) = @_;
    my $base = $root =~ m{/\z} ? $root : "$root/";
    for my $pair (split /\n/, $ENV{CACHE_PRUNE_COMPOSE_PROJECT_DIRS} // '') {
        my ($f, $d) = $pair =~ /\A([^=]+)=(.+)\z/s or next;
        return ('--project-directory', "$base$d") if $file eq "$base$f";
    }
    return ();
}

# compose_has_unresolved: any service image, or build context/dockerfile, still
# holds a variable reference. Build args are guarded in subst_args, only when a
# FROM actually consumes them.
sub compose_has_unresolved {
    my $cfg = shift;
    my $svc = $cfg->{services};
    for my $k (keys %$svc) {
        my $s = $svc->{$k};
        return 1 if unresolved_ref($s->{image});
        my $b = $s->{build};
        if (isobj($b)) { return 1 if unresolved_ref($b->{context}) || unresolved_ref($b->{dockerfile}); }
        elsif (defined $b) { return 1 if unresolved_ref($b); }
    }
    return 0;
}

# compose_entry: one resolved compose config -> {project, services}, plus the
# Dockerfiles its services build: [{path, args}] in service-name order.
sub compose_entry {
    my $cfg = shift;
    my $svc = $cfg->{services};
    my $entry = { project => $cfg->{name}, services => [ map {
        { name => $_, image => alt($svc->{$_}{image}, undef), build => (defined $svc->{$_}{build} ? JSON::PP::true : JSON::PP::false) }
    } sort keys %$svc ] };
    my @builds;
    for my $k (sort keys %$svc) {
        my $b = $svc->{$k}{build};
        next unless defined $b;
        my $df = alt($b->{dockerfile}, 'Dockerfile');
        my $path = substr($df, 0, 1) eq '/' ? $b->{dockerfile} : tostr($b->{context}) . '/' . $df;
        push @builds, { path => tostr($path), args => alt($b->{args}, undef) };
    }
    return ($entry, \@builds);
}

# unresolved_ref: true when a compose string still holds a variable reference
# (${VAR} or unbraced $VAR) -- `config --no-interpolate` leaves them verbatim.
# $$ is compose's escape for a literal dollar, not a reference.
sub unresolved_ref {
    my $s = shift;
    return 0 if !defined $s || ref $s;
    $s =~ s/\$\$//g;
    return $s =~ /\$(?:\{|[A-Za-z_])/ ? 1 : 0;
}

# arg_value: build-arg $key of the compose `args` object when it is a string
# (a number, boolean or nested value never counts), else ''.
sub arg_value {
    my ($args, $key) = @_;
    return '' unless isobj($args);
    my $v = $args->{$key};
    return '' if !defined $v || ref $v || isnum($v);
    $v =~ s/\n+\z//;
    return $v;
}

# subst_args: expand ${X}, ${X:-d} and $X in one FROM ref. Compose build args
# win over the Dockerfile's ARG default. undef if any variable is left
# unresolved -- an unknown base never becomes a guess.
sub subst_args {
    my ($ref, $args, $defaults) = @_;
    my $guard = 0;
    while ($ref =~ /\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)/) {
        return undef if ++$guard > 64;
        my $whole = substr($ref, $-[0], $+[0] - $-[0]);
        my $var = defined $1 ? $1 : $4;
        my $fallback = defined $3 ? $3 : '';
        my $value = arg_value($args, $var);
        if (!length $value) {
            $value = (defined $defaults->{$var} && length $defaults->{$var}) ? $defaults->{$var} : $fallback;
        }
        return undef unless length $value;
        return undef if unresolved_ref($value);  # an uninterpolated compose arg feeding FROM
        substr($ref, index($ref, $whole), length $whole) = $value;
    }
    return $ref;
}

# dockerfile_bases: the FROM refs of one Dockerfile (an array ref), ARG
# defaults substituted (compose build args override them), earlier `AS` stage
# names and `scratch` skipped. undef if unreadable or a ref is left with an
# unresolved variable.
sub dockerfile_bases {
    my ($path, $args) = @_;
    my $file = $path;
    utf8::encode($file);
    return undef unless -r $file && open(my $fh, '<:raw', $file);
    my (%vars, @stages, @out);
    while (defined(my $line = <$fh>)) {
        chomp $line;
        utf8::decode($line);
        $line =~ s/^[[:space:]]+//;
        my ($keyword) = $line =~ /^([^[:space:]]*)/;
        my $rest = substr($line, length $keyword);
        $rest =~ s/^[[:space:]]+//;
        my $kw = uc $keyword;
        if ($kw eq 'ARG') {
            my $name = $rest;
            $name =~ s/=.*//s;
            $name =~ s/[[:space:]].*//s;
            next unless length $name;
            if (index($rest, '=') >= 0) {
                my $value = substr($rest, index($rest, '=') + 1);
                $value =~ s/[[:space:]].*//s;
                $value =~ s/^"//;
                $value =~ s/"\z//;
                # An ARG re-declared without a default inside a stage keeps
                # the global value; only a default sets it.
                $vars{$name} = $value;
            }
        } elsif ($kw eq 'FROM') {
            # Drop flags such as --platform=...
            while ($rest =~ /^--/) {
                last unless $rest =~ s/^.*?[[:space:]]//s;
                $rest =~ s/^[[:space:]]+//;
            }
            my ($ref) = $rest =~ /^([^[:space:]]*)/;
            my $stage = $rest =~ /[[:space:]][Aa][Ss][[:space:]]+([^[:space:]]+)/ ? $1 : '';
            $ref = subst_args($ref, $args, \%vars);
            return undef unless defined $ref;
            push @out, $ref if $ref ne 'scratch' && !grep { $_ eq $ref } @stages;
            push @stages, $stage if length $stage;
        }
    }
    return \@out;
}

# capture: probe the daemon + compose files and print ONE JSON document (shape
# in docker-residue.sh). Fail closed: any compose/Dockerfile/inspect failure
# sets image_error and empties the image classes; volumes report regardless.
sub capture {
    my $root = shift // '';
    my ($image_error, $volume_error) = ('', '');
    my ($images, $containers, $compose, $volumes) = ([], [], [], []);
    my %bases;
    my ($ok, $out);

    # Volumes first: they report even when the image classes fail closed.
    ($ok, $out) = run_cmd(qw(docker system df -v --format json));
    my $vols = $ok && length $out ? eval { cap_volumes($out) } : undef;
    if (defined $vols) { $volumes = $vols; }
    else { $volume_error = 'docker system df -v failed'; }

    ($ok) = run_cmd(qw(docker compose version));
    $image_error = 'docker compose not available' unless $ok;

    if (!length $image_error) {
        # A failing `docker images` leaves the list empty, as the old pipeline did.
        (undef, $out) = run_cmd(qw(docker images -q --no-trunc));
        my %seen;
        my @ids = sort grep { length && !$seen{$_}++ } split /\s+/, $out;
        if (@ids) {
            ($ok, $out) = run_cmd(qw(docker image inspect), @ids);
            my $imgs = $ok ? eval { cap_images($out) } : undef;
            if (defined $imgs) { $images = $imgs; } else { $image_error = 'docker image inspect failed'; }
        }
    }

    if (!length $image_error) {
        ($ok, $out) = run_cmd(qw(docker ps -aq --no-trunc));
        if (!$ok) { $image_error = 'docker ps failed'; }
        else {
            my @ids = grep { length } split /\s+/, $out;
            if (@ids) {
                (undef, $out) = run_cmd(qw(docker ps -a --size --no-trunc --format), '{"id":{{json .ID}},"size":{{json .Size}}}');
                my $sizes = eval { cap_sizes($out) } || {};
                ($ok, $out) = run_cmd(qw(docker container inspect), @ids);
                my $cs = $ok ? eval { cap_containers($out, $sizes) } : undef;
                if (defined $cs) { $containers = $cs; } else { $image_error = 'docker container inspect failed'; }
            }
        }
    }

    if (!length $image_error) {
        my @files = compose_files($root);
        if (!@files) {
            my $r = $root;
            utf8::decode($r);
            $image_error = "no compose files found under $r";
        }
        FILE: for my $file (@files) {
            my $name = $file;
            utf8::decode($name);
            my @pd = compose_project_dir($root, $file);
            ($ok, $out) = run_cmd(qw(docker compose -f), $file, @pd, '--profile', '*', qw(config --no-interpolate --format json));
            my $cfg = $ok ? eval { dec($out) } : undef;
            my ($entry, $builds) = isobj($cfg) && truthy($cfg->{name}) && isobj($cfg->{services}) ? eval { compose_entry($cfg) } : ();
            if (!defined $entry) { $image_error = "compose config failed: $name"; last FILE; }
            if (compose_has_unresolved($cfg)) { $image_error = "compose config has unresolved variable: $name"; last FILE; }
            push @$compose, $entry;
            for my $b (@$builds) {
                my $refs = dockerfile_bases($b->{path}, $b->{args});
                if (!defined $refs) { $image_error = "Dockerfile unreadable or unresolved FROM: $b->{path}"; last FILE; }
                $bases{$_} = 1 for grep { length } @$refs;
            }
        }
    }

    if (length $image_error) {
        ($images, $containers, $compose, %bases) = ([], [], []);
    }
    print enc({ images => $images, containers => $containers, compose => $compose,
                base_refs => [ sort keys %bases ], volumes => $volumes,
                image_error => (length $image_error ? $image_error : undef),
                volume_error => (length $volume_error ? $volume_error : undef) }), "\n";
}

if ($mode eq 'capture') {
    capture(shift @ARGV);
} elsif ($mode eq 'classify') {
    my @rows = classify(dec(slurp()));
    binmode STDOUT, ':utf8';
    print "$_\n" for @rows;
} elsif ($mode eq 'footprint') {
    my @s = map { hbytes($_->{Size}) }
        grep { my $t = tostr($_->{Type}); $t eq 'Images' || $t eq 'Containers' || $t eq 'Local Volumes' }
        values_of(slurp());
    exit 1 unless @s == 3 && !grep { !defined } @s;
    my $sum = 0; $sum += $_ for @s;
    print "$sum\n";
} elsif ($mode eq "--help" || $mode eq "-h") {
    print "usage: perl docker-residue.pl <mode> [args]  (modes: capture, classify, footprint)\n";
} else {
    print STDERR "usage: perl docker-residue.pl <mode> [args]  (modes: capture, classify, footprint)\n";
    exit 2;
}
