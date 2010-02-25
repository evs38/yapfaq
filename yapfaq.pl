#! /usr/bin/perl -W
#
# yapfaq Version 0.6 by Thomas Hochstein
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

my $Version = "0.6-unreleased";

my $NNTPServer = "localhost";
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
use Getopt::Std;
my ($TDY, $TDM, $TDD) = Today(); #TD: Today's date

my %Options;
getopts('hvpdt:f:', \%Options);
if ($Options{'h'}) {
  print "$0 v $Version\nUsage: $0 [-hvpd] [-t <newsgroups>] [-f <faq>]\n";
  exit(0);
};
my ($Faq) = $Options{'f'} if ($Options{'f'});

my @Config;
readconfig (\$ConfigFile, \@Config, \$Faq);

foreach (@Config) { 
  my ($LPD,$LPM,$LPY) = (01, 01, 0001);  #LP: Last posting-date
  my ($NPY,$NPM,$NPD);                   #NP: Next posting-date
  my $SupersedeMID;
  
  my ($ActName,$File,$PFreq,$Expire) =($$_{'name'},$$_{'file'},$$_{'posting-frequency'},$$_{'expires'});
  my ($From,$Subject,$NG,$Fup2)=($$_{'from'},$$_{'subject'},$$_{'ngs'},$$_{'fup2'});
  my ($MIDF,$ReplyTo,$ExtHea)=($$_{'mid-format'},$$_{'reply-to'},$$_{'extraheader'});
  my ($Supersede)            =($$_{'supersede'});

  next if (defined($Faq) && $ActName ne $Faq);
	
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

  if (Delta_Days($NPY,$NPM,$NPD,$TDY,$TDM,$TDD) >= 0 or ($Options{'p'})) {
    if($Options{'d'}) {
	  print "$ActName: Would be posted now (but running in simulation mode [$0 -d]).\n" if $Options{'v'};
	} else {
      postfaq(\$ActName,\$File,\$From,\$Subject,\$NG,\$Fup2,\$MIDF,\$ExtHea,\$Sender,\$TDY,\$TDM,\$TDD,\$ReplyTo,\$SupersedeMID,\$Expire);
	}
  } elsif($Options{'v'}) {
    print "$ActName: Nothing to do.\n";
  }
}

exit;

################################## readconfig ##################################
# Takes a filename, a reference to an array, which will hold hashes with
# the data from $File, and - optionally - the name of the (single) FAQ to post

sub readconfig{
  my ($File, $Config, $Faq) = @_;
  my ($LastEntry, $Error, $i) = ('','',0);

  if($Options{'v'}) {
    print "Reading configuration.\n";
  }

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
    unless($$Config[$i]{'from'} =~ /\S+\@(\S+\.)?\S{2,}\.\S{2,}/) {
      $Error .= "E: The From-header for your project \"$$Config[$i]{'name'}\" seems to be incorrect.\n"
    }
    unless($$Config[$i]{'ngs'} =~ /^\S+$/) {
      $Error .= "E: The Newsgroups-header for your project \"$$Config[$i]{'name'}\" contains whitespaces.\n"
    }
    unless(!$$Config[$i]{'fup2'} || $$Config[$i]{'fup2'} =~ /^\S+$/) {
      $Error .= "E: The Followup-To-header for your project \"$$Config[$i]{'name'}\" contains whitespaces.\n"
    }
    unless($$Config[$i]{'posting-frequency'} =~ /^\s*\d+\s*[dwmy]\s*$/) {
      $Error .= "E: The Posting-frequency for your project \"$$Config[$i]{'name'}\" is invalid.\n"
    }
    unless($$Config[$i]{'expires'} =~ /^\s*\d+\s*[dwmy]\s*$/) {
      $$Config[$i]{'expires'} = '3m'; # set default: 3 month
	  warn "$0: W: The Expires for your project \"$$Config[$i]{'name'}\" is invalid - set to 3 month.\n";
    }
    $Error .= "-" x 25 . "\n" if $Error;
  }
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
  
