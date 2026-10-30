#!/usr/bin/env perl
use strict;
use warnings;
use Time::HiRes qw(sleep);

$| = 1;

my $led_root = $ENV{QS_LOCK_LED_ROOT} // '/sys/class/leds';
my %previous;

sub lock_state {
    my ($key) = @_;
    my @paths = glob("$led_root/*::$key/brightness");
    return undef unless @paths;

    my $found = 0;
    my $active = 0;
    for my $path (@paths) {
        open my $file, '<', $path or next;
        my $value = <$file>;
        close $file;
        next unless defined $value;
        $found = 1;
        $active = 1 if $value > 0;
    }
    return $found ? $active : undef;
}

while (1) {
    for my $key (qw(capslock numlock)) {
        my $state = lock_state($key);
        next unless defined $state;
        if (exists $previous{$key} && $state != $previous{$key}) {
            print "$key $state\n";
        }
        $previous{$key} = $state;
    }
    sleep 0.15;
}
