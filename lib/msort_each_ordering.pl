#! /usr/bin/perl

#$ -cwd
#$ -S /usr/bin/perl
#$ -e /dev/null
#$ -o /dev/null

use Data::Dumper;
use Getopt::Std;
use FindBin;
#use Tie::IxHash;
use strict;
use warnings;

use vars qw ($opt_d $opt_t $opt_g $opt_v);
&getopts('d:t:g:uv');

my $usage = <<_EOH_;

#
# -d dir_each_ordering
# -g phasefile.hap
#
# [-t 1]
#

_EOH_
;


#
# IN
#

my $type_painting = 2; #  -t 2 (ordering) | 1 (all against everyone else, not supported in orderedPainting.sh) 
if ($opt_t) {
  $type_painting = $opt_t;
}

my $dir_each_ordering   = $opt_d or die $usage;
my $phasefile           = $opt_g or die $usage;

#
# env
#
my $sort_path = "lib/sort"; # FindBin doesn't work in arrayjob in UGE
my $sort_opt = " -n -m --batch-size=100"; # Don't use --parallel option here because it is already parallelized
# "-n" is required to cat across recipient individuals sorted by position
# "-m" makes the sorting much faster when all input files are sorted (ascending order)

my $cat_copyprob_each_dir    = "copyprobsperlocus.cat";
my $gz_cat_copyprob_each_dir = "copyprobsperlocus.cat.gz";

my $arrayJobID = "";
if (defined($ENV{LSB_JOBINDEX})) {
  $arrayJobID = $ENV{LSB_JOBINDEX};
} elsif (defined($ENV{SGE_TASK_ID})) {
  $arrayJobID = $ENV{SGE_TASK_ID};
} elsif (defined($ENV{SLURM_ARRAY_TASK_ID})) {
    $arrayJobID = $ENV{SLURM_ARRAY_TASK_ID};
}

#
# vars
#
my $cmd = "";
my $stamp = "";

##############################################################################
# main
#   execute sort -m
#   for alreadly split *.copyprobsperlocus.out_?? files in $dir_each_ordering
##############################################################################

if ($type_painting == 1) {
  #
  # cannot be called from orderedPainting.sh
  #
  my @arr_split_copyprobsperlocus = glob("$dir_each_ordering/*.copyprobsperlocus.out_??");
  if (scalar(@arr_split_copyprobsperlocus) == 0) {
    die "Error: there is no .copyprobsperlocus.out file in $dir_each_ordering ";
  } else {
    foreach my $each_split_copyprobsperlocus (@arr_split_copyprobsperlocus) {
      # get recipient indices from file names, and add them to the 1st column 
      # (otherwise there is no way to know recipient names in the all-against-everyone else painting condition)
      my $i_recipient = $each_split_copyprobsperlocus;
      $i_recipient =~ s/\.copyprobsperlocus\.out_[a-z]+$//g;
      $i_recipient =~ s/^.*_//g;
      $i_recipient =~ s/^0+//g;

      $cmd = " perl -i -pe 's/^([0-9]+) /\$1\t$i_recipient /g' $each_split_copyprobsperlocus ";
      print("$cmd\n");
      if( system("$cmd") != 0) { die("Error: $cmd failed"); };
    }
  }
}

#
# if unnecessary .out files are remained in each ordering dir, remove them
#   (they are supposed to be removed just after painting)
# 
my @arr_dotout_files = glob("$dir_each_ordering/*.out");
foreach my $each_dotout_file (@arr_dotout_files) {
  if ($each_dotout_file !~ /copyprobsperlocus/) {
    unlink($each_dotout_file);
    print "$dir_each_ordering/$each_dotout_file was removed\n";
  }
}

