#!/usr/bin/perl

# Copyright 2000-2002 Katipo Communications
# Copyright 2010 BibLibre
# Copyright 2014 ByWater Solutions
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.


=head1 moremember.pl

 script to do a borrower enquiry/bring up patron details etc
 Displays all the details about a patron

=cut

use Modern::Perl;
use CGI qw ( -utf8 );
use C4::Context;
use C4::Auth;
use C4::Output;
use C4::Members::AttributeTypes;
use C4::Form::MessagingPreferences;
use List::MoreUtils qw/uniq/;
use C4::Members::Attributes qw(GetBorrowerAttributes);
use Koha::Patron::Debarments qw(GetDebarments);
use Koha::Patron::Messages;
use Koha::DateUtils;
use Koha::CsvProfiles;
use Koha::Patrons;
use Koha::Token;
use Koha::Checkouts;

use vars qw($debug);

BEGIN {
    $debug = $ENV{DEBUG} || 0;
}

my $input = CGI->new;
$debug or $debug = $input->param('debug') || 0;


my $print = $input->param('print');

my $template_name;

if (defined $print and $print eq "brief") {
        $template_name = "members/moremember-brief.tt";
} else {
        $template_name = "members/moremember.tt";
}

my ( $template, $loggedinuser, $cookie ) = get_template_and_user(
    {
        template_name   => $template_name,
        query           => $input,
        type            => "intranet",
        authnotrequired => 0,
        flagsrequired   => { borrowers => 'edit_borrowers' },
        debug           => 1,
    }
);
my $borrowernumber = $input->param('borrowernumber');
my $error = $input->param('error');
$template->param( error => $error ) if ( $error );

my $patron         = Koha::Patrons->find( $borrowernumber );
my $logged_in_user = Koha::Patrons->find( $loggedinuser ) or die "Not logged in";
output_and_exit_if_error( $input, $cookie, $template, { module => 'members', logged_in_user => $logged_in_user, current_patron => $patron } );

my $category_type = $patron->category->category_type;

for (qw(gonenoaddress lost borrowernotes is_debarred)) {
    $patron->$_ and $template->param(flagged => 1) and last;
}

if ( $patron->is_debarred ) {
    $template->param(
        debarments => scalar GetDebarments({ borrowernumber => $borrowernumber }),
    );
    if ( $patron->debarred ne "9999-12-31" ) {
        $template->param( 'userdebarreddate' => $patron->debarred );
    }
}

my @relatives;
if ( my $guarantor = $patron->guarantor ) {
    $template->param( guarantor => $guarantor );
    push @relatives, $guarantor->borrowernumber;
    push @relatives, $_->borrowernumber for $patron->siblings;
} elsif ( $patron->contactname || $patron->contactfirstname ) {
    $template->param(
        guarantor => {
            firstname => $patron->contactfirstname,
            surname   => $patron->contactname,
        }
    );
} else {
    my @guarantees = $patron->guarantees;
    $template->param( guarantees => \@guarantees );
    push @relatives, $_->borrowernumber for @guarantees;
}

my $relatives_issues_count =
    Koha::Checkouts->count({ borrowernumber => \@relatives });

# Generate CSRF token for upload and delete image buttons
$template->param(
    csrf_token => Koha::Token->new->generate_csrf({ session_id => $input->cookie('CGISESSID'),}),
);

if (C4::Context->preference('ExtendedPatronAttributes')) {
    my $attributes = C4::Members::Attributes::GetBorrowerAttributes($borrowernumber);
    my @classes = uniq( map {$_->{class}} @$attributes );
    @classes = sort @classes;

    my @attributes_loop;
    for my $class (@classes) {
        my @items;
        for my $attr (@$attributes) {
            push @items, $attr if $attr->{class} eq $class
        }
        my $av = Koha::AuthorisedValues->search({ category => 'PA_CLASS', authorised_value => $class });
        my $lib = $av->count ? $av->next->lib : $class;

        push @attributes_loop, {
            class => $class,
            items => \@items,
            lib   => $lib,
        };
    }

    $template->param(
        attributes_loop => \@attributes_loop
    );

    my @types = C4::Members::AttributeTypes::GetAttributeTypes();
    if (scalar(@types) == 0) {
        $template->param(no_patron_attribute_types => 1);
    }
}

if (C4::Context->preference('EnhancedMessagingPreferences')) {
    C4::Form::MessagingPreferences::set_form_values({ borrowernumber => $borrowernumber }, $template);
    $template->param(messaging_form_inactive => 1);
}

if ( C4::Context->preference("ExportCircHistory") ) {
    $template->param(csv_profiles => [ Koha::CsvProfiles->search({ type => 'marc' }) ]);
}

my $patron_messages = Koha::Patron::Messages->search(
    {
        'me.borrowernumber' => $patron->borrowernumber,
    },
    {
        join => 'manager',
        '+select' => ['manager.surname', 'manager.firstname' ],
        '+as' => ['manager_surname', 'manager_firstname'],
    }
);

if( $patron_messages->count > 0 ){
    $template->param( patron_messages => $patron_messages );
}

# Display the language description instead of the code
# Note that this is certainly wrong
my ( $subtag, $region ) = split '-', $patron->lang;
my $translated_language = C4::Languages::language_get_description( $subtag, $subtag, 'language' );

# if the expiry date is before today ie they have expired
if ( $patron->is_expired || $patron->is_going_to_expire ) {
    $template->param(
        flagged => 1
    );
}

$template->param(
    patron          => $patron,
    issuecount      => $patron->checkouts->count,
    holds_count     => $patron->holds->count,
    fines           => $patron->account->balance,
    translated_language => $translated_language,
    detailview      => 1,
    was_renewed     => scalar $input->param('was_renewed') ? 1 : 0,
    $category_type  => 1, # [% IF ( I ) %] = institutional/organisation
    housebound_role => scalar $patron->housebound_role,
    relatives_issues_count => $relatives_issues_count,
    relatives_borrowernumbers => \@relatives,
);

output_html_with_http_headers $input, $cookie, $template->output;
