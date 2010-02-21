#! /usr/bin/perl -W
#
# yapfaq Version 0.5b by Marc 'HE' Brockschmidt
#
# This script posts any project described in it's config-file. Most persons
# will use it in combination with cron(8).
# 
# Copyright (C) 2003 Marc Brockschmidt <marc@marcbrockschmidt.de>
#
# It can be redistributed and/or modified under the same terms under 
# which Perl itself is published.

my $Version = "0.5b";

my $NNTPServer = "";
my $NNTPUser = "";
my $NNTPPass = "";
my $Sender = "";
my $ConfigFile = "yapfaq.cfg";
my $UsePGP = 0;

################################## PGP-Config #################################

my $pgp	          = '/usr/bin/pgp';            # path to pgp
my $PGPVersion    = '2';                       # Use 2 for 2.X, 5 for PGP > 2.X and GPG for GPG

my $PGPSigner     = '';                        # sign as who?
my $PGPPass       = '';                        # pgp2 only
my $PathtoPGPPass = '';	                       # pgp2, pgp5 and gpg


my $pgpbegin  ='-----BEGIN PGP SIGNATURE-----';# Begin of PGP-Signature
my $pgpend    ='-----END PGP SIGNATURE-----';  # End of PGP-Signature
my $pgptmpf   ='pgptmp';                       # temporary file for PGP.
my $pgpheader ='X-PGP-Sig';

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
use Date::Calc qw(Add_Delta_YM Add_Delta_Days Delta_Days Today);
use Fcntl ':flock'; # import LOCK_* constants
my ($TDY, $TDM, $TDD) = Today(); #TD: Today's date

my @Config;
readconfig (\$ConfigFile, \@Config);

foreach (@Config) { 
  my ($LPD,$LPM,$LPY) = (01, 01, 0001);  #LP: Last posting-date
  my ($NPY,$NPM,$NPD);                   #NP: Next posting-date
  my $SupersedeMID;
  
  my ($ActName,$File,$PFreq) =($$_{'name'},$$_{'file'},$$_{'posting-frequency'});
  my ($From,$Subject,$NG,$Fup2)=($$_{'from'},$$_{'subject'},$$_{'ngs'},$$_{'fup2'});
  my ($MIDF,$ReplyTo,$ExtHea)=($$_{'mid-format'},$$_{'reply-to'},$$_{'extraheader'});
  my ($Supersede)            =($$_{'supersede'});
    
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
    warn "Couldn't open $File.cfg: $!";
  }

  $SupersedeMID = "" unless $Supersede;

  if ($PFreq =~ /(\d+)\s*([dw])/) { # Is counted in days or weeks: Use Add_Delta_Days.
    ($NPY,$NPM,$NPD) = Add_Delta_Days($LPY, $LPM, $LPD, (($2 eq "w")?$1 * 7: $1 * 1));
  } elsif ($PFreq =~ /(\d+)\s*([my])/) { #Is counted in months or years: Use Add_Delta_YM
    ($NPY,$NPM,$NPD) = Add_Delta_YM($LPY, $LPM, $LPD, (($2 eq "m")?(0,$1):($1,0)));
  }
    
  if (Delta_Days($NPY,$NPM,$NPD,$TDY,$TDM,$TDD) >= 0 ) {
    postfaq(\$ActName,\$File,\$From,\$Subject,\$NG,\$Fup2,\$MIDF,\$ExtHea,\$Sender,\$TDY,\$TDM,\$TDD,\$ReplyTo,\$SupersedeMID);
  }
}

exit;

################################## readconfig ##################################
# Takes a filename and the reference to an array, which will hold hashes with
# the data from $File.

