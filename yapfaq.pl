#! /usr/bin/perl -W
#
# yapfaq Version 0.7 by Thomas Hochstein
# (Original author: Marc Brockschmidt)
#
# This script posts any project described in its config-file. Most people
# will use it in combination with cron(8).
# 
# Copyright (C) 2003 Marc Brockschmidt <marc@marcbrockschmidt.de>
# Copyright (c) 2010 Thomas Hochstein <thh@inter.net>
#
# It can be redistributed and/or modified under the same terms under 
# which Perl itself is published.

my $Version = "0.8-prelease";

my $RCFile = '.yapfaqrc';
my @ValidConfVars = ('NNTPServer','NNTPUser','NNTPPass','Sender','ConfigFile',
                     'UsePGP','pgp','PGPVersion','PGPSigner','PGPPass',
                     'PathtoPGPPass','pgpbegin','pgpend','pgptmpf','pgpheader');

################################### Defaults ##################################
my %Config = (NNTPServer => "",
              NNTPUser   => "",
              NNTPPass   => "",
              Sender     => "",
              ConfigFile => "yapfaq.cfg",
              UsePGP     => 0,

              ################################## PGP-Config #################################
              pgp           => '/usr/bin/pgp',                  # path to pgp
              PGPVersion    => '2',                             # Use 2 for 2.X, 5 for PGP > 2.X and GPG for GPG
              PGPSigner     => '',                              # sign as who?
              PGPPass       => '',                              # pgp2 only
              PathtoPGPPass => '',                              # pgp2, pgp5 and gpg
              pgpbegin      => '-----BEGIN PGP SIGNATURE-----', # Begin of PGP-Signature
              pgpend        => '-----END PGP SIGNATURE-----',   # End of PGP-Signature
              pgptmpf       => 'pgptmp',                        # temporary file for PGP.
              pgpheader     => 'X-PGP-Sig');

my @PGPSignHeaders = ('From', 'Newsgroups', 'Subject', 'Control',
	'Supersedes', 'Followup-To', 'Date', 'Sender', 'Approved',
	'Message-ID', 'Reply-To', 'Cancel-Lock', 'Cancel-Key',
	'Also-Control', 'Distribution');

my @PGPorderheaders = ('from', 'newsgroups', 'subject', 'control',
	'supersedes', 'followup-To', 'date', 'organization', 'lines',
	'sender', 'approved', 'distribution', 'message-id',
	'references', 'reply-to', 'mime-version', 'content-type',
	'content-transfer-encoding', 'summary', 'keywords', 'cancel-lock',
	'cancel-key', 'also-control', 'x-pgp', 'user-agent');

############################# End of Configuration #############################

use strict;
use Net::NNTP;
use Net::Domain qw(hostfqdn);
use Date::Calc qw(Add_Delta_YM Add_Delta_Days Delta_Days Today);
use Fcntl ':flock'; # import LOCK_* constants
use Getopt::Std;
my ($TDY, $TDM, $TDD) = Today(); #TD: Today's date

# read commandline options
my %Options;
getopts('Vhvpdt:f:c:s:', \%Options);
# -V: print version / copyright information
if ($Options{'V'}) {
  print "$0 v $Version\nCopyright (c) 2003 Marc Brockschmidt <marc\@marcbrockschmidt.de>\nCopyright (c) 2010 Thomas Hochstein <thh\@inter.net>\n";
  print "This program is free software; you may redistribute it and/or modify it under the same terms as Perl itself.\n";
  exit(0);
}
# -h: feed myself to perldoc
if ($Options{'h'}) {
  exec ('perldoc', $0);
  exit(0);
};
# -f: set $Faq
my ($Faq) = $Options{'f'} if ($Options{'f'});

# read runtime configuration (configuration variables)
$RCFile = $Options{'c'} if ($Options{'c'});
if (-f $RCFile) {
  readrc (\$RCFile,\%Config);
} else {
  warn "$0: W: .rc file $RCFile does not exist!\n";
}

# read configuration (configured FAQs)
my @Config;
readconfig (\$Config{'ConfigFile'}, \@Config, \$Faq);

