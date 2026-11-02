#!/usr/bin/env perl
# Generates a fictional year of RevBank history in a new data directory, for
# testing. It runs the real revbank with a fake clock for every transaction, so
# the log is like a real one.
#
#   perl dev/gen-demo.pl ~/revbank ~/revbank-test
#   cd ~/revbank && ./revbank --datadir ~/revbank-test
#
# The products, prices and users are fictional.
use v5.36;
use Cwd qw(realpath);
use FindBin qw($RealBin);
use List::Util qw(shuffle sum);
use Time::Local qw(timelocal);

@ARGV == 2 or die "Usage: $0 <revbank directory> <new data directory>\n";
my ($revbank_dir, $datadir) = @ARGV;
my $revbank = realpath("$revbank_dir/revbank") // "";
-x $revbank or die "No revbank in $revbank_dir.\n";
die "$datadir already exists.\n" if -e $datadir;

sub run($t, $command) {
	local $ENV{FAKE_TIME} = $t;
	local $ENV{PERL5OPT} = "-I$RealBin -MFakeTime";
	open my $fh, "-|", $revbank, "--datadir", $datadir, "--command", $command
		or die $!;
	my $out = do { local $/; readline $fh };
	close $fh or warn "FAILED at " . localtime($t) . ": $command\n$out";
}

sub last_tid() {
	open my $fh, "<", "$datadir/log" or die $!;
	my $tid;
	/ END (\S+)/ and $tid = $1 while <$fh>;
	return $tid;
}

# A new data directory with the default files, and the plugin from this repo.
run(time, "help");
open my $plugins, ">>", "$datadir/plugins" or die $!;
print $plugins realpath("$RealBin/../plugins/sales"), "\n";
close $plugins;

srand 2026;

# id, price, description, addon, kind
my @products = (
	[ 8710001000011, 1.40, "Club-Mate, bottle 50 cl",          "+sm", "drink" ],
	[ 8710001000028, 1.40, "Club-Mate Zero, bottle 50 cl",     "+sm", "drink" ],
	[ 8710001000035, 1.40, "Club-Mate Granat, bottle 50 cl",   "+sm", "drink" ],
	[ 8710001000042, 0.90, "Coca-Cola Zero",                   "+sb", "drink" ],
	[ 8710001000059, 0.95, "Coca-Cola Zero Cherry",            "+sb", "drink" ],
	[ 8710001000066, 0.90, "Coca-Cola Zero (Zero cafeine)",    "+sb", "drink" ],
	[ 8710001000073, 0.90, "Coca-Cola",                        "+sb", "drink" ],
	[ 8710001000080, 1.50, "Fritz-Kola, bottle 33 cl",         "+sm", "drink" ],
	[ 8710001000097, 1.10, "Chocomel, can 25 cl",              "+sb", "drink" ],
	[ 8710001000103, 0.75, "Spa Rood, bottle 50 cl",           "+sf", "drink" ],
	[ 8710001000110, 1.75, "Red Bull, can 25 cl",              "+sb", "drink" ],
	[ 8710001000127, 1.00, "Lipton Ice Tea Green, can 33 cl",  "+sb", "drink" ],
	[ 8710001000134, 1.00, "Fernandes Rood, can 33 cl",        "+sb", "drink" ],
	[ 8710001000141, 0.95, "Croky Paprika",                    "",    "snack" ],
	[ 8710001000158, 0.95, "Lay's Naturel",                    "",    "snack" ],
	[ 8710001000165, 0.80, "Venco Lakritsdrop",                "",    "snack" ],
	[ 8710001000172, 0.70, "Katja Apekoppen",                  "",    "snack" ],
	[ 8710001000189, 0.95, "KitKat",                           "",    "snack" ],
	[ 8710001000196, 0.90, "Snickers",                         "",    "snack" ],
	[ 8710001000202, 0.90, "Twix",                             "",    "snack" ],
	[ 8710001000219, 0.90, "Mars",                             "",    "snack" ],
	[ 8710001000226, 0.50, "Daelmans Stroopwafel",             "",    "snack" ],
	[ 8710001000233, 1.15, "Tosti kaas",                       "",    "snack" ],
	[ 8710001000240, 1.40, "Tosti ham-kaas",                   "",    "snack" ],
	[ 8710001000257, 4.50, "AH Pizza Salami",                  "",    "pizza" ],
	[ 8710001000264, 4.00, "AH Pizza Margherita",              "",    "pizza" ],
	[ 8710001000271, 5.50, "Oetker Ristorante Pizza Funghi",   "",    "pizza" ],
	[ 8710001000288, 1.95, "Crème brûlée",                     "",    "snack" ],
	[ 8710001000295, 0.55, "Ola Raket",                        "",    "ice"   ],
	[ 8710001000301, 1.60, "Magnum Classic",                   "",    "ice"   ],
);

open my $pf, ">:encoding(UTF-8)", "$datadir/products" or die $!;
print $pf <<'END';
# Fictional products for testing. Not real prices.

+sb   0.15@+statiegeld  "Deposit can" #OPAQUE
+sf   0.15@+statiegeld  "Deposit bottle" #OPAQUE
+sm   0.15@+statiegeld  "Deposit Mehrwegpfand" #OPAQUE

