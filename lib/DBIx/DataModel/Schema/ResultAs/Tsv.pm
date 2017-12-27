#----------------------------------------------------------------------
package DBIx::DataModel::Schema::ResultAs::Tsv;
#----------------------------------------------------------------------
use warnings;
use strict;
use Carp::Clan        qw[^(DBIx::DataModel::|SQL::Abstract)];
use Scalar::Util 1.07 qw/openhandle/;

use parent 'DBIx::DataModel::Schema::ResultAs';

use namespace::clean;

sub new {
  my ($class, $file) = @_;

  croak "-result_as => [Tsv => ...] ... target file is missing" if !$file;
  return bless {file => $file}, $class;
}


sub get_result {
  my ($self, $statement) = @_;

  # open file
  my $fh;
  if (openhandle $self->{file}) {
    $fh = $self->{file};
  }
  else {
    open $fh, ">", $self->{file}
      or croak "open $self->{file} for writing : $!";
  }

  # get data
  $statement->execute;
  $statement->make_fast;

  # activate tsv mode by setting output field and record separators
  local $\ = "\n";
  local $, = "\t";

  # print header row
  no warnings 'uninitialized';
  my @headers   = $statement->headers;
  print $fh @headers;

  # print data rows
  while (my $row = $statement->next) {
    print $fh @{$row}{@headers};
  }

  # cleanup and return
  $statement->finish;
  return $self->{file};
}


1;


