#!/usr/bin/perl

use Modern::Perl;

use C4::Context;
use C4::Circulation;
use C4::Items;
use Koha::IssuingRule;
use Koha::Items;
use Test::More tests => 6;

use t::lib::TestBuilder;
use t::lib::Mocks;

BEGIN {
    use_ok('C4::Reserves');
}

my $schema = Koha::Database->schema;
$schema->storage->txn_begin;
my $dbh = C4::Context->dbh;

my $builder = t::lib::TestBuilder->new;

my $library1 = $builder->build({
    source => 'Branch',
});
my $library2 = $builder->build({
    source => 'Branch',
});
my $itemtype = $builder->build({
    source => 'Itemtype',
    value  => { notforloan => 0 }
})->{itemtype};

t::lib::Mocks::mock_userenv({ branchcode => $library1->{branchcode} });


my $borrower1 = $builder->build({
    source => 'Borrower',
    value => {
        branchcode => $library1->{branchcode},
        dateexpiry => '3000-01-01',
    }
});

my $borrower2 = $builder->build({
    source => 'Borrower',
    value => {
        branchcode => $library1->{branchcode},
        dateexpiry => '3000-01-01',
    }
});

my $borrower3 = $builder->build({
    source => 'Borrower',
    value => {
        branchcode => $library2->{branchcode},
        dateexpiry => '3000-01-01',
    }
});

my $borrowernumber1 = $borrower1->{borrowernumber};
my $borrowernumber2 = $borrower2->{borrowernumber};
my $library_A = $library1->{branchcode};
my $library_B = $library2->{branchcode};

my $biblio = $builder->build_sample_biblio({itemtype=>$itemtype});
my $biblionumber = $biblio->biblionumber;
my $item1  = $builder->build_sample_item({
    biblionumber=>$biblionumber,
    itype=>$itemtype,
    homebranch => $library_A,
    holdingbranch => $library_A
})->unblessed;
my $item2  = $builder->build_sample_item({
    biblionumber=>$biblionumber,
    itype=>$itemtype,
    homebranch => $library_A,
    holdingbranch => $library_A
})->unblessed;

# Test hold_fulfillment_policy



my $rule = Koha::IssuingRule->new(
    {
        categorycode => '*',
        itemtype     => $itemtype,
        branchcode   => '*',
        issuelength  => 7,
        lengthunit   => 8,
        reservesallowed => 99,
        onshelfholds => 2,
    }
);
$rule->store();

my $is = IsAvailableForItemLevelRequest( $item1, $borrower1);
is( $is, 0, "Item cannot be held, 2 items available" );

my $issue1 = AddIssue( $borrower2, $item1->{barcode} );

$is = IsAvailableForItemLevelRequest( $item1, $borrower1);
is( $is, 0, "Item cannot be held, 1 item available" );

AddIssue( $borrower2, $item2->{barcode} );

$is = IsAvailableForItemLevelRequest( $item1, $borrower1);
is( $is, 1, "Item can be held, no items available" );

AddReturn( $item1->{barcode} );

