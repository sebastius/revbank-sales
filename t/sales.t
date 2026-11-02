use v5.36;
use Test2::V0;

# Transactions are made by RevBank itself, at chosen times, so the log is a
# real one. Needs a RevBank checkout: ../revbank, or REVBANK_DIR.

use Cwd qw(realpath);
use File::Temp ();
use FindBin;
use Time::Local qw(timelocal);

my ($repo, $revbank);
BEGIN {
	$repo = realpath("$FindBin::RealBin/..");
	$revbank = realpath($ENV{REVBANK_DIR} // "$repo/../revbank");
	skip_all("No RevBank in ../revbank; set REVBANK_DIR")
		if not $revbank or not -e "$revbank/lib/RevBank/Shell.pm";

	# Where RevBank finds its plugins and default data.
	$FindBin::RealBin = $revbank;
}
use lib "$revbank/lib", "$repo/dev";
use FakeTime;

use RevBank::Global;
use RevBank::Plugins;
use RevBank::Shell;

my $tmpdir = File::Temp->newdir;
$ENV{REVBANK_DATADIR} = $tmpdir->dirname;
RevBank::FileIO::populate_datadir;

spurt "products", <<'END';
+sb  0.15@+statiegeld  "Deposit can" #OPAQUE
cola;zero  0.90  "Coca-Cola Zero" +sb
cherry     0.95  "Coca-Cola Zero Cherry" +sb
creme      1.95  "Crème brûlée"
venco      0.80  "Venco Lakritsdrop"
pizza      4.50  "AH Pizza Salami"
reimburse  -18.00@-expenses/supplies  "Reimbursement Coca-Cola Zero crate"
END
spurt "market", "noot taart 2.50 0.50 Zelfgebakken taart\n";

$ENV{REVBANK_PLUGINS} = join " ",
	qw(log products market undo deposit adduser users deduplicate),
	"$repo/plugins/sales";
$ENV{REVBANK_PLUGINDIR} = "$revbank/plugins";
RevBank::Plugins::load;
open STDOUT, ">", "/dev/null";

# The 15th of the month $n months ago, or the 1st of the current month, which
# is never in the future.
sub months_ago($n) {
	my ($m, $y) = (localtime)[4, 5];
	$m -= $n;
	($m, $y) = ($m + 12, $y - 1) while $m < 0;
	return timelocal(0, 0, 20, $n ? 15 : 1, $m, $y + 1900);
}

sub month($t) {
	my ($m, $y) = (localtime $t)[4, 5];
	return sprintf "%04d-%02d", $y + 1900, $m + 1;
}

sub at($t, $command) {
	local $ENV{FAKE_TIME} = $t;
	RevBank::Shell::exec($command) or die "Failed: $command\n";
}

sub last_tid() {
	my ($tid) = map / END (\S+)/, reverse slurp "log";
	return $tid;
}

at months_ago(14), "adduser aap; adduser noot; adduser mies";
at months_ago(14), "deposit 100; aap";
at months_ago(14), "deposit 100; noot";
at months_ago(14), "deposit 100; mies";

at months_ago(13), "cola aap";                      # outside the default range
at months_ago(11), "cola cola noot";                # quantity 2
at months_ago(2),  "cola aap";
at months_ago(2),  "cherry mies";
at months_ago(2),  "creme aap";
at months_ago(2),  "venco noot";
at months_ago(2),  "pizza aap";
at months_ago(2),  "taart aap";
at months_ago(1),  "cola mies";
at months_ago(1) + 60, "undo " . last_tid() . ' "wrong product" SKIP_CONFIRMATION';
at months_ago(1),  "reimburse noot";
at months_ago(0),  "cola mies";

# Rotated yearly, like at RevSpace.
{
	my %by_year;
	push @{ $by_year{ substr $_, 0, 4 } }, $_ for slurp "log";
	my ($current, @old) = reverse sort keys %by_year;
	spurt "log.$_", @{ $by_year{$_} } for @old;
	spurt "log", @{ $by_year{$current} };
}

# Output and errors.
sub script(@args) {
	local $ENV{NO_COLOR} = 1;
	local $ENV{COLUMNS};
	my $pid = open(my $fh, "-|") // die $!;
	if (not $pid) {
		open STDERR, ">&", \*STDOUT;
		exec $^X, "-I", "$revbank/lib", "$repo/contrib/product-sales.pl", @args;
	}
	binmode $fh, ":encoding(UTF-8)";
	my $out = do { local $/; readline $fh };
	close $fh;
	return $out;
}

# "Total" line: sold, users, amount
sub totals($out) {
	my ($sold, $users, $amount) = $out =~ /^  Total\s+(\d+)\s+(\d+)\s+(-?\d+\.\d\d)$/m
		or return undef;
	return [ $sold, $users, $amount ];
}

sub title($out) { ($out =~ /\A\s*(.*)/)[0] }

sub row($out, $label) {
	my ($sold, $users, $amount) = $out =~ /^  \Q$label\E\s+(\d+)\s+(\d+)\s+(-?\d+\.\d\d)/m
		or return undef;
	return [ $sold, $users, $amount ];
}

subtest "default range: the last 12 months" => sub {
	my $out = script("--exact", "Coca-Cola Zero");
	is title($out), "Coca-Cola Zero";
	is totals($out), [ 4, 3, "4.20" ], "not 13 months ago, not undone, with deposits";
	is row($out, month months_ago(11)), [ 2, 1, "2.10" ], "quantity 2, from log.YYYY";
	is row($out, month months_ago(1)), [ 0, 0, "0.00" ], "undone";
	is row($out, month months_ago(0)), [ 1, 1, "1.05" ], "current month";
	is scalar(() = $out =~ /^  \d{4}-\d\d /mg), 12, "12 months";
};

subtest "--from includes older logs" => sub {
	my $out = script("--exact", "--from", month(months_ago(13)), "Coca-Cola Zero");
	is totals($out), [ 5, 3, "5.25" ];
};

subtest "product ids and aliases" => sub {
	is title(script("cola")), "Coca-Cola Zero", "id";
	is title(script("coca")), "2 products", "not an id: fuzzy";
	is title(script("zero")), "Coca-Cola Zero", "alias";
	is title(script("--exact", "cherry")), "Coca-Cola Zero Cherry", "id with --exact";
};

subtest "fuzzy" => sub {
	is title(script("zero cherry")), "Coca-Cola Zero Cherry";
	is title(script("CHERRY ZERO")), "Coca-Cola Zero Cherry", "any order and case";
	is title(script("brulee")), "Crème brûlée", "accents";
	like script("zero", "venco"), qr/^  2 products$/m, "arguments are added";
};

subtest "exact" => sub {
	is title(script("--exact", "coca-cola zero")), "Coca-Cola Zero", "ignores case";
	is title(script("--exact", "creme brulee")), "Crème brûlée", "ignores accents";
	is title(script("--exact", "Coca")), "No sales found.";
	is title(script("--exact", "*zero*")), "2 products", "*";
	is title(script("--exact", "?enco lakritsdrop")), "Venco Lakritsdrop", "?";
	is title(script("--exact", "*lakrits")), "No sales found.", "* matches the whole description";
};

subtest "regex" => sub {
	is title(script("--regex", "^ah ")), "AH Pizza Salami";
	like script("--regex", "x("), qr/Invalid regex/;
};

subtest "not counted" => sub {
	like script("--regex", "reimburse"), qr/No sales found/, "negative price";
	my $list = script("--list");
	unlike $list, qr/Deposit can|Undo|deposit/i, "contras, undo and deposits";
	like $list, qr/^  Zelfgebakken taart \(sold by noot\)\s+1\s+1\s+3\.00/m, "market";
};

subtest "users" => sub {
	is totals(script("--list"))->[1], 3, "unique over all products";
	is row(script("--exact", "Coca-Cola Zero"), month months_ago(2)), [ 1, 1, "1.05" ];
};

subtest "csv" => sub {
	my @lines = split /\n/, script("--csv", "--exact", "Coca-Cola Zero");
	is $lines[0], "month,quantity,users,amount";
	is scalar @lines, 13;
	like script("--csv", "--list"), qr/^"Coca-Cola Zero",|^Coca-Cola Zero,/m;
};

subtest "fits in 80 columns and --lines" => sub {
	for my $args (
		[ "--list" ], [ "--by", "day", "-r", "." ], [ "--by", "week", "-r", "." ],
		[ "--by", "hour", "-r", "." ], [ "--by", "weekday", "-r", "." ],
		[ "-r", "." ], [ "--exact", "Coca-Cola Zero" ],
	) {
		my $out = script("--lines", 20, @$args);
		my @lines = split /\n/, $out;
		ok @lines <= 20, "@$args: at most 20 lines";
		ok !(grep length > 78, @lines), "@$args: at most 78 columns";
	}
	my $out = script("--lines", 20, "--by", "day", "--from", month(months_ago(13)), "-r", ".");
	like $out, qr/^  \.\.\. \d+ earlier$/m, "left out";
	is totals($out)->[0], 10, "totals are for everything";
};

subtest "old logs, before RevBank 3.4" => sub {
	spurt "old.log", <<'END';
2021-05-01_12:00:00 CHECKOUT 20210501120000 aap          LOSE   1   1.40  # Club-Mate
2021-05-01_12:00:00 CHECKOUT 20210501120000 aap          LOSE   1   0.70  # Katja
2021-05-02_12:00:00 BEGIN 1 aap
2021-05-02_12:00:00 CHECKOUT 1 aap          LOSE   1   1.40  # Club-Mate
2021-05-02_12:00:00 CHECKOUT 1 +sales/products GAIN   1   1.40  # aap bought Club-Mate
2021-05-02_12:00:00 END 1
2021-05-03_12:00:00 BEGIN 2 aap
2021-05-03_12:00:00 CHECKOUT 2 aap          GAIN   1   0.15  # Deposit (Club-Mate)
2021-05-03_12:00:00 CHECKOUT 2 +statiegeld  LOSE   1   0.15  # Deposit (Club-Mate) for aap
2021-05-03_12:00:00 END 2
END
	is totals(script("--log", "$ENV{REVBANK_DATADIR}/old.log", "club-mate")), [ 2, 1, "2.80" ],
		"old format counted, a returned deposit isn't";
	is totals(script("--log", "$ENV{REVBANK_DATADIR}/old.log", "--exact", "Katja")), [ 1, 1, "0.70" ],
		"several products in one old transaction";
};

sub sales($input) {
	open my $stdout, ">&", \*STDOUT or die $!;
	open STDOUT, ">", "$ENV{REVBANK_DATADIR}/plugin-output" or die $!;
	my $ok = RevBank::Shell::exec("sales $input");
	STDOUT->flush;
	open STDOUT, ">&", $stdout or die $!;
	return $ok, scalar slurp "plugin-output";
}

subtest "plugin" => sub {
	my ($ok, $out) = sales("zero");
	ok $ok;
	is title($out), "Coca-Cola Zero";
	ok +(split /\n/, $out) <= 20, "at most 20 lines";

	is title((sales '"coca-cola zero"')[1]), "Coca-Cola Zero", "always exact";
	is title((sales "*zero*")[1]), "2 products", "wildcards";
	is title((sales "--csv")[1]), "No sales found.", "not an option";
	ok !RevBank::Shell::exec("sales"), "needs a product";
};

done_testing;
