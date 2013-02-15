#!/bin/bash
#
# Install and upgrade software packages on selected hosts with mcollective
# Copyright (c) Nick Sandru <nick@sandesnet.com>
# License: Creative Commons
#
# Actions:
#   Install and upgrade software packages with mcollective on the selected hosts
#   Check the software packages' status on the selected hosts
#
# Optional actions:
#   Install/upgrade in batched mode (selectable number of servers at a time)
#     NOTE: the batched mode is not available with mcollective version 1
#   Stop selected services before each install/upgrade batch and start them thereafter
#   Refresh (restart) selected services after the install/upgrade run on each server
#   Verify the installed packages versions after the install/upgrade:
#     The version verification is done 5 seconds after the last batch, then at 5 seconds
#     intervals until all servers have the same version of the package(s) or the verify
#     timeout expires.
#   Detailed or succint output
#   Status mode displays the status of selected packages on selected hosts
#
# Usage:
#   package_upgrade.sh [options] --host=hostpat[,hostpat[,...]] package[.version] [package[.version]]...
#
# Mandatory parameter:
#   --host=hostpat[,hostpat[,...]]    - list of hostname patterns (host names, fqdns, wildcards and regexes)
#                                       Selection of hosts where the packages have to be installed or upgraded
# Options:
#   --pause=service[,service[,...]]   - services to be stopped before and started after the run
#   --refresh=service[,service[,...]] - services to be refreshed/restarted after the run
#   --timeout=seconds                 - runtime limit
#                                       default: 2 seconds
#   --verify=(true|yes|false|no)      - verify the version of packages after installation
#                                       forced to false if no version is specified
#                                       default: true if package versions are specified
#                                                false otherwise
#   --verifytimeout=seconds           - version verification time limit
#                                       default: 120 seconds
#   --downgrade                       - enable downgrade of packages
#                                       The selected packages are uninstalled before the specified versions are
#                                       installed
#   --verbose                         - verbose output
#   --quiet                           - no output
#   --status                          - display the status of selected packages on selected hosts
#   --help                            - display the usage screen and exit
#
# Options for mcollective version 2:
#   --batch=agents[,pause]            - agents - number of server agents running simultaneously
#                                       default: 0 (agents run at the same time on all servers)
#                                       pause  - number of seconds to pause after each batch
#                                       default: 1 second
#
# Exit codes:
#   0 - Succesfull run - packages installed/upgraded on all selected servers
#   1 - Incorrect or missing parameters
#   2 - Package installs/upgrades failed on some or all selected servers
#   3 - Version verification failed on some or all selected servers
#
# Revision history:
#  Feb 2, 2013 - Initial version for use with Mcollective 1.2.x
#

export PATH=/opt/puppet/bin:/usr/local/bin:/bin:/usr/bin:/var/lib/peadmin/bin

# Defaults
MCOUSER=peadmin
BATCH=0
BATCHINT=1
BATCHSPEC=f
DOWN=f
TIMEOUT=2
TIMESPEC=f
VERIFY=f
VERTIMEOUT=120
VERIFSPEC=f
VERBOSE=f
QUIET=f
PING=f
USAGEMSG=f
HOSTSPEC=f
PAUSE=f
REFRESH=f
INVARG=f
MISSARG=f
PKGSPEC=f
STATUS=f

usage()
{
(echo Usage: $0 '[options] --host=hostpat[,hostpat[,...]] package[.version] [package[.version]]...'
cat << EOF
 
  Mandatory parameter:
    --host=hostpat[,hostpat[,...]]    - list of hostname patterns (host names, fqdns, wildcards and regexes)
                                        Selection of hosts where the packages have to be installed or upgraded
  Options:
    --pause=service[,service[,...]]   - services to be stopped before and started after the run
    --refresh=service[,service[,...]] - services to be refreshed/restarted after the run
EOF
test 0$BATCHSW -gt 0 && {
cat << EOF
    --batch=agents[,pause]            - agents - number of server agents running simultaneously
                                        default: 0 (agents run at the same time on all servers)
                                        pause  - number of seconds to pause after each batch
                                        default: 1 second
EOF
}
cat << EOF
    --timeout=seconds                 - runtime limit
                                        default: 2 seconds
    --verify=(true|yes|false|no)      - verify the version of packages after installation
                                        forced to false if no version is specified
                                        default: true if package versions are specified
                                                 false otherwise
    --verifytimeout=seconds           - version verification time limit
                                        default: 120 seconds
    --downgrade                       - enable downgrade of packages
    --verbose                         - verbose output
    --quiet                           - no output
    --status                          - display the package status on the selected hosts
    --help                            - display this usage screen and exit
 
Examples:
  $0 --host=katmai --status httpd
  $0 --host=katmai.sandesnet.net --status httpd
  $0 --host=/^katmai/ --pause=httpd --verify=true --downgrade --verbose httpd.2.2.3-33
  $0 --host=/^katmai*/ --refrresh=httpd --verify=true --downgrade --quiet httpd.2.2.3-33
EOF
)
}

