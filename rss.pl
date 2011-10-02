#!/usr/bin/perl

use strict;
use warnings;

use Tk;
use Tk::Tree;
use Tk::ResizeButton;
use Tk::ItemStyle;
use Tk::ROText;
use Readonly;
use YAML;
use SQLite::DB;
use Encode;
use DateTime;
use POSIX;
#use Time::HiRes qw/gettimeofday tv_interval/;

# load configuration file...
my $config = YAML::LoadFile('config.yaml');

my $sql = SQLite::DB->new($config->{'database'});
$sql->connect() or die $sql->get_error;

my ($mw, $feeds, $articles, $one_article);
my (%styles, @sorted_feeds);

my $current_feed = q//;
my $current_article = -1;
my $articles_shown = 0;

Readonly my $article_limit => 100;

# initialize all widgets
sub setup_widgets {
	Readonly my @popts => qw/-fill both -expand 1/;
	Readonly my @hopts => qw/-header 1/;

	# create main window and panes...
	$mw = Tk::MainWindow->new(-title => 'RSS');

	my $pw = $mw->Panedwindow(-orient => 'horizontal')->pack(@popts);
	my $leftp = $pw->Frame;
	my $rightp = $pw->Frame;

	my $rightpw = $rightp->Panedwindow(
		-orient => 'vertical')->pack(@popts);
	my $rightupp = $rightpw->Frame;
	my $rightdnp = $rightpw->Frame;

	# create items in panes...
	$feeds = $leftp->Scrolled('Tree',
		-columns => 1,
		@hopts, qw/-scrollbars osw/
	)->pack(@popts);
	$articles = $rightupp->Scrolled('HList',
		-columns => 4,
		@hopts, qw/-scrollbars ose/
	)->pack(@popts);
	$one_article = $rightdnp->ROText(-wrap => 'word')->pack(@popts);

	$pw->add($leftp, $rightp);
	$rightpw->add($rightupp, $rightdnp);

	# helper function for headers...
	sub do_headers {
		my ($widgetref, @heads) = @_;
		my $cnt = 0;

		# walk through all headers, inserting a ResizeButton...
		for my $head (@heads) {
			$widgetref->header('create', $cnt,
				-itemtype => 'window',
				-widget => $widgetref->ResizeButton(
					-text => $head,
					-widget => \$widgetref,
					-relief => 'flat',
					-pady => 0,
					-column => $cnt,
				),
			);
			$cnt++;
		}
	}

	# create headers for lists...
	do_headers($feeds, qw/feed/);
	do_headers($articles, qw/title feed author time/);

	# create common styles...
	$styles{right} = $feeds->ItemStyle(
		'text',
		-justify => 'right',
	);
	$styles{unread} = $articles->ItemStyle(
		'text',
		-foreground => 'blue',
	);
	$styles{normal} = $articles->ItemStyle('text');
	
	# bind actions to user clicks...
	$articles->configure(
		-browsecmd => \&article_changed,
		-command => \&run_article,
	);
	$feeds->configure(-browsecmd => \&feed_changed);

	# replace the Tab key binding...
	$mw->bind('all', '<Key-Tab>' => undef);
	$articles->bind('<Key-Tab>' => sub { $feeds->focus });
	$feeds->bind('<Key-Tab>' => sub { $articles->focus });
}

# flush article description...
sub clear_one_article {
	$one_article->delete('1.0', 'end');
}

# load article description from db...
sub load_one_article {
	my $r = $sql->select_one_row(
		'select description from articles where id=?',
		$current_article
	) or warn $sql->get_error;

	my $text = decode('utf8', $r->{description});
	$one_article->insert('end', $text);
}

# event handler for browse on articles list
sub article_changed {
	my $article = shift;

	# handle the 'more' item...
	if ($article eq 'more') {
		load_articles();
		return;
	}
	# handle the 'end' item...
	elsif ($article eq 'end') {
		$current_article = -1;
		clear_one_article();
		return;
	}

	return if $current_article == $article;
	$current_article = $article;

	clear_one_article();
	load_one_article();
}

# mark current article as read
sub mark_current_read {
	my $r = $sql->select_one_row(
		'select read from articles where id=?',
		$current_article
	) or warn $sql->get_error;

	# mark only if is not already read...
	if ($r->{'read'} == 0) {
		# update in database...
		$sql->exec(
			q/update articles set read='1' where id=?/,
			$current_article
		) or warn $sql->get_error;

		# update style on screen...
		$articles->entryconfigure($current_article,
			-style => $styles{normal});
		for my $col (1..3) {
			$articles->itemConfigure($current_article,
				$col,
				-style => $styles{normal});
		}
	}
}