sub readconfig{
  my ($File, $Config) = @_;
  my ($LastEntry, $Error, $i) = ('','',0);

  open FH, "<$$File" or die "$0: Can't open $$File: $!";
  while (<FH>) {
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
    unless($$Config[$i]{'from'} =~ /\S+\@(\S+\.)?\S{2,}\.\S{2,}/) {
      $Error .= "The From-header for your project \"$$Config[$i]{'name'}\" seems to be incorrect.\n"
    }
    unless($$Config[$i]{'ngs'} =~ /^\S+$/) {
      $Error .= "The Newsgroups-header for your project \"$$Config[$i]{'name'}\" contains whitespaces.\n"
    }
    unless(!$$Config[$i]{'fup2'} || $$Config[$i]{'fup2'} =~ /^\S+$/) {
      $Error .= "The Followup-To-header for your project \"$$Config[$i]{'name'}\" contains whitespaces.\n"
    }
    unless($$Config[$i]{'posting-frequency'} =~ /^\s*\d+\s*[dwmy]\s*$/) {
      $Error .= "The Posting-frequency for your project \"$$Config[$i]{'name'}\" is invalid.\n"
    }
    $Error .= "-" x 25 . "\n" if $Error;
  }
  die $Error if $Error;
}

################################## postfaq ##################################
# Takes a filename and many other vars.
#
# It reads the data-file $File and then posts the article.

