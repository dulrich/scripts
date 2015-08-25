# Magic 8 Ball: A silly script to "answer" questions
# Copyright 2015  David Ulrich
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

use lib qw(..);
use JSON qw( );

my $answers_data = do {
	open(my $json_fh, "<:encoding(UTF-8)", "answers.json")
		or die("Can't open \$filename\": $!\n");
	local $/;
<$json_fh>
};

my $exit_codes_data = do {
	open(my $json_fh, "<:encoding(UTF-8)", "exit_codes.json")
		or die("Can't open \$filename\": $!\n");
	local $/;
<$json_fh>
};

my $json = JSON->new;
my %answers = %{ $json->decode($answers_data) };
my %exit_codes = %{ $json->decode($exit_codes_data) };

sub do_magic {
	my ($q) = @_;
	my $sum = 0;
	
	# who, what, where, why, when, how, how many|much
	my $answer_type = "probability";
	if (index($q,"what") == 0 || index($q,"wat") == 0) {
		$answer_type = "value";
	}
	elsif (index($q,"when") == 0) {
		$answer_type = "temporal";
	}
	elsif (index($q,"why") == 0) {
		$answer_type = "reason";
	}
	
	my $char;
	foreach $char (split(//,$q)) {
		$sum += ord($char);
	}
	
	my $answer_list = $answers{$answer_type};
	my $length = scalar(@$answer_list);
	my $index = $sum % $length;

	return $answers{$answer_type}[$index];
}

while (1) {
	print "What would you like to know? ";
	my $question = <>;
	chomp($question);

	$question = lc($question);
	
	if ($exit_codes{$question}) {
		last;
	}
	else {
		print do_magic($question),"\n";
	}
}

