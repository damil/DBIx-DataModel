#----------------------------------------------------------------------
package DBIx::DataModel::Schema::ResultAs::Xlsx;
#----------------------------------------------------------------------
use warnings;
use strict;
use Carp::Clan           qw[^(DBIx::DataModel::|SQL::Abstract)];
use Excel::Writer::XLSX;


use parent 'DBIx::DataModel::Schema::ResultAs';

use namespace::clean;

# TODO : args for
#  - filename
#  - sheet name
#  - add technical details O/N


sub new {
  my $class = shift;

  my $self = bless \@_, $class;
  return $self;
}


sub get_result {
  my ($self, $statement) = @_;

  # 
  $statement->execute;
  $statement->make_fast;
  my @headers   = $statement->headers;
  my @rows;
  while (my $row = $statement->next) {
    push @rows, [@{$row}{@headers}];
  }
  $statement->finish;


  my $workbook  = Excel::Writer::XLSX->new(@$self)
    or die "open Excel file @$self: $!";
  my $worksheet = $workbook->add_worksheet();

  $worksheet->add_table(0, 0, scalar(@rows), scalar(@headers)-1, {
    data       => \@rows,
    columns    => [ map { {header => $_}} @headers ],
    autofilter => 1,
   });
  $worksheet->freeze_panes(1, 0);

  # finalize the workbook
  $workbook->close();

  # THINK : include technical worksheet with details about SQL
  # statement, datasource, etc. ???

}


1;


