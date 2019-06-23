#!/usr/bin/perl

use strict;
use warnings;

use lib 'lib/';

use Data::Dumper;
use Ham::APRS::IS;
use Ham::APRS::FAP qw(parseaprs);
use HTTP::Request;
use JSON::MaybeXS;
use LWP::UserAgent;
use YAML::XS qw(LoadFile);

my $PRECISION = "%.5f";

my $exit = 0;
$SIG{INT} = sub { $exit = 1 };

sub main {
    my $config = LoadFile('./aprsis-slack.conf');
    print Dumper($config);

    # TODO Improve connection handling to APRS-IS
    my $is = new Ham::APRS::IS(
        "$config->{aprsis}{dns}:$config->{aprsis}{port}", 'N0CALL',
        'appid'  => 'HB9ESX-APRS-TEST 0.3',
        'filter' => 'p/' . join( '/', @{ $config->{callsigns} } )
    );
    $is->connect( 'retryuntil' => 3 ) || die "Failed to connect: $is->{error}";
    if ( $is->connected() ) {
        print "APRS-IS connected\n";
    }

    for ( ; ; ) {
        last if ($exit);

        my $line = $is->getline_noncomment();
        next if ( !defined $line );

        my $packetdata = {};
        my $rv = parseaprs( $line, $packetdata );

        if ( $rv == 1 ) {
            if ( $packetdata->{type} eq 'location' ) {
                update_slack( $config->{slack}{webhook_url}, $packetdata );
                print Dumper($packetdata);
            }
        }
        else {
            warn "Parsing failed: $packetdata->{resultmsg} ($packetdata->{resultcode})\n";
        }
    }

    $is->disconnect() || die "Failed to disconnect: $is->{error}";
}

sub get_formatted_slack_message {
    my $data = shift;

    my $icon_lookup = {
        '/[' => ':runner:',
        '/b' => ':bike:',
        '/>' => ':car:',
        '/`' => ':satellite:',
        '/-' => ':house:',
        '/_' => ':cloud:',       # wx station
    };

    my $icon = "$data->{symboltable}$data->{symbolcode}";

    # my $emoji = " '$icon'";
    my $emoji = '';

    if ( exists $icon_lookup->{$icon} ) {
        $emoji = " $icon_lookup->{$icon}";
    }

    my $comment = '';
    if (   $data->{comment}
        && $data->{comment} =~ m/^[A-Za-z0-9\.,-_()\/{}\[\]@%=+ ]+$/ )
    {
        $data->{comment} =~ s/`//g;
        if ( $data->{comment} =~ m/>/ ) {
            $data->{comment} = substr( $data->{comment}, 1 );
        }
        $comment = " _$data->{comment}_";
    }

    return
        "*$data->{srccallsign}*$emoji$comment\n`"
      . sprintf( $PRECISION, $data->{latitude} ) . " N, "
      . sprintf( $PRECISION, $data->{longitude} )
      . " W`\nhttps://aprs.fi/$data->{srccallsign}";
}

sub update_slack {
    my $url  = shift;
    my $data = shift;

    my $message = { "text" => get_formatted_slack_message($data), };

    my $req = HTTP::Request->new( 'POST', $url );
    $req->header( 'Content-Type' => 'application/json' );
    $req->content( encode_json($message) );

    my $lwp = LWP::UserAgent->new();
    $lwp->request($req);

    return;
}

main();