optarg()
{
  echo $1 | cut -f2 -d=
}

optbool()
{
  BOOLVAL=`echo $1 | cut -f2 -d=`
  case $BOOLVAL in
    true|t|yes|y)
      echo 't'
      ;;
    false|f|no|n)
      echo 'f'
      ;;
    *)
      echo 'e'
      ;;
  esac
}

optdec()
{
  test "`echo $1 | cut -f2 -d= | tr -d '[0-9]'`" != "" && {
    echo 'e'
  } || {
    echo $1 | cut -f2 -d=
  }
}

optdeclist()
{
  test "`echo $1 | cut -f2 -d= | tr -d '[0-9,]'`" != "" && {
    echo 'e'
  } || {
    echo $1 | cut -f2 -d=
  }
}

# Test whether the user is $MCOUSER
test `whoami` != $MCOUSER && {
  echo "$0 must be run as user $MCOUSER"
  exit 1
}

# Test whether the mco rpc has the --batch parameter
BATCHSW=`mco rpc --help | grep ' --batch ' | wc -l`

while [ $1 ] ; do
  test $PKGSPEC = 'f' && {
    case $1 in
      # --verbose and --quiet are mutually exclusive
      --verbose)
        test $VERBOSE = 't' -o $QUIET = 't' && INVARG=t
        VERBOSE=t
        ;;
      --quiet)
        test $QUIET = 't' -o $VERBOSE = 't' && INVARG=t
        QUIET=t
        ;;
      # --downgrade and --status are mutually exclusive
      --downgrade)
        test $DOWN = 't' -o $STATUS = 't' && INVARG=t
        DOWN=t
        ;;
      --status)
        test $STATUS = 't' -o $DOWN = 't' -o $VERIFY = 't' -o $PAUSE = 't' -o $REFRESH = 't' && INVARG=t
        STATUS=t
        ;;
      --help)
        USAGEMSG=t
        break
        ;;
      --host=*)
        test $HOSTSPEC = 'f' && HOSTLIST="`optarg $1`"
        test $HOSTSPEC = 't' && HOSTLIST="$HOSTLIST,`optarg $1`"
        HOSTSPEC=t
        ;;
      # --verify and --status are mutually exclusive
      --verify=*)
        test $VERIFSPEC = 't' -o $STATUS = 't' && INVARG=t
        VERIFSPEC=t
        VERIFY=`optbool $1`
        test $VERIFY = 'e' && INVARG=t
        ;;
      --verifytimeout=*)
        VERTIMEOUT=`optdec $1`
        test $VERTIMEOUT = 'e' && INVARG=t
        ;;
      --timeout=*)
        test $TIMESPEC = 't' && INVARG=t
        TIMEOUT=`optdec $1`
        test $TIMEOUT = 'e' && INVARG=t
        TIMESPEC=t
        ;;
      # --batch is only available with mcollective V2
      --batch=*)
        test $BATCHSPEC = 't' -o $BATCHSW -eq 0 && INVARG=t
        BATCH=`optdec $1`
        test $BATCH = 'e' && {
          BATCH=`optdeclist $1 | cut -f1 -d,`
          BATCHINT=`optdeclist $1 | cut -f2 -d,`
        }
        BATCHSPEC=t
        ;;
      # --pause and --status are mutually exclusive
      --pause=*)
        test $STATUS = 't' && INVARG=t
        test $PAUSE = 'f' && PAUSELIST="`optarg $1`"
        test $PAUSE = 't' && PAUSELIST="$PAUSELIST,`optarg $1`"
        PAUSE=t
        ;;
      # --refresh and --status are mutually exclusive
      --refresh=*)
        test $STATUS = 't' && INVARG=t
        test $REFRESH = 'f' && REFRESHLIST="`optarg $1`"
        test $REFRESH = 't' && REFRESHLIST="$REFRESHLIST,`optarg $1`"
        REFRESH=t
        ;;
      *)
        PKGSPEC=t
        ;;
    esac
  }
  test $PKGSPEC = 't' && {
    case $1 in
      -*)
        INVARG=t
        ;;
      *)
        PKGLIST="$PKGLIST $1"
        ;;
    esac
  }
  test $INVARG = 't' && break
  test "$1" = '--help' && break
  shift
