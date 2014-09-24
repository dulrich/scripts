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
	_M_ => "that other mining game, whose name we do not mention",
	_MMM_ => "Frederick P. Brooks' mythical man month",
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
