# expando.pl: turn short sequences into longer statments
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

$VERSION = '0.0.2';
%IRSSI = (
	authors		=> 'David Ulrich',
	contact		=> 'dvulrich47@gmail.com',
	name		=> 'no_vowels',
	description	=> 'Strips vowels out of messages started with $$, consonants with $_.',
	license		=> 'BSD',
	url		=> 'none',
);

sub do_expansion () {
	my ($line, $server_rec, $wi_item_rec) = @_;
	
	
	my ($vn) = $line =~ /^\$\$/;
	my ($cn) = $line =~ /^\$\_/;
	
	if ($vn) {
		$line =~ s/^\$\$(\s+)?//;
		
		$line =~ s/(?:[aeiou]+)([b-df-hj-np-tv-z])/$1/gi;
		$line =~ s/([b-df-hj-np-tv-z])(?:[aeiou]+)/$1/gi;
	}
	elsif ($cn) {
		$line =~ s/^\$\_(\s+)?//;
		
		$line =~ s/(?:[b-df-hj-np-tv-z]+)([aeiou])/$1/gi;
		$line =~ s/([aeiou])(?:[b-df-hj-np-tv-z]+)/$1/gi;
	}
	
	Irssi::signal_continue($line, $server_rec, $wi_item_rec);
}

Irssi::signal_add_first('send text', "do_expansion");
