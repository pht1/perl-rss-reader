#!/usr/bin/perl

use strict;
use warnings;

use XML::RSS;
use XML::Entities;
use LWP::UserAgent;
use SQLite::DB;
use DateTime::Format::Mail;
use DateTime::Format::ISO8601;
use YAML;

# load configuration file...
my $config = YAML::LoadFile('config.yaml');

# start database connection...
my $sql = SQLite::DB->new($config->{'database'});
$sql->connect() or die $sql->get_error;

# initialize objects...
my $agent = LWP::UserAgent->new(env_proxy => 1);
my $feeds = YAML::LoadFile('feeds.yaml');

# fetch one feed and store it to database...
sub fetch_one {
	my ($feed, $url) = @_;

	# retrieve data from internet...
	my $reply = $agent->get($url);
	if (not $reply->is_success) {
		warn($feed . ':' . $reply->status_line);
		return;
	}

	# parse RSS...
	my $rss = XML::RSS->new();
	eval { $rss->parse($reply->content); };
	if ($@) {
		warn($feed . ':' . $@);
		return;
	}

	my $insert = <<'_END';
insert into articles (feed, title, link, author, description,
	time) values (?, ?, ?, ?, ?, ?)
_END
	my $update = <<'_END';
update articles set feed=?, title=?, link=?, author=?, description=?,
	time=? where id=?
_END
	# process all items...
	for my $itemref (@{$rss->{items}}) {
		my %item = %$itemref;
		my $hasdc = ref $item{dc} eq 'HASH';

		# figure missing 'author' from dc namespace...
		if (!$item{author} and $hasdc) {
	    		my %dc = %{$item{dc}};
	    		$item{author}	= $dc{creator} ? $dc{creator}
					: $dc{contributor};
		}

		# make sure all items are defined...
		for my $i (qw/title link author description pubDate/) {
			$item{$i} ||= q//;
			$item{$i} = 
				XML::Entities::decode('all', $item{$i});
		}

		my $datetime;

		eval {
			# try to get datetime from pubDate, from dc,
			# or from 'now'...
			if ($item{pubDate}) {
				my $p =	DateTime::Format::Mail->new;
				$p->loose;
				$datetime = $p->parse_datetime(
					$item{pubDate});
			} elsif ($hasdc) {
				$datetime = 
				DateTime::Format::ISO8601->parse_datetime(
					$item{dc}->{date});
			} else {
				$datetime = DateTime->now;
			}
		};
		if ($@) {
			warn($feed . ':' . $@);
			$datetime = DateTime->now;
		}

		# see if db record already exists...
		my $r = $sql->select_one_row(
			'select id from articles where feed=? and link=?',
			$feed,
			$item{'link'}
		);

		# run update query...
		$sql->exec(
			($r->{id} ? $update : $insert),
			$feed,
			@item{qw/title link author description/},
			$datetime->epoch,
			($r->{id} ? $r->{id} : ())
		) or warn $sql->get_error;
	}
}

# figure out feed names to fetch...
my @to_process;

if (scalar @ARGV) {
	# fetch names from command line, expanding groups...
	for my $feed (@ARGV) {
		if ($feeds->{$feed}) {
			push @to_process, $feed;
		} else {
			push @to_process, grep { 
				index($_, $feed, 0) >= 0
			} sort keys %$feeds;
		}
	}
} else {
	# no command line - fetch all feeds...
	@to_process = sort keys %$feeds;
}

# process feeds...
for my $feed (@to_process) {
	next if !$feeds->{$feed};
	print "$feed\n";
	$sql->transaction_mode();
	fetch_one($feed, $feeds->{$feed});
	$sql->commit() or die $sql->get_error;
}

# finalize database connection...
$sql->exec('analyze') or die $sql->get_error;
$sql->disconnect();

# notify GUI of changes...
system('killall -USR1 rss.pl 2>/dev/null');

print DateTime->now->iso8601(), " done fetching\n";

