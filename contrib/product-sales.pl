#!/usr/bin/env perl

=head1 NAME

product-sales.pl - Show sales of a product over time, from a RevBank log

=head1 SYNOPSIS

	perl contrib/product-sales.pl [options] <product>...

	perl contrib/product-sales.pl 4029764001807
	perl contrib/product-sales.pl --by week --from 2025-01 "Club-Mate, bottle 50 cl"
	perl contrib/product-sales.pl --regex --list mate
	perl contrib/product-sales.pl --regex --by weekday 'pizza|ristorante'

=head1 DESCRIPTION

This script reads the RevBank log and shows how many of one or more products
were sold per period, with the amount paid and a simple bar chart.

A product can be given by its id (barcode or alias) from the C<products> file,
or by (part of) its description. An argument that isn't an id matches every
description that contains all of its words, ignoring case and accents, so
C<lakrits> finds "Venco Lakritsdrop". Use quotes for multiple words, because
every argument is a separate product.

The log doesn't contain product ids, so ids are translated to the I<current>
description. If a description has changed, the sales with the old description
aren't found that way; use C<--list> and C<--regex> to find all variants.

Undone transactions are not counted, and neither are products with a negative
price, like reimbursements and bounties.

=head1 DISCLAIMER

This script was written by AI, and has only been tested to a limited extent:
against synthetic logs, and briefly on one real RevBank installation. Check the
numbers before relying on them.

=head1 OPTIONS

=over 4

=item --by <period>

One of C<day>, C<week> (ISO week), C<month> (the default), C<year>,
C<weekday> or C<hour>. The first four are chronological, and periods without
sales are shown too. The last two add up all sales per day of the week or hour
of the day.

=item --from <date>, --to <date>

Only use sales in this range, inclusive. A date can be partial: C<--to 2025>
includes all of 2025, C<--from 2025-03> starts on March 1st. Without these
options and C<--log>, the range is the last 12 months, including the current
one.

=item --regex, -r

Interpret the arguments as case insensitive regular expressions that are
matched against product descriptions.

=item --exact, -e

Only match descriptions that are exactly the same as an argument, ignoring
case and accents. Product ids still work.

=item --list, -l

Instead of periods, show totals per description. Without arguments, all
products are listed. Useful for finding the right description or regex.

=item --csv

Output CSV instead of a table.

=item --lines <number>

Show at most this many lines. If there are more periods, the earliest are left
out, but the totals are still for all of them. The C<sales> plugin uses 20, so
that it fits on an IBM 3151 under GNU screen, with the prompt.

=item --log <file>

Read this log file instead of the ones in C<REVBANK_DATADIR>: C<log>, and the
yearly rotated logs like C<log.2025> that are in the range. Can be given
multiple times. Files ending in C<.gz> are
decompressed, and C<-> reads from standard input.

=back

=head2 Caveats

Users are the number of different accounts that bought the product. Cash sales
and other special accounts are not counted as users.

The amount is what customers paid for the product, including addons such as
container deposits or discounts, but not including deposits that were returned
later.

In logs from before RevBank 3.4 (2022), products can't be told apart from other
cart entries with the same description, and C<--list> doesn't show them.

=cut

use v5.36;
use autodie;
use utf8;
use open qw(:std :encoding(UTF-8));

use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use Getopt::Long qw(GetOptions);
use List::Util qw(sum0 max);
use Pod::Usage qw(pod2usage);
use POSIX qw(strftime);
use Time::Local qw(timegm);
use Unicode::Normalize qw(NFD);

utf8::decode($_) for @ARGV;

my $by = "month";
my ($from, $to, $regex, $exact, $list, $csv, $max_lines, @logs);

GetOptions(
	"by|b=s"   => \$by,
	"from|f=s" => \$from,
	"to|t=s"   => \$to,
	"regex|r"  => \$regex,
	"exact|e"  => \$exact,
	"list|l"   => \$list,
	"csv"      => \$csv,
	"log=s"    => \@logs,
	"lines=i"  => \$max_lines,
	"help|h"   => sub { pod2usage(-verbose => 2) },
) or pod2usage(2);

my %periods = map { $_ => 1 } qw(day week month year weekday hour);
$periods{$by} or pod2usage("Unknown period '$by'.");
@ARGV or $list or pod2usage("No product given.");
$regex and $exact and pod2usage("Use either --regex or --exact.");

