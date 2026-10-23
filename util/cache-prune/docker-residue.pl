#!/usr/bin/perl
# docker-residue.pl: the JSON half of docker-residue.sh (capture shaping,
# classifier, footprint sum), in perl + JSON::PP so cache-prune needs no jq.
# Not a util subcommand: it sits under util/cache-prune/, which the router
# never lists. Invoked as `perl docker-residue.pl <mode> [args]`; reads stdin.
#
# Modes:
#   argval <key>            stdin: build-args JSON; prints .[key] if a string
#   volumes                 stdin: `system df -v` JSON -> volumes array
#   images                  stdin: `image inspect` JSON -> images array
#   sizes                   stdin: concatenated {id,size} docs -> {id: bytes}
#   containers <sizes>      stdin: `container inspect` JSON -> containers array
#   cfgok                   stdin: compose config; exit 0 iff .name and object .services
#   compose-append <cfg>    stdin: compose array; prints it with <cfg>'s entry appended
#   builds                  stdin: compose config; TSV "<dockerfile>\t<args-json>" lines
#   assemble <images> <containers> <compose> <volumes> <image_error> <volume_error>
#                           stdin: base refs, one per line -> the capture document
#   classify                stdin: capture JSON -> TSV rows (see docker-residue.sh)
#   footprint               stdin: `system df` JSON lines -> bytes, exit 1 if incomplete
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

my $T = JSON::PP::true;
my $F = JSON::PP::false;

if ($mode eq 'argval') {
    my $key = shift @ARGV;
    my $v = eval { JSON::PP->new->utf8->allow_nonref->decode(slurp()) };
    if (isobj($v) && defined $v->{$key} && !ref $v->{$key} && !isnum($v->{$key})) {
        binmode STDOUT, ':utf8';
        print $v->{$key}, "\n";
    }
} elsif ($mode eq 'volumes') {
    my $doc = dec(slurp());
    my $src = isobj($doc) ? $doc->{Volumes} : undef;
    my @out = map {
        my $links = tonum(alt($_->{Links}, '0'));
        my $labels = tostr(alt($_->{Labels}, ''));
        my $anon = grep { ((split /=/, $_, 2)[0] // '') eq 'com.docker.volume.anonymous' } split /,/, $labels;
        { name => $_->{Name}, size => (hbytes($_->{Size}) // 0), links => (defined $links ? $links : 0),
          anonymous => ($anon ? $T : $F) }
    } arr($src);
    print enc(\@out), "\n";
} elsif ($mode eq 'images') {
    my @out = map { { id => $_->{Id}, tags => alt($_->{RepoTags}, []), created => $_->{Created}, size => $_->{Size} } }
        arr(dec(slurp()));
    print enc(\@out), "\n";
} elsif ($mode eq 'sizes') {
    my %out;
    $out{tostr($_->{id})} = hbytes($_->{size}) for values_of(slurp());
    print enc(\%out), "\n";
} elsif ($mode eq 'containers') {
    my $sizes = dec(shift @ARGV);
    my @out = map {
        my $name = tostr($_->{Name}); $name =~ s{^/}{};
        my $lab = isobj($_->{Config}) && isobj($_->{Config}{Labels}) ? $_->{Config}{Labels} : {};
        { name => $name, id => $_->{Id}, image_id => $_->{Image},
          image_ref => (isobj($_->{Config}) ? $_->{Config}{Image} : undef),
          state => (isobj($_->{State}) ? $_->{State}{Status} : undef), created => $_->{Created},
          project => alt($lab->{'com.docker.compose.project'}, undef),
          service => alt($lab->{'com.docker.compose.service'}, undef),
          size_rw => alt($sizes->{tostr($_->{Id})}, undef) }
    } arr(dec(slurp()));
    print enc(\@out), "\n";
} elsif ($mode eq 'cfgok') {
    my $c = eval { dec(slurp()) };
    exit((isobj($c) && truthy($c->{name}) && isobj($c->{services})) ? 0 : 1);
} elsif ($mode eq 'compose-append') {
    my $cfg = dec(shift @ARGV);
    my $list = dec(slurp());
    my $svc = $cfg->{services};
    push @$list, { project => $cfg->{name}, services => [ map {
        { name => $_, image => alt($svc->{$_}{image}, undef), build => (defined $svc->{$_}{build} ? $T : $F) }
    } sort keys %$svc ] };
    print enc($list), "\n";
} elsif ($mode eq 'builds') {
    my $cfg = dec(slurp());
    my $svc = $cfg->{services};
    my $cj = JSON::PP->new->utf8->canonical->allow_nonref;
    for my $k (sort keys %$svc) {
        my $b = $svc->{$k}{build};
        next unless defined $b;
        my $df = alt($b->{dockerfile}, 'Dockerfile');
        my $path = substr($df, 0, 1) eq '/' ? $b->{dockerfile} : tostr($b->{context}) . '/' . $df;
        my @f = (tostr($path), $cj->encode(alt($b->{args}, undef)));
        for (@f) { s/\\/\\\\/g; s/\t/\\t/g; s/\n/\\n/g; s/\r/\\r/g; }
        print join("\t", @f), "\n";
    }
} elsif ($mode eq 'assemble') {
    my ($images, $containers, $compose, $volumes, $ie, $ve) = @ARGV;
    my %b;
    my $raw = slurp();
    utf8::decode($raw);
    $b{$_} = 1 for grep { length } split /\n/, $raw;
    print enc({ images => dec($images), containers => dec($containers), compose => dec($compose),
                base_refs => [ sort keys %b ], volumes => dec($volumes),
                image_error => (length $ie ? do { utf8::decode($ie); $ie } : undef),
                volume_error => (length $ve ? do { utf8::decode($ve); $ve } : undef) }), "\n";
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
    print "usage: perl docker-residue.pl <mode> [args]  (modes: see the file header)\n";
} else {
    print STDERR "usage: perl docker-residue.pl <mode> [args]  (modes: see header)\n";
    exit 2;
}
