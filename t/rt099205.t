use strict;
use warnings;
use DBIx::DataModel;

use constant NTESTS => 1;
use Test::More tests => NTESTS;

# do_transaction(), without a dbh, and within an eval, has an unexpected
# side-effect.

DBIx::DataModel->Schema('Tst')
->Table(Foo   => T_Foo   => qw/foo_id/);

SKIP: {
  eval "use DBD::Mock 1.36; 1"
    or skip "DBD::Mock 1.36 does not seem to be installed", NTESTS;

  my $dbh = DBI->connect('DBI:Mock:', '', '', 
                         {RaiseError => 1, AutoCommit => 1});

  my $work = sub {Tst->table('Foo')->select};

  # Trying to do a transaction without a DB connection ... normally
  # this raises an exception, but if captured in a eval, we don't see the
  # exception, and it has the naughty side-effect of silently setting
  # Tst->singleton->{dbh} = {}
  eval {Tst->do_transaction($work);};

  # now $schema->{dbh} is true but $schema->{dbh}[0]{AutoCommit} is false,
  # so it looks like we are running a transaction
  # ==> croak "cannot change dbh(..) while in a transaction";
  Tst->dbh($dbh);

  # once the bug is fixed, this should work
  ok scalar(Tst->dbh), "schema has a dbh";
}