for ($from, $to) {
	defined or next;
	/^\d{4}(?:-\d\d(?:-\d\d)?)?$/ or pod2usage("Invalid date '$_', use YYYY-MM-DD.");
}

my $datadir = $ENV{REVBANK_DATADIR} || "$ENV{HOME}/.revbank";
my $today = strftime "%Y-%m-%d", localtime;

# The last 12 months, including the current one.
my $default_range = !@logs && !defined $from && !defined $to;
if ($default_range) {
	my ($y, $m) = split /-/, $today;
	($y, $m) = ($y - 1, $m + 12) if ($m -= 11) < 1;
	$from = sprintf "%04d-%02d-01", $y, $m;
}

if (not @logs) {
	# Rotated yearly, to log.2025 etc.
	@logs = (
		(sort grep {
			my ($year) = /\.(\d{4})$/;
			(not defined $from or $year >= substr $from, 0, 4)
			and (not defined $to or $year <= substr $to, 0, 4)
		} glob "$datadir/log.[0-9][0-9][0-9][0-9]"),
		"$datadir/log",
	);
}

# Case and accent insensitive, so "brulee" finds "Crème brûlée".
sub fold($text) {
	return NFD(fc $text) =~ s/\p{Mn}//gr;
}

my $match;  # sub($description)

if ($regex) {
	my $re = eval { qr/@{[ join "|", map "(?:$_)", @ARGV ]}/i }
		or pod2usage("Invalid regex: $@");
	$match = sub ($desc) { $desc =~ $re };
} elsif (@ARGV) {
	my %wanted;
	my %exact;  # folded descriptions
	my @words;  # per argument, all of them must occur
	my $products;
	for my $arg (@ARGV) {
		# Only needed for ids, and needs the datadir.
		$products //= do {
			require RevBank::Products;
			RevBank::Products::read_products();
		};

		if (my $product = $products->{$arg}) {
			$wanted{ $product->{description} } = 1;
		} elsif ($exact) {
			$exact{ fold($arg) } = 1;
		} else {
			push @words, [ split " ", fold($arg) ];
		}
	}
	$match = sub ($desc) {
		return 1 if $wanted{$desc};
		my $folded = fold $desc;
		return 1 if $exact{$folded};
		for my $words (@words) {
			return 1 if not grep { index($folded, $_) < 0 } @$words;
		}
		return 0;
	};
} else {
	$match = sub ($desc) { 1 };
}

# Sales are kept until the end, because an undo comes after its transaction.
my @sales;    # [ $tid, $date, $time, $description, $quantity, $cents, $old, $account ]
my %undone;   # transaction ids
my %bought;   # descriptions of products, per transaction id
my $old = 1;  # before RevBank 3.4, products had no contras

sub read_log($fn) {
	my $fh;
	if ($fn eq "-") {
		$fh = \*STDIN;
	} elsif ($fn =~ /\.gz$/) {
		open $fh, "-|", "gzip", "-dc", $fn;
	} else {
		open $fh, "<", $fn;
	}

	while (defined(my $line = readline $fh)) {
		my ($date, $time, $tid, $account, $dir, $qty, $amount, $desc) = $line =~ m[
			^(\d\d\d\d-\d\d-\d\d)_(\d\d:\d\d:\d\d)  # date_time
			(?>\@\S*)?             # terminal ID (optional)
			\s++ CHECKOUT
			\s++ (\S++)            # transaction id
			\s++ (\S++)            # account name
			\s++ (GAIN|LOSE|====)  # direction
			\s++ (\d++)            # quantity
			\s++ ([\d.]++)         # total amount (absolute)
			\s++ \#\s(.*)          # description
		]x or next;

		$desc =~ s/ \[\d+x [\d.]+\]$//;  # quantity and price, if not 1

		if ($account eq "-undo") {
			$undone{$1} = 1 if $desc =~ /^Undo (\S+)/;
			next;
		}

		# Contras of the products plugin, "$you bought ...", or of addons,
		# "Deposit ($you bought ...)", since RevBank 3.4.
		if ($desc =~ /^\S+ bought (.*)/) {
			$bought{$tid}{$1} = 1;
			$old = 0;
			$bought{$tid}{"$1 (sold by $2)"} = 1 if $1 =~ /^(.*) from (\S+)$/;  # market
			next;
		}
		next if $desc =~ /\(\S+ bought .*\)$/;
		next if $dir eq "GAIN";  # negative price: reimbursements, bounties

		next if defined $from and $date lt $from;
		next if defined $to and substr($date, 0, length $to) gt $to;
		next if not $match->($desc);

		my $cents = $amount =~ tr/.//dr;

		push @sales, [ $tid, $date, $time, $desc, $qty, 0 + $cents, $old, $account ];
	}
}