# for each FAQ:
# - parse configuration
# - read status data
# - if FAQ is due: call postfaq()
foreach (@Config) { 
  my ($LPD,$LPM,$LPY) = (01, 01, 0001);  #LP: Last posting-date
  my ($NPY,$NPM,$NPD);                   #NP: Next posting-date
  my $SupersedeMID;
  
  my ($ActName,$File,$PFreq,$Expire) =($$_{'name'},$$_{'file'},$$_{'posting-frequency'},$$_{'expires'});
  my ($From,$Subject,$NG,$Fup2)=($$_{'from'},$$_{'subject'},$$_{'ngs'},$$_{'fup2'});
  my ($MIDF,$ReplyTo,$ExtHea)=($$_{'mid-format'},$$_{'reply-to'},$$_{'extraheader'});
  my ($Supersede)            =($$_{'supersede'});

  # -f: loop if not FAQ to post
  next if (defined($Faq) && $ActName ne $Faq);
	
  # read status data
  if (open (FH, "<$File.cfg")) {
    while(<FH>){
      if (/##;; Lastpost:\s*(\d{1,2})\.(\d{1,2})\.(\d{2}(\d{2})?)/){
        ($LPD, $LPM, $LPY) = ($1, $2, $3);
      } elsif (/^##;;\s*LastMID:\s*(<\S+@\S+>)\s*$/) {
        $SupersedeMID = $1;
      }
    }
    close FH;
  } else { 
    warn "$0: W: Couldn't open $File.cfg: $!\n";
  }

  $SupersedeMID = "" unless $Supersede;

  ($NPY,$NPM,$NPD) = calcdelta ($LPY,$LPM,$LPD,$PFreq);

  # if FAQ is due: get it out
  if (Delta_Days($NPY,$NPM,$NPD,$TDY,$TDM,$TDD) >= 0 or ($Options{'p'})) {
    if($Options{'d'}) {
	  print "$ActName: Would be posted now (but running in simulation mode [$0 -d]).\n" if $Options{'v'};
	} else {
      postfaq(\$ActName,\$File,\$From,\$Subject,\$NG,\$Fup2,\$MIDF,\$ExtHea,\$Config{'Sender'},\$TDY,\$TDM,\$TDD,\$ReplyTo,\$SupersedeMID,\$Expire);
	}
  } elsif($Options{'v'}) {
    print "$ActName: Nothing to do.\n";
  }
}

exit;

#################################### readrc ####################################
# Takes a filename and the reference to an array which contains the valid options