done
test $USAGEMSG = 'f' -a $INVARG = 'f' && {
  test $HOSTSPEC = 'f' -o $PKGSPEC = 'f' && {
    MISSARG=t
    INVARG=f
  }
}
test $INVARG = 't' && echo "$0: Invalid or duplicate parameter"
test $MISSARG = 't' && echo "$0: Missing parameter"
test $MISSARG = 't' -o $INVARG = 't' -o $USAGEMSG = 't' && {
  usage
  test $MISSARG = 't' -o $INVARG = 't' && exit 1
  exit 0
}

# Set the verbose/quiet flags
test $VERBOSE = 't' && VFLG='-v'
test $QUIET = 't' && {
  VFLG='-q'
}

# Install/upgrade/downgrade/check status
touch /tmp/mco-$$.out
for HOSTPAT in `echo $HOSTLIST | tr ',' ' '` ; do
  test $QUIET = 'f' && {
    echo;echo "=== $HOSTPAT ==="
  }
# Determine whether the host pattern is a hostname or a fully-qualified-domain-name
  test "$HOSTPAT" = `echo $HOSTPAT | cut -f1 -d.` && {
    HFACT=hostname
  } || {
    HFACT=fqdn
  }
  for PKG in $PKGLIST ; do
# Stop listed services
    test $PAUSE = 't' && {
      for SERVICE in $PAUSELIST ; do
        test $QUIET = 'f' && {
          echo;echo "...Stopping service $SERVICE";echo
          mco rpc --np $VFLG -F "$HFACT=$HOSTPAT" service stop "service=$SERVICE" 2>>/tmp/mco-$$.out
        } || {
          mco rpc --np $VFLG -F "$HFACT=$HOSTPAT" service stop "service=$SERVICE" >/dev/null 2>>/tmp/mco-$$.out
        }
      done
      sleep 10
    }
# Check whether the version is specfied for the package
    PKGNAME=`echo $PKG | cut -f1 -d.`
    PKGFULL=$PKGNAME
    PKGHASVERS=`echo ${PKG}. | cut -f2- -d.`
    test "$PKGHASVERS" != "" && PKGFULL=$PKGNAME-`echo $PKG | cut -f2- -d.`
# Check status and skip the rest of the loop
    test $STATUS = 't' && {
      mco rpc --np $VFLG -F "$HFACT=$HOSTPAT" package status "package=$PKGFULL" 2>>/tmp/mco-$$.out
      continue
    }
# If downgrade is enabled delete the current versions of the packages
    test $DOWN = 't' && {
      test $QUIET = 'f' && {
        echo;echo "...Uninstalling package $PKGNAME before downgrade";echo
        mco rpc --np $VFLG -F "$HFACT=$HOSTPAT" package uninstall "package=$PKGNAME" 2>>/tmp/mco-$$.out
      } || {
        mco rpc --np $VFLG -F "$HFACT=$HOSTPAT" package uninstall "package=$PKGNAME" >/dev/null 2>>/tmp/mco-$$.out
      }
    # Wait for $VERTIMEOUT seconds until the packages to be downgraded are uninstalled on all hosts
      sleep 5
      test $QUIET = 'f' && {
        echo;echo "...Verifying that the $PKGNAME package has been uninstalled";echo
      }
      CNT=$VERTIMEOUT
      while [ `mco rpc --np -F "$HFACT=$HOSTPAT" package status "package=$PKGNAME" 2>>/tmp/mco-$$.out | grep ' Ensure: ' | grep -v ' absent' | wc -l` -gt 0 ] ; do
        sleep 5
        CNT=`expr $CNT - 5`
        test $CNT -lt 5 && break
      done
      test `mco rpc --np -F "$HFACT=$HOSTPAT" package status "package=$PKGNAME" 2>>/tmp/mco-$$.out | grep ' Ensure: ' | grep -v ' absent' | wc -l` -gt 0 && {
        echo "*** Downgraded package uninstall failed - $PKGNAME ***"
        cat /tmp/mco-$$.out | grep -v '^Determining the amount of hosts matching filter'
        rm -f /tmp/mco-$$.out
        exit 2
      }
    }