read_log($_) for @logs;

@sales = grep {
	my ($tid, $desc, $old) = @$_[0, 3, 6];
	not $undone{$tid}
	and (
		$bought{$tid} ? $bought{$tid}{$desc}
		# Without contras, only the description is known. Not for --list
		# without arguments, because that would include everything.
		: ($old and @ARGV)
	)
} @sales;

sub money($cents) {
	my $sign = $cents < 0 ? "-" : "";
	$cents = abs $cents;
	return sprintf "%s%d.%02d", $sign, int($cents / 100), $cents % 100;
}

sub epoch($date) {
	my ($y, $m, $d) = split /-/, $date;
	return timegm(0, 0, 12, $d, $m - 1, $y);
}

my @weekdays = qw(Mon Tue Wed Thu Fri Sat Sun);

sub period($date, $time) {
	return $date                        if $by eq "day";
	return substr $date, 0, 7           if $by eq "month";
	return substr $date, 0, 4           if $by eq "year";
	return substr $time, 0, 2           if $by eq "hour";
	return strftime "%G-W%V", gmtime epoch $date if $by eq "week";
	return $weekdays[ (strftime "%u", gmtime epoch $date) - 1 ];
}

my (@rows, %matched);  # [ $label, $quantity, $cents, \%users ]

# Not -cash and other special accounts, because it's unknown who they are.
sub user($account) {
	return $account =~ /^[-+*]/ ? () : $account;
}