# launch article in external browser
sub run_article {
	# shouldn't happen, but you never know...
	return if $current_article eq 'more';
	return if $current_article < 0;

	# mark it as read...
	mark_current_read();

	# fetch link from db...
	my $r = $sql->select_one_row(
		'select link from articles where id=?', $current_article
	) or warn $sql->get_error;

	# fork and exec browser...
	my $pid = fork();
	if (not defined $pid) {
		warn "fork: $!";
	} elsif ($pid == 0) {
		# split the browser command and substitute URL...
		my @execparts = map {
			$_ =~ s/__URL__/$r->{'link'}/ge;
			$_;
		} (split(/\s+/, $config->{'browser'}));
		# need CORE:: to override SQLite's exec
		CORE::exec(@execparts);
		die "exec browser: $!";
	}
}

# flush article list...
sub clear_articles {
	$articles->delete('all');
	$articles_shown = 0;
}

# fetch $article_limit more articles from db
sub load_articles {
	my $first = undef;

	# subroutine to process SQL query
	my $process = sub {
		my $st = shift;

		# process all rows...
		while (my $row = $st->fetchrow_hashref) {
			my @opts = (
				-itemtype => 'text',
				-style => $row->{'read'} ? $styles{normal} 
							 : $styles{unread}
			);
			my $id = $row->{id};

			# save first inserted row id...
			$first = $id unless defined $first;

			# add widgets...
			$articles->add($id,
				-text => decode('utf8', $row->{title}),
				@opts
			);
			$articles->itemCreate($id,
				1,
				-text => $row->{feed},
				@opts
			);
			$articles->itemCreate($id,
				2,
				-text => decode('utf8', $row->{author}),
				@opts
			);
			my $time = 
				DateTime->from_epoch(epoch => $row->{'time'});
			$articles->itemCreate($id,
				3,
				-text =>  $time->ymd('-') 
					. q/ / x 2
					. $time->hms(':'),
				@opts
			);
		}
	};

	# delete the 'more' entry...
	$articles->delete('entry', 'more')
		if $articles->info('exists', 'more');

	# fetch and process articles from db...
#	my $start = [ gettimeofday() ];
	$sql->select(
		'select id, title, feed, author, time, read from articles'
		. ' where feed like ? order by time desc' 
		. " limit $article_limit offset $articles_shown",
		$process,
		$current_feed . '%',
	) or warn $sql->get_error;
#	warn tv_interval($start);

	# see if we fetched something...
	if (defined $first) {
		# conveniently make first inserted row seen and selected...
		$articles->see($first);
		$articles->anchorSet($first);
		article_changed($first);
		
		# update count and add a 'more' item...
		# note that we don't need to precisely increase by the
		# number of rows returned...
		$articles_shown += $article_limit;
		$articles->add('more', -text => '[ more ]');
	}
	else {
		# inform the user that there's no more articles...
		$articles->add('end', -text => '[ end ]');
	}
}

# event handler for browse on feeds list
sub feed_changed {
	my $feed = shift;
	return if $feed eq $current_feed;

	$current_feed = $feed;
	clear_articles();
	load_articles();
}

# fetch feeds from YAML and db
sub load_feeds {
	# fetch list from YAML...
	my $feed_list = YAML::LoadFile('feeds.yaml');
	
	# clear widgets and initialize...
	$feeds->delete('all');
	# due to groups it's most useful to have the keys sorted
	@sorted_feeds = sort keys %$feed_list;

	# walk through feeds...
	for my $feed (@sorted_feeds) {
		my $base = $feed;
		$base =~ s/^.*\.//;

		# add widgets...
		$feeds->add($feed, -text => $base);
	}

	# make the groups initially closed...
	for my $feed (@sorted_feeds) {
		next if $feed_list->{$feed};
		$feeds->setmode($feed, 'close');
		$feeds->close($feed);
	}
}

# refresh (USR1) handler
sub do_refresh {
	# obliterate all and load feeds...
	load_feeds();
	clear_articles();
	clear_one_article();

	# if current feed still exists, make it seen and selected and
	# load its articles...
	if ($feeds->info('exists', $current_feed)) {
		$feeds->see($current_feed);
		$feeds->anchorSet($current_feed);
		load_articles();
		# dtto if current article still exists...
		if ($articles->info('exists', $current_article)) {
			$articles->see($current_article);
			$articles->anchorSet($current_article);
			load_one_article;
		} else {
			$current_article = -1;
		}
	} else {
		$current_feed = q//;
	}
}

# signal handlers
sub sig_usr1 {
	$mw->afterIdle(\&do_refresh);
	$SIG{USR1} = \&sig_usr1;
}

sub sig_chld {
	while (waitpid(-1, WNOHANG) > 0) {};
	$SIG{CHLD} = \&sig_chld;
}

@SIG{qw/CHLD USR1/} = (\&sig_chld, \&sig_usr1);

# load and run!
setup_widgets();
load_feeds();
MainLoop();