################################## postfaq ##################################
# Takes a filename and many other vars.
#
# It reads the data-file $File and then posts the article.

sub postfaq {
  my ($ActName,$File,$From,$Subject,$NG,$Fup2,$MIDF,$ExtraHeaders,$Sender,$TDY,$TDM,$TDD,$ReplyTo,$Supersedes,$Expire) = @_;
  my (@Header,@Body,$MID,$InRealBody,$LastModified);

  if($Options{'v'}) {
    print "$$ActName: Preparing to post.\n";
  }
  
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

  my @Article = ($UsePGP)?@{signpgp(\@Header, \@Body)}:(@Header, "\n", @Body);
  
  if($Options{'v'}) {
    print "$$ActName: Posting article ...\n";
  }
  post(\@Article);

  if($Options{'v'}) {
    print "$$ActName: Save status information.\n";
  }

  open (FH, ">$$File.cfg") or die "$0: E: Can't open $$File.cfg: $!";
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

  # Test mode?
  if(defined($Options{'t'}) and $Options{'t'} =~ /console/i) {
    print "\n-----BEGIN--------------------------------------------------\n";
	print @$ArticleR;
    print "\n------END---------------------------------------------------\n";
	return;
  }

  my $NewsConnection = Net::NNTP->new($NNTPServer, Reader => 1)
    or die "$0: E: Can't connect to news server '$NNTPServer'!\n";

  $NewsConnection->authinfo ($NNTPUser, $NNTPPass);
  $NewsConnection->post();
  $NewsConnection->datasend (@$ArticleR);
  $NewsConnection->dataend();

  if (!$NewsConnection->ok()) {
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
      open (PGPPW, $PathtoPGPPass) or die "$0: E: Can't open $PathtoPGPPass: $!";
      $PGPPass = <PGPPW>;
      close PGPPW;
    }
  
    if ($PGPPass) {
      $PGPCommand = "PGPPASS=\"".$PGPPass."\" ".$pgp." -u \"".$PGPSigner."\" +verbose=0 language='en' -saft <".$pgptmpf.".txt >".$pgptmpf.".txt.asc";
    } else {
      die "$0: E: PGP-Passphrase is unknown!\n";
    }
  } elsif ($PGPVersion eq '5') {
    if ($PathtoPGPPass) {
      $PGPCommand = "PGPPASSFD=2 ".$pgp."s -u \"".$PGPSigner."\" -t --armor -o ".$pgptmpf.".txt.asc -z -f < ".$pgptmpf.".txt 2<".$PathtoPGPPass;
    } else {
      die "$0: E: PGP-Passphrase is unknown!\n";
    }
  } elsif ($PGPVersion =~ m/GPG/io) {
    if ($PathtoPGPPass) {
      $PGPCommand = $pgp." --digest-algo MD5 -a -u \"".$PGPSigner."\" -o ".$pgptmpf.".txt.asc --no-tty --batch --passphrase-fd 2 2<".$PathtoPGPPass." --clearsign ".$pgptmpf.".txt";
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
  unlink "$pgptmpf.txt";
  unlink "$pgptmpf.txt.asc";
  $signheaders = join(",", @signheaders);

  $pgphead = "X-Signed-Headers: $signheaders\n";
  foreach $header (@signheaders) {
    if ($$HeaderR{lc($header)} =~ m/^[^\s:]+: (.+?)\n?$/so) {
      $pgphead .= $header.": ".$1."\n";
    }
  }

  open(FH, ">" . $pgptmpf . ".txt") or die "$0: E: can't open $pgptmpf: $!\n";
  print FH $pgphead, "\n", $pgpbody;
  print FH "\n" if ($PGPVersion =~ m/GPG/io);	# workaround a pgp/gpg incompatibility - should IMHO be fixed in pgpverify
  close(FH) or warn "$0: W: Couldn't close TMP: $!\n";

  # Start PGP, then read the signature;
  my $PGPCommand = getpgpcommand($PGPVersion);
  `$PGPCommand`;

  open (FH, "<" . $pgptmpf . ".txt.asc") or die "$0: E: can't open ".$pgptmpf.".txt.asc: $!\n";
  $/ = "$pgpbegin\n";
  $_ = <FH>;
  unless (m/\Q$pgpbegin\E$/o) {
#    unlink $pgptmpf . ".txt";
#    unlink $pgptmpf . ".txt.asc";
    die "$0: E: $pgpbegin not found in ".$pgptmpf.".txt.asc\n"
  }
  unlink($pgptmpf . ".txt") or warn "$0: W: Couldn't unlink $pgptmpf.txt: $!\n";

  $/ = "\n";
  $_ = <FH>;
  unless (m/^Version: (\S+)(?:\s(\S+))?/o) {
    unlink $pgptmpf . ".txt";
    unlink $pgptmpf . ".txt.asc";
    die "$0: E: didn't find PGP Version line where expected.\n";
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
    die "$0: E: unexpected data following $pgpend\n";
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

__END__

################################ Documentation #################################

=head1 NAME

yapfaq - Post Usenet FAQs I<(yet another postfaq)>

=head1 SYNOPSIS

B<yapfaq> [B<-hvpd>] [B<-t> I<newsgroups> | CONSOLE] [B<-f> I<project name>]

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
of definitions in the form of I<param = value>.

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

=item B<Expires> = I<time period>

The period of time after which your message will expire. An Expires
header will be calculated adding this time period to today's date.

You can declare this  time period either in I<B<d>ays> or I<B<w>weeks>
or I<B<m>onths> or I<B<y>ears>.

This setting is optional; the default  is 3 months.

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

=item B<Fup2> = I<newsgroup | poster>

A comma-separated list of newsgroup(s) or the special string I<poster>
as it will appear in the Followup-To header of the message.

This setting is optional.

=item B<MID-Format> = I<pattern>

A pattern from which the message ID is generated as it will appear in
the Message-ID header of the message.

You may use the special strings C<%n> for the I<Name> of your project,
C<%d> for the date the message is posted, C<%m> for the month and
C<%y> for the year, respectively.

This value must be set.

=item B<Supersede> = I<yes>

Add Supersedes header to the message containing the Message-ID header
of the last posting.

This setting is optional; you should set it to yes or leave it out.

=item B<ExtraHeader> = I<additional headers>

The contents of I<ExtraHeader> is added verbatim to the headers of
your message so you can add custom headers like Approved.

This setting is optional.

=back

=head2 Example configuration file

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
    Expires = '3m'
    
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
    Fup2 = 'poster'
    
    # Message-ID ("%n" is $Name)
    MID-Format = '<%n-%d.%m.%y@domain.invalid>'
    
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

Information about the last post and about how to form message IDs for
posts is stored in a file named F<I<project name>.cfg> which will be
generated if it does not exist. Each of those status files will
contain two lines, the first being the date of the last time the FAQ
was posted and the second being the message ID of that incarnation.

=head1 OPTIONS

=over 3

=item B<-h> (help)

Print out version and usage information on B<yapfaq> and exit.

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

=head1 ENVIRONMENT

There are no special environment variables used by B<yapfaq>.

=head1 FILES

=over 4

=item F<yapfaq.pl>

The script itself.

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

Original author (until version 0.5b from 2003):
Marc Brockschmidt <marc@marcbrockschmidt.de>


=head1 COPYRIGHT AND LICENSE

Copyright (c) 2003 Marc Brockschmidt <marc@marcbrockschmidt.de>

Copyright (c) 2010 Thomas Hochstein <thh@inter.net>

This program is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=cut
