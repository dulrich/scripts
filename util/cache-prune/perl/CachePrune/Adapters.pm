# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# CachePrune::Adapters: the size probes shared by runtime modules (hardlink-aware directory
# census, path du). Every size hook built on these returns one probe record
# (CachePrune::Measurement) and prints nothing. perl-base only.
package CachePrune::Adapters;
use strict;
use warnings;
use CachePrune::Core ();
use CachePrune::Measurement qw(probe_available);

# dir_census_bytes($dir): (total, reclaimable) over the regular files under $dir, walked
# without following symlinks, keyed by inode: a file hardlinked twice inside the tree counts
# once, and an inode is reclaimable only when every one of its links lives inside the tree
# (links seen == st_nlink). Unreadable subdirectories are skipped silently; a missing or
# unreadable $dir censuses as (0, 0), never an error.
sub dir_census_bytes {
	my ($dir) = @_;
	return (0, 0) unless defined $dir && length $dir && -d $dir;
	my (%nlink, %size, %seen);
	my @stack = ($dir);
	while (@stack) {
		my $d = pop @stack;
		opendir(my $dh, $d) or next;
		my @names = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
		closedir $dh;
		for my $n (@names) {
			my $p = "$d/$n";
			my @st = lstat $p or next;
			if (-d _) { push @stack, $p; next; }
			next unless -f _;
			$nlink{ $st[1] } = $st[3];
			$size{ $st[1] } = $st[7];
			$seen{ $st[1] }++;
		}
	}
	my ($t, $r) = (0, 0);
	for my $i (keys %size) {
		$t += $size{$i};
		$r += $size{$i} if $seen{$i} == $nlink{$i};
	}
	return ($t, $r);
}

# generic_size($rt, $cache_dir): the size hook of every directory-backed runtime -- the census
# wrapped in a record whose source is "census" (one source, so a before/after pair is always
# comparable).
sub generic_size {
	my (undef, $dir) = @_;
	my ($t, $r) = dir_census_bytes($dir);
	return probe_available($t, $r, 'census');
}

# path_du_bytes($path): `du -sb` of one path, or 0 for anything that cannot be measured (for
# trees with no hardlink-sharing question: trash, fleet residue).
sub path_du_bytes {
	my ($path) = @_;
	my ($out) = CachePrune::Core::cmd_capture({ stderr => 'null' }, 'du', '-sb', '--', $path);
	my ($b) = split /\s/, ($out // ''), 2;
	return (defined $b && $b =~ /\A[0-9]+\z/) ? $b : 0;
}

1;
