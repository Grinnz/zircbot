package Bot::Maverick::Network::Freenode;

use Moo;
use namespace::clean;

extends 'Bot::Maverick::Network';

our $VERSION = '0.50';

after '_irc_rpl_whoreply' => sub {
	my ($self, $message) = @_;
	my ($to, $channel, $username, $host, $server, $nick, $state, $realname) = @{$message->{params}};
	my $user = $self->user($nick);
	$user->is_bot(1) if $host =~ m!/bot/!;
};

after '_irc_rpl_whoisuser' => sub {
	my ($self, $message) = @_;
	my ($to, $nick, $username, $host, $star, $realname) = @{$message->{params}};
	my $user = $self->user($nick);
	$user->is_bot(1) if $host =~ m!/bot/!;
};

1;