END
for (@products) {
	my ($id, $price, $desc, $addon) = @$_;
	my $alias = $desc eq "Ola Raket" ? ";raket" : $desc eq "Tosti kaas" ? ";tosti" : "";
	printf $pf "%-22s %5.2f  \"%s\"%s\n", "$id$alias", $price, $desc, $addon ? " $addon" : "";
}
print $pf qq{\nreimburse-mate  -18.00\@-expenses/supplies  "Reimbursement krat Club-Mate"\n};
close $pf;

my @names = qw(
	ada bitflip c0ffee dikkie elmo fnord glitch hexa icepick juul kabouter
	lambda m0ntje nibbler octopus pixel quux rooibos sjaak tinkerbell uwe
	vortex wortel xor yuki zuurtje acid boris cronos dorus egel fiets gertje
	hacky ijzer jopie knor loempia marvin noppes olaf pieter qubit rakker
	snoepje tux ufo vlinder xantippe ziggy
);

# The year up to today.
my @today = localtime;
my $end   = timelocal(0, 0, 0, @today[3, 4, 5]);
my $days  = 365;
my $start = $end - $days * 86400;

my %user;
for my $i (0 .. $#names) {
	my @fav = (shuffle 0 .. $#products)[0 .. 2 + int rand 3];
	$user{ $names[$i] } = {
		joined   => $i < 35 ? 0 : int rand($days - 30),
		left     => rand() < 0.1 ? int($days / 2 + rand($days / 2)) : $days,
		activity => 0.2 + 3 * rand() ** 2,  # a few heavy users
		fav      => \@fav,
		balance  => 0,
	};
}

sub weekday_weight($wday) { (0.6, 0.8, 1.6, 0.9, 1.5, 1.0, 1.3)[$wday] }  # Sun..Sat

sub season_weight($kind, $month) {
	return (0.2, 0.2, 0.4, 0.7, 1.2, 1.8, 2.0, 2.0, 1.4, 0.7, 0.3, 0.2)[$month] if $kind eq "ice";
	return (1.6, 1.5, 1.3, 1.0, 0.8, 0.6, 0.5, 0.5, 0.8, 1.1, 1.4, 1.6)[$month] if $kind eq "pizza";
	return 1;
}

my @events;  # [ $epoch, $command, $user, \@cart ]
for my $name (@names) {
	my $u = $user{$name};
	my $join = $start + $u->{joined} * 86400 + 3600 * (19 + int rand 3);
	push @events, [ $join, "adduser $name" ];
	for my $day ($u->{joined} .. $u->{left} - 1) {
		my $t0 = $start + $day * 86400;
		my @lt = localtime $t0;
		next if rand() > 0.02 * $u->{activity} * weekday_weight($lt[6]);

		my $hour = (rand() < 0.75 ? 19 + int rand 5 : 13 + int rand 6);
		my $t = $t0 + 3600 * $hour + int rand 3600;
		$t = $join + 60 if $t <= $join;

		my @cart;
		for (1 .. (rand() < 0.25 ? 2 : 1)) {
			my $p;
			for (1 .. 10) {
				$p = rand() < 0.8 ? $u->{fav}[rand @{ $u->{fav} }] : int rand @products;
				last if rand() < season_weight($products[$p][4], $lt[4]) / 2;
			}
			my $qty = rand() < 0.15 ? 2 : 1;
			push @cart, ($products[$p][0]) x $qty;
		}
		push @events, [ $t, join(" ", @cart, $name), $name, \@cart ];
	}
}

# A few people reimbursed for buying supplies.
for (1 .. 6) {
	my $name = $names[rand 35];
	push @events, [ $start + int(rand $days) * 86400 + 3600 * 20, "reimburse-mate $name", $name, [] ];
}

@events = sort { $a->[0] <=> $b->[0] } @events;

my %price = map { $_->[0] => $_->[1] + ($_->[3] ? 0.15 : 0) } @products;

my ($n_sales, $n_undo) = (0, 0);
for my $e (@events) {
	my ($t, $command, $name, $cart) = @$e;
	if ($name and @$cart) {
		my $cost = sum map $price{$_}, @$cart;
		if ($user{$name}{balance} < $cost) {
			my $amount = (10, 20, 20, 50)[rand 4];
			run($t - 120, "deposit $amount; $name");
			$user{$name}{balance} += $amount;
		}
		$user{$name}{balance} -= $cost;
		$n_sales++;
	} elsif ($name) {
		$user{$name}{balance} += 18;
	}
	run($t, $command);

	if ($name and @$cart and rand() < 0.01) {
		run($t + 90, "undo " . last_tid() . q{ "wrong product" SKIP_CONFIRMATION});
		$user{$name}{balance} += sum map $price{$_}, @$cart;
		$n_undo++;
	}
}

# Rotated yearly, like at RevSpace.
my %by_year;
open my $log, "<", "$datadir/log" or die $!;
push @{ $by_year{ substr $_, 0, 4 } }, $_ while <$log>;
close $log;
my ($current, @old) = reverse sort keys %by_year;
for my $year ($current, @old) {
	open my $fh, ">", $year eq $current ? "$datadir/log" : "$datadir/log.$year" or die $!;
	print $fh @{ $by_year{$year} };
}

say "Events: " . @events . ", sales transactions: $n_sales, undone: $n_undo";