{ # Remove the issue for the first patron, and modify the branch for item1
    subtest 'IsAvailableForItemLevelRequest behaviours depending on ReservesControlBranch + holdallowed' => sub {
        plan tests => 2;

        my $hold_allowed_from_home_library = 1;
        my $hold_allowed_from_any_libraries = 2;
        my $sth_delete_rules = $dbh->prepare(q|DELETE FROM default_circ_rules|);
        my $sth_insert_rule = $dbh->prepare(q|INSERT INTO default_circ_rules(singleton, holdallowed, hold_fulfillment_policy, returnbranch) VALUES ('singleton', ?, 'any', 'homebranch');|);
        my $sth_insert_branch_rule = $dbh->prepare(q|INSERT INTO default_branch_circ_rules(branchcode, holdallowed, hold_fulfillment_policy, returnbranch) VALUES (?, ?, 'any', 'homebranch');|);

        subtest 'Item is available at a different library' => sub {
            plan tests => 7;

            $item1 = Koha::Items->find( $item1->{itemnumber} );
            $item1->set({homebranch => $library_B, holdingbranch => $library_B })->store;
            $item1 = $item1->unblessed;
            #Scenario is:
            #One shelf holds is 'If all unavailable'/2
            #Item 1 homebranch library B is available
            #Item 2 homebranch library A is checked out
            #Borrower1 is from library A

            {
                $sth_delete_rules->execute;
                $sth_insert_rule->execute( $hold_allowed_from_home_library );

                t::lib::Mocks::mock_preference('ReservesControlBranch', 'ItemHomeLibrary');
                $is = IsAvailableForItemLevelRequest( $item1, $borrower1);
                is( $is, 1, "Hold allowed from home library + ReservesControlBranch=ItemHomeLibrary, One item is available at different library, not holdable = none available => the hold is allowed at item level" );
                $is = IsAvailableForItemLevelRequest( $item1, $borrower2);
                is( $is, 1, "Hold allowed from home library + ReservesControlBranch=ItemHomeLibrary, One item is available at home library, holdable = one available => the hold is not allowed at item level" );
                $sth_insert_branch_rule->execute( $library_B, $hold_allowed_from_any_libraries );
                #Adding a rule for the item's home library affects the availability for a borrower from another library because ReservesControlBranch is set to ItemHomeLibrary
                $is = IsAvailableForItemLevelRequest( $item1, $borrower1);
                is( $is, 0, "Hold allowed from home library + ReservesControlBranch=ItemHomeLibrary, One item is available at different library, holdable = one available => the hold is not allowed at item level" );

                t::lib::Mocks::mock_preference('ReservesControlBranch', 'PatronLibrary');
                $is = IsAvailableForItemLevelRequest( $item1, $borrower1);
                is( $is, 1, "Hold allowed from home library + ReservesControlBranch=PatronLibrary, One item is available at different library, not holdable = none available => the hold is allowed at item level" );
                #Adding a rule for the patron's home library affects the availability for an item from another library because ReservesControlBranch is set to PatronLibrary
                $sth_insert_branch_rule->execute( $library_A, $hold_allowed_from_any_libraries );
                $is = IsAvailableForItemLevelRequest( $item1, $borrower1);
                is( $is, 0, "Hold allowed from home library + ReservesControlBranch=PatronLibrary, One item is available at different library, holdable = one available => the hold is not allowed at item level" );
            }

            {
                $sth_delete_rules->execute;
                $sth_insert_rule->execute( $hold_allowed_from_any_libraries );

                t::lib::Mocks::mock_preference('ReservesControlBranch', 'ItemHomeLibrary');
                $is = IsAvailableForItemLevelRequest( $item1, $borrower1);
                is( $is, 0, "Hold allowed from any library + ReservesControlBranch=ItemHomeLibrary, One item is available at the diff library, holdable = 1 available => the hold is not allowed at item level" );

                t::lib::Mocks::mock_preference('ReservesControlBranch', 'PatronLibrary');
                $is = IsAvailableForItemLevelRequest( $item1, $borrower1);
                is( $is, 0, "Hold allowed from any library + ReservesControlBranch=PatronLibrary, One item is available at the diff library, holdable = 1 available => the hold is not allowed at item level" );
            }
        };

        subtest 'Item is available at the same library' => sub {
            plan tests => 4;

            $item1 = Koha::Items->find( $item1->{itemnumber} );
            $item1->set({homebranch => $library_A, holdingbranch => $library_A })->store;
            $item1 = $item1->unblessed;
            #Scenario is:
            #One shelf holds is 'If all unavailable'/2
            #Item 1 homebranch library A is available
            #Item 2 homebranch library A is checked out
            #Borrower1 is from library A
            #CircControl has no effect - same rule for all branches as set at line 96
            #ReservesControlBranch is not checked in these subs we are testing?

            {
                $sth_delete_rules->execute;
                $sth_insert_rule->execute( $hold_allowed_from_home_library );

                t::lib::Mocks::mock_preference('ReservesControlBranch', 'ItemHomeLibrary');
                $is = IsAvailableForItemLevelRequest( $item1, $borrower1);
                is( $is, 0, "Hold allowed from home library + ReservesControlBranch=ItemHomeLibrary, One item is available at the same library, holdable = 1 available  => the hold is not allowed at item level" );

                t::lib::Mocks::mock_preference('ReservesControlBranch', 'PatronLibrary');
                $is = IsAvailableForItemLevelRequest( $item1, $borrower1);
                is( $is, 0, "Hold allowed from home library + ReservesControlBranch=PatronLibrary, One item is available at the same library, holdable = 1 available  => the hold is not allowed at item level" );
            }

            {
                $sth_delete_rules->execute;
                $sth_insert_rule->execute( $hold_allowed_from_any_libraries );

                t::lib::Mocks::mock_preference('ReservesControlBranch', 'ItemHomeLibrary');
                $is = IsAvailableForItemLevelRequest( $item1, $borrower1);
                is( $is, 0, "Hold allowed from any library + ReservesControlBranch=ItemHomeLibrary, One item is available at the same library, holdable = 1 available => the hold is not allowed at item level" );

                t::lib::Mocks::mock_preference('ReservesControlBranch', 'PatronLibrary');
                $is = IsAvailableForItemLevelRequest( $item1, $borrower1);
                is( $is, 0, "Hold allowed from any library + ReservesControlBranch=PatronLibrary, One item is available at the same library, holdable = 1 available  => the hold is not allowed at item level" );
            }
        };
    };
}

my $itemtype2 = $builder->build({
    source => 'Itemtype',
    value  => { notforloan => 0 }
})->{itemtype};
my $item3 = $builder->build_sample_item({ itype => $itemtype2 });

my $hold = $builder->build({
    source => 'Reserve',
    value =>{
        itemnumber => $item3->itemnumber,
        found => 'T'
    }
});

$rule = Koha::IssuingRule->new(
    {
        categorycode => '*',
        itemtype     => $itemtype2,
        branchcode   => '*',
        issuelength  => 7,
        lengthunit   => 8,
        reservesallowed => 99,
        onshelfholds => 0,
    }
);
$rule->store();

$is = IsAvailableForItemLevelRequest( $item3->unblessed, $borrower1);
is( $is, 1, "Item can be held, items in transit are not available" );

# Cleanup
$schema->storage->txn_rollback;
