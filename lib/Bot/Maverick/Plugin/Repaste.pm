package Bot::Maverick::Plugin::Repaste;

use Mojo::URL;

use Moo;
with 'Bot::Maverick::Plugin';

our $VERSION = '0.50';

use constant PASTEBIN_RAW_ENDPOINT => 'http://pastebin.com/raw.php';
use constant HASTEBIN_RAW_ENDPOINT => 'http://hastebin.com/raw/';
use constant DPASTE_PASTE_ENDPOINT => 'http://dpaste.com/api/v1/';

sub register {
	my ($self, $bot) = @_;
	
	$bot->config->channel_default(repaste_lang => 'text');
	
	$bot->on(privmsg => sub {
		my ($bot, $m) = @_;
		
		my @pastebin_keys = ($m->text =~ m!\bpastebin\.com/(?:raw(?:/|\.php\?i=))?([a-z0-9]+)!ig);
		my @hastebin_keys = ($m->text =~ m!\bhastebin\.com/(?:raw/)?([a-z]+)!ig);
		my @pastes = ((map { +{type => 'pastebin', key => $_} } @pastebin_keys),
			(map { +{type => 'hastebin', key => $_} } @hastebin_keys));
		return() unless @pastes;
		
		my $future = _retrieve_pastes($m, \@pastes)->then(sub { _repaste_pastes($m, shift) })->on_done(sub {
			my $urls = shift;
			return() unless @$urls;
			my $reply = 'Repasted text';
			$reply .= ' from ' . $m->sender if defined $m->channel;
			$reply .= ': ' . join ' ', @$urls;
			$m->reply_bare($reply);
		})->on_fail(sub { chomp (my $err = $_[0]); $m->logger->error("Error repasting pastes from message '" . $m->text . "': $err") });
		$m->bot->adopt_future($future);
	});
}

sub _retrieve_pastes {
	my ($m, $pastes) = @_;
	
	my @futures;
	foreach my $paste (@$pastes) {
		my $url;
		if ($paste->{type} eq 'pastebin') {
			$url = Mojo::URL->new(PASTEBIN_RAW_ENDPOINT)->query(i => $paste->{key});
		} elsif ($paste->{type} eq 'hastebin') {
			$url = Mojo::URL->new(HASTEBIN_RAW_ENDPOINT)->path($paste->{key});
		}
		$m->logger->debug("Found $paste->{type} link to $paste->{key}: $url");
		push @futures, $m->bot->ua_request($url);
	}
	return $m->bot->new_future->wait_all(@futures)->then(sub {
		my @results = @_;
		foreach my $i (0..$#results) {
			my $future = $results[$i];
			my $paste = $pastes->[$i];
			$m->logger->error("Error retrieving $paste->{type} paste $paste->{key}: " . $future->failure) if $future->is_failed;
			next unless $future->is_done;
			my $res = $future->get;
			my $contents = $res->text;
			$m->logger->debug("No paste contents for $paste->{type} paste $paste->{key}"), next unless length $contents;
			if ($paste->{type} eq 'pastebin' and $contents =~ /Please refresh the page to continue\.\.\./) {
				$paste->{recheck} = 1;
			} else {
				$paste->{contents} = $contents;
			}
		}
		
		my @futures;
		foreach my $paste (@$pastes) {
			if ($paste->{recheck}) {
				my $url = Mojo::URL->new(PASTEBIN_RAW_ENDPOINT)->query(i => $paste->{key});
				$m->logger->debug("Rechecking $paste->{type} paste $paste->{key}: $url");
				push @futures, $m->bot->timer_future(1)
					->then(sub { $m->bot->ua_request($url) });
			} else {
				push @futures, $m->bot->new_future->done(undef);
			}
		}
		return $m->bot->new_future->wait_all(@futures);
	})->transform(done => sub {
		my @results = @_;
		foreach my $i (0..$#results) {
			my $future = $results[$i];
			my $paste = $pastes->[$i];
			$m->logger->error("Error retrieving $paste->{type} paste $paste->{key}: " . $future->failure) if $future->is_failed;
			next unless $future->is_done;
			my $res = $future->get // next;
			my $contents = $res->text;
			$m->logger->debug("No paste contents for $paste->{type} paste $paste->{key}"), next unless length $contents;
			$paste->{contents} = $contents;
		}
		return $pastes;
	});
}

sub _repaste_pastes {
	my ($m, $pastes) = @_;
	
	my @futures;
	foreach my $paste (@$pastes) {
		unless (defined $paste->{contents}) {
			push @futures, $m->bot->new_future->done(undef);
			next;
		}
		
		my $lang = $m->config->channel_param($m->channel, 'repaste_lang') // 'text';
		
		my %form = (
			content => $paste->{contents},
			syntax => $lang,
			poster => $m->sender->nick,
			expiry_days => 1,
		);
		
		$m->logger->debug("Repasting $paste->{type} paste $paste->{key} contents to dpaste");
		push @futures, $m->bot->ua_request(no_redirect => post => DPASTE_PASTE_ENDPOINT, form => \%form);
	}
	return $m->bot->new_future->wait_all(@futures)->transform(done => sub {
		my @results = @_;
		my @urls;
		foreach my $i (0..$#results) {
			my $future = $results[$i];
			my $paste = $pastes->[$i];
			$m->logger->error("Error repasting $paste->{type} paste $paste->{key}: " . $future->failure) if $future->is_failed;
			next unless $future->is_done;
			
			my $res = $future->get // next;
			my $url = $res->headers->header('Location');
			unless (length $url) {
				$m->logger->error("No paste URL returned");
				next;
			}
			
			$m->logger->debug("Repasted $paste->{type} paste $paste->{key} to $url");
			push @urls, $url;
		}
		return \@urls;
	});
}

1;

=head1 NAME

Bot::Maverick::Plugin::Repaste - Repasting plugin for Maverick

=head1 SYNOPSIS

 my $bot = Bot::Maverick->new(
   plugins => { Repaste => 1 },
 );

=head1 DESCRIPTION

Hooks into public messages of a L<Bot::Maverick> IRC bot and whenever a
L<pastebin.com|http://pastebin.com> or L<hastebin.com|http://hastebin.com> link
is detected, repastes it to another pastebin site like
L<dpaste|http://dpaste.com>.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick>
