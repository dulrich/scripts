# piglatin.pl: convert messages into piglatin
# Copyright (C) 2014 - 2015  David Ulrich
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

$VERSION = '0.0.1';
%IRSSI = (
	authors     => 'David Ulrich',
	contact     => 'david@ulrichdev.com',
	name        => 'piglatin',
	description => 'Converts messages started with $w to w-piglatin, and $y to y-piglatin',
	license     => 'BSD',
	url         => 'none',
);

sub do_expansion () {
	my ($line, $server_rec, $wi_item_rec) = @_;
	
	
	my ($wn) = $line =~ /^\$w/;
	my ($yn) = $line =~ /^\$y/;
	
	if ($wn) {
		$line =~ s/^\$w(\s+)?//;
		
		$line =~ s/\b([aeiou]\w+)\b/$1way/gi;
		$line =~ s/\b([b-df-hj-np-tv-z])([b-df-hj-np-tv-xz]+)?([aeiouy])(\w+)?\b/$3$4$1$2ay/gi;
	}
	elsif ($yn) {
		$line =~ s/^\$y(\s+)?//;
		
		$line =~ s/\b([aeiou]\w+)\b/$1yay/gi;
		$line =~ s/\b([b-df-hj-np-tv-z])([b-df-hj-np-tv-xz]+)?([aeiouy])(\w+)?\b/$3$4$1$2ay/gi;
	}
	
	if ($wn || $yn) {
		$line =~ s/\/emay/\/me/;
	}
	
	Irssi::signal_continue($line, $server_rec, $wi_item_rec);
}

Irssi::signal_add_first('send text', "do_expansion");
