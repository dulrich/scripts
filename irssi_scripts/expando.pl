# expando.pl: turn short sequences into longer statments
# Copyright (C) 2014 - 2016  David Ulrich
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use strict;

use vars qw($VERSION %IRSSI);

$VERSION = '0.0.2';
%IRSSI = (
	authors     => 'David Ulrich',
	contact     => 'david@ulrichdev.com',
	name        => 'expando',
	description => 'Expands given character sequences into other sequences. Originally for giving simple things ridiculously long, formal names.',
	license     => 'BSD',
	url         => 'none',
);

my %replacements = (
	_A_   => 'Modern Web App(tm)',
	_C_   => 'the arcane language known only as \'C\'',
	_H_   => 'the inevitable heat death of the universe',
	_I_   => 'I, for one, welcome our Reptilian overlords',
	_M_   => 'that other mining game, whose name we do not mention',
	_MMM_ => 'Frederick P. Brooks\' classic, the mythical man month',
	_R_   => 'the dreaded \'Real Programmer(TM)(R)(C)\'',
	_S_   => 'in \'Soviet Amerika\',',
	_U_   => 'University Shaped Place',
	_W_   => 'the infallible wikipedia',
);

sub do_expansion () {
	my ($line, $server_rec, $wi_item_rec) = @_;
	my $r;
	my $rr;
	
	foreach $r ( keys %replacements ) {
		$rr = $replacements{$r};
		$line =~ s/\b$r\b/$rr/g;
	}
	
	my ($vn) = $line =~ /^:(\d+):/;
	my $repl = '\$1.\$2';
	
	if ($vn) {
		$line =~ s/^:(\d+):\s*//;
		
		for(my $i=0;$i<$vn;$i++) {
			$repl = '$repl.\$3';
		}
		
		$line =~ s/\b([b-df-hj-np-tv-z0-9]*)([aeiou]*)([aeiou])/$repl/giee;
	}
	
	Irssi::signal_continue($line, $server_rec, $wi_item_rec);
}

Irssi::signal_add_first('send text', 'do_expansion');