if ($list) {
	my %by_desc;
	for (@sales) {
		my ($date, $desc, $qty, $cents, $account) = @$_[1, 3, 4, 5, 7];
		my $row = $by_desc{$desc} //= [ $desc, 0, 0, {} ];
		$row->[1] += $qty;
		$row->[2] += $cents;
		$row->[3]{$_} = 1 for user($account);
	}
	@rows = sort { $b->[1] <=> $a->[1] or $a->[0] cmp $b->[0] } values %by_desc;
} else {
	my %by_period;
	for (@sales) {
		my ($date, $time, $desc, $qty, $cents, $account) = @$_[1 .. 5, 7];
		my $row = $by_period{ period($date, $time) } //= [ period($date, $time), 0, 0, {} ];
		$row->[1] += $qty;
		$row->[2] += $cents;
		$row->[3]{$_} = 1 for user($account);
		$matched{$desc} += $qty;
	}

	my @labels;
	if ($by eq "hour") {
		@labels = map sprintf("%02d", $_), 0 .. 23;
	} elsif ($by eq "weekday") {
		@labels = @weekdays;
	} elsif (@sales) {
		my ($first, $last) = (sort map $_->[1], @sales)[0, -1];
		$first = $from if defined $from and length $from == 10;
		$last  = $to   if defined $to   and length $to   == 10;
		$last  = $today if $default_range;

		my %seen;
		for (my $t = epoch $first; $t <= epoch $last; $t += 86400) {
			my $label = period(strftime("%Y-%m-%d", gmtime $t), "00");
			push @labels, $label if not $seen{$label}++;
		}
	}
	@rows = map { $by_period{$_} // [ $_, 0, 0, {} ] } @labels;

	if ($by eq "hour") {
		shift @rows while @rows and not $rows[0][1];
		pop @rows while @rows and not $rows[-1][1];
	}
}

$_->[3] = keys %{ $_->[3] } for @rows;

if ($csv) {
	print $list ? "description" : $by, ",quantity,users,amount\n";
	for (@rows) {
		my ($label, $qty, $cents, $users) = @$_;
		$label = qq{"$label"} if $label =~ s/"/""/g or $label =~ /[,\n]/;
		say join ",", $label, $qty, $users, money($cents);
	}
	exit;
}

if (not @sales) {
	say "No sales found.";
	exit 1;
}

my $color = -t STDOUT && !exists $ENV{NO_COLOR};

sub sgr($code, $text) {
	return $color ? "\e[${code}m$text\e[0m" : $text;
}

# The end of a bar with an odd number of halves. "▌" shows as "?" on an IBM
# 3151, so it's a space until a better character is found. The lower half
# blocks, also used by revspace_qr, keep bars on adjacent lines apart.
my @halves = ("", " ");

sub bar($value, $max, $width) {
	return "" if $max <= 0 or $value <= 0;
	my $n = int(0.5 + 2 * $width * $value / $max);
	return "▄" x int($n / 2) . $halves[$n % 2];
}

my $total_qty = sum0 map $_->[1], @rows;
my $total_cents = sum0 map $_->[2], @rows;
my $total_users = keys %{{ map { $_ => 1 } map user($_->[7]), @sales }};
my ($first_date, $last_date) = (sort map $_->[1], @sales)[0, -1];

my $columns = $ENV{COLUMNS} || 80;

sub fit($text, $width = $columns - 4) {
	return length $text > $width ? substr($text, 0, $width - 1) . "~" : $text;
}

my @matched = sort { $matched{$b} <=> $matched{$a} or $a cmp $b } keys %matched;
my $title = $list ? "Products" : @matched == 1 ? $matched[0] : @matched . " products";

my @head = (
	sgr(1, fit $title),
	sgr(2, fit join ", ",
		($first_date eq $last_date ? $first_date : "$first_date - $last_date"),
		($list ? () : "per $by"),
		"$total_qty sold",
		"$total_users users",
		money($total_cents),
	),
);
if (@matched > 1) {
	# On one line, as many as fit.
	my $text;
	for my $n (reverse 1 .. @matched) {
		$text = join ", ", @matched[0 .. $n - 1];
		$text .= ", +" . (@matched - $n) . " more" if $n < @matched;
		last if length $text <= $columns - 4;
	}
	push @head, sgr(2, fit $text);
}

# Not per weekday or hour, which are not a timeline.
my $average = !$list && $by !~ /^(?:weekday|hour)$/ && @rows > 1 ? 1 : 0;

# The totals are still for all rows.
my @shown = @rows;
my $hidden = "";
if ($max_lines) {
	my $room = $max_lines - @head - 4 - $average;  # blank, header, line, total
	$room = 2 if $room < 2;
	if (@shown > $room) {
		my $n = @shown - ($room - 1);
		if ($list) {
			splice @shown, $room - 1;
			$hidden = "... $n more";
		} else {
			splice @shown, 0, $n;
			$hidden = "... $n earlier";
		}
	}
}

say "  $_" for @head;
say "";

my $width = max map length, "Average", map $_->[0], @rows;
$width = $columns - 42 if $width > $columns - 42;  # room for a bar of 10

my $bar_width = $columns - $width - 32;
$bar_width = 10 if $bar_width < 10;
$bar_width = 50 if $bar_width > 50;

my $max = max map $_->[1], @rows;
my $line = sub ($label, $qty, $users, $amount) {
	$label = substr($label, 0, $width - 1) . "~" if length $label > $width;
	return sprintf "  %-*s %7s %6s %10s", $width, $label, $qty, $users, $amount;
};

say sgr(2, $line->($list ? "product" : $by, "sold", "users", "amount"));
say sgr(2, "  $hidden") if length $hidden and not $list;
for (@shown) {
	my ($label, $qty, $cents, $users) = @$_;
	my $text = $line->($label, $qty, $users, money($cents));
	say $qty ? $text . "  " . sgr(36, bar($qty, $max, $bar_width)) : sgr(2, $text);
}
say sgr(2, "  $hidden") if length $hidden and $list;

say sgr(2, "  " . "─" x ($width + 26));
say sgr(1, $line->("Total", $total_qty, $total_users, money($total_cents)));
if ($average) {
	say $line->(
		"Average",
		sprintf("%.1f", $total_qty / @rows),
		sprintf("%.1f", (sum0 map $_->[3], @rows) / @rows),
		money(int $total_cents / @rows),
	);
}
say "" if not $max_lines;  # RevBank already adds space before its prompt
