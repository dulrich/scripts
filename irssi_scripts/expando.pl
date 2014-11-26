# expando.pl: turn short sequences into longer statments
# Copyright 2013 - 2014 David Ulrich
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
	authors		=> 'David Ulrich',
	contact		=> 'david@ulrichdev.com',
	name		=> 'expando',
	description	=> 'Expands given character sequences into other sequences. Originally for giving simple things ridiculously long, formal names.',
	license		=> 'BSD',
	url		=> 'none',
);

my %replacements = (
	_C_ => "the arcane language known only as 'C'",
	_H_ => "the inevitable heat death of the universe",
	_I_ => "I, for one, welcome our Reptilian overlords",
	_M_ => "that other mining game, whose name we do not mention",
	_MMM_ => "Frederick P. Brooks' classic, the mythical man month",
	_S_ => "in 'Soviet Amerika',",
	_W_ => "the infallible wikipedia",
);

sub do_expansion () {
	my ($line, $server_rec, $wi_item_rec) = @_;
	my $r;
	my $rr;
	
	foreach $r ( keys %replacements ) {
		$rr = $replacements{$r};
		$line =~ s/\b$r\b/$rr/;
	}
	
	Irssi::signal_continue($line, $server_rec, $wi_item_rec);
}

Irssi::signal_add_first('send text', "do_expansion");
