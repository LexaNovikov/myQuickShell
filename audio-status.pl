#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use JSON::PP;

sub command_output {
    my (@command) = @_;
    my $pid = open my $handle, '-|';
    return '' unless defined $pid;
    if ($pid == 0) {
        open STDERR, '>', '/dev/null';
        exec @command;
        exit 127;
    }
    local $/;
    my $output = <$handle> // '';
    close $handle;
    return $? == 0 ? $output : '';
}

sub decode_list {
    my (@command) = @_;
    my $raw = command_output(@command);
    return [] if $raw eq '';
    my $decoded = eval { JSON::PP->new->utf8->decode($raw) };
    return ref $decoded eq 'ARRAY' ? $decoded : [];
}

sub average_volume {
    my ($entry) = @_;
    my $channels = $entry->{volume};
    return 0 unless ref $channels eq 'HASH';
    my ($sum, $count) = (0, 0);
    for my $channel (values %$channels) {
        next unless ref $channel eq 'HASH';
        my $percent = $channel->{value_percent} // '';
        next unless $percent =~ /([\d.]+)%/;
        $sum += $1;
        ++$count;
    }
    return $count ? int($sum / $count + 0.5) : 0;
}

sub display_name {
    my ($entry, $fallback) = @_;
    my $properties = $entry->{properties} // {};
    return $properties->{'device.description'}
        // $properties->{'node.description'}
        // $entry->{description}
        // $fallback;
}

my $default_sink = command_output('pactl', 'get-default-sink');
my $default_source = command_output('pactl', 'get-default-source');
$default_sink =~ s/\s+$//;
$default_source =~ s/\s+$//;

my $sinks = decode_list('pactl', '--format=json', 'list', 'sinks');
my $sources = decode_list('pactl', '--format=json', 'list', 'sources');
my $inputs = decode_list('pactl', '--format=json', 'list', 'sink-inputs');

my $sink = (grep { ($_->{name} // '') eq $default_sink } @$sinks)[0] // $sinks->[0];
my $source = (grep { ($_->{name} // '') eq $default_source } @$sources)[0] // $sources->[0];

my @apps;
for my $input (@$inputs) {
    my $properties = $input->{properties} // {};
    my $name = $properties->{'application.name'}
        // $properties->{'media.name'}
        // 'Application';
    push @apps, {
        id => 0 + ($input->{index} // 0),
        name => $name,
        icon => $properties->{'application.icon_name'} // 'application-x-executable',
        volume => average_volume($input)
    };
}

@apps = sort { lc($a->{name}) cmp lc($b->{name}) } @apps;
splice @apps, 3 if @apps > 3;

my $payload = {
    output => {
        name => $sink ? display_name($sink, 'Default output') : 'No output',
        volume => $sink ? average_volume($sink) : 0
    },
    input => {
        name => $source ? display_name($source, 'Default microphone') : 'No microphone',
        volume => $source ? average_volume($source) : 0
    },
    apps => \@apps
};

print JSON::PP->new->utf8->canonical->encode($payload);