sub readrc{
  my ($File, $Config) = @_;

  print "Reading $$File.\n" if($Options{'v'});

  open FH, "<$$File" or die "$0: Can't open $$File: $!";
  while (<FH>) {
    if (/^\s*(\S+)\s*=\s*'?(.*?)'?\s*(#.*$|$)/) {
      if (grep(/$1/,@ValidConfVars)) {
        $$Config{$1} = $2 if $2 ne '';
      } else {
        warn "$0: W: $1 is not a valid configuration variable (reading from $$File)\n";
      }
    }
  }
}

################################## readconfig ##################################
# Takes a filename, a reference to an array, which will hold hashes with
# the data from $File, and - optionally - the name of the (single) FAQ to post

sub readconfig{
  my ($File, $Config, $Faq) = @_;
  my ($LastEntry, $Error, $i) = ('','',0);

  print "Reading configuration from $$File.\n" if($Options{'v'});

  open FH, "<$$File" or die "$0: E: Can't open $$File: $!";
  while (<FH>) {
    next if (defined($$Faq) && !/^\s*=====\s*$/ && defined($$Config[$i]{'name'}) && $$Config[$i]{'name'} ne $$Faq );
    if (/^(\s*(\S+)\s*=\s*'?(.*?)'?\s*(#.*$|$)|^(.*?)'?\s*(#.*$|$))/ && not /^\s*$/) {
      $LastEntry = lc($2) if $2;
      $$Config[$i]{$LastEntry} .= $3 if $3;  
      $$Config[$i]{$LastEntry} .= "\n$5" if $5 && $5;
    } 
    if (/^\s*=====\s*$/) {
      $i++;
    }
  }
  close FH;

  #Check saved values:
  for $i (0..$i){
    next if (defined($$Faq) && defined($$Config[$i]{'name'}) && $$Config[$i]{'name'} ne $$Faq );
    unless(defined($$Config[$i]{'name'}) && $$Config[$i]{'name'} =~ /^\S+$/) {
      $Error .= "E: The name of your project \"$$Config[$i]{'name'}\" is not defined or contains whitespaces.\n"
    }
    unless(defined($$Config[$i]{'file'}) && -f $$Config[$i]{'file'}) {
      $Error .= "E: The file to post for your project \"$$Config[$i]{'name'}\" is not defined or does not exist.\n"
    }
    unless(defined($$Config[$i]{'from'}) && $$Config[$i]{'from'} =~ /\S+\@(\S+\.)?\S{2,}\.\S{2,}/) {
      $Error .= "E: The From header for your project \"$$Config[$i]{'name'}\" seems to be incorrect.\n"
    }
    unless(defined($$Config[$i]{'ngs'}) && $$Config[$i]{'ngs'} =~ /^\S+$/) {
      $Error .= "E: The Newsgroups header for your project \"$$Config[$i]{'name'}\" is not defined or contains whitespaces.\n"
    }
    unless(defined($$Config[$i]{'subject'})) {
      $Error .= "E: The Subject header for your project \"$$Config[$i]{'name'}\" is not defined.\n"
    }
    unless(!$$Config[$i]{'fup2'} || $$Config[$i]{'fup2'} =~ /^\S+$/) {
      $Error .= "E: The Followup-To header for your project \"$$Config[$i]{'name'}\" contains whitespaces.\n"
    }
    unless(defined($$Config[$i]{'posting-frequency'}) && $$Config[$i]{'posting-frequency'} =~ /^\s*\d+\s*[dwmy]\s*$/) {
      $Error .= "E: The Posting-frequency for your project \"$$Config[$i]{'name'}\" is invalid.\n"
    }
    unless(!$$Config[$i]{'expires'} || $$Config[$i]{'expires'} =~ /^\s*\d+\s*[dwmy]\s*$/) {
      warn "$0: W: The Expires for your project \"$$Config[$i]{'name'}\" is invalid - set to 3 month.\n";
      $$Config[$i]{'expires'} = '3m'; # set default (3 month) if expires is unset or invalid
    }
    unless(!$$Config[$i]{'mid-format'} || $$Config[$i]{'mid-format'} =~ /^<\S+\@\S{2,}\.\S{2,}>$/) {
      warn "$0: W: The Message-ID format for your project \"$$Config[$i]{'name'}\" seems to be invalid - set to default.\n";
      $$Config[$i]{'mid-format'} = '<%n-%d.%m.%y@'.hostfqdn.'>'; # set default if mid-format is invalid
    }
  }
  $Error .= "-" x 25 . 'program terminated' . "-" x 25 . "\n" if $Error;
  die $Error if $Error;
}

################################# calcdelta #################################
# Takes a date (year,  month and day) and a time period (1d, 1w, 1m, 1y, ...)
# and adds the latter to the former

sub calcdelta {
  my ($Year, $Month, $Day, $Period) = @_;
  my ($NYear, $NMonth, $NDay);

  if ($Period =~ /(\d+)\s*([dw])/) { # Is counted in days or weeks: Use Add_Delta_Days.
    ($NYear, $NMonth, $NDay) = Add_Delta_Days($Year, $Month, $Day, (($2 eq "w")?$1 * 7: $1 * 1));
  } elsif ($Period =~ /(\d+)\s*([my])/) { #Is counted in months or years: Use Add_Delta_YM
    ($NYear, $NMonth, $NDay) = Add_Delta_YM($Year, $Month, $Day, (($2 eq "m")?(0,$1):($1,0)));
  }
  return ($NYear, $NMonth, $NDay);
}

################################ updatestatus ###############################
# Takes a MID and a status file name
# and writes status information to disk

sub updatestatus {
  my ($ActName, $File, $date, $MID) = @_;
  
  print "$$ActName: Save status information.\n" if($Options{'v'});

  open (FH, ">$$File.cfg") or die "$0: E: Can't open $$File.cfg: $!";
  print FH "##;; Lastpost: $date\n";
  print FH "##;; LastMID: $MID\n";
  close FH;
}
  
################################## postfaq ##################################
# Takes a filename and many other vars.
#
# It reads the data-file $File and then posts the article.

sub postfaq {
  my ($ActName,$File,$From,$Subject,$NG,$Fup2,$MIDF,$ExtraHeaders,$Sender,$TDY,$TDM,$TDD,$ReplyTo,$Supersedes,$Expire) = @_;
  my (@Header,@Body,$MID,$InRealBody,$LastModified);

  print "$$ActName: Preparing to post.\n" if($Options{'v'});
  
  #Prepare MID:
  $$TDM = ($$TDM < 10 && $$TDM !~ /^0/) ? "0" . $$TDM : $$TDM;
  $$TDD = ($$TDD < 10 && $$TDD !~ /^0/) ? "0" . $$TDD : $$TDD;

  $MID = $$MIDF;
  $MID = '<%n-%d.%m.%y@'.hostfqdn.'>' if !defined($MID); # set to default if unset
  $MID =~ s/\%n/$$ActName/g;
  $MID =~ s/\%d/$$TDD/g;
  $MID =~ s/\%m/$$TDM/g;
  $MID =~ s/\%y/$$TDY/g;

  #Now get the body:
  open (FH, "<$$File");
  while (<FH>){  
    s/\r//;
    push (@Body, $_), next if $InRealBody;
    $InRealBody++ if /^$/;
    $LastModified = $1 if /^Last-modified: (\S+)$/i;
    push @Body, $_;
  }
  close FH;
  push @Body, "\n" if ($Body[-1] ne "\n");

  #Create Date- and Expires-Header:
  my @time = localtime;
  my $ss =  ($time[0]<10) ? "0" . $time[0] : $time[0];
  my $mm =  ($time[1]<10) ? "0" . $time[1] : $time[1];
  my $hh =  ($time[2]<10) ? "0" . $time[2] : $time[2];
  my $day = $time[3];
  my $month = ($time[4]+1<10) ? "0" . ($time[4]+1) : $time[4]+1;
  my $monthN = ("Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec")[$time[4]];
  my $wday = ("Sun","Mon","Tue","Wed","Thu","Fri","Sat")[$time[6]];
  my $year = (1900 + $time[5]);
  my $tz = $time[8] ? " +0200" : " +0100";

  $$Expire = '3m' if !$$Expire; # set default if unset: 3 month

  my ($expY,$expM,$expD) = calcdelta ($year,$month,$day,$$Expire);
  my $expmonthN = ("Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec")[$expM-1];

  my $date = "$day $monthN $year " . $hh . ":" . $mm . ":" . $ss . $tz;
  my $expdate = "$expD $expmonthN $expY $hh:$mm:$ss$tz";
 
  #Replace %LM by the content of the news.answer-pseudo-header Last-modified:
  if ($LastModified) {
    $$Subject =~ s/\%LM/$LastModified/;
  }

  # Test mode?
  if($Options{'t'} and $Options{'t'} !~ /console/i) {
    $$NG = $Options{'t'};
  }

  #Now create the complete Header:
  push @Header, "From: $$From\n";
  push @Header, "Newsgroups: $$NG\n";
  push @Header, "Followup-To: $$Fup2\n" if $$Fup2;
  push @Header, "Subject: $$Subject\n";
  push @Header, "Message-ID: $MID\n";
  push @Header, "Supersedes: $$Supersedes\n" if $$Supersedes;
  push @Header, "Date: $date\n";
  push @Header, "Expires: $expdate\n";
  push @Header, "Sender: $$Sender\n" if $$Sender;
  push @Header, "Mime-Version: 1.0\n";
  push @Header, "Reply-To: $$ReplyTo\n" if $$ReplyTo;
  push @Header, "Content-Type: text/plain; charset=ISO-8859-15\n";
  push @Header, "Content-Transfer-Encoding: 8bit\n";
  push @Header, "User-Agent: yapfaq/$Version\n";
  if ($$ExtraHeaders) {
    push @Header, "$_\n" for (split /\n/, $$ExtraHeaders);
  }

  # sign article if $UsePGP is true
  my @Article = ($Config{'UsePGP'})?@{signpgp(\@Header, \@Body)}:(@Header, "\n", @Body);
  
  # post article
  print "$$ActName: Posting article ...\n" if($Options{'v'});
  my $failure = post(\@Article);
  
  if ($failure) {
    print "$$ActName: Posting failed, ERROR.dat may have more information.\n" if($Options{'v'} && (!defined($Options{'t'}) || $Options{'t'} !~ /console/i));
  } else {
    updatestatus($ActName, $File, "$day.$month.$year", $MID) if !defined($Options{'t'});
  }
}

################################## post ##################################
# Takes a complete article (Header and Body).
#
# It opens a connection to $NNTPServer and posts the message.

sub post {
  my ($ArticleR) = @_;
  my ($failure) = -1;

  # test mode - print article to console
  if(defined($Options{'t'}) and $Options{'t'} =~ /console/i) {
    print "-----BEGIN--------------------------------------------------\n";
    print @$ArticleR;
    print "------END---------------------------------------------------\n";
  # pipe article to script
  } elsif(defined($Options{'s'})) {
    open (POST, "| $Options{'s'}") or die "$0: E: Cannot fork $Options{'s'}: $!\n";
    print POST @$ArticleR;
    close POST;
    if ($? == 0) {
      $failure = 0;
    } else {
      warn "$0: W: $Options{'s'} exited with status ", ($? >> 8), "\n";
      $failure = $?;
    }
  # post article
  } else {
    my $NewsConnection = Net::NNTP->new($Config{'NNTPServer'}, Reader => 1) or die "$0: E: Can't connect to news server '$Config{'NNTPServer'}'!\n";
    $NewsConnection->authinfo ($Config{'NNTPUser'}, $Config{'NNTPPass'}) if (defined($Config{'NNTPUser'}));
    $NewsConnection->post();
    $NewsConnection->datasend (@$ArticleR);
    $NewsConnection->dataend();

    if ($NewsConnection->ok()) {
      $failure = 0;
    # Posting failed? Save to ERROR.dat
    } else {
	  warn "$0: W: Posting failed!\n";
      open FH, ">>ERROR.dat";
      print FH "\nPosting failed! Saving to ERROR.dat. Response from news server:\n";
      print FH $NewsConnection->code();
      print FH $NewsConnection->message();
      print FH "\n";
      print FH @$ArticleR;
      print FH "-" x 80, "\n";
      close FH;
    }
    $NewsConnection->quit();
  }
  return $failure;
}

#-------- sub getpgpcommand
# getpgpcommand generates the command to sign the message and returns it.
#
# Receives:
# 	- $PGPVersion: A scalar holding the PGPVersion
sub getpgpcommand {
  my ($PGPVersion) = @_;
  my $PGPCommand;

  if ($PGPVersion eq '2') {
    if ($Config{'PathtoPGPPass'} && !$Config{'PGPPass'}) {
      open (PGPPW, $Config{'PathtoPGPPass'}) or die "$0: E: Can't open $Config{'PathtoPGPPass'}: $!";
      Config{'$PGPPass'} = <PGPPW>;
      close PGPPW;
    }
  
    if (Config{'$PGPPass'}) {
      $PGPCommand = "PGPPASS=\"".$Config{'PGPPass'}."\" ".$Config{'pgp'}." -u \"".$Config{'PGPSigner'}."\" +verbose=0 language='en' -saft <".$Config{'pgptmpf'}.".txt >".$Config{'pgptmpf'}.".txt.asc";
    } else {
      die "$0: E: PGP-Passphrase is unknown!\n";
    }
  } elsif ($PGPVersion eq '5') {
    if ($Config{'PathtoPGPPass'}) {
      $PGPCommand = "PGPPASSFD=2 ".$Config{'pgp'}."s -u \"".$Config{'PGPSigner'}."\" -t --armor -o ".$Config{'pgptmpf'}.".txt.asc -z -f < ".$Config{'pgptmpf'}.".txt 2<".$Config{'PathtoPGPPass'};
    } else {
      die "$0: E: PGP-Passphrase is unknown!\n";
    }
  } elsif ($PGPVersion =~ m/GPG/io) {
    if (Config{'$PathtoPGPPass'}) {
      $PGPCommand = $Config{'pgp'}." --digest-algo MD5 -a -u \"".$Config{'PGPSigner'}."\" -o ".$Config{'pgptmpf'}.".txt.asc --no-tty --batch --passphrase-fd 2 2<".$Config{'PathtoPGPPass'}." --clearsign ".$Config{'pgptmpf'}.".txt";
    } else {
      die "$0: E: Passphrase is unknown!\n";
    }
  } else {
    die "$0: E: Unknown PGP-Version $PGPVersion!";
  }
  return $PGPCommand;
}


#-------- sub signarticle
# signarticle signs an articel and returns a reference to an array
# 	containing the whole signed Message.
#
# Receives:
# 	- $HeaderAR: A reference to a array containing the articles headers.
# 	- $BodyR: A reference to an array containing the body.
#
# Returns:
# 	- $MessageRef: A reference to an array containing the whole message.
sub signpgp {
  my ($HeaderAR, $BodyR) = @_;
  my (@pgphead, @pgpbody, $pgphead, $pgpbody, $header, $signheaders, @signheaders, $currentheader, $HeaderR, $line);

  foreach my $line (@$HeaderAR) {
    if ($line =~ /^(\S+):\s+(.*)$/s) {
      $currentheader = $1;
      $$HeaderR{lc($currentheader)} = "$1: $2";
    } else {
      $$HeaderR{lc($currentheader)} .= $line;
    }
  }

  foreach (@PGPSignHeaders) {
    if (defined($$HeaderR{lc($_)}) && $$HeaderR{lc($_)} =~ m/^[^\s:]+: .+/o) {
      push @signheaders, $_;
    }
  }

  $pgpbody = join ("", @$BodyR);

  # Delete and create the temporary pgp-Files
  unlink "$Config{'pgptmpf'}.txt";
  unlink "$Config{'pgptmpf'}.txt.asc";
  $signheaders = join(",", @signheaders);

  $pgphead = "X-Signed-Headers: $signheaders\n";
  foreach $header (@signheaders) {
    if ($$HeaderR{lc($header)} =~ m/^[^\s:]+: (.+?)\n?$/so) {
      $pgphead .= $header.": ".$1."\n";
    }
  }

  open(FH, ">" . $Config{'pgptmpf'} . ".txt") or die "$0: E: can't open $Config{'pgptmpf'}: $!\n";
  print FH $pgphead, "\n", $pgpbody;
  print FH "\n" if ($Config{'PGPVersion'} =~ m/GPG/io);	# workaround a pgp/gpg incompatibility - should IMHO be fixed in pgpverify
  close(FH) or warn "$0: W: Couldn't close TMP: $!\n";

  # Start PGP, then read the signature;
  my $PGPCommand = getpgpcommand($Config{'PGPVersion'});
  `$PGPCommand`;

  open (FH, "<" . $Config{'pgptmpf'} . ".txt.asc") or die "$0: E: can't open ".$Config{'pgptmpf'}.".txt.asc: $!\n";
  $/ = "$Config{'pgpbegin'}\n";
  $_ = <FH>;
  unless (m/\Q$Config{'pgpbegin'}\E$/o) {
#    unlink $Config{'pgptmpf'} . ".txt";
#    unlink $Config{'pgptmpf'} . ".txt.asc";
    die "$0: E: $Config{'pgpbegin'} not found in ".$Config{'pgptmpf'}.".txt.asc\n"
  }
  unlink($Config{'pgptmpf'} . ".txt") or warn "$0: W: Couldn't unlink $Config{'pgptmpf'}.txt: $!\n";

  $/ = "\n";
  $_ = <FH>;
  unless (m/^Version: (\S+)(?:\s(\S+))?/o) {
    unlink $Config{'pgptmpf'} . ".txt";
    unlink $Config{'pgptmpf'} . ".txt.asc";
    die "$0: E: didn't find PGP Version line where expected.\n";
  }
  
  if (defined($2)) {
    $$HeaderR{$Config{'pgpheader'}} = $1."-".$2." ".$signheaders;
  } else {
    $$HeaderR{$Config{'pgpheader'}} = $1." ".$signheaders;
  }
  
  do {          # skip other pgp headers like
    $_ = <FH>;  # "charset:"||"comment:" until empty line
  } while ! /^$/;

  while (<FH>) {
    chomp;
    last if /^\Q$Config{'pgpend'}\E$/;
    $$HeaderR{$Config{'pgpheader'}} .= "\n\t$_";
  }
  
  $$HeaderR{$Config{'pgpheader'}} .= "\n" unless ($$HeaderR{$Config{'pgpheader'}} =~ /\n$/s);

  $_ = <FH>;
  unless (eof(FH)) {
    unlink $Config{'pgptmpf'} . ".txt";
    unlink $Config{'pgptmpf'} . ".txt.asc";
    die "$0: E: unexpected data following $Config{'pgpend'}\n";
  }
  close(FH);
  unlink "$Config{'pgptmpf'}.txt.asc";

  my $tmppgpheader = $Config{'pgpheader'} . ": " . $$HeaderR{$Config{'pgpheader'}};
  delete $$HeaderR{$Config{'pgpheader'}};

  @pgphead = ();
  foreach $header (@PGPorderheaders) {
    if ($$HeaderR{$header} && $$HeaderR{$header} ne "\n") {
      push(@pgphead, "$$HeaderR{$header}");
      delete $$HeaderR{$header};
    }
  }

  foreach $header (keys %$HeaderR) {
    if ($$HeaderR{$header} && $$HeaderR{$header} ne "\n") {
      push(@pgphead, "$$HeaderR{$header}");
      delete $$HeaderR{$header};
    }
  }

  push @pgphead, ("X-PGP-Key: " . $Config{'PGPSigner'} . "\n"), $tmppgpheader;
  undef $tmppgpheader;

  @pgpbody = split /$/m, $pgpbody;
  my @pgpmessage = (@pgphead, "\n", @pgpbody);
  return \@pgpmessage;
}

__END__

################################ Documentation #################################

=head1 NAME

yapfaq - Post Usenet FAQs I<(yet another postfaq)>

=head1 SYNOPSIS

B<yapfaq> [B<-Vhvpd>] [B<-t> I<newsgroups> | CONSOLE] [B<-f> I<project name>] [B<-s> I<program>] [B<-c> I<.rc file>]

=head1 REQUIREMENTS

=over 2

=item -

Perl 5.8 or later

=item -

Net::NNTP

=item -

Date::Calc

=item -

Getopt::Std

=back

Furthermore you need access to a news server to actually post FAQs.

=head1 DESCRIPTION

B<yapfaq> posts (one or more) FAQs to Usenet with a certain posting
frequency (every n days, weeks, months or years), adding all necessary
headers as defined in its config file (by default F<yapfaq.cfg>).

=head2 Configuration

F<yapfaq.cfg> consists of one or more blocks, separated by C<=====> on
a single line, each containing the configuration for one FAQ as a set
of definitions in the form of I<param = value>. Everything after a "#"
sign is ignored so you may comment your configuration file.

=over 4

=item B<Name> = I<project name>

A name referring to your FAQ, also used for generation of a Message-ID.

This value must be set.

=item B<File> = I<file name>

A file containing the message body of your FAQ and all pseudo headers
(subheaders in the news.answers style).

This value must be set.

=item B<Posting-frequency> = I<time period>

The posting frequency defines how often your FAQ will be posted.
B<yapfaq> will only post your FAQ if this period of time has passed
since the last posting.

You can declare that time period either in I<B<d>ays> or I<B<w>weeks>
or I<B<m>onths> or I<B<y>ears>.

This value must be set.

=item B<Expires> = I<time period> (optional)

The period of time after which your message will expire. An Expires
header will be calculated adding this time period to today's date.

You can declare this  time period either in I<B<d>ays> or I<B<w>weeks>
or I<B<m>onths> or I<B<y>ears>.

This setting is optional; the default is 3 months.

=item B<From> = I<author>

The author of your FAQ as it will appear in the From header of the
message.

This value must be set.

=item B<Subject> = I<subject>

The title of your FAQ as it will appear in the Subject header of the
message.

You may use the special string C<%LM> which will be replaced with
the contents of the Last-Modified subheader in your I<File>.

This value must be set.

=item B<NGs> = I<newsgroups>

A comma-separated list of newsgroup(s) to post your FAQ to as it will
appear in the Newsgroups header of the message.

This value must be set.

=item B<Fup2> = I<newsgroup | poster>  (optional)

A comma-separated list of newsgroup(s) or the special string I<poster>
as it will appear in the Followup-To header of the message.

This setting is optional.

=item B<MID-Format> = I<pattern>  (optional)

A pattern from which the message ID is generated as it will appear in
the Message-ID header of the message.

You may use the special strings C<%n> for the I<Name> of your project,
C<%d> for the date the message is posted, C<%m> for the month and
C<%y> for the year, respectively.

This setting is optional; the default is '<%n-%d.%m.%y@I<YOURHOST>>'
where I<YOURHOST> is the fully qualified domain name (FQDN) of the
host B<yapfaq> is running on. Obviously that will only work if you
have defined a reasonable hostname that the hostfqdn() function of
Net::Domain can return.

=item B<Supersede> = I<yes>  (optional)

Add Supersedes header to the message containing the Message-ID header
of the last posting.

This setting is optional; you should set it to yes or leave it out.

=item B<ExtraHeader> = I<additional headers>  (optional)

The contents of I<ExtraHeader> is added verbatim to the headers of
your message so you can add custom headers like Approved.

This setting is optional.

=back

=head3 Example configuration file

    # name of your project
    Name = 'testpost'
    
    # file to post (complete body and pseudo-headers)
    # ($File.cfg contains data on last posting and last MID)
    File = 'test.txt'
    
    # how often your project should be posted
    # use (d)ay OR (w)eek OR (m)onth OR (y)ear
    Posting-frequency = '1d'
    
    # time period after which the posting should expire
    # use (d)ay OR (w)eek OR (m)onth OR (y)ear
    # Expires = '3m'
    
    # header "From:"
    From = 'test@domain.invalid'
    
    # header "Subject:"
    # (may contain "%LM" which will be replaced by the contents of the
    #  Last-Modified pseudo header).
    Subject = 'test noreply ignore'
    
    # comma-separated list of newsgroup(s) to post to
    # (header "Newsgroups:")
    NGs = 'de.test'
    
    # header "Followup-To:"
    # Fup2 = 'poster'
    
    # Message-ID ("%n" is $Name)
    # MID-Format = '<%n-%d.%m.%y@domain.invalid>'
    
    # Supersede last posting?
    Supersede = yes
    
    # extra headers (appended verbatim)
    # use this for custom headers like "Approved:"
    ExtraHeader = 'Approved: moderator@domain.invalid
    X-Header: Some text'
    
    # other projects may follow separated with "====="
    =====
    
    Name = 'othertest'
    File = 'test.txt'
    Posting-frequency = '2m'
    From = 'My Name <my.name@domain.invalid>'
    Subject = 'Test of yapfag <%LM>'
    NGs = 'de.test,de.alt.test'
    Fup2 = 'de.test'
    MID-Format = '<%n-%m.%y@domain.invalid>'
    Supersede = yes

=head3 Status Information

Information about the last post and about how to form message IDs for
posts is stored in a file named F<I<project name>.cfg> which will be
generated if it does not exist. Each of those status files will
contain two lines, the first being the date of the last time the FAQ
was posted and the second being the message ID of that incarnation.

=head2 Runtime Configuration

Apart from configuring which FAQ(s) to post you may (re)set some
runtime configuration variables via the .rcfile (by default
F<.yapfaqrc>). F<.yapfaqrc> must contain one definition in the form of
I<param = value> on each line; everything after a "#" sign is ignored.

If you omit some settings they will be set to default values hardcoded
in F<yapfaq.pl>.

B<Please note that all parameter names are case-sensitive!>

=over 4

=item B<NNTPServer> = I<NNTP server> (mandatory)

Host name of the NNTP server to post to. Must be set (or omitted; the
default is "localhost"); if set to en empty string, B<yapfaq> falls
back to Perl's build-in defaults (contents of environment variables
NNTPSERVER and NEWSHOST; if not set, default from Net::Config; if not
set, "news" is used).

=item B<NNTPUser> = I<user name> (optional)

User name used for authentication with the NNTP server (I<AUTHINFO
USER>).

This setting is optional; if it is not set, I<NNTPPass> is ignored and
no authentication is tried.

=item B<NNTPPass> = I<password> (optional)

Password used for authentication with the NNTP server (I<AUTHINFO
PASS>).

This setting is optional; it must be set if I<NNTPUser> is present.

=item B<Sender> = I<Sender header> (optional)

The Sender header that will be added to every posted message.

This setting is optional.

=item B<ConfigFile> = I<configuration file> (mandatory)

The configuration file defining the FAQ(s) to post. Must be set (or
omitted; the default is "yapfaq.cfg").

=item B<UsePGP> = I<whether to add a digital signature> (optional)

Boolean value (0 or 1) controlling whether the FAQs will get digitally
signed via an X-PGP-Sig header.

This setting is optional; the default is 0.

If you have set I<UsePGP> to 1, you must also supply the necessary
information on your PGP oder GPG installation; please refer to the
sample F<.yapfaqrc> file (see below) for more information on this
topic.

=back

=head3 Example runtime configuration file

    NNTPServer = 'localhost'
    NNTPUser   = ''
    NNTPPass   = ''
    Sender     = ''
    ConfigFile = 'yapfaq.cfg'
    UsePGP     = 0

    ################################## PGP-Config #################################
    pgp        = '/usr/bin/pgp'                  # path to pgp
    PGPVersion = '2'                             # Use 2 for 2.X 5 for PGP > 2.X and GPG for GPG
    PGPSigner  = ''                              # sign as who?
    PGPPass    = ''                              # pgp2 only
    PathtoPGPPass = ''                           # pgp2 pgp5 and gpg
    pgpbegin   = '-----BEGIN PGP SIGNATURE-----' # Begin of PGP-Signature
    pgpend     = '-----END PGP SIGNATURE-----'   # End of PGP-Signature
    pgptmpf    = 'pgptmp'                        # temporary file for PGP.
    pgpheader  = 'X-PGP-Sig'

=head3 Using more than one runtime configuration

You may use more than one runtime configuration file with the B<-c>
option (see below).

=head1 OPTIONS

=over 3

=item B<-V> (version)

Print out version and copyright information on B<yapfaq> and exit.

=item B<-h> (help)

Print this man page and exit.

=item B<-v> (verbose)

Print out status information while running to STDOUT.

=item B<-p> (post unconditionally)

Post (all) FAQs unconditionally ignoring the posting frequency setting.

You may want to use this with the B<-f> option (see below).

=item B<-d> (dry run)

Start B<yapfaq> in simulation mode, i.e. don't post anything and don't
update any status information.

=item B<-t> I<newsgroup(s) | CONSOLE> (test)

Don't post to the newsgroups defined in F<yqpfaq.cfg>, but to the
newsgroups given after B<-t> as a comma-separated list or print the
FAQs to STDOUT separated by lines of dashes if the special string
C<CONSOLE> is given.  This can be used to preview what B<yapfaq> would
do without embarassing yourself on Usenet.  The status files are not
updated when this option is given.

You may want to use this with the B<-f> option (see below).

=item B<-f> I<project name>

Just deal with one FAQ only.

By default B<yapfaq> will work on all FAQs that are defined in
F<yapfaq.cfg>, check whether they are due for posting and - if they
are - post them. Consequently when the B<-p> option is set all FAQs
will be posted unconditionally. That may not be what you want to
achieve, so you can limit the operation of B<yapfaq> to the named FAQ
only.

=item B<-s> I<program> (pipe to script)

Instead of posting the article(s) to Usenet pipe them to the external
I<program> on STDIN (which may post the article(s) then). A return
value of 0 will be considered success.

=item B<-c> I<.rc file>

Load another runtime configuration file (.rc file) than F<.yaofaq.rc>.

You may for example define another usenet server to post your FAQ(s)
to or load another configuration file defining (an)other FAQ(s).

=back

=head1 EXAMPLES

Post all FAQs that are due for posting:

    yapfaq

Do a dry run, showing which FAQs would be posted:

    yapfaq -dv

Do a test run and print on STDOUT what the FAQ I<myfaq> would look
like when posted, regardless whether it is due for posting or not:

    yapfaq -pt CONSOLE -f myfaq

Do a "real" test run and post the FAQ I<myfaq> to I<de.test>, but only
if it is due:

    yapfaq -t de.test -f myfaq

Post all FAQs (that are due for posting) using inews from INN:

    yapfaq -s inews

Do a dry run using a runtime configuration from .alternaterc, showing
which FAQs would be posted:

    yapfaq -dvc .alternaterc

=head1 ENVIRONMENT

=over 4

=item NNTPSERVER

The default NNTP server to post to, used by the Net::NNTP module. You
can also  specify the server using the runtime configuration file (by
default F<.yapfaqrc>).

=back

=head1 FILES

=over 4

=item F<yapfaq.pl>

The script itself.

=item F<.yapfaqrc>

Runtime configuration file for B<yapfaq>.

=item F<yapfaq.cfg>

Configuration file for B<yapfaq>.

=item F<*.cfg>

Status data on FAQs.

The status files will be created on successful posting if they don't
already exist. The first line of the file will be the date of the last
time the FAQ was posted and the second line will be the message ID of
the last post of that FAQ.

=back

=head1 BUGS

Many, I'm sure.

=head1 SEE ALSO

L<http://th-h.de/download/scripts.php> will have the current
version of this program.

=head1 AUTHOR

Thomas Hochstein <thh@inter.net>

Original author (up to version 0.5b, dating from 2003):
Marc Brockschmidt <marc@marcbrockschmidt.de>

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2003 Marc Brockschmidt <marc@marcbrockschmidt.de>

Copyright (c) 2010 Thomas Hochstein <thh@inter.net>

This program is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=cut
