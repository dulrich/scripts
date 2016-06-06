# expando.pl: turn short sequences into longer statments
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

$VERSION = '0.0.2';
%IRSSI = (
	authors     => 'David Ulrich',
	contact     => 'david@ulrichdev.com',
	name        => 'self_censor',
	description => 'Calls unnecessay attention to certain words by replacing letters with special characters.',
	license     => 'BSD',
	url         => 'none'
);

my %replacements = (
	# 'ass'   => [ '@ss', ['es'] ],
	'bi+tch' => [ 'b!tch', ['es'] ],
	'da+mn'  => [ 'd@mn', ['it'] ],
	'di+ck'  => [ 'd!ck', ['s'] ],
	'fu+ck'  => [ 'f*ck', ['er','ers','ing','s'] ],
	'he+ll'  => [ 'he!!', ['s'] ],
	'shi+t'  => [ 'sh!t', ['s','ting'] ],
	'who+re+' => [ 'wh*r3', ['s'] ]
);

sub do_expansion () {
	my ($line, $server_rec, $wi_item_rec) = @_;
	my $r;
	my $rr;
	my $rs;
	my $sfx;
	
	if ($line !~ /^\%raw\s+/) {
		foreach $r ( keys %replacements ) {
			$rr = $replacements{$r}[0];
			$rs = $replacements{$r}[1];
			
			if (scalar(@$rs) == 0) {
				$line =~ s/(\b$r|$r\b)/$rr/g;
			}
			else {
				$sfx = join("|",@$rs);
				
				$line =~ s/(\b$r|$r($sfx)?\b)/$rr\2/g;
			}
		}
	}
	else {
		$line =~ s/^\%raw\s+//;
	}
	
	Irssi::signal_continue($line, $server_rec, $wi_item_rec);
}

Irssi::signal_add_first('send text', "do_expansion");