sub postfaq {
  my ($ActName,$File,$From,$Subject,$NG,$Fup2,$MIDF,$ExtraHeaders,$Sender,$TDY,$TDM,$TDD,$ReplyTo,$Supersedes) = @_;
  my (@Header,@Body,$MID,$InRealBody,$LastModified);

  #Prepare MID:
  $$TDM = ($$TDM < 10 && $$TDM !~ /^0/) ? "0" . $$TDM : $$TDM;
  $$TDD = ($$TDD < 10 && $$TDD !~ /^0/) ? "0" . $$TDD : $$TDD;

  $MID = $$MIDF;
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
  
  my ($expY,$expM,$expD) = Add_Delta_YM($year, $month, $day, 0, 3);
  my $expmonthN = ("Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec")[$expM-1];

  my $date = "$day $monthN $year " . $hh . ":" . $mm . ":" . $ss . $tz;
  my $expdate = "$expD $expmonthN $expY $hh:$mm:$ss$tz";

  #Replace %LM by the content of the news.answer-pseudo-header Last-modified:
  if ($LastModified) {
    $$Subject =~ s/\%LM/$LastModified/;
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

  my @Article = ($UsePGP)?@{signpgp(\@Header, \@Body)}:(@Header, "\n", @Body);
  
  post(\@Article);

  open (FH, ">$$File.cfg") or die "$0: Can't open $$File.cfg: $!";
  print FH "##;; Lastpost: $day.$month.$year\n";
  print FH "##;; LastMID: $MID\n";
  close FH;
}

################################## post ##################################
# Takes a complete article (Header and Body).
#
# It opens a connection to $NNTPServer and posts the message.

sub post {
  my ($ArticleR) = @_;

  my $NewsConnection = Net::NNTP->new($NNTPServer, Reader => 1)
    or die "Can't connect to news server $NNTPServer!\n";

  $NewsConnection->authinfo ($NNTPUser, $NNTPPass);
  $NewsConnection->post();
  $NewsConnection->datasend (@$ArticleR);
  $NewsConnection->dataend();

  if (!$NewsConnection->ok()) {
    open FH, ">>ERROR.dat";
    print FH "\nPosting failed!  Response from news server:\n";
    print FH $NewsConnection->code();
    print FH $NewsConnection->message();
    print FH "\n";
    print FH @$ArticleR;
    print FH "-" x 80, "\n";
    close FH;
  }

  $NewsConnection->quit();
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
    if ($PathtoPGPPass && !$PGPPass) {
      open (PGPPW, $PathtoPGPPass) or die "Can't open $PathtoPGPPass: $!";
      $PGPPass = <PGPPW>;
      close PGPPW;
    }
  
    if ($PGPPass) {
      $PGPCommand = "PGPPASS=\"".$PGPPass."\" ".$pgp." -u \"".$PGPSigner."\" +verbose=0 language='en' -saft <".$pgptmpf.".txt >".$pgptmpf.".txt.asc";
    } else {
      die "$0: PGP-Passphrase is unknown!\n";
    }
  } elsif ($PGPVersion eq '5') {
    if ($PathtoPGPPass) {
      $PGPCommand = "PGPPASSFD=2 ".$pgp."s -u \"".$PGPSigner."\" -t --armor -o ".$pgptmpf.".txt.asc -z -f < ".$pgptmpf.".txt 2<".$PathtoPGPPass;
    } else {
      die "$0: PGP-Passphrase is unknown!\n";
    }
  } elsif ($PGPVersion =~ m/GPG/io) {
    if ($PathtoPGPPass) {
      $PGPCommand = $pgp." --digest-algo MD5 -a -u \"".$PGPSigner."\" -o ".$pgptmpf.".txt.asc --no-tty --batch --passphrase-fd 2 2<".$PathtoPGPPass." --clearsign ".$pgptmpf.".txt";
    } else {
      die "$0: Passphrase is unknown!\n";
    }
  } else {
    die "$0: Unknown PGP-Version $PGPVersion!";
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
  unlink "$pgptmpf.txt";
  unlink "$pgptmpf.txt.asc";
  $signheaders = join(",", @signheaders);

  $pgphead = "X-Signed-Headers: $signheaders\n";
  foreach $header (@signheaders) {
    if ($$HeaderR{lc($header)} =~ m/^[^\s:]+: (.+?)\n?$/so) {
      $pgphead .= $header.": ".$1."\n";
    }
  }

  open(FH, ">" . $pgptmpf . ".txt") or die "$0: can't open $pgptmpf: $!\n";
  print FH $pgphead, "\n", $pgpbody;
  print FH "\n" if ($PGPVersion =~ m/GPG/io);	# workaround a pgp/gpg incompatibility - should IMHO be fixed in pgpverify
  close(FH) or warn "$0: Couldn't close TMP: $!\n";

  # Start PGP, then read the signature;
  my $PGPCommand = getpgpcommand($PGPVersion);
  `$PGPCommand`;

  open (FH, "<" . $pgptmpf . ".txt.asc") or die "$0: can't open ".$pgptmpf.".txt.asc: $!\n";
  $/ = "$pgpbegin\n";
  $_ = <FH>;
  unless (m/\Q$pgpbegin\E$/o) {
#    unlink $pgptmpf . ".txt";
#    unlink $pgptmpf . ".txt.asc";
    die "$0: $pgpbegin not found in ".$pgptmpf.".txt.asc\n"
  }
  unlink($pgptmpf . ".txt") or warn "$0: Couldn't unlink $pgptmpf.txt: $!\n";

  $/ = "\n";
  $_ = <FH>;
  unless (m/^Version: (\S+)(?:\s(\S+))?/o) {
    unlink $pgptmpf . ".txt";
    unlink $pgptmpf . ".txt.asc";
    die "$0: didn't find PGP Version line where expected.\n";
  }
  
  if (defined($2)) {
    $$HeaderR{$pgpheader} = $1."-".$2." ".$signheaders;
  } else {
    $$HeaderR{$pgpheader} = $1." ".$signheaders;
  }
  
  do {          # skip other pgp headers like
    $_ = <FH>;  # "charset:"||"comment:" until empty line
  } while ! /^$/;

  while (<FH>) {
    chomp;
    last if /^\Q$pgpend\E$/;
    $$HeaderR{$pgpheader} .= "\n\t$_";
  }
  
  $$HeaderR{$pgpheader} .= "\n" unless ($$HeaderR{$pgpheader} =~ /\n$/s);

  $_ = <FH>;
  unless (eof(FH)) {
    unlink $pgptmpf . ".txt";
    unlink $pgptmpf . ".txt.asc";
    die "$0: unexpected data following $pgpend\n";
  }
  close(FH);
  unlink "$pgptmpf.txt.asc";

  my $tmppgpheader = $pgpheader . ": " . $$HeaderR{$pgpheader};
  delete $$HeaderR{$pgpheader};

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

  push @pgphead, ("X-PGP-Key: " . $PGPSigner . "\n"), $tmppgpheader;
  undef $tmppgpheader;

  @pgpbody = split /$/m, $pgpbody;
  my @pgpmessage = (@pgphead, "\n", @pgpbody);
  return \@pgpmessage;
}
