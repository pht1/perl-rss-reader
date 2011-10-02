#!/usr/bin/perl

use strict;
use warnings;

use SQLite::DB;
use Data::Dumper;
use YAML;

# load configuration file...
my $config = YAML::LoadFile('config.yaml');

my $sql = SQLite::DB->new($config->{'database'});

$sql->connect() or die $sql->get_error;
$sql->transaction_mode();

my $create = 'create table articles (';
for my $col (qw/feed title link author description/) {
	$create .= "$col text not null, ";
}
$create .= 'time integer not null, read integer not null default 0,'
	.  'id integer not null primary key autoincrement)';
$sql->exec($create) or die $sql->get_error;

$sql->exec('create index feed on articles (feed)');
$sql->exec('create index read on articles (feed, read)');
$sql->exec('create index time on articles (time desc)');
$sql->exec(
	'create unique index article on articles (feed, link)');

$sql->select('SELECT * FROM sqlite_master',
	sub {
		my $st = shift;
		while (my $r = $st->fetchrow_hashref) {
			print Dumper($r);
		}
	}
) or die $sql->get_error;

$sql->commit() or die $sql->get_error;
$sql->disconnect();
