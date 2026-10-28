#!/usr/bin/env perl

use strict;
use warnings;
use Time::HiRes qw(sleep);

$| = 1;

my ($device) = grep { -f "$_/brightness" && -f "$_/max_brightness" }
    glob '/sys/class/backlight/*';
exit 0 unless defined $device;

sub read_number {
    my ($path) = @_;
    open my $handle, '<', $path or return;
    my $value = <$handle>;
    close $handle;
    return unless defined $value;
    $value =~ s/\s+//g;
    return $value =~ /^\d+$/ ? 0 + $value : undef;
}

my $maximum = read_number("$device/max_brightness");
exit 0 unless defined $maximum && $maximum > 0;

my $last = -1;
while (1) {
    my $current = read_number("$device/brightness");
    if (defined $current) {
        my $percent = int($current * 100 / $maximum + 0.5);
        if ($percent != $last) {
            print "$percent\n";
            $last = $percent;
        }
    }
    sleep 0.25;
}
