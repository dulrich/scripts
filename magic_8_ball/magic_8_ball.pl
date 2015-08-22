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

my $json = JSON->new;
my %answers = %{ $json->decode($answers_data) };

my %exit_responses = (
	end => 1,
	exit => 1,
	no => 1,
	nothing => 1,
	quit => 1
);

sub do_magic {
	my ($q) = @_;
	my $sum = 0;
	
	# who, what, where, why, when, how, how many|much
	my $answer_type = "probability";
	if (substr($q,0,4) == "what" || substr($q,0,3) == "wat") {
		$answer_type = "value";
	}
	elsif (substr($q,0,4) == "when") {
		$answer_type = "temporal";
	}
	elsif (substr($q,0,3) == "why") {
		$answer_type = "reason";
	}
	
	my $q_len = length($q);
	my %letters = unpack("w*",$q);
	for(my $l=0;$l<$q_len;$l++) {
		$sum += $letters{$l};
	}
	
	my $answer_list = $answers{$answer_type};
	#my $ans;
	#print $answer_list;
	#foreach $ans ( @$answer_list ) {
		#print "ans $ans";
		#}
	#my $index = scalar @(answers{$answer_type});
	my $length = length(@$answer_list);
	my $index = $sum % $length;

	print "len $index";
	return @$answer_list{$index};
	#return "hello";
}

while (1) {
	print "WHat would you like to know? ";
	my $question = <>;
	chomp($question);

	$question = lc($question);
	
	if ($exit_responses{$question}) {
		last;
	}
	else {
		print do_magic($question),"\n";
	}
}

