#!/bin/bash

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
export PATH

VERSION="0.9.4"
RELEASE_DATE="2011-12-06"

LC_ALL=POSIX

if [[ ! $(uname) =~ Linux ]]; then
  echo "This is version only for linux. Please install appropriate version from ftp://ftp.ovh.net/made-in-ovh/rtm/";
  exit 1;
fi

DIR="/usr/local/rtm"
DIR_SCRIPTS_DAILY="${DIR}/scripts/daily"
DIR_SCRIPTS_MIN="${DIR}/scripts/min"
DIR_SCRIPTS_HOUR="${DIR}/scripts/hour"
HDDTEMPDB_LINK="ftp://ftp.ovh.net/made-in-ovh/rtm/hddtemp.db"
HDDTEMP_LINK="ftp://ftp.ovh.net/made-in-ovh/rtm/hddtemp-0.3-beta12.tar.bz2"
DMIDECODE_LINK="ftp://ftp.ovh.net/made-in-ovh/rtm/dmidecode-2.4.tar.gz"
SLACK_HDDTEMP_LINK="ftp://ftp.ovh.net/made-in-ovh/rtm/utils/slackware/hddtemp"
SLACK_DMIDECODE_LINK="ftp://ftp.ovh.net/made-in-ovh/rtm/utils/slackware/dmidecode"
LSIUTIL_LINK="ftp://ftp.ovh.net/made-in-ovh/dedie/lsiutil"
DNSSERVER="213.186.33.99"
SCRIPTS_TO_INSTALL="check kernel release usage usage_root hwinfo hwinfo_root hddinfo smart raid raid_daily listen_ports"

RTM_PL=$DIR/bin/rtm-${VERSION}.pl
RTM_SH=$DIR/bin/rtm
RTM_UPDATE_IP=$DIR/bin/rtm-update-ip.sh

RTM_REPORT=$DIR/bin/update-report.pl

LSPCI=`which lspci 2>/dev/null`
CRONTAB=`which crontab 2>/dev/null`
SCREENDIR=`which screen 2>/dev/null`
if [ "$SCREENDIR" != "" ]; then SCREEN="$SCREENDIR -d -m"; fi
SCRIPTDIR="$DIR/scripts"
MPTSTATUS=`which mpt-status 2>/dev/null`
LSIUTIL=`which lsiutil 2>/dev/null`
HDDTEMP=`which hddtemp 2>/dev/null`
DMIDECODE=`which dmidecode 2>/dev/null`


# 
# Generate update-report.pl file
function generate_update_report {
    echo "Generating update-report.pl..."
    cat << EOF > $RTM_REPORT
#! /usr/bin/perl
# version: $VERSION ($RELEASE_DATE)

\$ENV{"LC_ALL"} = "POSIX";

EOF
    cat <<'EOF' >> $RTM_REPORT
#!/usr/bin/perl

use strict;
use Socket;

EOF
    echo "my \$destination_ip = '$ip';" >> $RTM_REPORT
    cat <<'EOF' >> $RTM_REPORT
my $message = <>;
chomp($message);
exit if ($message eq '');

send_info($message);

sub send_info {
    my $message = shift;
    $message = "rtm dINFO_RTM_update|$message\n";
    my $port = 6100 + int(rand(100));
    my $ok = eval {
        local $SIG{ALRM} = sub { print "rtm timeout\n"; die; };
        alarm(10);

        my $proto = getprotobyname('udp');
        socket(Socket_Handle, PF_INET, SOCK_DGRAM, $proto);
        my $iaddr = gethostbyname($destination_ip);
        my $sin = sockaddr_in("$port", $iaddr);
        send(Socket_Handle, "$message", 10, $sin);
        print "$message";
        alarm(0);
    };
    if (!defined($ok)) {
        warn "error: $@\n";
    }
}
EOF
    chown root.root "$RTM_REPORT"
    chmod 750 "$RTM_REPORT"
}

# check if script dirs point to reasonable paths
for scr in "$DIR_SCRIPTS_DAILY", "$DIR_SCRIPTS_MIN", "$DIR_SCRIPTS_HOUR"; do
    if ! echo "$scr" | grep -q '^/usr/local/'; then
        echo "invalid script directory: $scr" >&2
        exit 1
    fi
done
# Remove old scripts dirs so there are no unwanted scripts hanging
# around
rm -rf "$DIR_SCRIPTS_DAILY"
rm -rf "$DIR_SCRIPTS_MIN"
rm -rf "$DIR_SCRIPTS_HOUR"

if [ ! -e "$DIR" ]; then mkdir -p $DIR; fi
if [ ! -e "$DIR_SCRIPTS_DAILY" ]; then mkdir -p "$DIR_SCRIPTS_DAILY"; fi
if [ ! -e "$DIR_SCRIPTS_MIN" ]; then mkdir -p "$DIR_SCRIPTS_MIN"; fi
if [ ! -e "$DIR_SCRIPTS_HOUR" ]; then mkdir -p "$DIR_SCRIPTS_HOUR"; fi
if [ ! -e "$DIR/bin" ]; then mkdir -p "$DIR/bin"; fi
if [ ! -e "$DIR/etc" ]; then mkdir -p "$DIR/etc"; fi

if [ ! -d "/usr/local/man/" ]; then mkdir -p  "/usr/local/man/"; fi

# main interface from route:
mainif=`route -n | grep "^0.0.0.0" | awk '{print $8}' | tail -1`

if test -n "$mainif"; then
  ips=`ifconfig $mainif | awk 'NR == 2 { print $2 }' | cut -f2 -d':' | egrep '[0-9]+(\.[0-9]+){3}'`
else
  for iface in 'eth0' 'eth1'; do
    ips=`ifconfig $iface 2>/dev/null | awk 'NR == 2 { print $2 }' | cut -f2 -d':' | egrep '[0-9]+(\.[0-9]+){3}'`
    if test -n "$ips"; then break; fi;
  done;
fi;

arpa=`echo "$ips" | sed "s/\./ /g" | awk '{print $3"."$2"."$1}'`;
ip=`host -t A mrtg.$arpa.in-addr.arpa $DNSSERVER 2>/dev/null | tail -n 1 | sed -ne 's/.*[\t ]\([0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p'`
if [ -z "$ip" ]; then
  echo "No IP from OVH network or couldn't define MRTG server! Please contact OVH support."
  exit 1;
fi
echo $ip > "$DIR/etc/rtm-ip"


upgrade=$1
if [ "$upgrade" != "-u" ]; then
  if [ -z "$HDDTEMP" -o -z "$DMIDECODE" ]; then
    upgrade=""
  fi
fi

if [ -z "`which bzip2 2>/dev/null`" ]; then
  echo "bzip2 not found!!"
  echo "Please install bzip2."
  exit
fi


hostname=`hostname`
CWD=`pwd`

if [ "$update" != "-u" ]; then
  mkdir -p /rpms /usr/share/misc/

  # ###########################################
  # hddtemp check and compile/install:
  # ###########################################
  wget $HDDTEMPDB_LINK -O /usr/share/misc/hddtemp.db
  v=`hddtemp --version 2>/dev/null | cut -d' ' -f3`
  hddtempbeta=`echo $v | grep beta`
  if test "$hddtempbeta" != ""; then hddtempbeta='-beta'; fi;
  v=`echo $v | sed 's/-beta/ /'`
  hddtempmajor=`echo $v | cut -d' ' -f1`
  hddtempminor=`echo $v | cut -d' ' -f2`
  hddtempinstall=0

  if test "$hddtempbeta" == ""; then
    hddtempinstall=1
  else
    if test "$hddtempmajor" == ""; then
      hddtempinstall=1
    else
      echo "Found hddtemp version installed: ${hddtempmajor}${hddtempbeta}$hddtempminor. No new install needed."
    fi
  fi
  
  if test $hddtempinstall -ne 1; then
    if test "$hddtempmajor" == "0.3"; then
      case `echo "r=0;a=$hddtempmajor;b=0.3;if(a<b)r=1;r"|bc` in
        1) hddtempinstall=1
        ;;
      esac
    else
      case `echo "r=0;a=$hddtempmajor;b=0.3;if(a<b)r=1;r"|bc` in
        1) hddtempinstall=1
        ;;
      esac
    fi
  fi

  if test $hddtempinstall -eq 1; then
    if [ -f "/etc/slackware-version" ]; then
      wget $SLACK_HDDTEMP_LINK -O /usr/local/sbin/hddtemp
      chmod +x /usr/local/sbin/hddtemp
    else
      # compile and install:
      cd /rpms && \
      wget $HDDTEMP_LINK -O /rpms/hddtemp-0.3-beta12.tar.bz2 && \
      tar -xjf hddtemp-0.3-beta12.tar.bz2 && \
      cd hddtemp-0.3-beta12 && \
      ./configure && \
      make && \
      make install && \
      echo "hddtemp compilation and installation finished successfull."
    fi
  fi

  HDDTEMP=`which hddtemp 2>/dev/null`

  # ###########################################
  # dmidecode check and install if needed
  # ###########################################

  # check if version >= 2.4
  dmiver=`dmidecode --version 2>/dev/null`
  if test "$dmiver" == ""; then # for version 2.4:
    dmiver=`dmidecode | head -n1 | grep "# dmidecode" | cut -d' ' -f3 2>/dev/null`
  fi
  if test $? = 0; then
    case `echo "r=0;a=$dmiver;b=2.4;if(a<b)r=1;r" | bc` in
      0) echo "Found dmidecode v.$dmiver"
      ;;
      1) if [ -f "/etc/slackware-version" ]; then
           wget $SLACK_DMIDECODE_LINK -O /usr/local/sbin/dmidecode
           chmod +x /usr/local/sbin/dmidecode
         else
           cd /rpms/
           wget $DMIDECODE_LINK -O dmidecode-2.4.tar.gz
           tar xfz dmidecode-2.4.tar.gz
           cd dmidecode-2.4
           make
           make install
         fi
      ;;                                                                                                                                                                                                                                     
    esac
  fi

  DMIDECODE=`which dmidecode 2>/dev/null`

fi

echo "Checking for lsiutil ..."
if [ -z "$LSIUTIL" ]; then
  if [ -n "$LSPCI" -a "$LSPCI" ]; then
    PCIONBOARD=`$LSPCI -d 1000:`
  fi
  if [ -n "$PCIONBOARD" ]; then
    echo "Installing lsi-util ...";
    wget $LSIUTIL_LINK -O /usr/local/rtm/bin/lsiutil
    chmod 700 /usr/local/rtm/bin/lsiutil
  fi
fi

echo "Checking for mpt-status ..."
if [ -z "$MPTSTATUS" ]; then
  MPTADAPTERS=`cat /var/log/dmesg /var/log/boot.msg 2>/dev/null | grep "MPT" | grep "mptbase:" | cut -f2 -d" "`
  if [ -n "$MPTADAPTERS" -a "$MPTADAPTERS" != "0" ]; then
    echo "Installing mpt-status ...";
    wget ftp://ftp.ovh.net/made-in-ovh/dedie/mpt-status -O /usr/sbin/mpt-status
    chmod 700 /usr/sbin/mpt-status
  fi
fi

cd $CWD