#
# msort (arrayjob from 1 to 9)
#
if ($arrayJobID > 0) {

  my $each_suffix = sprintf("%02d", $arrayJobID);

  $stamp = `date +%Y%m%d_%T`;
  chomp($stamp);
  print "$stamp $each_suffix\n";
  
  #
  # msort and create split gz files
  #
  $cmd  = "$sort_path $sort_opt ";
  $cmd .= " -T $dir_each_ordering $dir_each_ordering/*.copyprobsperlocus.out_$each_suffix";
  $cmd .= "       > $dir_each_ordering/$gz_cat_copyprob_each_dir.$each_suffix"; # split gz files
  print "$cmd\n";
  if( system("$cmd") != 0) { die("Error: $cmd failed"); };

  $cmd  = "gzip     $dir_each_ordering/$gz_cat_copyprob_each_dir.$each_suffix";
  print "$cmd\n";
  if( system("$cmd") != 0) { die("Error: $cmd failed"); };

  $cmd  = "/bin/mv -v  $dir_each_ordering/$gz_cat_copyprob_each_dir.$each_suffix.gz";
  $cmd .= "         $dir_each_ordering/$gz_cat_copyprob_each_dir.$each_suffix";
  print "$cmd\n";
  if( system("$cmd") != 0) { die("Error: $cmd failed"); };

  #
  # remove the uncompressed files required for msort
  #    which can be large for a large dataset
  #
  $cmd = "/bin/rm -v $dir_each_ordering/*.copyprobsperlocus.out_$each_suffix";
  print "$cmd\n";
  if( system("$cmd") != 0) { die("Error: $cmd failed"); };

#
# msort (non-arrayjob)
#
} else {

  my $nrecip = `head -2 $phasefile | tail -1`;
  chomp($nrecip);
  if ($type_painting == 2) {
    $nrecip--;
  }
  
  my $nsnp = `head -3 $phasefile | tail -1`;
  chomp($nsnp);

  my $correct_nrow_catCopyprob = $nsnp*$nrecip+($nrecip*2); # ($nrecip*2) is the number of headers

  #
  # get suffix of split files
  #
  my $first_recipient_file = `ls $dir_each_ordering/*.copyprobsperlocus.out_?? | head -1`;
  chomp($first_recipient_file);

  my $first_recipient_prefix = $first_recipient_file;
     $first_recipient_prefix =~ s/\.copyprobsperlocus\.out_..//g;

  my $str_split_suffixes = `ls $first_recipient_prefix*.copyprobsperlocus.out_?? | perl -pe 's/^.*\.copyprobsperlocus\.out_//g'`;
  my @arr_split_suffixes = split(/\n/, $str_split_suffixes);

  while () {

    #
    # if there is an incomplete $cat_copyprob_each_dir files created previously, remove it
    #
    if (  -f "$dir_each_ordering/$gz_cat_copyprob_each_dir") {
      unlink("$dir_each_ordering/$gz_cat_copyprob_each_dir");
    }

    #
    # msort across recipients
    #
    # save them as a concatenated gzip file
    #   (gzipping does not give difference of computational time)
    #
    foreach my $each_suffix (@arr_split_suffixes) {

      $stamp = `date +%Y%m%d_%T`;
      chomp($stamp);
      print "$stamp $each_suffix\n";
      
      $cmd  = "$sort_path $sort_opt ";
      $cmd .= " -T $dir_each_ordering $dir_each_ordering/*.copyprobsperlocus.out_$each_suffix";
      $cmd .= " | gzip - >> $dir_each_ordering/$gz_cat_copyprob_each_dir";
      print "$cmd\n";
      if( system("$cmd") != 0) { die("Error: $cmd failed"); };

    }

    #
    # check
    #
    $stamp = `date +%Y%m%d_%T`;
    print "$stamp";
   
    print("checking $dir_each_ordering/$gz_cat_copyprob_each_dir ... \n");
    my $nrow = `gzip -dc $dir_each_ordering/$gz_cat_copyprob_each_dir | wc -l`;
    chomp($nrow);
    
    if ($nrow == $correct_nrow_catCopyprob) {
      print("OK, there are $nrow rows in $dir_each_ordering/$gz_cat_copyprob_each_dir\n");
      last;
    } else {
      print "gzip -dc $dir_each_ordering/$gz_cat_copyprob_each_dir | wc -l: $nrow, but must be $correct_nrow_catCopyprob.  Do the msort again.\n";
    }

    print "\n";

  }

}
