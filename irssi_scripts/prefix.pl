# piglatin.pl: Prefixes each word in a message with a random character
# Copyright (C) 2016  David Ulrich
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
	name        => 'prefix',
	description => 'Prefixes each word in a message with a random character',
	license     => 'BSD',
	url         => 'none',
);

sub do_expansion () {
	my ($line, $server_rec, $wi_item_rec) = @_;
	
	my $setval = '~!@#$%^&*-_+=<>';
	my $setlen = length($setval);
	my $char;
	
	my ($wp) = $line =~ /^\$p/;
	
	if ($wp) {
		$line =~ s/^\$p(\s+)?//;
		
		$line =~ s/\b(\w+)\b/"" . substr($setval, int(rand($setlen)), 1) . "$1"/egi;
	}
	
	Irssi::signal_continue($line, $server_rec, $wi_item_rec);
}

Irssi::signal_add_first('send text', "do_expansion");