# Install the new package
    test $QUIET = 'f' && {
      echo;echo "...Installing package $PKGFULL";echo
      mco rpc --np $VFLG -F "$HFACT=$HOSTPAT" package install "package=$PKGFULL" 2>>/tmp/mco-$$.out
    } || {
      mco rpc --np $VFLG -F "$HFACT=$HOSTPAT" package install "package=$PKGFULL" >/dev/null 2>>/tmp/mco-$$.out
    }
# Verify the installed versions, they must be the same on all hosts
    sleep 5
    test $QUIET = 'f' && {
      echo;echo "...Verifying package $PKGFULL install";echo
    }
    CNT=$VERTIMEOUT
    while [ `mco rpc --np -F "$HFACT=$HOSTPAT" package status "package=$PKGNAME" 2>>/tmp/mco-$$.out | grep ' Ensure: ' | sort -u | wc -l` -gt 1 ] ; do
      sleep 5
      CNT=`expr $CNT - 5`
      test $CNT -lt 5 && break
    done
    test `mco rpc --np -F "$HFACT=$HOSTPAT" package status "package=$PKGNAME" 2>>/tmp/mco-$$.out | grep ' Ensure: ' | sort -u | wc -l` -gt 1 && {
      echo "*** Package verification failed - $PKGFULL ***"
      echo "Installed versions:"
      mco rpc --np -F "$HFACT=$HOSTPAT" package status "package=$PKGNAME" 2>>/tmp/mco-$$.out | grep ' Ensure: ' | cut -f2- -d: | sort -u
      cat /tmp/mco-$$.out | grep -v '^Determining the amount of hosts matching filter'
      rm -f /tmp/mco-$$.out
      exit 2
    }
# Verify that the installed version matches the requested version
    test $VERIFY = 't' && {
      test "$PKGHASVERS" != "" && {
        PKGVERS=`echo $PKG | cut -f2- -d.`
        test $QUIET = 'f' && {
          echo;echo "...Verifying that the installed package $PKGNAME has version $PKGVERS";echo
        }
        INSTVERS=`mco rpc --np -F "$HFACT=$HOSTPAT" package status "package=$PKGNAME" 2>>/tmp/mco-$$.out | grep ' Ensure: ' | sort -u | cut -f2- -d: | tr -d ' '`
        test "$PKGVERS" != "$INSTVERS" && {
          echo "*** Package verification failed - $PKGFULL ***"
          echo "Installed version $INSTVERS different from requested version $PKGVERS"
          cat /tmp/mco-$$.out | grep -v '^Determining the amount of hosts matching filter'
          rm -f /tmp/mco-$$.out
          exit 2
        }
      }
    }
    test $QUIET = 'f' && {
      echo;echo "=== Package $PKGFULL install successful ===";echo
    }
# Start services that have been stopped before the install
    test $PAUSE = 't' && {
      for SERVICE in $PAUSELIST ; do
        test $QUIET = 'f' && {
          echo;echo "...Starting service $SERVICE";echo
          mco rpc --np $VFLG -F "$HFACT=$HOSTPAT" service start "service=$SERVICE" 2>>/tmp/mco-$$.out
        } || {
          mco rpc --np $VFLG -F "$HFACT=$HOSTPAT" service start "service=$SERVICE" >/dev/null 2>>/tmp/mco-$$.out
        }
      done
    }
# Refresh listed services
    test $REFRESH = 't' && {
      for SERVICE in $REFRESHLIST ; do
        test $QUIET = 'f' && {
          echo;echo "...Refreshing service $SERVICE";echo
          mco rpc --np $VFLG -F "$HFACT=$HOSTPAT" service restart "service=$SERVICE" 2>>/tmp/mco-$$.out
        } || {
          mco rpc --np $VFLG -F "$HFACT=$HOSTPAT" service restart "service=$SERVICE" >/dev/null 2>>/tmp/mco-$$.out
        }
      done
    }
  done
done
rm -f /tmp/mco-$$.out
exit 0
