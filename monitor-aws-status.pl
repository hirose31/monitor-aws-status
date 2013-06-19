#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Getopt::Long qw(:config posix_default no_ignore_case no_ignore_case_always);
use Smart::Args;
use Log::Minimal;
use Carp;

use AnyEvent;
use AnyEvent::Feed;
use AnyEvent::HTTP;
use String::IRC;
use Furl;

my $BOOT_TIME = time;

my $Debug    = 0;
my $Interval = 300;

my $Ikachan_URL = 'http://127.0.0.1:4979';

my %Target_Region = (
    #"eu-west-1"      => "EU (Ireland)",
    #"sa-east-1"      => "South America (Sao Paulo)",
    "us-east-1"      => "US East (Northern Virginia)",
    "ap-northeast-1" => "Asia Pacific (Tokyo)",
    #"us-west-2"      => "US West (Oregon)",
    "us-west-1"      => "US West (Northern California)",
    #"ap-southeast-1" => "Asia Pacific (Singapore)",
    #"ap-southeast-2" => "Asia Pacific (Sydney)",
);

my %Ignore_Service = map {$_=>1} qw(fps);

my $_UA;
sub ua() {
    $_UA ||= Furl->new( timeout => 5 );
    return $_UA;
}

MAIN: {
    my %arg;
    GetOptions(
        \%arg,
        'interval|i=i',
        'debug|d+' => \$Debug,
        'help|h|?' => sub { die "usage" }) or die "usage";
    $ENV{LM_DEBUG} = 1 if $Debug;

    $Interval = $arg{interval} if exists $arg{interval};

    my $target_feeds = load_config();
    my @feed_readers;

    for my $target (@{ $target_feeds }) {
        push @feed_readers,
            AnyEvent::Feed->new (
                url      => $target->{url},
                interval => $Interval,

                on_fetch => sub {
                    my ($feed_reader, $new_entries, $feed, $error) = @_;
                    debugf("on fetch: $target->{url}");

                    if (defined $error) {
                        critf("ERROR: %s", $error);
                        return;
                    }

                    $target->{process}->($new_entries, $target->{opt});
                }
            );
    }

    AE::cv->recv;

    exit 0;
}

sub load_config {
    return [
        {
            name    => 'aws-status',
            url     => 'http://status.aws.amazon.com/rss/all.rss',
            process => \&process_aws_status,
            opt => {
                channel => '#aws-status', # change as you like
            },
        },
    ];
}

sub post_irc {
    args(
        my $channel  => { isa => 'Str' },
        my $messages => { isa => 'ArrayRef[Str]' },
        my $type     => { isa => 'Str' }, # notice or privmsg
    );
    $type = 'notice' unless $type =~ /^(notice|privmsg)$/;

    # $channel = '#hirose31' if $Debug;

    for my $message (@$messages) {
        debugf("POST to %s, %s", $channel, $message);

        utf8::encode($message);

        ua->post(
            "${Ikachan_URL}/${type}",
            [],
            [
                channel => $channel,
                message => $message,
            ],
        );
    }
}

sub process_aws_status {
    my($entries, $opt) = @_;

    for (@$entries) {
        # entry is XML::Feed::Entry object
        my ($hash, $entry) = @$_;

        # skip old entries
        if ($entry->issued->epoch < $BOOT_TIME) {
            infof("skip %s, because issued < BOOT_TIME (%d < %d)",
                  $entry->title,
                  $entry->issued->epoch,
                  $BOOT_TIME,
              );
            next;
        }

        my $title = $entry->title;
        my $description = $entry->content->body;
        $description =~ s/[\r\n]/ /g;

        my($sv_reg) = $entry->id =~ /#(.+)$/; # <guid>
        $sv_reg =~ s/_[0-9]+$//;
        my($service, $region) = split /-/, $sv_reg, 2;
        $region ||= 'ALL';

        # issued is DateTime object
        my $dt = $entry->issued;
        # convert to JST
        $dt->set_time_zone('Asia/Tokyo');

        my $status = $title =~ /resolved/i ? 'RECOVER' : 'PROBLEM';
        my $status_color = $status eq 'RECOVER' ? 'green' : 'red';

        infof("[%s] %s on %s at %s (%s)\n  %s\n  %s\n\n",
               $status,
               $service, $region, $dt->iso8601, $dt->time_zone_short_name,
               $title,
               $description,
           );

        if (!$Target_Region{ $region } && $region ne 'ALL') {
            next;
        }
        if (exists $Ignore_Service{$service}) {
            next;
        }

        my @messages;
        push @messages, sprintf("%s [%s] on %s, %s at %s (%s)",
                                String::IRC->new($status)->$status_color,
                                String::IRC->new($service)->bold, $region,
                                String::IRC->new($title)->bold,
                                $dt->iso8601, $dt->time_zone_short_name,
                            );
        push @messages, sprintf("%s, <%s>",
                                $description,
                                $entry->link,
                            );

        post_irc(
            channel  => $opt->{channel},
            messages => \@messages,
            type     => 'notice',
        );
    }
}

__END__

# for Emacsen
# Local Variables:
# mode: cperl
# cperl-indent-level: 4
# cperl-close-paren-offset: -4
# cperl-indent-parens-as-block: t
# indent-tabs-mode: nil
# coding: utf-8
# End:

# vi: set ts=4 sw=4 sts=0 et ft=perl fenc=utf-8 ff=unix :