# 
# Generate /scripts/min/check.pl file
function generate_check {
    echo "Generating $DIR_SCRIPTS_MIN/check.pl..."
    cat << EOF > $DIR_SCRIPTS_MIN/check.pl
#! /usr/bin/perl
# version: $VERSION ($RELEASE_DATE)

\$ENV{"LC_ALL"} = "POSIX";

EOF
    cat <<'EOF' >> $DIR_SCRIPTS_MIN/check.pl
use strict;

if (`dmesg | grep -i "allocation failed"`) {
        print "mCHECK_vm|1\n";
} else {
        print "mCHECK_vm|\n";
}

if (`dmesg | grep -i "Oops"`) {
        print "mCHECK_oops|1\n";
} else {
        print "mCHECK_oops|\n";
}
EOF
    chown root.root "$DIR_SCRIPTS_MIN/check.pl"
    chmod 750 "$DIR_SCRIPTS_MIN/check.pl"
}

# 
# Generate /scripts/day/kernel.sh file
function generate_kernel {
    echo "Generating $DIR_SCRIPTS_DAILY/kernel.sh..."
    cat << EOF > $DIR_SCRIPTS_DAILY/kernel.sh
#! /bin/bash
# version: $VERSION ($RELEASE_DATE)

LC_ALL=POSIX

EOF
    cat <<'EOF' >> $DIR_SCRIPTS_DAILY/kernel.sh
rel=`uname -r`
ver=`uname -v`

if [ ! -z "$ver" ]; then
    echo "dINFO_KERNEL_release|$rel";
    echo "dINFO_KERNEL_version|$ver"
fi
EOF
    chown 500.500 "$DIR_SCRIPTS_DAILY/kernel.sh"
    chmod 750 "$DIR_SCRIPTS_DAILY/kernel.sh"
}

# 
# Generate /scripts/day/release.sh file
function generate_release {
    echo "Generating $DIR_SCRIPTS_DAILY/release.sh..."
    cat << EOF > $DIR_SCRIPTS_DAILY/release.sh
#! /bin/bash
# version: $VERSION ($RELEASE_DATE)

LC_ALL=POSIX

EOF
    cat <<'EOF' >> $DIR_SCRIPTS_DAILY/release.sh
test -f /etc/redhat-release && distro=`cat /etc/redhat-release`
test -f /etc/gentoo-release &&  distro=`cat /etc/gentoo-release`
test -f /etc/debian_version && distro="Debian "`cat /etc/debian_version`
test -f /etc/SuSE-release && distro=`cat /etc/SuSE-release`
test -f /etc/slackware-version && distro=`cat /etc/slackware-version`
test -f /etc/lsb-release && test -n "`grep -i ubuntu /etc/lsb-release`" && test -f /etc/lsb-release && uv=`grep DISTRIB_DESCRIPTION /etc/lsb-release | cut -d\= -f2` && test -n "$uv" && distro=$uv

test -f /etc/ovhrelease && release_ovh=`cat /etc/ovhrelease`


echo "dINFO_RELEASE_os|$distro"
echo "dINFO_RELEASE_ovh|$release_ovh"
EOF
    chown 500.500 "$DIR_SCRIPTS_DAILY/release.sh"
    chmod 750 "$DIR_SCRIPTS_DAILY/release.sh"
}

# 
# Generate /scripts/day/raid-daily.pl file
function generate_raid_daily {
    echo "Generating $DIR_SCRIPTS_DAILY/raid-daily.pl..."
    cat << EOF > $DIR_SCRIPTS_DAILY/raid-daily.pl
#! /usr/bin/perl
# version: $VERSION ($RELEASE_DATE)

\$ENV{"LC_ALL"} = "POSIX";

EOF
    cat <<'EOF' >> $DIR_SCRIPTS_DAILY/raid-daily.pl
use strict;
use IO::Select;

my $dmesg = `cat /var/log/dmesg /var/log/boot.msg 2>/dev/null`;

#3Ware-9xxx
if ( $dmesg =~ m/3w-9xxx: scsi.: Found/) {
    my $MAX_FORKS = 3;

    my $TWCLI = `which tw_cli 2>/dev/null`;
    chomp($TWCLI);
    if ($TWCLI ne "") {
        my @twCliInfo = `$TWCLI info`;
        my @controlers = ();
        foreach my $line (@twCliInfo) {
            push @controlers, $1 if $line =~ /^c(\d+)\s+/;
        }
        foreach my $controler (@controlers) {
            my %units = ();
            @twCliInfo = `$TWCLI info c$controler`;
            foreach my $line (@twCliInfo) {
                if ( $line =~ m/^p(\d)\s+([^\s]+)\s+u([^\s]+)\s+([^\s]+)\s+([^\s]+)\s+([^\s]+)/) {
                    push @{$units{$3}}, $1 if $2 ne "NOT-PRESENT";
                }
            }
            foreach my $unit (keys %units) {
                my $read_set = IO::Select->new();
                my $n_forked = 0;
                my @units = @{$units{$unit}};
                while (@units > 0) {
                    my $phys = pop @units;
                    pipe my $P_READ, my $P_WRITE or die "pipe(): $!";
                    my $pid = fork();
                    die "cannot fork: $!" if $pid < 0;
                    if ($pid == 0) {
                        close $P_READ;
                        select($P_WRITE);
                        my $line = `$TWCLI info c$controler p$phys model`;
                        $line =~ m/Model\s=\s(.+)/;
                        print "dHW_SCSIRAID_PORT_c$controler\_u$unit\_phy$phys\_model|$1\n";
                        exit();
                    }
                    close $P_WRITE;
                    $read_set->add($P_READ);

                    ++$n_forked;
                    if ($n_forked > $MAX_FORKS || @units == 0) {
                        while (my @fds = $read_set->can_read()) {
                            foreach my $fd (@fds) {
                                my $line = <$fd>;
                                if (!$line) {
                                    $read_set->remove($fd);
                                    close $fd;
                                } else {
                                    print $line;
                                }
                            }
                        }
                        while (waitpid(-1, 0) > 0) {
                        }
                        $n_forked = 0;
                    }
                }
            }
        }
    }
}
EOF
    chown root.root "$DIR_SCRIPTS_DAILY/raid-daily.pl"
    chmod 750 "$DIR_SCRIPTS_DAILY/raid-daily.pl"
}

