#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use Encode qw(decode);
use JSON::PP;
use Time::Local qw(timegm);

my $base_dir = $0;
$base_dir =~ s{/[^/]+$}{};
my $url_file = "$base_dir/google-calendar.url";

sub result {
    my ($payload) = @_;
    print JSON::PP->new->utf8->canonical->encode($payload);
    exit 0;
}

result({ configured => JSON::PP::false, events => [] }) unless -s $url_file;

open my $url_fh, '<', $url_file or result({ configured => JSON::PP::false, events => [] });
my $url = <$url_fh> // '';
close $url_fh;
$url =~ s/^\s+|\s+$//g;
result({ configured => JSON::PP::false, events => [] }) unless $url =~ m{^https://};

open my $curl, '-|', 'curl', '--fail', '--silent', '--show-error', '--location',
    '--max-time', '15', $url
    or result({ configured => JSON::PP::true, events => [], error => 'Could not start calendar download' });
local $/;
my $ics = <$curl> // '';
close $curl;
result({ configured => JSON::PP::true, events => [], error => 'Could not download calendar' })
    if $? != 0 || $ics eq '';

$ics = decode('UTF-8', $ics);
$ics =~ s/\r//g;
$ics =~ s/\n[ \t]//g;

sub unescape_text {
    my ($value) = @_;
    $value =~ s/\\[nN]/ /g;
    $value =~ s/\\,/,/g;
    $value =~ s/\\;/;/g;
    $value =~ s/\\\\/\\/g;
    return $value;
}

sub ordinal {
    my ($year, $month, $day) = @_;
    return int(timegm(0, 0, 12, $day, $month - 1, $year) / 86400);
}

sub date_from_ordinal {
    my ($value) = @_;
    my @parts = gmtime($value * 86400);
    return ($parts[5] + 1900, $parts[4] + 1, $parts[3]);
}

sub date_key {
    return sprintf('%04d-%02d-%02d', @_);
}

sub parse_date_value {
    my ($value) = @_;
    return unless defined $value;
    if ($value =~ /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2}))?Z?$/) {
        my ($year, $month, $day, $hour, $minute) = ($1, $2, $3, $4, $5);
        my $all_day = !defined $hour;
        return {
            year => 0 + $year,
            month => 0 + $month,
            day => 0 + $day,
            ordinal => ordinal($year, $month, $day),
            time => $all_day ? 'All day' : sprintf('%02d:%02d', $hour, $minute),
            all_day => $all_day
        };
    }
    return;
}

my @raw_events;
my $current;
for my $line (split /\n/, $ics) {
    if ($line eq 'BEGIN:VEVENT') {
        $current = {};
        next;
    }
    if ($line eq 'END:VEVENT') {
        push @raw_events, $current if $current;
        $current = undef;
        next;
    }
    next unless $current && $line =~ /^([^:]+):(.*)$/;
    my ($left, $value) = ($1, $2);
    my ($name) = split /;/, $left;
    $name = uc $name;
    push @{ $current->{$name} }, $value;
}

my @now = localtime;
my $year = $now[5] + 1900;
my $month = $now[4] + 1;
my $window_start = ordinal($year, $month, 1);
my ($next_year, $next_month) = $month == 12 ? ($year + 1, 1) : ($year, $month + 1);
my $window_end = ordinal($next_year, $next_month, 1) - 1;

my %weekday_number = (SU => 0, MO => 1, TU => 2, WE => 3, TH => 4, FR => 5, SA => 6);
my %output;

EVENT:
for my $event (@raw_events) {
    next if (($event->{STATUS} // [])->[0] // '') eq 'CANCELLED';
    my $start = parse_date_value(($event->{DTSTART} // [])->[0]);
    next unless $start;

    my $summary = unescape_text(($event->{SUMMARY} // ['Untitled'])->[0]);
    my $uid = ($event->{UID} // [$summary])->[0];
    my %excluded;
    for my $raw (@{ $event->{EXDATE} // [] }) {
        for my $value (split /,/, $raw) {
            my $date = parse_date_value($value);
            $excluded{date_key($date->{year}, $date->{month}, $date->{day})} = 1 if $date;
        }
    }

    my $rrule_raw = ($event->{RRULE} // [])->[0];
    my @occurrences;
    if (!$rrule_raw) {
        push @occurrences, $start->{ordinal}
            if $start->{ordinal} >= $window_start && $start->{ordinal} <= $window_end;
    } else {
        my %rule = map { split /=/, $_, 2 } split /;/, $rrule_raw;
        my $frequency = $rule{FREQ} // '';
        my $interval = $rule{INTERVAL} || 1;
        my $until = parse_date_value($rule{UNTIL});
        my $last_day = $window_end;
        $last_day = $until->{ordinal} if $until && $until->{ordinal} < $last_day;
        my $maximum_count = $rule{COUNT} || 0;
        my %byday = map { $weekday_number{$_} => 1 } grep { exists $weekday_number{$_} } split /,/, ($rule{BYDAY} // '');
        my %bymonthday = map { 0 + $_ => 1 } split /,/, ($rule{BYMONTHDAY} // '');
        my %bymonth = map { 0 + $_ => 1 } split /,/, ($rule{BYMONTH} // '');
        my $start_weekday = (gmtime($start->{ordinal} * 86400))[6];
        $byday{$start_weekday} = 1 if $frequency eq 'WEEKLY' && !%byday;
        $bymonthday{$start->{day}} = 1 if $frequency eq 'MONTHLY' && !%bymonthday;
        my $week_anchor = $start->{ordinal} - (($start_weekday + 6) % 7);
        my $seen = 0;

        for (my $day_ordinal = $start->{ordinal}; $day_ordinal <= $last_day; ++$day_ordinal) {
            my ($candidate_year, $candidate_month, $candidate_day) = date_from_ordinal($day_ordinal);
            my $weekday = (gmtime($day_ordinal * 86400))[6];
            my $matches = 0;

            if ($frequency eq 'DAILY') {
                $matches = (($day_ordinal - $start->{ordinal}) % $interval) == 0;
            } elsif ($frequency eq 'WEEKLY') {
                my $weeks = int(($day_ordinal - $week_anchor) / 7);
                $matches = ($weeks % $interval) == 0 && $byday{$weekday};
            } elsif ($frequency eq 'MONTHLY') {
                my $months = ($candidate_year - $start->{year}) * 12 + $candidate_month - $start->{month};
                $matches = ($months % $interval) == 0 && $bymonthday{$candidate_day};
            } elsif ($frequency eq 'YEARLY') {
                my $years = $candidate_year - $start->{year};
                my $month_ok = %bymonth ? $bymonth{$candidate_month} : $candidate_month == $start->{month};
                $matches = ($years % $interval) == 0 && $month_ok && $candidate_day == $start->{day};
            }

            next unless $matches;
            ++$seen;
            last if $maximum_count && $seen > $maximum_count;
            push @occurrences, $day_ordinal if $day_ordinal >= $window_start;
        }
    }

    for my $day_ordinal (@occurrences) {
        my ($event_year, $event_month, $event_day) = date_from_ordinal($day_ordinal);
        my $key = date_key($event_year, $event_month, $event_day);
        next if $excluded{$key};
        $output{"$uid|$key"} = {
            date => $key,
            title => $summary,
            time => $start->{time},
            allDay => $start->{all_day} ? JSON::PP::true : JSON::PP::false
        };
    }
}

my @events = sort {
    $a->{date} cmp $b->{date}
        || $a->{allDay} <=> $b->{allDay}
        || $a->{time} cmp $b->{time}
} values %output;

result({ configured => JSON::PP::true, events => \@events });
