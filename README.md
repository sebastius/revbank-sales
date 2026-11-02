# revbank-sales

Sales of a product over time, from the log of a [RevBank](https://codeberg.org/revspace/revbank)
installation: per month (or day, week, year, weekday, hour), with the number
of items sold, unique users, the amount, and a bar chart.

Example, from a synthetic log with three users:

```
  Katja Apekoppen
  2026-01-01 - 2026-09-29, per month, 260 sold, 3 users, 182.00

  month      sold  users     amount
  2025-12       0      0       0.00
  2026-01      29      3      20.30  ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
  2026-02      40      3      28.00  ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
  2026-03      21      3      14.70  ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
  ...
```

> **Disclaimer:** this code was written by AI, and has only been tested to a
> limited extent: against synthetic logs, and briefly on one real RevBank
> installation. Check the numbers before relying on them.

## Contents

- `contrib/product-sales.pl`: command line tool. See `perldoc contrib/product-sales.pl`
  or `--help` for all options.
- `plugins/sales`: RevBank plugin that adds the command `sales <product>`. It
  runs the command line tool, with output that fits on an 80x24 terminal.

## Installation

Copy both files into the RevBank directory, at the same paths, and add the
plugin to the `plugins` file in the data directory:

```
cp plugins/sales /path/to/revbank/plugins/
cp contrib/product-sales.pl /path/to/revbank/contrib/
echo sales >> ~/.revbank/plugins
```

Then type `restart` in RevBank.

## Usage

In RevBank:

```
sales 4029764001807
sales "Coca-Cola Zero"
```

The product is a product id from the `products` file, or a description, which
must match exactly (ignoring case and accents).

On the command line:

```
perl contrib/product-sales.pl lakrits
perl contrib/product-sales.pl --by week --from 2025-01 "Club-Mate"
perl contrib/product-sales.pl --exact "Coca-Cola Zero"
perl contrib/product-sales.pl --regex --list mate
perl contrib/product-sales.pl --csv --by day pizza > pizza.csv
```

Without `--exact` or `--regex`, a product matches every description that
contains all of the words, so quote multiple words.

By default, the last 12 months are shown, from `log` and yearly rotated logs
like `log.2025`.

## Requirements

- RevBank with Perl 5.36 or newer.
- Looking up products by id needs RevBank 8.0.0 or newer (`lib/RevBank/Products.pm`).
  Descriptions work with older versions too.
- Products can only be told apart from other entries in logs from RevBank 3.4
  (2022) or newer.

## License

Like RevBank: see `LICENSE`.
