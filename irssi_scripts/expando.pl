use strict;

use vars qw($VERSION %IRSSI);

$VERSION = '0.0.1';
%IRSSI = (
	authors		=> 'Bitt Faulk',
	contact		=> 'david@ulrichdev.com',
	name		=> 'expando',
	description	=> 'Expands given character sequences into other sequences',
	license		=> 'BSD',
	url		=> 'none',
);

my %replacements = (
	_C_ => "the arcane language known only as 'C'"
);

sub event_send_text () {
	my ($line, $server_rec, $wi_item_rec) = @_;
	my $r;
	my $rr;
	
	foreach $r ( keys %replacements ) {
		$rr = $replacements{$r};
		print $rr;
		$line =~ s/\b$r\b/$rr/;
	}
	
	Irssi::signal_continue($line, $server_rec, $wi_item_rec);
}

Irssi::signal_add_first('send text', "event_send_text");