# 
# Generate /scripts/hour/raid.pl file
function generate_raid {
    echo "Generating $DIR_SCRIPTS_HOUR/raid.pl..."
    cat << EOF > $DIR_SCRIPTS_HOUR/raid.pl
#! /usr/bin/perl
# version: $VERSION ($RELEASE_DATE)

\$ENV{"LC_ALL"} = "POSIX";

EOF
    cat <<'EOF' >> $DIR_SCRIPTS_HOUR/raid.pl
use strict;
use IO::Select;

chomp(my $MDADM=`which mdadm 2>/dev/null`);
chomp(my $MPTSTATUS = `which mpt-status 2>/dev/null`);
chomp(my $LSIUTIL = `which lsiutil 2>/dev/null`);
if($LSIUTIL eq '' and -e "/usr/local/rtm/bin/lsiutil"){
    $LSIUTIL = "/usr/local/rtm/bin/lsiutil";
  }
chomp(my $LSPCI = `which lspci 2>/dev/null`);


if ($LSPCI && `$LSPCI -d 1000:` && $MPTSTATUS) {
    my $SCSI_ID = `$MPTSTATUS -p 2>/dev/null | grep "Found SCSI" | cut -f1 -d, | cut -f2 -d=`;
    if ($SCSI_ID eq ""){
        $SCSI_ID = `cat /proc/scsi/scsi 2>/dev/null | grep Host | tail -n 1 | cut -d ' ' -f6`;
    }
    chomp $SCSI_ID;
    if ($SCSI_ID ne "") { $MPTSTATUS = "$MPTSTATUS -i $SCSI_ID"; }
} else {
    undef $MPTSTATUS;
}

my $dmesg = `cat /var/log/dmesg /var/log/boot.msg 2>/dev/null`;
my ($line, @mptInfo, @twCliInfo, $controler);

#SOFT RAID
my $mdstat;
if ( $MDADM ne "" && -e "/proc/mdstat" && `cat /proc/mdstat | grep md` ne "") {
    open(FILE, "/proc/mdstat");
    my $matrix;
    foreach $line (<FILE>) {
        if ( $line =~ /(md\d+)\s+:\s+([^\s]+)\s+([^\s]+)/ ) {
            $matrix = $1;
            $mdstat->{$matrix}{status}  = $2;
            $mdstat->{$matrix}{type}    = $3;
        }
        if ( $line =~ /\s+(\d+)/ ) {
            $mdstat->{$matrix}{capacity}    = $1;
        }
    }
    close(FILE);
    foreach $matrix (keys %{$mdstat}) {
        open(IN, "$MDADM -D /dev/$matrix |");
        foreach $line (<IN>) {
            if ( $line =~ /\s+\d+\s+\d+\s+\d+\s+(\d+)\s+(\w+)\s+(\w+)\s+\/dev\/(\w+)/ ) {
                $mdstat->{$matrix}{device}{$1}{state} = $2;
                $mdstat->{$matrix}{device}{$1}{flags} = $3;
                $mdstat->{$matrix}{device}{$1}{drive} = $4;
            }
            if ( $line =~ /^\s+State\s+:\s+([^\s]+)/ ) {
                $mdstat->{$matrix}{state}   = $1;
            }
        }
        close(IN);

        print "hHW_SCSIRAID_UNIT_$matrix\_vol0_capacity|".sprintf("%.1f", $mdstat->{$matrix}{capacity}/1024/1024)." GB\n";
        print "hHW_SCSIRAID_UNIT_$matrix\_vol0_phys|".(keys %{$mdstat})."\n";
        print "hHW_SCSIRAID_UNIT_$matrix\_vol0_type|$mdstat->{$matrix}{type}\n";
        print "hHW_SCSIRAID_UNIT_$matrix\_vol0_status|$mdstat->{$matrix}{status}\n";
        print "hHW_SCSIRAID_UNIT_$matrix\_vol0_flags|$mdstat->{$matrix}{state}\n";

        open(FILE, "/proc/partitions");
        my @file = <FILE>;
        close(FILE);
        foreach my $device (keys %{$mdstat->{$matrix}{device}}) {
            foreach $line (@file) {
                if ( $line =~ /\s+\d+\s+\d+\s+(\d+)\s+$mdstat->{$matrix}{device}{$device}{drive}/ ) {
                    $mdstat->{$matrix}{device}{$device}{capacity} = $1;
                }
            }
            print "hHW_SCSIRAID_PORT_$matrix\_vol0\_$mdstat->{$matrix}{device}{$device}{drive}\_capacity|".sprintf("%.1f", $mdstat->{$matrix}{device}{$device}{capacity}/1024/1024)." GB\n";
            print "hHW_SCSIRAID_PORT_$matrix\_vol0\_$mdstat->{$matrix}{device}{$device}{drive}\_status|$mdstat->{$matrix}{device}{$device}{state}\n";
            print "hHW_SCSIRAID_PORT_$matrix\_vol0\_$mdstat->{$matrix}{device}{$device}{drive}\_flags|$mdstat->{$matrix}{device}{$device}{flags}\n";
        }
    }
}


#SCSI-RAID
if ($MPTSTATUS and not $LSIUTIL) {
    my %mptStat;
    @mptInfo = `$MPTSTATUS 2>/dev/null`;
    foreach $line (@mptInfo) {
        if ( $line =~ m/(^[^\s]+)\s+([^\s]+)\s+(\d+)\s+type\s+([^,]+),\s+(\d+)\s+phy,\s+(\d+)\s+GB,\s+flags\s+([^,]+),\s+state\s+(.+)/) {
            $mptStat{cntrl} = $1;
            $mptStat{vol}   = "$2$3";
            $mptStat{cap}   = $6;
            $mptStat{phys}  = $5;
            $mptStat{type}  = $4;
            $mptStat{flags} = $7;
            $mptStat{status}= $8;
            $mptStat{vol}   =~ s/\_/-/g;
            print "hHW_SCSIRAID_UNIT_$mptStat{cntrl}\_$mptStat{vol}\_capacity|$mptStat{cap} GB\n";
            print "hHW_SCSIRAID_UNIT_$mptStat{cntrl}\_$mptStat{vol}\_phys|$mptStat{phys}\n";
            print "hHW_SCSIRAID_UNIT_$mptStat{cntrl}\_$mptStat{vol}\_type|$mptStat{type}\n";
            print "hHW_SCSIRAID_UNIT_$mptStat{cntrl}\_$mptStat{vol}\_status|$mptStat{status}\n";
            print "hHW_SCSIRAID_UNIT_$mptStat{cntrl}\_$mptStat{vol}\_flags|$mptStat{flags}\n";
            next;
        } elsif ( $line =~ m/(^[^\s]+)\s+([^\s]+)\s+(\d+)\s+type\s+([^,]+),\s+(\d+)\s+phy,\s+(\d+)\s+GB,\s+state\s+(.+),\s+flags\s+([^,]+)\n/) {
            $mptStat{cntrl} = $1;
            $mptStat{vol}   = "$2$3";
            $mptStat{cap}   = $6;
            $mptStat{phys}  = $5;
            $mptStat{type}  = $4;
            $mptStat{status}= $7;
            $mptStat{flags} = $8;
            $mptStat{vol}   =~ s/\_/-/g;
            print "hHW_SCSIRAID_UNIT_$mptStat{cntrl}\_$mptStat{vol}\_capacity|$mptStat{cap} GB\n";
            print "hHW_SCSIRAID_UNIT_$mptStat{cntrl}\_$mptStat{vol}\_phys|$mptStat{phys}\n";
            print "hHW_SCSIRAID_UNIT_$mptStat{cntrl}\_$mptStat{vol}\_type|$mptStat{type}\n";
            print "hHW_SCSIRAID_UNIT_$mptStat{cntrl}\_$mptStat{vol}\_status|$mptStat{status}\n";
            print "hHW_SCSIRAID_UNIT_$mptStat{cntrl}\_$mptStat{vol}\_flags|$mptStat{flags}\n";
            next;
        }
        if ( $line =~ m/(^[^\s]+)\s+([^\s]+)\s+(\d+)\s+scsi_id\s+\d+\s+([^\s]+)\s+([^\s]+)[^,]+,\s+(\d+)[^,]+,\s+state\s+(.+), flags\s+(.+)/ ) {
            next if $6 == 0;        # ignore fake raid entries
            print "hHW_SCSIRAID_PORT_$1_$mptStat{vol}\_$2$3_capacity|$6 GB\n";
            print "hHW_SCSIRAID_PORT_$1_$mptStat{vol}\_$2$3_model|$4 $5\n";
            print "hHW_SCSIRAID_PORT_$1_$mptStat{vol}\_$2$3_status|$7\n";
            print "hHW_SCSIRAID_PORT_$1_$mptStat{vol}\_$2$3_flags|$8\n";
        } elsif ( $line =~ m/(^[^\s]+)\s+([^\s]+)\s+(\d+)\s+([^\s]+)\s+([^\s]+)[^,]+,\s+(\d+)[^,]+,\s+state\s+(.+)/ ) {
            next if $6 == 0;
            print "dHW_SCSIRAID_PORT_$1_$mptStat{vol}\_$2$3_capacity|$6 GB\n";
            print "dHW_SCSIRAID_PORT_$1_$mptStat{vol}\_$2$3_model|$4 $5\n";
            print "dHW_SCSIRAID_PORT_$1_$mptStat{vol}\_$2$3_status|$7\n";
        } elsif ( $line =~ m/(^[^\s]+)\s+([^\s]+)\s+(\d+)\s+([^\s]+)\s+([^\s]+)[^,]+,\s+(\d+)[^,]+,\s+state\s+(.+), flags\s+(.+)/ ) {
            next if $6 == 0;
            print "hHW_SCSIRAID_PORT_$1_$mptStat{vol}\_$2$3_capacity|$6 GB\n";
            print "hHW_SCSIRAID_PORT_$1_$mptStat{vol}\_$2$3_model|$4 $5\n";
            print "hHW_SCSIRAID_PORT_$1_$mptStat{vol}\_$2$3_status|$7\n";
            print "hHW_SCSIRAID_PORT_$1_$mptStat{vol}\_$2$3_flags|$8\n";
        } elsif ( $line =~ m/(^[^\s]+)\s+([^\s]+)\s+(\d+)\s+([^\s]+)\s+([^\s]+)[^,]+,\s+(\d+)[^,]+,\s+flags\s+([^,]+),\s+state\s+(.+)/ ) {
            next if $6 == 0;
            print "hHW_SCSIRAID_PORT_$1_$mptStat{vol}\_$2$3_capacity|$6 GB\n";
            print "hHW_SCSIRAID_PORT_$1_$mptStat{vol}\_$2$3_model|$4 $5\n";
            print "hHW_SCSIRAID_PORT_$1_$mptStat{vol}\_$2$3_status|$8\n";
            print "hHW_SCSIRAID_PORT_$1_$mptStat{vol}\_$2$3_flags|$7\n";
        }
    }
}

# LSI:
if($LSIUTIL) {
  my %data;
  chomp(my @devs = `cat /proc/mpt/summary`);

  # foreach ioc device:
  foreach (@devs){
    m/^(.*?):.*Ports=(\d+),/;
    my ($unit, $ports) = ($1, $2);

    # foreach ports:
    for (my $port=1; $port <= $ports; $port++){
      chomp(my @diskDetails = `$LSIUTIL -p$port -a 21,2,0,0,0`);
      chomp(my @LSIRES = `$LSIUTIL -p$port -a 21,1,0,0,0`);

      # each line:
      my ($vol, $bus, $target, $type);
      $vol = -1;
      foreach my $line (@LSIRES){
        #Volume 0 is Bus 0 Target 2, Type IM (Integrated Mirroring)
        if($line =~ /^Volume (\d+) is Bus (\d+) Target (\d+), Type (\w+) /) {
          ($vol, $bus, $target, $type) = ($1, $2, $3, $4);
          $data{$unit}{$port}{$vol}{$bus}{$target}{type} = $type;
          # Warning: $target is a scsi id (vol_id$target) in RTM
        }
        # skip all till Volume.. line
        next if $vol == -1;

        #  Volume State:  optimal, enabled
        if($line =~ /Volume State:  (.+?), (.*)$/) {
          $data{$unit}{$port}{$vol}{$bus}{$target}{status} = uc $1;
          $data{$unit}{$port}{$vol}{$bus}{$target}{flags} = uc $2;
          if($2 =~ /resync in progress/i){
            chomp(my @lsitmp = `$LSIUTIL -p$port -a 21,3,0,0,0`);
            my $checkNextLine = 0;
            foreach(@lsitmp){
              # Resync Progress:  total blocks 4394526720, blocks remaining 3298477568, 75%
              if($checkNextLine and /^\s*Resync Progress:.*?,\s*(\d+)%\s*/){
                $data{$unit}{$port}{$vol}{$bus}{$target}{syncprogress} = $1;
              }
              next unless /Volume $vol State:/i;
              $checkNextLine = 1;
            }
          }
        }

        #Volume Size 417708 MB, Stripe Size 64 KB, 6 Members
        if($line =~ /Volume Size (\d+ \w+), Stripe Size (\d+ \w+), (\d+) Members/){
          $data{$unit}{$port}{$vol}{$bus}{$target}{capacity} = $1;
          $data{$unit}{$port}{$vol}{$bus}{$target}{stripe} = $2; # NEW
          $data{$unit}{$port}{$vol}{$bus}{$target}{phys} = $3;
        }elsif($line =~ /Volume Size (\d+ \w+), (\d+) Members/){
        #Volume Size 417708 MB, 2 Members
          $data{$unit}{$port}{$vol}{$bus}{$target}{capacity} = $1;
          $data{$unit}{$port}{$vol}{$bus}{$target}{phys} = $2;
        }

        if($line =~ /is PhysDisk (\d+)/){
          my %disk;
          $disk{nr} = $1;

          # now we know which disk is here, so find it:
          my $stop = 0;
          foreach(@diskDetails) {
            $stop = 1 and next
              if(/PhysDisk $disk{nr} is Bus/);
              #PhysDisk 0 is Bus 0 Target 3

            next unless $stop;

            #PhysDisk State:  online
            if(/PhysDisk State: (.*)/){
              $disk{status} = uc $1;
              $disk{status} =~ s/^\s+|\s+$//g;
            }
            
            #PhysDisk Size 238475 MB, Inquiry Data:  ATA      ST3250410AS      A
            if(/PhysDisk Size (\d+ \w+), Inquiry Data:\s+(.*)/){
              $disk{capacity} = $1;
              $disk{model} = $2;
              $disk{model} =~ s/\s+/ /g;
              $disk{model} =~ s/^\s+|\s+$//g;
              $disk{model} =~ s/(\w+ \w+) \w+/\1/g; # delete rev, for backward compatibility
            }

           # fix for 2 SSD IM sizes
            if( $data{$unit}{$port}{$vol}{$bus}{$target}{type} eq 'IM'
                and $data{$unit}{$port}{$vol}{$bus}{$target}{phys} == 2
                and $disk{capacity} > $data{$unit}{$port}{$vol}{$bus}{$target}{capacity} * 1.01 ){
              my $old_model = $disk{model};
              my $d = scan4LsiDisks($port);
              my $new_model = $d->{$disk{nr}}{model};
              $new_model =~ s/\s+/ /g;
              $new_model =~ s/^\s+|\s+$//g;
              $new_model = $d->{$disk{nr}}{vendor} . ' ' . $new_model;
              if($old_model ne $new_model){
                $disk{model} = $new_model;
                $disk{capacity} = $data{$unit}{$port}{$vol}{$bus}{$target}{capacity}; # ugly
              }
            }

          }
          push @{$data{$unit}{$port}{$vol}{$bus}{$target}{disks}}, \%disk;
        }
      }
    }
  }

  #@{$data{$unit}{$port}{$vol}{$bus}{$target}{disks}}
  foreach my $unit (keys %data){
    foreach my $port (keys %{$data{$unit}}){
       foreach my $vol (keys %{$data{$unit}{$port}}){
          foreach my $bus (keys %{$data{$unit}{$port}{$vol}}){
            foreach my $target (keys %{$data{$unit}{$port}{$vol}{$bus}}){
              foreach my $key (keys %{$data{$unit}{$port}{$vol}{$bus}{$target}}){
                if($key eq 'capacity'){
                  print "hHW_SCSIRAID_UNIT_$unit\_vol-id$vol\_$key|".changeSizeUnit($data{$unit}{$port}{$vol}{$bus}{$target}{$key})."\n";
                } elsif($key eq 'disks') {
                  foreach my $d (@{$data{$unit}{$port}{$vol}{$bus}{$target}{$key}}){
                      next unless $d->{status};
                      print "hHW_SCSIRAID_PORT_$unit\_vol-id$vol\_phy".$d->{nr}."\_model|".$d->{model}."\n";
                      print "hHW_SCSIRAID_PORT_$unit\_vol-id$vol\_phy".$d->{nr}."\_capacity|".changeSizeUnit($d->{capacity})."\n";
                      print "hHW_SCSIRAID_PORT_$unit\_vol-id$vol\_phy".$d->{nr}."\_status|".$d->{status}."\n";
                      # TODO: no idea from where get the disk flags
                      print "hHW_SCSIRAID_PORT_$unit\_vol-id$vol\_phy".$d->{nr}."\_flags|".(($d->{flags})?$d->{flags}:"NONE")."\n";
                  }
                } else {
                  print "hHW_SCSIRAID_UNIT_$unit\_vol-id$vol\_$key|$data{$unit}{$port}{$vol}{$bus}{$target}{$key}\n";
                }
              }
            }
          }
       }
    }
  }
}

#3Ware
if (( $dmesg =~ m/3w-xxxx: scsi/) || ( $dmesg =~ m/scsi. : Found a 3ware/)) {
    my (%units, @controlers);

    my $TWCLI = `which tw_cli 2>/dev/null`;
    chomp($TWCLI);
    if ($TWCLI ne "") {
        @twCliInfo = `$TWCLI info`;
        foreach $line (@twCliInfo) {
            if ($line =~ m/Controller (\d+):/ || $line =~ /^c(\d+).*$/)  { push @controlers, $1;}
        }
        foreach $controler (@controlers) {
            @twCliInfo = `$TWCLI info c$controler`;
            foreach $line (@twCliInfo) {
                if ( $line =~ m/Unit\s(\d):\s+(RAID\s+\d+|[^\s]+)\s([^\s]+)\s([^\s]+)[^:]+:\s(.+)/) {
                    print "hHW_SCSIRAID_UNIT_c$controler\_u$1_capacity|$3 $4\n";
                    print "hHW_SCSIRAID_UNIT_c$controler\_u$1_type|$2\n";
                    print "hHW_SCSIRAID_UNIT_c$controler\_u$1_status|$5\n";
                }
                if ( $line =~ m/Port\s(\d+):\s([^\s]+)\s([^\s]+)\s([^\s]+)\s([^\s]+)\s([^\s]+)[^:]+:\s([^\(]+)\(unit\s(\d+)/) {
                    print "hHW_SCSIRAID_PORT_c$controler\_u$8_phy$1_capacity|$5 $6\n";
                    print "hHW_SCSIRAID_PORT_c$controler\_u$8_phy$1_model|$2 $3\n";
                    print "hHW_SCSIRAID_PORT_c$controler\_u$8_phy$1_status|$7\n";
                    if (! exists $units{$controler}{$8}) {$units{$controler}{$8} = 0;}
                    $units{$controler}{$8} = $units{$controler}{$8} + 1;
                }
                if (  $line =~ /^u(\d+)\s+(RAID\-\d+)\s+(\S+)\s+\S+\s+\S+\s+(\S+)\s.*/ )
                {
                    print "hHW_SCSIRAID_UNIT_c$controler\_u$1_capacity|$4 GB\n";
                    print "hHW_SCSIRAID_UNIT_c$controler\_u$1_type|$2\n";
                    print "hHW_SCSIRAID_UNIT_c$controler\_u$1_status|$3\n";
                }
                if ( $line =~ /^p(\d+)\s+(\S+)\s+(\S+)\s+(\S+\s\S+)\s+(\d+)\s+(\S+)\s*$/ )
                {
                    print "hHW_SCSIRAID_PORT_c$controler\_$3_phy$1_capacity|$4\n";
                    print "hHW_SCSIRAID_PORT_c$controler\_$3_phy$1_model|$6\n";
                    print "hHW_SCSIRAID_PORT_c$controler\_$3_phy$1_status|$2\n";
                    if (! exists $units{$controler}{$3}) {$units{$controler}{$3} = 0;}
                    $units{$controler}{$3} = $units{$controler}{$3} + 1;
                }
            }
            foreach (keys %{$units{$controler}}) {print "hHW_SCSIRAID_UNIT_c$controler\_$_\_phys|".($units{$controler}{$_})."\n";}
        }
    }
}


#3Ware-9xxx
if ( $dmesg =~ m/3w-9xxx: scsi.: Found/) {
    if (open my $FP, "tw_cli info |") {
        my (%units, @controlers);
        while (my $line = <$FP>) {
            if ($line =~ m/^c(\d+)\s+/) {push @controlers, $1;}
        }
        close $FP;
        foreach $controler (@controlers) {
            open my $FP, "tw_cli info c$controler |" or next;
            while (my $line = <$FP>) {
                if ( $line =~ m/^u(\d)\s+([A-Z0-9\-]+)\s+([^\s]+)\s+([^\s]+)\s+([^\s]+)\s+([^\s]+)\s+/ ) {
                    print "hHW_SCSIRAID_UNIT_c$controler\_u$1_capacity|$6\n";
                    print "hHW_SCSIRAID_UNIT_c$controler\_u$1_type|$2\n";
                    print "hHW_SCSIRAID_UNIT_c$controler\_u$1_status|$3\n";
                }
                if ( $line =~ m/^p(\d)\s+([^\s]+)\s+u([^\s]+)\s+([^\s]+)\s+([^\s]+)\s+([^\s]+)/) {
                    print "hHW_SCSIRAID_PORT_c$controler\_u$3_phy$1_capacity|$4 $5\n";
                    print "hHW_SCSIRAID_PORT_c$controler\_u$3_phy$1_status|$2\n";
                    push @{$units{$3}}, $1 if ($2 ne "NOT-PRESENT");
                }
            }
            foreach my $unit (keys %units) {
                print "hHW_SCSIRAID_UNIT_c$controler\_u$unit\_phys|".(scalar @{$units{$unit}})."\n";
            }
            close $FP;
        }
    }
}

#Mylex
if ( $dmesg =~ m/Mylex AcceleRAID 160 PCI RAID Controller/) {
    my( @dirContents, $dirContent, @info, $line, $unit, $i, $sectorSize, $count);
    if ( ! -e "/proc/rd") {exit;}
    $count = 0;
    opendir(DIR,"/proc/rd");
    @dirContents=readdir(DIR);
    closedir(DIR);

    $unit = 0;
    foreach $dirContent (@dirContents) {
        if (( $dirContent =~ m/\./ ) || (! -d "/proc/rd/".$controler )) {next;}
        $controler = $dirContent;
        $controler =~ s/c//g;
        open(FILE, "/proc/rd/c$controler/current_status") or exit;
        @info = <FILE>;
        close(FILE);

        for ($i=-1; $i<=scalar @info; $i++) {
            $line = $info[$i];
            chomp($line);
            if ( $line =~ m/\/dev\/rd\/c(\d+)d(\d+):\s+([^,]+),\s+([^,]+),\s+(\d+)/ ) {
                my $capacity = $5;
                my $type = $3;
                my $status = $4;

                $capacity = $capacity * 512 / 1024 / 1024 / 1024;
                print "hHW_SCSIRAID_UNIT_c$controler\_u$unit\_capacity|".sprintf("%.2f",$capacity)." GB\n";
                print "hHW_SCSIRAID_UNIT_c$controler\_u$unit\_type|$type\n";
                print "hHW_SCSIRAID_UNIT_c$controler\_u$unit\_status|$status\n";
            }
            if ( $line =~ m/\s+(\d+):(\d+)\s+Vendor:\s+([^\s]+)\s+Model:\s+([^\s]+)/ ) {
                my $unit = $1;
                my $phys = $2;
                my $vendor = $3;
                my $model = $4;
                next if $model eq 'AcceleRAID'; # it's the controller, not disk
                $count++;
                $line = @info[$i+3];
                $line =~ /Disk Status:\s+([^,]+),\s+(\d+)\sblocks/;

                my $status = $1;
                my $capacity = $2 * 512 / 1024 / 1024 / 1024;

                print "hHW_SCSIRAID_PORT_c$controler\_u$unit\_phy$phys\_capacity|".sprintf("%.2f",$capacity)." GB\n" if ($status ne "0");
                print "hHW_SCSIRAID_PORT_c$controler\_u$unit\_phy$phys\_status|$status\n" if ($status ne "0");
                print "hHW_SCSIRAID_PORT_c$controler\_u$unit\_phy$phys\_model|$model\n";
            }
        }
        print "hHW_SCSIRAID_UNIT_c$controler\_u$unit\_phys|$count\n";
    }
}

# sub to normalize units
sub changeSizeUnit {
  my $str = shift || return;

  $str =~ /^(\d+) (\w+)$/
    and $1 > 1024
    and uc $2 eq 'KB'
    and return int($1/1024)." MB";


  $str =~ /^(\d+) (\w+)$/
    and $1 > 1024
    and uc $2 eq 'MB'
    and return int($1/1024)." GB";
}

# sometimes we need to rescan disks in LSI (sas + ssd cofigurations mostly)
sub scan4LsiDisks {
  my $port = shift;
  return {} unless $port;
  my %disks;

  my @out = `$LSIUTIL -p$port -a8,0`;
# 0   1  PhysDisk 1     ATA      ST3750528AS      CC44  1221000001000000     1
# 0   3  PhysDisk 2     ATA      INTEL SSDSA2M080 02HD  1221000003000000     3
  foreach (@out){
    next unless /PhysDisk\s+(\d+)\s+(\w+)\s+(\w+(?:\s\w+)?)\s+([\da-zA-Z]+)\s+([\dABCDEF]+)\s+(\d+)\s+$/;
    $disks{$1} = {vendor=>$2, model=>$3, rev=>$4, phy=>$6};
  }

  return \%disks;
}


EOF
    chown root.root "$DIR_SCRIPTS_HOUR/raid.pl"
    chmod 750 "$DIR_SCRIPTS_HOUR/raid.pl"
}

# 
# Generate /scripts/hour/smart.pl file
function generate_smart {
    echo "Generating $DIR_SCRIPTS_HOUR/smart.pl..."
    cat << EOF > $DIR_SCRIPTS_HOUR/smart.pl
#! /usr/bin/perl
# version: $VERSION ($RELEASE_DATE)

\$ENV{"LC_ALL"} = "POSIX";

EOF
    cat <<'EOF' >> $DIR_SCRIPTS_HOUR/smart.pl
use strict;
use IO::Select;

my %smartData;

sub parse_smartctl_line {
    my $line = shift;
    my $dev = shift;
        my $other_errors = 0;

    if ($line =~ /^196 Reallocated_Event_Count.*\s+(\d+)$/) {
        print "hINFO_HDD_$dev\_SMART_realocated-event-count|$1\n";
    }
    if ($line =~ /^197 Current_Pending_Sector.*\s+(\d+)$/) {
        print "hINFO_HDD_$dev\_SMART_current-pending-sector|$1\n";
    }
    if ($line =~ /^198 Offline_Uncorrectable.*\s+(\d+)$/) {
        print "hINFO_HDD_$dev\_SMART_offline-uncorrectable|$1\n";
    }
    if ($line =~ /^199 UDMA_CRC_Error_Count.*\s+(\d+)$/) {
        print "hINFO_HDD_$dev\_SMART_udma-crc-error|$1\n";
    }
    if ($line =~ /^200 Multi_Zone_Error_Rate.*\s+(\d+)$/) {
        print "hINFO_HDD_$dev\_SMART_multizone-error-rate|$1\n";
    }
    if ($line =~ /^209 Offline_Seek_Performnce.*\s+(\d+)$/) {
        print "hINFO_HDD_$dev\_SMART_offline-seek-performance|$1\n";
    }
    if ($line =~ m/^194 Temperature_Celsius .*\s+(\d+)(\s+\([\w\s\/]+\))?$/) {
        print "hINFO_HDD_$dev\_SMART_temperature-celsius|$1\n";
    }

    if ($line =~ /Error \d+ (occurred )?at /){
        $other_errors = 1;
    }

    return (other_errors=>$other_errors);
}

sub check_ide {
    opendir(DIR,"/proc/ide") or return;
    my @diskList = readdir(DIR);
    closedir(DIR);
    foreach my $dev (@diskList) {
        next unless $dev =~ /^hd.$/;
        my $smart_other_error = 0;
        my @smartctlData = `smartctl -a /dev/$dev`;
        foreach my $line (@smartctlData) {
            my %ret = parse_smartctl_line($line, $dev);
            $smart_other_error = 1 if $ret{other_errors};
        }
        print "hINFO_HDD_$dev\_SMART_other-errors|".int($smart_other_error)."\n";
    }
}

sub check_scsi {
    open PART, "/proc/partitions" or return;
    my @disks = ();
    while (<PART>) {
        chomp;
        next unless /\b(sd\D+)\b/;
        push @disks, $1;
    }
    close PART;
    return unless @disks > 0;

    foreach my $dev (@disks) {
        my @smartctlData = `smartctl -a /dev/$dev`;
        my $smart_other_error = 0;
        foreach my $line (@smartctlData) {
            my %ret = parse_smartctl_line($line, $dev);
            $smart_other_error = 1 if $ret{other_errors};

            if ($line =~ /^read:.+(\d+)$/) {
                print "hINFO_HDD_$dev\_SMART_uncorrected-read-errors|$1\n";
            }
            if ($line =~ /^write:.+(\d+)$/) {
                print "hINFO_HDD_$dev\_SMART_uncorrected-write-errors|$1\n";
            }
        }
        print "hINFO_HDD_$dev\_SMART_other-errors|".int($smart_other_error)."\n";
    }
}

sub _3ware_get_ports_for_disk {
    my $disk = shift;
    my @ports = ();
    open my $TWCLI_OUTPUT, "tw_cli info c$disk |" or die("failed to run 'tw_cli'");
    while (<$TWCLI_OUTPUT>) {
        next unless /^p(\d+) /;
        push @ports, $1;
    }
    close $TWCLI_OUTPUT;
    return @ports;
}

sub check_3ware {
    opendir(DIR,"/proc/scsi/3w-9xxx") or return;
    my @disk_list = readdir(DIR);
    closedir(DIR);

    my $read_set = IO::Select->new();

    foreach my $disk (@disk_list) {
        next unless $disk =~ /^\d+$/;
        foreach my $port (_3ware_get_ports_for_disk($disk)) {
            pipe my $P_READ, my $P_WRITE or die "pipe(): $!";
            my $pid = fork();
            die "cannot fork: $!" if $pid < 0;
            if ($pid == 0) {
                open my $SMARTCTL_OUTPUT, "smartctl --device=3ware,$port /dev/twa$disk -a |" or die("failed to run smartctl");
                close $P_READ;
                select($P_WRITE);
                while (<$SMARTCTL_OUTPUT>) {
                    parse_smartctl_line($_, "twa$disk-$port");
                }
                exit();
            }
            close $P_WRITE;
            $read_set->add($P_READ);
        }
    }
    while (my @fds = $read_set->can_read()) {
        foreach my $fd (@fds) {
            my @lines = <$fd>;
            if (!@lines) {
                close $fd;
                next;
            }
            print join('', @lines);
        }
    }
    while (waitpid(-1, 0) > 0) {
    }
}


check_ide();
check_scsi();
check_3ware();
EOF
    chown root.root "$DIR_SCRIPTS_HOUR/smart.pl"
    chmod 750 "$DIR_SCRIPTS_HOUR/smart.pl"
}

# 
# Generate /scripts/hour/listen_ports.pl file
function generate_listen_ports {
    echo "Generating $DIR_SCRIPTS_HOUR/listen_ports.pl..."
    cat << EOF > $DIR_SCRIPTS_HOUR/listen_ports.pl
#! /usr/bin/perl
# version: $VERSION ($RELEASE_DATE)

\$ENV{"LC_ALL"} = "POSIX";

EOF
    cat <<'EOF' >> $DIR_SCRIPTS_HOUR/listen_ports.pl
use strict;
use utf8; # for \x{nnn} regex

my (@netstatTable, $line, $socketInfo, $procInfo, @tempTable, $port, $pid, $procName, $ip, $cmdline, $exe, @status, $statusLine, $uid, @passwd, $passwdLine, %passwdHash);

chomp(@netstatTable = `netstat -tlenp | grep LISTEN | awk '{print \$4"|"\$9}'`);

open(FILE, "/etc/passwd");
chomp(@passwd = <FILE>);
close(FILE);

foreach $passwdLine (@passwd) {
    $passwdLine =~ /^([^:]+):[^:+]:(\d+):/;
    $passwdHash{$2} = $1;
}

foreach $line (@netstatTable) {

    @tempTable = split(/\|/, $line);
    $socketInfo = $tempTable[0];
    $procInfo = $tempTable[1];

    $socketInfo =~ /:(\d+)$/;
    $port = $1;
    $socketInfo =~ /(.+):\d+$/;
    $ip = $1;
    $ip =~ s/\./-/g;
    $ip =~ s/[^0-9\-]//g;
    if ($ip eq "") {$ip = 0;}
    @tempTable = split(/\//, $procInfo);
    $pid = $tempTable[0];
    open(FILE, "/proc/$pid/cmdline");
    chomp($cmdline = <FILE>);
    $cmdline =~ s/\x{0}/ /g;
    close(FILE);

    open(FILE, "/proc/$pid/status");
    chomp(@status = <FILE>);
    close(FILE);
    $statusLine = join("|", @status);
    $statusLine =~ /Uid:\s(\d+)/;
    $uid = $1;

    my $username = '';
    if (defined $passwdHash{$uid}) {
        $username = $passwdHash{$uid};
    }

    $procName = $tempTable[1];
    $exe = readlink("/proc/$pid/exe");

    print "hINFO_TCP_LISTEN_IP-$ip\_PORT-$port\_pid\|$pid\n";
    print "hINFO_TCP_LISTEN_IP-$ip\_PORT-$port\_procname\|$procName\n";
    print "hINFO_TCP_LISTEN_IP-$ip\_PORT-$port\_cmdline\|$cmdline\n";
    print "hINFO_TCP_LISTEN_IP-$ip\_PORT-$port\_exe\|$exe\n";
    print "hINFO_TCP_LISTEN_IP-$ip\_PORT-$port\_username\|$username\n";
    print "hINFO_TCP_LISTEN_IP-$ip\_PORT-$port\_uid\|$uid\n";
}
EOF
    chown root.root "$DIR_SCRIPTS_HOUR/listen_ports.pl"
    chmod 750 "$DIR_SCRIPTS_HOUR/listen_ports.pl"
}

# 
# Generate /scripts/min/usage.pl file
function generate_usage {
    echo "Generating $DIR_SCRIPTS_MIN/usage.pl..."
    cat << EOF > $DIR_SCRIPTS_MIN/usage.pl
#! /usr/bin/perl
# version: $VERSION ($RELEASE_DATE)

\$ENV{"LC_ALL"} = "POSIX";

EOF
    cat <<'EOF' >> $DIR_SCRIPTS_MIN/usage.pl
use strict;

# tmp file for storing cpu stats from /proc/stat
my $CPU_STATS = "/tmp/cpu_stats";

sub send_loadavg {
    my %loadavg = get_loadavg();
    print "mINFO_LOAD_loadavg1|" . $loadavg{'loadavg1'} . "\n";
    print "mINFO_LOAD_loadavg2|" . $loadavg{'loadavg2'} . "\n";
    print "mINFO_LOAD_loadavg3|" . $loadavg{'loadavg3'} . "\n";
}

sub send_mem_swap_usage {
    my %mem_swap_usage = get_mem_swap_usage();
    print "mINFO_MEM_memusage|" . $mem_swap_usage{'mem_used_pr'} . "\n";
    print "mINFO_MEM_swapusage|" . $mem_swap_usage{'swap_used_pr'} . "\n";
}

sub send_cpu_usage {
    my $cpu_usage = get_cpu_usage();
    print "mINFO_CPU_usage|" . $cpu_usage . "\n";
}

sub send_hdd_usage {
    my %hdd_usage = get_hdd_usage();
    foreach (keys %{$hdd_usage{'usage'}}) {
        print "mINFO_PART_$_\_mount|" . $hdd_usage{'mount'}{$_} . "\n";
        print "mINFO_PART_$_\_usage|" . $hdd_usage{'usage'}{$_} . "\n";
        print "mINFO_PART_$_\_inodes|" . $hdd_usage{'inodes'}{$_} . "\n";
    }
}

sub get_loadavg {
    open(CONF, "/proc/loadavg") or die "loadavg: $!\n";
    chomp(my @load = split(/\s/, <CONF>));
    close(CONF);
    return ('loadavg1' => $load[0],
            'loadavg2' => $load[1],
            'loadavg3' => $load[2],);
}

sub get_cpu_usage {
    my ($cpu_usage, @cpu_usage1, @cpu_usage2, $delta);
    @cpu_usage1 = (0, 0, 0, 0);
    @cpu_usage2 = (0, 0, 0, 0);


    open(STAT, "/proc/stat") or die "/proc/stat: $!\n";
    my @stats = <STAT>;
    close (STAT);

    foreach (@stats) {
        if (/^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/i) {
            @cpu_usage2 = ($1, $2, $3, $4);
        }
    }

    # it can happen after reboot
    if( ! -e $CPU_STATS) {
       open(TMP, ">$CPU_STATS") or die "$CPU_STATS: $!\n";
       print TMP @stats;
       close(TMP);
       return 0;
    }

    open(TMP, '+<', $CPU_STATS) or die "$CPU_STATS: $!\n";
    while (<TMP>) {
        if (/^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/i) {
            @cpu_usage1 = ($1, $2, $3, $4);
        }
    }
    seek(TMP, 0, 0);
    print TMP @stats;
    close (TMP);

    $delta = $cpu_usage2[0]+$cpu_usage2[1]+$cpu_usage2[2]+$cpu_usage2[3]-
        ($cpu_usage1[0]+$cpu_usage1[1]+$cpu_usage1[2]+$cpu_usage1[3]);
    if ($delta > 0) {
        $cpu_usage = sprintf("%d", 100-(($cpu_usage2[3]-$cpu_usage1[3])/$delta*100));
    } else {
        $cpu_usage = 0;
    }
    return $cpu_usage;
}

sub get_mem_swap_usage {
    my %mem_swap_usage = ();
    my @free = `free`;
    foreach (@free) {
        if (/^Swap:\s+(\d+)\s+(\d+)\s+(\d+)/i) {
            $mem_swap_usage{'swap_total'} = $1;
            $mem_swap_usage{'swap_used'} = $2;
            if ($1 == 0) {
                # prevent division by zero
                $mem_swap_usage{'swap_used_pr'} = 0;
            } else {
                $mem_swap_usage{'swap_used_pr'} = sprintf("%d", $2/$1*100);
            }
        }
        if (/^Mem:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/i) {
            $mem_swap_usage{'mem_total'} = $1;
            $mem_swap_usage{'mem_used'} = $2;
            $mem_swap_usage{'mem_free'} = $3;
            $mem_swap_usage{'mem_shared'} = $4;
            $mem_swap_usage{'mem_buffers'} = $5;
            $mem_swap_usage{'mem_cached'} = $6;
            $mem_swap_usage{'mem_used_pr'} = sprintf("%d", (($2-$5-$6)/$1*100));
        }
    }
    return %mem_swap_usage;
}

sub get_hdd_usage {
    my %hdd_usage = ();
    my @df = `df -l`;
    foreach (@df){
        if (/^(\/dev\/\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)/i) {
            my $hdd_name = $1;
            my $hdd_usage = $5;
            my $hdd_mount = $6;
            $hdd_name =~ s!^/dev/!!g;
            $hdd_name =~ s!/!-!g;
            $hdd_usage{'usage'}{$hdd_name} = $hdd_usage;
            $hdd_usage{'usage'}{$hdd_name} =~ s/%//;
            $hdd_usage{'mount'}{$hdd_name} = $hdd_mount;
        }
    }

    # inodes
    @df = `df -li`;
    foreach (@df) {
        if (/^(\/dev\/\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)/i) {
            my $hdd_name = $1;
            my $hdd_usage = $5;
            $hdd_usage =~ s/%//;
            $hdd_usage = 0 unless $hdd_usage =~ /^\d+$/;
            $hdd_name =~ s/^\/dev\///g;
            $hdd_name =~ s!/!-!g;
            $hdd_usage{'inodes'}{$hdd_name} = $hdd_usage;
        }
    }
    return %hdd_usage;
}

send_hdd_usage();
send_mem_swap_usage();
send_loadavg();
send_cpu_usage();
EOF
    chown 500.500 "$DIR_SCRIPTS_MIN/usage.pl"
    chmod 750 "$DIR_SCRIPTS_MIN/usage.pl"
}

# 
# Generate /scripts/min/usage-root.pl file
function generate_usage_root {
    echo "Generating $DIR_SCRIPTS_MIN/usage-root.pl..."
    cat << EOF > $DIR_SCRIPTS_MIN/usage-root.pl
#! /usr/bin/perl
# version: $VERSION ($RELEASE_DATE)

\$ENV{"LC_ALL"} = "POSIX";

EOF
    cat <<'EOF' >> $DIR_SCRIPTS_MIN/usage-root.pl
use strict;

sub send_process {
    my %processes = get_processes();
    print "mINFO_LOAD_processesactive|" . $processes{'processesactive'} . "\n";
    print "mINFO_LOAD_processesup|" . $processes{'processesup'} . "\n";
}

sub send_top_rss {
    my $top = get_top_mem_procs();
    my $n = 1;
    foreach my $info (@$top) {
        my $vsz = $info->[0];
        my $cmd = $info->[1];
        printf "mINFO_MEM_top_mem_%02d_name|%s\n", $n, $cmd;
        printf "mINFO_MEM_top_mem_%02d_size|%s\n", $n, $vsz;
        ++$n;
    }
}

sub get_processes {
    chomp(my @rtm_sids = `ps --no-headers -C rtm -o sess | sort -n | uniq`);
    my @ps_output = `ps --no-headers -A -o sess,state,command`;
    my $active = 0;
    my $total = 0;
    my $rtm_procs = 0;
    foreach my $line (@ps_output) {
        next if $line !~ /(\d+)\s+(\S+)/;
        my $sid = $1;
        my $state = $2;
        if (grep $sid == $_, @rtm_sids) {
            ++$rtm_procs;
            next;
        }
        ++$total;
        ++$active if $state =~ /^R/;
    }
    return ('processesactive' => $active, 'processesup' => $total);
}

sub get_top_mem_procs {
    my @top;
    my @output = `ps -A -o vsz,cmd --sort=-vsz --no-headers | head -n 5`;
    return [] unless $? == 0;
    foreach (@output) {
        next unless m/\s*(\d+)\s+(.+)/;
        push @top, [$1, $2];
    }
    return \@top;
}

send_process();
send_top_rss();
EOF
    chown root.root "$DIR_SCRIPTS_MIN/usage-root.pl"
    chmod 750 "$DIR_SCRIPTS_MIN/usage-root.pl"
}

# 
# Generate /scripts/hour/hwinfo.pl file
function generate_hwinfo {
    echo "Generating $DIR_SCRIPTS_HOUR/hwinfo.pl..."
    cat << EOF > $DIR_SCRIPTS_HOUR/hwinfo.pl
#! /usr/bin/perl
# version: $VERSION ($RELEASE_DATE)

\$ENV{"LC_ALL"} = "POSIX";

EOF
    cat <<'EOF' >> $DIR_SCRIPTS_HOUR/hwinfo.pl
use strict;

sub send_cpu_info {
    my %cpu_info = get_cpu_info();
    print "dHW_CPU_name|" . $cpu_info{'cpu_name'} . "\n";
    print "dHW_CPU_mhz|" . $cpu_info{'cpu_mhz'} . "\n";
    print "dHW_CPU_cache|" . $cpu_info{'cpu_cache'} . "\n";
    print "dHW_CPU_number|" . $cpu_info{'cpu_no'} . "\n";
}

sub send_lspci_info {
    my %lspci_info = get_lspci_info();
    foreach (keys %lspci_info) {
        my $tempKey = $_;
        $tempKey =~ s/\:|\.|\_/-/g;
        print "dHW_LSPCI_PCI-$tempKey|" . $lspci_info{$_} . "\n";
    }
}


sub get_cpu_info {
    my %cpu_info = ( 'cpu_no' => 0 );
    open(CONF,"/proc/cpuinfo") or die "loadavg: $!\n";
    while( <CONF> ) {
        chomp($_);
        if ($_ =~ /^model name\s+:\s(.*)/) {
            $cpu_info{'cpu_name'} = $1;
            $cpu_info{'cpu_no'} += 1;
        }
        if ($_ =~ /^cpu MHz/) {
            s/cpu MHz\s+:\s*//g;
            $cpu_info{'cpu_mhz'} = $_;
        }
        if ($_ =~ /^cache size/) {
            s/cache size\s+:\s*//g;
            $cpu_info{'cpu_cache'} = $_;
        }
    }
    $cpu_info{'cpu_no'} = $cpu_info{'cpu_no'};
    close(CONF);
    return %cpu_info;
}


sub get_lspci_info {
    my %lspci_info = ();
    my @lspci = `lspci -n 2>/dev/null`;
    if ($? == 0) {
        foreach (@lspci) {
            if (/^(\S+).+:\s+(.+:.+)\s+\(/i) {
                $lspci_info{$1} = $2;
            }
            elsif (/^(\S+).+:\s+(.+:.+$)/i){
                $lspci_info{$1} = $2;
            }
        }
    }
    return %lspci_info;
}

send_cpu_info();
send_lspci_info();
EOF
    chown 500.500 "$DIR_SCRIPTS_HOUR/hwinfo.pl"
    chmod 750 "$DIR_SCRIPTS_HOUR/hwinfo.pl"
}

# 
# Generate /scripts/hour/hwinfo-root.pl file
function generate_hwinfo_root {
    echo "Generating $DIR_SCRIPTS_HOUR/hwinfo-root.pl..."
    cat << EOF > $DIR_SCRIPTS_HOUR/hwinfo-root.pl
#! /usr/bin/perl
# version: $VERSION ($RELEASE_DATE)

\$ENV{"LC_ALL"} = "POSIX";

EOF
    cat <<'EOF' >> $DIR_SCRIPTS_HOUR/hwinfo-root.pl
use strict;

sub send_mainboard_memory_info {
    my %mainboard_memory_info = get_mainboard_memory_info();
    print "dHW_MB_manufacture|" . $mainboard_memory_info{'mainboard'}{'manufacture'} . "\n";
    print "dHW_MB_name|" . $mainboard_memory_info{'mainboard'}{'name'} . "\n";
    foreach (keys %{$mainboard_memory_info{'memory'}}) {
        print "dHW_MEM_BANK-$_|" . $mainboard_memory_info{'memory'}{$_} . "\n";
    }
}

sub send_hdd_info {
    my %hdd_info = get_hdd_info();
    get_hdd_info_scsi(\%hdd_info);
    foreach (keys %{$hdd_info{'model'}}) {
        print "dHW_HDD_$_\_capacity|" . $hdd_info{'capacity'}{$_} . " GB" . "\n";
        print "dHW_HDD_$_\_model|" . $hdd_info{'model'}{$_} . "\n";
    }
}

sub get_mainboard_memory_info {
    my %mainboard_memory_info = ();
    my @dmidecode = `dmidecode 2>/dev/null`;
    if ($? == 0) {
        my $module = "";
        for (my $i = 0; $i < @dmidecode; $i++) {
            if($dmidecode[$i] =~ /^\s*Base Board Information/i) {
                $dmidecode[$i+1] =~ s/Manufacturer://g;
                $dmidecode[$i+2] =~ s/Product Name://g;
                $mainboard_memory_info{'mainboard'}{'manufacture'} = $dmidecode[$i+1];
                $mainboard_memory_info{'mainboard'}{'name'} = $dmidecode[$i+2];
            }
            if($dmidecode[$i] =~ /^\s*Memory Module Information/i) {
                $dmidecode[$i+1] =~ /^\s+(\S+)\s+(\S+)\s+(.+)$/i;
                $module = $3;
                $module =~ s/\W/-/g;
                chomp($module);
            }
            if(($dmidecode[$i] =~ /^\s+Installed Size:/i)  && ($module =~ /\S+/)) {
                $module =~ s/#/_/;
                $dmidecode[$i] =~ s/Installed Size://g;
                $mainboard_memory_info{'memory'}{$module} = $dmidecode[$i];
                $mainboard_memory_info{'memory'}{$module} =~ s/^\s+//;
                chomp($mainboard_memory_info{'memory'}{$module});
                $module = "";
            }
        }
        if (!defined $mainboard_memory_info{'memory'}) {
            for (my $i = 0; $i < @dmidecode; $i++){
                if($dmidecode[$i] =~ /^\s*Memory Device/i) {
                    my $bank = $dmidecode[$i+9];
                    $bank =~ /Bank Locator:\s+(.*)/;
                    $bank = $1;
                    next if !$bank;
                    $bank =~ s/\s//g;
                    $bank =~ s/[\s\.\/\\_]/-/g;
                    my $locator = $dmidecode[$i+8];
                    $locator =~ /Locator:\s+(.*)/;
                    $locator = $1;
                    next if !$locator;
                    $locator =~ s/\s//g;
                    $locator =~ s![\s./\\_#]!-!g;
                    my $size = $dmidecode[$i+5];
                    $size =~ /Size:\s+(.*)/;
                    $size = $1;
                    next if !$size;
                    $size =~ s/\s*MB\s*//g;
                    chomp($size);
                    if ($bank . $locator ne "") {
                        $mainboard_memory_info{'memory'}{$bank . "-" . $locator} = $size;
                    }
                }
            }
        }
        $mainboard_memory_info{'mainboard'}{'manufacture'} =~ s/^\s+//;
        $mainboard_memory_info{'mainboard'}{'name'} =~ s/^\s+//;
        chomp($mainboard_memory_info{'mainboard'}{'manufacture'});
        chomp($mainboard_memory_info{'mainboard'}{'name'});
    } else {
        $mainboard_memory_info{'mainboard'}{'manufacture'} = "dmidecode not installed";
        $mainboard_memory_info{'mainboard'}{'name'} = "dmidecode not installed";
    }
    return %mainboard_memory_info;
}

sub has_raid {
    my $dmesg = `cat /var/log/dmesg`;
    return ((-e "/proc/mdstat" && `grep md /proc/mdstat` ne "") ||
            ($dmesg =~ m/3w-xxxx: scsi/) ||
            (`lspci -d 1000: 2>&1` ne "") ||
            ($dmesg =~ m/scsi. : Found a 3ware/) ||
            ($dmesg =~ m/3w-9xxx: scsi.: Found/) ||
            ($dmesg =~ m/LSISAS1064 A3/) ||
            ($dmesg =~ m/Mylex AcceleRAID 160 PCI RAID Controller/));
}

sub get_scsi_disk_capacity {
    my $device = shift;
    my $capacity = "0";
    open my $FP, "fdisk -l $device |" or return "0";
    while (my $line = <$FP>) {
        next unless $line =~ /^Disk\s+$device:\s+([^,]+)/;
        $capacity = $1;
        $capacity =~ s/\s//g;
        $capacity =~ s/GB$//g;
        last;
    }
    return "0" unless close $FP;
    return $capacity;
}

sub get_hdd_info_scsi {
    return () if has_raid();
    my $hdd_info = shift;
    open my $FP, "/proc/scsi/scsi" or return ();
    chomp(my $scsi = join('', <$FP>));
    close $FP;
    my @letters = ('a'..'z');
    while ($scsi =~ /^\s*Vendor:\s*.+Model:\s*(.+?)\s*Rev:/mg) {
        my $l = shift @letters;
        $hdd_info->{'model'}{"sd$l"} = $1;
        $hdd_info->{'capacity'}{"sd$l"} = get_scsi_disk_capacity("/dev/sd$l");
    }
}

sub get_hdd_info {
    my %hdd_info = ();
    my $ide = `ls /proc/ide`;
    my @ide = split(/\s+/, $ide);
    foreach (@ide) {
        if (/^hd/) {
            $ide = $_;
            if (-e "/proc/ide/$ide/model") {
                open(FILE, "/proc/ide/$ide/model");
                while (<FILE>) {
                    chomp($_);
                    $hdd_info{'model'}{$ide} = $_;
                }
                close(FILE);
            } else {
                $hdd_info{'model'}{$ide} = "";
            }
            if (-e "/proc/ide/$ide/capacity") {
                open(FILE, "/proc/ide/$ide/capacity");
                while (<FILE>) {
                    chomp($_);
                    $hdd_info{'capacity'}{$ide} = sprintf("%d",$_*512/1000000000);
                }
                close(FILE);
            }  else {
                $hdd_info{'capacity'}{$ide} = ""
            };
        }
    }
    return %hdd_info;
}


send_mainboard_memory_info();
send_hdd_info();
EOF
    chown root.root "$DIR_SCRIPTS_HOUR/hwinfo-root.pl"
    chmod 750 "$DIR_SCRIPTS_HOUR/hwinfo-root.pl"
}

# 
# Generate /scripts/min/hddinfo.pl file
function generate_hddinfo {
    echo "Generating $DIR_SCRIPTS_MIN/hddinfo.pl..."
    cat << EOF > $DIR_SCRIPTS_MIN/hddinfo.pl
#! /usr/bin/perl
# version: $VERSION ($RELEASE_DATE)

\$ENV{"LC_ALL"} = "POSIX";

EOF
    cat <<'EOF' >> $DIR_SCRIPTS_MIN/hddinfo.pl
use strict;

sub send_hdd_status {
    chomp(my $ide = `ls /proc/ide`);
    chomp(my @status = `\/bin\/dmesg \| grep -i \"error\\\|drive not ready\" \| grep -i \"\^hd\" \| cut -f 1 -d \":\" \| sort \| uniq`);
    my @ide = split(/\s+/, $ide);
    foreach $ide (@ide) {
        my $error = 0;
        if ($ide =~ /^hd/) {
            foreach (@status) {
                $error = 1 if $_ eq $ide;
            }
            if ($error == 1) {
                print "mHW_HDD_$ide\_status|ERROR\n";
            } else {
                print "mHW_HDD_$ide\_status|OK\n";
            }
        }
    }

    # check of scsi errors
    my $scsi_available = `grep '^Host:' /proc/scsi/scsi 2>/dev/null`;
    my $possible_error;
    if ($scsi_available) {
        open my $dmesg, "dmesg |" or die "Can't launch dmesg: $!";
        my $status = 'OK';
        while (<$dmesg>) {
            if (/Info fld=([^,]+), Deferred (\S+?): sense key (.+ Error)/) {
                $status = $3;
            }
            if (/^sd.: .+?: sense key: (.+ Error)/) {
                $status = $1;
            }
            if (/^(sd.+?): *rw=\d+/) {
                $possible_error = $1;
                next;
            }
            if (defined($possible_error) && /^attempt to access beyond/) {
                $status = 'BAD_ACCESS';
            }
            $possible_error = undef;
        }
        print "mHW_HDD_scsi_status|$status\n";
    }
}

sub send_hdd_temp {
    my %hdd_temp = get_hdd_temp();
    foreach (keys %hdd_temp) {
        print "mINFO_HDD_$_\_temperature|" . $hdd_temp{$_} . "\n";
    }
}


sub get_hdd_temp {
    my %hdd_temp = ();
    my $ide = `ls /proc/ide`;
    my @ide = split(/\s+/, $ide);
    foreach (@ide) {
        if (/^hd/) {
            $ide = $_;
            my $temp = `hddtemp /dev/$ide 2>/dev/null`;
            if ($? == 0) {
                if ($temp =~ m/.*:.*:\s(\d+)/) {
                    $temp = $1;
                } else {
                    $temp = "-1";
                }
                $hdd_temp{$ide} = $temp;
            } else {
                $hdd_temp{$ide} = "-2";
            }
        }
    }
    return %hdd_temp;
}


send_hdd_status();
send_hdd_temp();
EOF
    chown root.root "$DIR_SCRIPTS_MIN/hddinfo.pl"
    chmod 750 "$DIR_SCRIPTS_MIN/hddinfo.pl"
}

# 
# Generate rtm.pl file
function generate_rtm {
    echo "Generating rtm.pl..."
    cat << EOF > $RTM_PL
#! /usr/bin/perl
# version: $VERSION ($RELEASE_DATE)

\$ENV{"LC_ALL"} = "POSIX";

EOF
    cat <<'EOF' >> $RTM_PL
use Fcntl;
use strict;
use Socket;
use Time::localtime;
use Symbol qw(gensym);
use IO::Select;
use POSIX qw(dup2);

# Check for root permission
if ($) != 0) {
    die "You are not a root!";
}

# Version of script
EOF
    echo "my \$version = '$VERSION';" >> $RTM_PL
    echo "my \$release_date = '$RELEASE_DATE';" >> $RTM_PL
    cat <<'EOF' >> $RTM_PL

# at this hour all information will be send
my $HOUR = 2;

# get uptime
open(FILE, "/proc/uptime") || die("Cannot open /proc/uptime");
my $uptime = <FILE>;
close(FILE);
$uptime =~ /^(\d+)/;
$uptime = $1;

my $script_name = $0;
# get basename of the script
$script_name =~ s/(^.*\/)//;

EOF
    echo "my \$base_dir = '$DIR';" >> $RTM_PL
    echo "my \$scripts_dir_daily = '$DIR_SCRIPTS_DAILY';" >> $RTM_PL
    echo "my \$scripts_dir_hour = '$DIR_SCRIPTS_HOUR';" >> $RTM_PL
    echo "my \$scripts_dir_min = '$DIR_SCRIPTS_MIN';" >> $RTM_PL
    echo "my \$rtm_update_ip = '$RTM_UPDATE_IP';" >> $RTM_PL
    cat <<'EOF' >> $RTM_PL

chomp(my @scripts_daily = `/bin/ls -1 $scripts_dir_daily`);
chomp(my @scripts_hour = `/bin/ls -1 $scripts_dir_hour`);
chomp(my @scripts_min = `/bin/ls -1 $scripts_dir_min`);

my $env_path = $ENV{'PATH'};
$ENV{'PATH'} = "/usr/local/sbin:/usr/local/bin:$env_path";

# global variable used to report errors from failed scripts
my $script_error = 0;

# determine rtm server ip from mrtg config
my $ipfile = "$base_dir/etc/rtm-ip";
open FP, "$ipfile" or die("failed to open '$ipfile' for reading: $!");
chomp(my $destination_ip = <FP>);
close FP;
if ($destination_ip !~ /^\d+\.\d+\.\d+\.\d+$/) {
    die "failed to read destination ip from '$ipfile': invalid ip: $destination_ip";
}

my $LOCK_FILE = "/var/lock/rtm.flock";
lockProcess();

my $TIMEOUT = 45;
my $MAX_UDP_BUFFER_SIZE = 200;
my $udp_buffer = '';

my $tm = localtime(time);
my $hour = $tm->hour;
my $min = $tm->min;

my @scripts_to_run = ();

# per minute data
push @scripts_to_run, map { "$scripts_dir_min/$_" } @scripts_min;

# hourly data
if ((scalar @ARGV == 0) or (($min >= 0) && ($min <= 5)) or $uptime < 900) {
    send_info("hINFO_uptime|" . $uptime);
    push @scripts_to_run, map { "$scripts_dir_hour/$_" } @scripts_hour;
}

# daily data
if (scalar @ARGV == 0 || (($hour eq $HOUR || $uptime < 900) && $min % 10 == 0)) {
    send_info("dINFO_RTM_version|" . $version);
    push @scripts_to_run, map { "$scripts_dir_daily/$_" } @scripts_daily;
}

# update rtm-ip daily
if (@ARGV > 0 && $hour eq $HOUR && $ARGV[0] == $min) {
    system("$rtm_update_ip &");
}

# run collected scripts in separate processes
my $read_set = IO::Select->new();
my %scripts_output = ();
foreach my $script (@scripts_to_run) {
    my $P_STDOUT_READ = gensym();
    my $P_STDOUT_WRITE = gensym();
    my $P_STDERR_READ = gensym();
    my $P_STDERR_WRITE = gensym();
    pipe $P_STDOUT_READ, $P_STDOUT_WRITE or die "pipe(): $!";
    pipe $P_STDERR_READ, $P_STDERR_WRITE or die "pipe(): $!";
    my @stats = stat($script);
    my $uid =  $stats[4];

    my $pid = fork();
    die "cannot fork: $!" if $pid < 0;
    if ($pid == 0) {
        if($uid > 0) {
            my $gid =  $stats[5];
            drop_priv($uid, $gid)
        }

        dup2(fileno($P_STDOUT_WRITE), 1) or die "dup2(): $!";
        dup2(fileno($P_STDERR_WRITE), 2) or die "dup2(): $!";
        close $P_STDOUT_READ;
        close $P_STDERR_READ;
        close $P_STDOUT_WRITE;
        close $P_STDERR_WRITE;
        my $error = "timeout";
        my $ok = eval {
            local $SIG{ALRM} = sub { die; };
            alarm($TIMEOUT);
            system($script);
            if ($? == -1) {
                $error = "failed to execute '$script': $!";
                die;
            }
        };
        if (!defined($ok)) {
            print STDERR "$error";
            exit 1;
        }
        exit;
    }
    close $P_STDOUT_WRITE;
    close $P_STDERR_WRITE;
    $read_set->add($P_STDOUT_READ);
    $read_set->add($P_STDERR_READ);
    $scripts_output{$pid} = { 'script' => $script,
                              'stdout' => $P_STDOUT_READ,
                              'stderr' => $P_STDERR_READ,
                              'error' => [],
    };
}

# wait for all scripts to complete
while (my @fds = $read_set->can_read()) {
    foreach my $fd (@fds) {
        my $slot;
        foreach my $s (values %scripts_output) {
            if ($s->{'stdout'} == $fd || $s->{'stderr'} == $fd) {
                $slot = $s;
                last;
            }
        }
        unless (defined($slot)) {
            warn "FATAL: got event on unknown file descriptor!";
            $read_set->remove($fd);
            close $fd;
            next;
        }
        my $line = <$fd>;
        if (!$line) {
            $read_set->remove($fd);
            close $fd;
            next;
        }
        chomp($line);
        if ($fd == $slot->{'stderr'}) {
            push @{$slot->{'error'}}, $line;
            print STDERR "$line\n";
        } else {
            send_info($line);
        }
    }
}
while (1) {
    my $pid = waitpid(-1, 0);
    last unless $pid > 0;
    $scripts_output{$pid}->{'status'} = $? >> 8;
}

# find scripts which returned error
foreach my $slot (values %scripts_output) {
    next if $slot->{'status'} == 0;
    $slot->{'script'} =~ m!/([^/]+?)$ !;
    my $script_name = $1;
    my $stderr = join ' ', map { chomp; $_ } @{$slot->{'error'}}; # perl sucks
    if (length $stderr > 20) {
        $stderr = substr($stderr, 0, 150);
        $stderr .= '...';
    }
    chomp($stderr);
    $script_error = "1 $script_name $stderr";
    # TODO: it currently sends errors for the first failed script
    last;
}

send_info("mINFO_RTM_status|$script_error");

unlockProcess();
exit 0;


sub flush_info {
  return if length ($udp_buffer) == 0;
  my $port = 6100 + int(rand(100));

  my $ok = eval {
    local $SIG{ALRM} = sub { print "rtm timeout\n"; die; };
    alarm(10);

    my $proto = getprotobyname('udp');
    socket(Socket_Handle, PF_INET, SOCK_DGRAM, $proto);
    my $iaddr = gethostbyname($destination_ip);
    my $sin = sockaddr_in("$port", $iaddr);
    send(Socket_Handle, $udp_buffer, 10, $sin);
    print $udp_buffer;
    alarm(0);
  };
  if (!defined($ok)) {
    $script_error = "1 send_info() rtm timeout";
    warn "error: $@\n";
  }
  $udp_buffer = '';
}

sub send_info {
  my $message = shift;
  $message = "rtm $message\n";

  if(length($message) > $MAX_UDP_BUFFER_SIZE and length($udp_buffer) == 0){
    $udp_buffer = $message;
    flush_info();
  }elsif(length($message) + length($udp_buffer) >= $MAX_UDP_BUFFER_SIZE){
    flush_info();
  }

  $udp_buffer .= $message;
}

sub drop_priv {
    my ($uid, $gid) = @_;

    # set EGID
    $) = "$gid $gid";
    # set EUID
    $> = $uid + 0;
    if ($> != $uid) {
        die "Can't drop EUID.";
    }
}

sub lockProcess {
    my $pid = $$;

    if (-e "$LOCK_FILE") {
        open(LOCKFILE, $LOCK_FILE) or die "Impossible to open lock file: $LOCK_FILE !!!";
        my $lockPID=<LOCKFILE> || "";
        close(LOCKFILE);

        if ($lockPID !~ m/^\d+$/ ) {
            warn("There is no PID in lock. Something is broken...");
            exit 1;
        } elsif (-e "/proc/$lockPID") {
            exit 0;
        }
        warn("There is a lock file $LOCK_FILE, but no process for it. Overwritting lock file");
    }

    unlink($LOCK_FILE); # in case it's a symlink, sysopen below would refuse to open it, and we would always die()
    # open for writing, create file if it doesn't exist, truncate it if it does, never follow symlinks but fail instead:
    sysopen(LOCKFILE, $LOCK_FILE, O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW, 0600) or die "Impossible to open lock file for writting: $LOCK_FILE !!!";

    print LOCKFILE $pid;
    close(LOCKFILE);
}


sub unlockProcess {
    unlink($LOCK_FILE);
}
EOF
    chown root.root "$RTM_PL"
    chmod 750 "$RTM_PL"
}

# 
# Generate rtm-update-ip.sh file
function generate_rtm_update_ip {
    echo "Generating rtm-update-ip.sh..."
    cat << EOF > $RTM_UPDATE_IP.tmp
#! /bin/bash
# version: $VERSION ($RELEASE_DATE)

LC_ALL=POSIX

EOF
    cat <<'EOF' >> $RTM_UPDATE_IP.tmp
EOF
    echo "DIR='$DIR'" >> $RTM_UPDATE_IP.tmp
    cat <<'EOF' >> $RTM_UPDATE_IP.tmp

# main interface from route:
mainif=`route -n | grep "^0.0.0.0" | awk '{print $8}' | tail -1`

if test -n "$mainif"; then
	ips=`ifconfig $mainif | awk 'NR == 2 { print $2 }' | cut -f2 -d':' | egrep '[0-9]+(\.[0-9]+){3}'`
else
	for iface in 'eth0' 'eth1'; do
		ips=`ifconfig $iface 2>/dev/null | awk 'NR == 2 { print $2 }' | cut -f2 -d':' | egrep '[0-9]+(\.[0-9]+){3}'`
		if test -n "$ips"; then break; fi;
	done;
fi;

arpa=`echo "$ips" | sed "s/\./ /g" | awk '{print $3"."$2"."$1}'`;
ip=`host -t A mrtg.$arpa.in-addr.arpa $DNSSERVER 2>/dev/null | tail -n 1 | sed -ne 's/.*[\t ]\([0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p'`
if [ -z "$ip" ]; then
  echo "No IP from OVH network or couldn't define MRTG server! Please contact OVH support."
  exit 1;
fi
echo $ip > "$DIR/etc/rtm-ip"

EOF
    chown root.root "$RTM_UPDATE_IP.tmp"
    chmod 750 "$RTM_UPDATE_IP.tmp"
    mv "$RTM_UPDATE_IP.tmp" "$RTM_UPDATE_IP"
}

function lock_process {
    if [ -e "$lockfile" ]; then
        lockpid=`cat "$lockfile"`
        if [ -e "/proc/$lockpid" ]; then
            echo "there seems to be stale $scriptname process running. check \"ps aux | grep $scriptname\"" >&2
            exit 1;
        fi
        echo "Lock $lockfile with pid $lockpid exist for script $scriptname but no process not exist, replaced by new one!!" >&2
        echo $$ > "$lockfile"
    fi
    echo $$ > "$lockfile.$$"
    mv "$lockfile.$$" "$lockfile"
}

function unlock_process {
    rm -f "$lockfile"
}

function wait_for_lock {
    echo "Waiting for finish rtm running from CRON"
    for i in `seq 1 1 30`; do
        if [ -e "$lockfile" ]; then
            echo -n "."
            sleep 2
        else
            echo -e "\nFinished."
            break
        fi
    done
}

# 
# RTM installation code

lockfile='/tmp/rtm.flock'
if [ -e "$lockfile" ]; then
    wait_for_lock
fi
lock_process

# Generate selected scripts
for script in $SCRIPTS_TO_INSTALL; do
    generate_$script
done
generate_rtm_update_ip
generate_rtm

unlock_process

if [ -e "$RTM_SH" ];then
    mv $RTM_SH $RTM_SH.old
fi
ln -s $RTM_PL $RTM_SH

rm -rf /rpms

let minute=$RANDOM%60
# treat dillo cron in a special way
is_dillo=`crond --version 2>/dev/null | grep dcron`
if [ -e /etc/slackware-version -a ! -z "$is_dillo" ]; then
    CRONTAB=/var/spool/cron/crontabs/root
    CRONTABLINE='*/1 * * * * '$RTM_SH' '$minute' > /dev/null 2> /dev/null'
else
    CRONTAB=/etc/crontab
    CRONTABLINE='*/1 * * * * root '$RTM_SH' '$minute' > /dev/null 2> /dev/null'
fi
if [ -z "`cat $CRONTAB | grep \"$RTM_SH\"`" ]; then
  echo "$CRONTABLINE" >> $CRONTAB
else
    perl -pe 's!>/dev/null!> /dev/null!g' -i "$CRONTAB"
fi

# List entries in crontab
echo ""
echo "Crontab entries:"
cat $CRONTAB
sleep 2
echo ""
# restarting CRON
for i in `seq 1 1 5` ; do
  echo "Restarting CRON. Try $i"
  if [ -x "/etc/rc.d/init.d/crond" ];then
    killall -9 crond
    screen -d -m /etc/rc.d/init.d/crond restart
  elif [ -x "/etc/init.d/cron" ];then
    killall -9 cron
    screen -d -m /etc/init.d/cron restart
  elif [ -x "/etc/init.d/crond" ];then
    killall -9 crond
    screen -d -m /etc/init.d/crond restart
  elif [ -x "/etc/rc.d/init.d/cron" ];then
    killall -9 cron
    screen -d -m /etc/rc.d/init.d/cron restart
  elif [ -e /etc/slackware-version ]; then
    killall -9 crond
    /usr/sbin/crond -l10 >>/var/log/crond 2>&1
  elif [ -x /etc/init.d/vixie-cron ]; then
      /etc/init.d/vixie-cron restart
  else
    echo "WARNING: Didn't find any method of restarting cron on your distribution!" >&2
  fi
  sleep 2
  if [ -z "`ps aux | grep -v grep | grep cron 2>/dev/null`" ]; then
    echo "Cron didn't start."
  else
    break
  fi
done

if [ -z "`ps aux | grep -v grep | grep cron 2>/dev/null`" ]; then
  echo "Please check it!"
  sleep 10
else
  echo "CRON restarted succefully."
  sleep 2
fi

echo ""
echo "NOTICE:"
echo "in $DIR_SCRIPTS_MIN/check.pl you can add more check that you are interested to monitor. The form should be:"
echo "When everything is fine:"
echo "CHECK_vm|"
echo "CHECK_oops|"
echo "On error:"
echo "CHECK_vm|1"
echo "CHECK_oops|1"
echo
echo "For example:"
echo "# $DIR_SCRIPTS_MIN/check.pl"
$DIR_SCRIPTS_MIN/check.pl
echo ""
echo "Sending all informations:"

$RTM_SH

# Local variables:
# page-delimiter: "^# *\f"
# sh-basic-offset: 4
# End:

